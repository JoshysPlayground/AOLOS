import AppKit
import AVFoundation
import Photos
import UniformTypeIdentifiers

struct PhotoAlbum: Equatable {
    enum Kind: Equatable { case all, smart, user }

    let id: String
    let title: String
    let kind: Kind
    let count: Int
    let collection: PHAssetCollection?
    let subtype: PHAssetCollectionSubtype?

    var isFavorites: Bool { subtype == .smartAlbumFavorites }
    var acceptsUploads: Bool { kind == .all || (collection?.canPerform(.addContent) ?? false) }

    static func == (a: PhotoAlbum, b: PhotoAlbum) -> Bool { a.id == b.id && a.count == b.count && a.title == b.title }
}

enum PhotoError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let reason): return reason
        }
    }
}

/// The Mac's Photos library through PhotoKit. Every callback is delivered on the main queue.
@MainActor
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (() -> Void)?

    private let images = PHCachingImageManager()
    private var observing = false

    static let allID = "all"
    static let maxMailBytes = 24 * 1024 * 1024
    private static let smartAlbums: [(PHAssetCollectionSubtype, String)] = [
        (.smartAlbumFavorites, "heart.fill"), (.smartAlbumRecentlyAdded, "clock"), (.smartAlbumVideos, "video"),
        (.smartAlbumSelfPortraits, "person.crop.square"), (.smartAlbumLivePhotos, "livephoto"),
        (.smartAlbumPanoramas, "pano"), (.smartAlbumScreenshots, "camera.viewfinder"),
    ]

    var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    var isAuthorized: Bool { status == .authorized || status == .limited }

    func authorize() async -> Bool {
        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        startObserving()
        return result == .authorized || result == .limited
    }

    func startObserving() {
        guard isAuthorized, !observing else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    static func symbol(for album: PhotoAlbum) -> String {
        if album.kind == .all { return "photo.on.rectangle" }
        if album.kind == .user { return "rectangle.stack" }
        return smartAlbums.first { $0.0 == album.subtype }?.1 ?? "rectangle.stack"
    }

    func albums() -> [PhotoAlbum] {
        guard isAuthorized else { return [] }
        var out = [PhotoAlbum(id: Self.allID, title: "All Pictures", kind: .all,
                              count: PHAsset.fetchAssets(with: nil).count, collection: nil, subtype: nil)]
        for (subtype, _) in Self.smartAlbums {
            guard let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { continue }
            let count = PHAsset.fetchAssets(in: c, options: nil).count
            guard count > 0 || subtype == .smartAlbumFavorites else { continue }
            out.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", kind: .smart,
                                  count: count, collection: c, subtype: subtype))
        }
        var user: [PhotoAlbum] = []
        for type in [PHAssetCollectionSubtype.albumRegular, .albumCloudShared] {
            let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: type, options: nil)
            for i in 0..<fetch.count {
                let c = fetch.object(at: i)
                user.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled Album", kind: .user,
                                       count: PHAsset.fetchAssets(in: c, options: nil).count, collection: c, subtype: type))
            }
        }
        user.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return out + user
    }

    /// Library-wide and smart albums list newest first. User albums keep the order set in Photos.
    func assets(in album: PhotoAlbum) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        if album.kind != .user { options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] }
        if let c = album.collection { return PHAsset.fetchAssets(in: c, options: options) }
        return PHAsset.fetchAssets(with: options)
    }

    @discardableResult
    func image(_ asset: PHAsset, size: NSSize, fast: Bool, _ done: @escaping (NSImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = fast ? .fast : .exact
        options.isNetworkAccessAllowed = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return images.requestImage(for: asset, targetSize: target, contentMode: fast ? .aspectFill : .aspectFit,
                                   options: options) { image, _ in
            DispatchQueue.main.async { done(image) }
        }
    }

    func cancel(_ request: PHImageRequestID) {
        images.cancelImageRequest(request)
    }

    func playerItem(_ asset: PHAsset, _ done: @escaping (AVPlayerItem?) -> Void) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        images.requestPlayerItem(forVideo: asset, options: options) { item, _ in
            DispatchQueue.main.async { done(item) }
        }
    }

    static func originalResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        for type in preferred {
            if let r = resources.first(where: { $0.type == type }) { return r }
        }
        return resources.first
    }

    /// Writes each original file into `folder`, adding a number when the name is taken.
    func saveOriginals(_ assets: [PHAsset], to folder: URL) async throws -> Int {
        var saved = 0
        for asset in assets {
            guard let resource = Self.originalResource(asset) else { continue }
            let url = Self.unusedURL(in: folder, name: resource.originalFilename)
            try await write(resource, to: url)
            saved += 1
        }
        return saved
    }

    /// Mail-ready copies. HEIC photos become JPEG so every mail client can open them.
    func mailAttachments(_ assets: [PHAsset]) async throws -> [MailAttachment] {
        var out: [MailAttachment] = []
        var total = 0
        for asset in assets {
            guard let resource = Self.originalResource(asset) else { continue }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let url = temp.appendingPathComponent(resource.originalFilename)
            try await write(resource, to: url)
            var data = try Data(contentsOf: url)
            var name = resource.originalFilename
            var type = UTType(resource.uniformTypeIdentifier) ?? UTType(filenameExtension: url.pathExtension) ?? .data
            if type.conforms(to: .heic) || type.conforms(to: .heif),
               let jpeg = NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                data = jpeg
                name = (name as NSString).deletingPathExtension + ".jpg"
                type = .jpeg
            }
            total += data.count
            guard total <= Self.maxMailBytes else {
                throw PhotoError.failed("Those pictures add up to more than Gmail's 25 MB limit. Pick fewer.")
            }
            out.append(MailAttachment(filename: name, mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data))
        }
        return out
    }

    func importFiles(_ urls: [URL], into album: PhotoAlbum?) async throws {
        let collection = album?.kind == .user ? album?.collection : nil
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for url in urls {
                let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
                if let p = request.placeholderForCreatedAsset { placeholders.append(p) }
            }
            if let collection, let change = PHAssetCollectionChangeRequest(for: collection) {
                change.addAssets(placeholders as NSArray)
            }
        }
    }

    /// Favorites the whole selection, or unfavorites it when every picture is already a favorite.
    func toggleFavorite(_ assets: [PHAsset]) async throws {
        let favorite = !assets.allSatisfy(\.isFavorite)
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets { PHAssetChangeRequest(for: asset).isFavorite = favorite }
        }
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    static func unusedURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}
