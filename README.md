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
| People | Buddy List for Discord, or the Discord web app | `https://discord.com/channels/@me` |
| Music | AOL Radio for Spotify, or YouTube Music | Spotify Web API, `https://music.youtube.com` |
| Pictures | AOL Pictures for the Mac Photos library | PhotoKit |
| Finance | Your bank | Set on first use |

Mail needs a one-time Google OAuth setup. See [docs/gmail.md](docs/gmail.md).
The keyword `gmail` opens Gmail on the web instead.

AOL Pictures asks for Photos access the first time it opens. It can view,
favorite, save, and mail pictures, and Upload Pictures adds files to the
library.

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

## Branding

Branding images live in the same two places as sounds. Git ignores them.

| File | Used for | Without it |
| --- | --- | --- |
| `Branding/signon-logo.png` | Sign On window logo | A plain AOL-OS wordmark |
| `Branding/titlebar-icon.png` | Title bar, Sign On window, toolbar logo and Dock icon | A white triangle |
| `Branding/Toolbar/<name>-active.png` and `-inactive.png` | Toolbar buttons | Tinted system symbols |

Toolbar names are `read`, `read-closed`, `write`, `im`, `people`, `safety`,
`settings`, `music`, `finance`, `pictures`, `expressions`, `buzzline`,
`remindme`, `greetings` and `moviefone`. Buttons show the inactive image while
signed off. Read shows `read` while unread mail is waiting and `read-closed`
otherwise.

Write Mail uses the same scheme for its side buttons: `sendnow`, `sendlater`,
`addressbook` and `print`.

## Notifications

The Mailbox keeps an IMAP IDLE connection open. New mail plays `gotmail` and
turns the Mailbox title bar orange.

Each web window replaces the page's Notification API. A notification from
Discord or Slack plays that service's sound and turns its title bar orange
until you open it. Turn on desktop notifications inside each service for this
to fire.

## Buddy List

The Buddy List shows your Discord friends in AIM style. It opens at sign on.
The keyword `buddy list` and the People button bring it back after you close
it.

The list reads friends and presence from the Discord web app, so People
Connection stays open. Sign in to Discord there once. Closing that window
minimizes it so the Buddy List keeps working.

Presence changes play these sounds:

| Change | Sound |
| --- | --- |
| Signs on, from any device | `buddyin` |
| Signs off | `buddyout` |
| Goes idle | `doorclose` |
| Comes back from idle | `dooropen` |

Do Not Disturb counts as signed on. A phone icon marks a friend who is online
only on the Discord mobile app.

Recent Buddies lists the people you last had a direct message with, online or
not. They do not have to be friends.

Right click a buddy and choose Hide from Buddy List to leave them out of every
group and silence their sounds. Their direct messages still open. Right click
the list and choose Show Hidden Buddy to bring someone back. Hidden buddies are
Discord user IDs under `hiddenBuddies` in the config file.

Double click a buddy to open an Instant Message window for your direct
messages with them. A new direct message opens its window and plays `imrcv`.
Return sends and plays `imsend`. Shift Return adds a line. The B, I, U, S and
code buttons wrap the selection in Discord markdown. Drop or paste images and
files on the window to attach them. Click the attachment list to clear it.
Attachments are capped at 10 MB, the Discord limit without Nitro.

Right click the list and choose Send Instant Message To for anyone you have an
open direct message with, friend or not.

Group Chats lists your group direct messages. Double click one to open a chat
window with its members on the right. It sends, receives and attaches files
the same way as an Instant Message window.

The bridge script is `Scripts.discordBridge` in
[DiscordScripts.swift](Sources/AOLOS/Discord/DiscordScripts.swift). It uses
the web client's internal stores, which Discord can change in any release.
When it cannot find them the Buddy List says so.

## Chat Rooms

Chat Rooms opens from the People button, the Community menu or the keyword
`chat rooms`. Your Discord servers are the categories and their text channels
are the rooms. Rooms with unread messages are bold. Enter a room to read its
recent history and chat. The list on the right shows who has spoken. Rooms do
not play sounds, but a room window turns orange when a message arrives while
it is in the background.

Voice channels show with a speaker and the people in them. Join Voice connects
the Discord window to that channel, and Leave Voice disconnects.

Replies show the message they answer above them. Reactions follow each
message and update live, with yours in blue. Right click a message to reply to
it, copy it, or send its author an Instant Message. Right click someone in a
chat's member list to IM them. Open conversations recheck Discord every 20
seconds for anything the live connection missed.

## Passwords

Sign on asks for Touch ID or the Mac password. Turn this off in Settings.

After a login form submits and the page navigates, AOL-OS offers to save the
login as an internet password in the login keychain. Saved logins fill in on
the next visit to the same https host. Keychain Access shows them under the
label `<host> (AOL-OS)`. Set `autofill` to `false` on a service to turn this
off for it.

## Limits

Discord has no supported API for personal messages. The Buddy List reads the
Discord web app's internal state instead. Discord's
[Terms of Service](https://discord.com/terms) forbid modifying or automating
the client, so this can put the account at risk. IM is the Slack web app.

Spotify playback depends on Spotify supporting DRM in WebKit. YouTube Music
does not need it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI-assisted work follows the
[AI contribution policy](docs/ai/README.md).
