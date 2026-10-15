# AOL-OS

AOL-OS is a full-screen macOS shell styled after America Online 9.0. Gmail,
Discord, Slack, YouTube Music, Spotify, and a bank site open as windows inside
one AOL frame, with AOL-style sign on, toolbar, and sounds.

## Requirements

AOL-OS needs macOS 14 or later and a Swift 5.10 or later toolchain. Xcode or
the Command Line Tools provide the toolchain.

## Run

```sh
make run      # windowed, for development
make kiosk    # full screen with the Dock and menu bar hidden
make app      # builds build/AOL-OS.app
```

Command Q exits. Command H hides the app. Command Tab still switches apps.

## Services

| Toolbar | Service | Source |
| --- | --- | --- |
| Read | Native Mailbox for Gmail | IMAP |
| Write | Native Write Mail window | SMTP |
| IM | Slack | `https://app.slack.com/client` |
| Chat | Discord | `https://discord.com/channels/@me` |
| Music | AOL Radio for Spotify, or YouTube Music | Spotify Web API, `https://music.youtube.com` |
| Finance | Your bank | Set on first use |

Mail needs a one-time Google OAuth setup. See [docs/gmail.md](docs/gmail.md).
The keyword `gmail` opens Gmail on the web instead.

AOL Radio needs a Spotify app ID. See [docs/spotify.md](docs/spotify.md). The
keyword `spotify web` opens the Spotify web player instead.

Web services live in `~/Library/Application Support/AOL-OS/config.json`. Each
service names a `profile`. Services with the same profile share cookies and
logins, so Gmail and YouTube Music sign in once through `google`.

The Keyword box accepts a service keyword, a web address, or a search.
Keywords are in the same config file.

## Windows

Every service opens in a child window inside the desktop. Windows drag by the
title bar, resize from any edge, and maximize with a double click. Minimized
windows sit along the bottom of the desktop. The Window menu cascades, tiles,
and lists open windows.

## Sounds

Each event plays a macOS system sound until a custom file replaces it. Put
files in `~/Library/Application Support/AOL-OS/Sounds/`, or in
`Resources/Sounds/` before `make app`. Name each file after its event. Event
names are the raw values of `SoundEvent` in
[SoundManager.swift](Sources/AOLOS/SoundManager.swift).

Git ignores sound files. Supply your own.

## Notifications

The Mailbox keeps an IMAP IDLE connection open. New mail plays `gotmail` and
turns the Mailbox title bar orange.

Each web window replaces the page's Notification API. A notification from
Discord or Slack plays that service's sound and turns its title bar orange
until you open it. Turn on desktop notifications inside each service for this
to fire.

## Passwords

Sign on asks for Touch ID or the Mac password. Turn this off in Settings.

After a login form submits and the page navigates, AOL-OS offers to save the
login as an internet password in the login keychain. Saved logins fill in on
the next visit to the same https host. Keychain Access shows them under the
label `<host> (AOL-OS)`. Set `autofill` to `false` on a service to turn this
off for it.

## Limits

Discord has no supported API for personal messages. Chat and IM are the
Discord and Slack web apps.

Spotify playback depends on Spotify supporting DRM in WebKit. YouTube Music
does not need it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI-assisted work follows the
[AI contribution policy](docs/ai/README.md).
