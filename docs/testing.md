# Testing guide

Run the build and the tests before every pull request:

```sh
swift build
swift test
```

The build must pass without new warnings.

Then exercise the change in a running window:

```sh
make run
```

Describe the steps you took in the pull request. Name the service and the
window you tested.

Logic that does not need a window or a network belongs in a unit test under
`Tests/AOLOSTests`. Examples are IMAP response parsing, MIME decoding, address
handling, and keyword resolution.

Mail changes that touch the network need a manual check against a real Gmail
account. Name the account type in the pull request, either personal Gmail or
Workspace.
