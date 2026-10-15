# Evidence and claims

A claim is any statement that a service, web app, or macOS API behaves a
certain way. Claims appear in code comments, docs, commit messages, and pull
request descriptions.

Every claim needs a source from the [evidence guide](../evidence.md). Cite the
source next to the claim or in the pull request.

An agent summary, a chat transcript, or a search result snippet is not a
source. Follow it to the page or observation it describes and cite that.

Mark a claim as unverified when no source exists yet. Say what would confirm
it. Do not write unverified behavior into public docs as fact.

Quote identifiers verbatim. This covers API method names, OAuth scopes, HTTP
headers, page titles used for parsing, and DOM selectors.

Web apps change without notice. A claim about page structure or title format
should name the observation it came from so the next contributor can recheck
it.
