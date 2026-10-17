# Gmail

The Mailbox reads Gmail over IMAP at `imap.gmail.com:993` and sends over SMTP
at `smtp.gmail.com:465`. Both sign in with OAuth through the SASL `XOAUTH2`
mechanism. Google documents the mechanism in the
[XOAUTH2 protocol guide](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol).

## Google Cloud setup

You supply your own OAuth client. AOL-OS ships without one.

1. Create a project in the Google Cloud console.
2. Enable the Gmail API for the project.
3. Configure the OAuth consent screen. Choose **Internal** for a Google
   Workspace account. Choose **External** for a personal Gmail account and add
   yourself as a test user.
4. Add the scope `https://mail.google.com/` to the consent screen.
5. Create an OAuth client ID with the application type **Desktop app**.
6. Copy the client ID and client secret.

In AOL-OS, open Settings, paste both values, and click Connect Gmail. Your
browser opens the Google sign in. When it finishes, return to AOL-OS.

## More than one account

Click Add Account in Settings, or Mail Options > Add Gmail Account in the
Mailbox. Google shows its account chooser, so pick the other account there. All
accounts share the one OAuth client. On an External app in Testing, add each
address as a test user.

Manage Accounts in Settings lists each account with Reconnect, Make Primary,
and Remove. The first account is the primary one. Write Mail starts from it.

- The Mailbox merges New, Old, Sent, and Search across accounts, newest first.
  A colored badge with the account's first letter marks each row. Hover it for
  the address.
- The Account menu next to Show mail from narrows the Mailbox, its folders,
  Check Mail Now, and Search to one account. Manage Mail lists each account's
  Gmail folders under its address.
- Write Mail shows a From menu when two or more accounts are signed in. Replies
  and forwards start from the account that received the message, else an
  account named in To or Cc, else the primary account.
- Each account keeps its own IMAP command and IDLE connections. When several
  accounts report new mail at sign on, `gotmail` plays once.
- Open Gmail on the Web, with one account picked in the Account menu, adds
  `authuser` so the web pane opens that account if the `google` profile is
  signed in to it.

An External app left in the Testing publishing status gets refresh tokens that
expire after 7 days, per Google's
[token expiration rules](https://developers.google.com/identity/protocols/oauth2#expiration).
Connect again in Settings when that happens. An Internal app does not have
this limit.

A Workspace admin can turn off IMAP or third-party OAuth access for the
domain. Both must be allowed.

## Sign in

The sign in uses the loopback redirect flow with PKCE. AOL-OS listens on
`127.0.0.1` on a random port for the redirect. Google supports this flow for
Desktop app clients, per the
[loopback migration guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration).

The requested scopes are `https://mail.google.com/`, `openid`, and `email`.
The sign in asks with `prompt=select_account consent`. Reconnect passes the
address as `login_hint`.

Secrets live in the login keychain under the service `com.aolos.app`:
`google.clientID`, `google.clientSecret`, `google.accounts` (a JSON list of
addresses, primary first), and one `google.refreshToken.<address>` per account.
The single-account keys `google.email` and `google.refreshToken` move to the
new keys on first use.

Remove in Settings revokes that account's refresh token and removes it from the
keychain. A refresh token that Google rejects is dropped. The account stays in
the list as signed out until you reconnect or remove it.

## Mailbox behavior

| Mailbox | Source |
| --- | --- |
| New Mail | Unread messages among the newest 300 in INBOX |
| Old Mail | Read messages among the newest 300 in INBOX |
| Sent Mail | The newest 100 messages in the folder marked `\Sent` |

Opening a message marks it read. Keep As New marks it unread. Delete moves it
to the folder marked `\Trash`.

A second IMAP connection waits in IDLE on INBOX. New mail plays the `gotmail`
sound and turns the Mailbox title bar orange. Sign on plays it too when unread
mail is waiting.

Message bodies render without JavaScript. Remote images and other remote
content stay blocked until you click Show Images. Inline images that the
message carries are shown right away.

Compose sends plain text. Gmail files sent messages in Sent Mail.

The keyword `gmail` still opens Gmail on the web.
