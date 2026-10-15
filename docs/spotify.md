# AOL Radio

AOL Radio is a native player window for Spotify. It controls playback through
the Spotify Web API and plays on a Spotify device. That device is usually the
Spotify desktop app on the same Mac, started hidden when nothing else is
active. Radio Setup picks any other device, such as a phone or speaker.

## Spotify app setup

You supply a Spotify app. AOL-OS ships without one unless `SpotifyClient.id`
in [SpotifyModels.swift](../Sources/AOLOS/Radio/SpotifyModels.swift) is set.

1. Create an app in the Spotify Developer Dashboard.
2. Select Web API as the API used.
3. Add the redirect URI `http://127.0.0.1:43821/callback`.
4. Copy the client ID.

Paste the client ID into Settings, or set `SpotifyClient.id` to build it in.
The sign in uses PKCE, so there is no client secret.

The dashboard rejects a loopback redirect without a port, so AOL-OS listens on
the fixed port `43821` during sign in. Loopback redirects must use `127.0.0.1`
rather than `localhost`, per the
[redirect URI rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
Development Mode apps need a Premium account on the app owner and allow at
most 5 users, per the
[February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide).
Playback control needs Premium on the listening account.

## Stations

| Category | Source |
| --- | --- |
| My Presets | Playlists and albums saved with Add to My Presets, stored in `config.json` |
| My Playlists | Playlists you own or follow, played as a whole |
| Liked Songs | Your 50 most recent liked songs |
| Saved Albums | Albums in your library |
| Recently Played | Your last 30 distinct tracks |
| Search Results | Up to 10 each of songs, playlists, and albums |

The window polls the player every 2.5 seconds while it is open and stops when
it closes. Save Song adds the current track to Liked Songs.

The refresh token lives in the login keychain under the service
`com.aolos.app`. Disconnect in Settings removes it.
