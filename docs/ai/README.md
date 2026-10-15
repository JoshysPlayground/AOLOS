# AI-assisted contributions

AI-assisted work follows the same
[contribution policy](../../CONTRIBUTING.md) as any other work. The contributor
owns every submitted change and must be able to explain what it does, why it is
appropriate, and how it was verified.

Agent output is not evidence of how a service, web app, or macOS API behaves.
Use [evidence-and-claims.md](evidence-and-claims.md) when turning research into
a claim. State clearly in the pull request when a behavior change was not
verified against a source in the [evidence guide](../evidence.md).

Public contribution policy excludes private maintainer context. Private context
does not establish public policy or service behavior.

Add the smallest check that catches a demonstrated defect. Prefer a product
test over a check that only enforces repository shape.

## Documentation policy

### Public contract

Write concise public prose in a human voice. Describe the current contract
only. Do not record dates, change history, branch state, progress,
completeness, or project status.

Leave out migration notes, old names, moved paths, prior behavior, and other
breadcrumbs. Do not name private repositories, include private maintainer
context, narrate agent work, or add AI callouts to ordinary project pages.

### Shape

Use ASCII punctuation. Do not use em dashes, en dashes, smart punctuation,
bracketed asides, or dash asides. Avoid semicolons. Prefer short sentences and
one idea per paragraph.
These are length and punctuation defaults for new prose. Preserve technical
identifiers and provenance when needed for clarity or correctness.

Avoid stock agent jargon. Name the actual hazard or dependency instead.

Lead with the subject. Do not introduce documentation by describing its
contents or purpose.

Use lists for real sequences and tables for repeated mappings. Do not turn
ordinary prose into a large bullet inventory. Do not copy counts, file
catalogs, enum members, or other inventories owned by the source tree.

### Canonical sources

Link the canonical policy, source file, or technical guide instead of repeating
it.

Stable identifiers belong in docs when they are part of the current contract.
Examples are config keys, script message names, sound event names, and data
store profile names. Source technical facts through the
[evidence guide](../evidence.md).

## Shelf

Read in this order:

1. [Evidence and claims](evidence-and-claims.md)
2. [Comments and prose](comments-and-prose.md)

Code style, test commands, and contribution workflow remain canonical in the
[style guide](../style-guide.md), [testing guide](../testing.md), and
[contribution guide](../../CONTRIBUTING.md).
