# Contributing

Work happens on a branch and lands through a pull request.

1. Branch from `main`.
2. Make the change and follow the [style guide](docs/style-guide.md).
3. Verify it with the [testing guide](docs/testing.md).
4. Open a pull request.

A pull request description states what changed, why, and how it was verified.
Link the source for any claim about service or API behavior. The
[evidence guide](docs/evidence.md) lists accepted sources.

Keep each pull request to one change. Split unrelated fixes into their own
pull requests.

Do not commit credentials, tokens, cookies, or sound files. Sound files stay
local in `Resources/Sounds/`, which git ignores.

AI-assisted work follows the [AI contribution policy](docs/ai/README.md).
