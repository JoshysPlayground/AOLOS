# Usage

## Requirements

AOL-OS needs macOS 14 or later and a Swift 5.10 or later toolchain. Xcode or
the Command Line Tools provide the toolchain.

## Run

```sh
make run      # windowed, for development
make kiosk    # full screen with the Dock and menu bar hidden
make app      # builds build/AOL-OS.app
make install  # builds and copies AOL-OS.app to /Applications
```

AOL-OS can be the Mac's default web browser. Run `make install`, open AOL-OS
from Applications, and choose Settings > Make AOL-OS Your Browser. macOS asks
to confirm. Links clicked in other apps then open in a new browser window.
Links that arrive before sign on open once you sign on. Google and Spotify
sign in pages still open in your previous browser because Google blocks sign
in inside embedded web views.

Command Q exits. Command H hides the app. Command Tab still switches apps.

## Services

| Toolbar | Service | Source |
| --- | --- | --- |
| Read | Native Mailbox for Gmail | IMAP |
| Write | Native Write Mail window | SMTP |
| IM | Slack | `https://app.slack.com/client` |
| People | Buddy List for Discord, or the Discord web app | `https://discord.com/channels/@me` |
| Community menu | Facebook Messenger, also on the Buddy List | `https://www.facebook.com/messages/t/` |
| Music | AOL Radio for Spotify, or YouTube Music | Spotify Web API, `https://music.youtube.com` |
| Pictures | AOL Pictures for the Mac Photos library | PhotoKit |
| Finance | Your bank | Set on first use |

Mail needs a one-time Google OAuth setup. See [gmail.md](gmail.md).
Add more Gmail accounts in Settings. The Mailbox merges them with a badge per
account and an Account filter, and Write Mail gets a From menu.
The keyword `gmail` opens Gmail on the web instead.

AOL Pictures asks for Photos access the first time it opens. It can view,
favorite, save, and mail pictures, and Upload Pictures adds files to the
library.

AOL Radio needs a Spotify app ID. See [spotify.md](spotify.md). The
keyword `spotify web` opens the Spotify web player instead.

Web services live in `~/Library/Application Support/AOL-OS/config.json`. Each
service names a `profile`. Services with the same profile share cookies and
logins, so Gmail and YouTube Music sign in once through `google`.

The Keyword box accepts a service keyword, a web address, or a search.
A web address or a search opens in a new browser window.
Keywords are in the same config file.

## Windows

Every service opens in a child window inside the desktop. Windows drag by the
title bar, resize from any edge, and maximize with a double click. Minimized
windows sit along the bottom of the desktop. The Window menu cascades, tiles,
and lists open windows.

## Browsing

The mouse side buttons, Cmd+[ and Cmd+], and Cmd or Option with the arrow
keys go back and forward. The arrow keys pass through while a text field has
focus. Cmd+L selects the address box and F5 reloads.

A middle click or Cmd click on a link opens it in a new browser window. So does
a link that targets a new window. The new window uses the profile of the page
the link came from, so it stays signed in.

## Favorites

The heart in the nav bar, the Favorites toolbar button and Cmd+D save the
current page. Saved pages list under the Favorites button and the Favorites
menu. Manage Favorite Places renames, reorders and deletes them. The keyword
`favorites` opens it too. Favorites are stored under `favorites` in the config
file.

## Sounds

Each event plays a macOS system sound until a custom file replaces it. Put
files in `~/Library/Application Support/AOL-OS/Sounds/`, or in
`Resources/Sounds/` before `make app`. Name each file after its event. Event
names are the raw values of `SoundEvent` in
[SoundManager.swift](../Sources/AOLOS/SoundManager.swift).

Git ignores sound files. Supply your own.

## Branding

Branding images live in the same two places as sounds. Git ignores them.

| File | Used for | Without it |
| --- | --- | --- |
| `Branding/signon-logo.png` | Sign On window logo | A plain AOL-OS wordmark |
| `Branding/titlebar-icon.png` | Title bar, Sign On window, toolbar logo and Dock icon | A white triangle |
| `Branding/Toolbar/<name>-active.png` and `-inactive.png` | Toolbar buttons | Tinted system symbols |

Toolbar names are `read`, `read-closed`, `write`, `im`, `people`, `safety`,
`settings`, `music`, `finance`, `pictures`, `greetings` and `moviefone`.
The Entertainment button uses the `moviefone` images.
Buttons show the inactive image while signed off. Read shows `read` while
unread mail is waiting and `read-closed` otherwise.

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

The Buddy List shows your Discord friends, Slack direct message partners and
Facebook friends from Messenger in AIM style. Slack needs a one-time app setup. See [slack.md](slack.md).
It opens at sign on.
The keyword `buddy list` and the People button bring it back after you close
it.

The list reads friends and presence from the Discord web app, so People
Connection stays open. Sign in to Discord there once. Closing that window
minimizes it so the Buddy List keeps working.

Messenger works the same way from the Messenger window, which opens minimized
with the Buddy List. Sign in to Facebook there once. A Facebook friend counts
as signed on while Facebook shows them as active, and as idle for 15 minutes
after that. When more than one service is signed on, a small colored square on
each buddy icon shows its service.

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
IDs under `hiddenBuddies` in the config file. Slack IDs start with `slack:` and
Messenger IDs with `fb:`.

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

Messenger Instant Message and group chat windows send text only. Sending types
the message into the Messenger window and opens that chat there. The first time
a chat opens, the Messenger window opens it to load its history.

Facebook keeps the text of end-to-end encrypted chats sealed in the browser and
decrypts it only to draw the chat. AOL-OS reads that drawn text, so a new
message in an encrypted chat opens that chat in the Messenger window first.
Messages the Messenger window has not drawn, such as older history, show as a
note to open them in Messenger. Photos in encrypted chats show as `[photo]`.

The Messenger bridge script is `Scripts.messengerBridge` in
[MessengerScripts.swift](../Sources/AOLOS/Messenger/MessengerScripts.swift). It
reads the inbox database inside the Messenger web client, which Facebook can
change in any release.

The Discord bridge script is `Scripts.discordBridge` in
[DiscordScripts.swift](../Sources/AOLOS/Discord/DiscordScripts.swift). It uses
the web client's internal stores, which Discord can change in any release.
When it cannot find them the Buddy List says so.

## Chat Rooms

Chat Rooms opens from the People button, the Community menu or the keyword
`chat rooms`. Your Slack workspace and Discord servers are the categories and
their text channels are the rooms. Rooms with unread messages are bold. Enter a room to read its
recent history and chat. The list on the right shows who has spoken. Rooms do
not play sounds, but a room window turns orange when a message arrives while
it is in the background.

A message in a server that mentions you or one of your roles opens its room,
plays `imrcv` and names who mentioned you in the status bar. Mentions of
@everyone and @here do not.

Any other message in a room you do not have open also opens that room and plays
`imrcv`. Right click a server, a channel category or a room to mute it. A
muted room stays closed until someone mentions you, and muted rows show a
muted speaker. Muted IDs are kept under `mutedRooms` in the config file.

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

Messenger has no supported API for personal messages either. The Buddy List
reads and drives the Messenger web client, which Meta's
[Terms of Service](https://www.facebook.com/terms) also forbid automating.

Spotify playback depends on Spotify supporting DRM in WebKit. YouTube Music
does not need it.
