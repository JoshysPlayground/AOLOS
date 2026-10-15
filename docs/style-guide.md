# Style guide

AOL-OS is Swift 5 language mode on AppKit and WebKit. It targets macOS 14 and
later.

## Swift

- Use four spaces for indentation.
- Keep UI types on the main actor. AppKit views already are.
- Chrome views subclass `FlippedView` so frames use a top-left origin.
- Draw chrome in `draw(_:)` with colors and fonts from `Theme`. Do not
  hard-code a color that `Theme` already names.
- Route user actions through `Session`. Views expose closures and do not
  reach into other windows.
- Avoid force unwraps outside static literals.

## Web views

- Every service gets a data store through `DataStores.store(for:)`. Do not
  create a `WKWebsiteDataStore` directly.
- Page-world scripts may only shadow page APIs. Anything that touches saved
  credentials runs in `Scripts.autofillWorld`.
- Never pass a secret into `evaluateJavaScript` through string building. Use
  `callAsyncJavaScript` with arguments.

## Mail

- Protocol code lives in `Sources/AOLOS/Mail`. Network types are actors.
- IMAP commands go through `MailService`, which runs one at a time per
  connection.
- Message HTML renders with JavaScript off and remote loads blocked by
  `RemoteContentBlocker`.
- Strip CR and LF from any user text that lands in a mail header.

## Comments and prose

Follow [comments and prose](ai/comments-and-prose.md).
