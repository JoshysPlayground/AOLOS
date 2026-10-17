# Slack

Slack joins the Buddy List, Instant Message windows and Chat Rooms next to
Discord. AOL-OS talks to the Slack Web API with your own user token, so
messages go out as you. Live messages arrive over Socket Mode when an
app-level token is present.

| Slack | AOL-OS |
| --- | --- |
| Direct message partners | Buddies, up to 60 in Slack's priority order |
| Group direct messages | Group Chats |
| Channels you are a member of | Rooms under the workspace in Find a Chat |
| Mentions of you in a channel | Open the room and play `imrcv` |
| Status emoji and text | The buddy's away message |

A small colored square on each icon marks the service while Discord and Slack
are both signed on.

## App setup

You supply a Slack app installed in your own workspace.

1. Create an app at <https://api.slack.com/apps> with From an app manifest.
2. Paste the manifest below and create the app.
3. Under Basic Information, generate an app-level token with the
   `connections:write` scope. It starts with `xapp-`.
4. Under Install App, install to the workspace and copy the User OAuth Token.
   It starts with `xoxp-`.
5. Paste both tokens into Settings and press Connect Slack.

```yaml
display_information:
  name: AOL-OS
oauth_config:
  scopes:
    user:
      - channels:history
      - channels:read
      - groups:history
      - groups:read
      - im:history
      - im:read
      - im:write
      - mpim:history
      - mpim:read
      - mpim:write
      - chat:write
      - files:read
      - files:write
      - reactions:read
      - users:read
      - team:read
settings:
  event_subscriptions:
    user_events:
      - message.channels
      - message.groups
      - message.im
      - message.mpim
      - reaction_added
      - reaction_removed
      - user_change
  socket_mode_enabled: true
  org_deploy_enabled: false
  token_rotation_enabled: false
```

Both tokens live in the login keychain under the service `com.aolos.app`, as
`slack.userToken` and `slack.appToken`. Disconnect in Settings removes them.

Without the app token the Buddy List and rooms still work. Open windows then
pick up new messages once a minute, and new IMs do not open on their own.

## Presence

Slack sends presence changes only over the legacy RTM API, per
[user presence and status](https://docs.slack.dev/apis/web-api/user-presence-and-status).
AOL-OS polls `users.getPresence` for one buddy every 3 seconds instead.
A buddy can take a few minutes to move between Buddies and Offline.
Slack reports `away` for both idle and signed off, so away shows as signed
off.

## Rate limits

Internal apps keep the higher `conversations.history` limits, per the
[rate limit changes for non-Marketplace apps](https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps).
Keep the app internal to your workspace. A distributed unlisted app is limited
to one history request a minute.

## Messages

Replies go to the thread of the message they answer and are also sent to the
channel. Thread replies from others show the reply line above them. The B, I
and S buttons become Slack's `*bold*`, `_italic_` and `~strike~`. Slack has no
underline, so U sends plain text. Attachments
upload with `files.getUploadURLExternal` and `files.completeUploadExternal`.
Images from Slack load with your user token.

The code is in [Sources/AOLOS/Slack](../Sources/AOLOS/Slack).
