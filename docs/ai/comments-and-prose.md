# Comments and prose

The [style guide](../style-guide.md) remains canonical for code style.
Delete explanatory comments unless they meet the keep criteria.
These are defaults. Clarity, correctness, provenance, source identifiers, and
runtime behavior take precedence over length or punctuation preferences.

Deletion is the default. Keep a comment only when it records one of these:

- a current invariant
- a web app or WebKit quirk
- an evidence citation
- a safety or security constraint
- an API contract not inferable from types and names

Describe current behavior without maintainer validation labels, work-session
narration, or implementation and verification dates. Keep that history in
private work logs.

Keep source and evidence identifiers verbatim. They are exempt from shortening.

Evidence citations must identify a durable source. A disposable local log,
build output, or scratch path is not a public citation. Retain the supported
behavior in the comment and keep local validation history in private work logs.

Compress other survivors to about one line at the use site. Move longer
contracts to a type-level doc comment or a documentation page, leaving a short
pointer. Prose about branch history is scaffolding and is removed before merge.

When unsure, keep one line and flag it in review notes.

User-facing strings are runtime text. Treat alert text, menu titles, and
injected page HTML as public contracts, not removable comments. Tighten one
rather than deleting it.

Injected JavaScript follows the same comment rules as Swift.

## Examples

Keep a web app quirk:

```swift
// Gmail puts the unread count in the page title, for example "Inbox (3)".
```

Keep a security constraint:

```swift
// Autofill runs in its own content world so page scripts cannot call into it.
```

Move a lifecycle description with multiple steps to the type contract:

```swift
// See WebPane for popup configuration ownership.
```

Delete narration that repeats the code:

```swift
// Increment the index.
index += 1
```

## Authored public prose

Public prose uses a plain, direct register. This covers the README,
CONTRIBUTING, the docs folder, and anything a stranger reads.

- Prefer plain noun phrases over hyphen chains. Keep established technical
  terms, but rephrase invented compound modifiers.
- Avoid semicolons in prose. Put independent thoughts in separate sentences.
- Cut parenthetical asides. If the aside matters, make it a short sentence
  of its own. If it does not, delete it.
- Short declarative sentences, one idea each. A rule gets one line of
  practical justification, then stops.
- "Footgun" and the metaphor "load-bearing" never ship in docs or comments.
  Name the actual hazard or dependency: "pitfall guard", "required order",
  "X relies on Y".

Internal working docs are out of scope. These rules govern the public tier.
