# Evidence guide

These sources can support a claim about behavior.

| Source | Use it for |
| --- | --- |
| Apple developer documentation | AppKit, WebKit, Security, and LocalAuthentication behavior |
| Official service API docs from Google, Slack, Discord, and Spotify | API methods, scopes, rate limits, and terms of use |
| Service terms of service and developer policies | Whether an integration is allowed |
| A reproducible observation in a running build | Web app page titles, DOM structure, notification behavior |
| Screenshots or recordings of AOL 9.0 | Look, layout, and sound behavior of the original client |

A reproducible observation states the macOS version, the service URL, and the
steps taken. Put it in the pull request or an issue so it has a durable link.

Prefer official documentation over observation when both exist. Observation
wins when the documentation is silent or the web app disagrees with it.
