/// The Desktop OAuth client that ships with AOL-OS. Settings can override it per Mac.
/// Google's installed app guidance embeds the client secret in the app and does not treat it as secret:
/// https://developers.google.com/identity/protocols/oauth2
enum GoogleClient {
    static let id = ""
    static let secret = ""

    static var isConfigured: Bool { !id.isEmpty && !secret.isEmpty }
}
