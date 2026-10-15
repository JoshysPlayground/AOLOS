# Testing guide

Run the build before every pull request:

```sh
swift build
```

The build must pass without new warnings.

Then exercise the change in a running window:

```sh
make run
```

Describe the steps you took in the pull request. Name the service and the
window you tested.

Logic that does not need a window belongs in a unit test. Examples are config
decoding, keyword resolution, URL parsing, and unread count parsing. Add an
XCTest target when the first such test lands.
