# Pass to 1Password Regression Fix Design

## Status

Validated on 2026-07-25.

## Problem

The migration preview selects hundreds of password-store entries that were created years ago. It also checks duplicate URLs only after restricting 1Password candidates to the same normalized title, so an existing item with a different title can be missed.

## Root cause and evidence

`git log --since=<date>` filters on committer time. The password-store history was rewritten in February 2026, which assigned recent committer times to old commits while preserving their original author times.

The current discovery command selected 595 addition commits. Of those, 520 have author dates older than the six-month cutoff. For example, `private/login/france-visas-rocheupfrontsoftware.co.za.gpg` was authored in February 2024 but recommitted in February 2026.

The matching code builds only a title index. The installed 1Password CLI returns non-secret top-level URL summaries from `op item list`; the current `Private` vault has URL summaries for 440 of 520 items. A vault-wide URL index therefore does not require retrieving every item’s detailed fields.

## Goals

- Interpret “added within the last six months” using the addition commit’s author timestamp.
- Preserve the existing `--since` interface and Git-style date expressions.
- Avoid treating renamed old entries as newly added.
- Match exact canonical URLs across the entire destination vault, regardless of title.
- Require a normalized username match for URL candidates when the source entry has a username.
- Allow URL-only matching when the source has no username.
- Fetch detailed 1Password fields only for candidate items that need them.
- Preserve dry-run, ambiguity, secret-handling, and idempotence behavior.

## Non-goals

- Hostname-only or registrable-domain matching.
- Fuzzy URL, title, or username matching.
- Comparing password, API credential, TOTP, or other concealed values.
- Updating existing 1Password items.
- Changing item classification or payload mapping.
- Following renamed paths through a separate Git subprocess per current entry.

## Author-time discovery

### Cutoff

The script converts `--since` to an epoch by running:

```text
git -C <store> rev-parse --since=<expression>
```

Git returns `--max-age=<epoch>`. The script validates this exact shape and parses the epoch as an integer. Invalid or unexpected output is a sanitized discovery error.

### Addition scan

The script removes `--since` from the history scan and requests all `.gpg` additions with their author timestamps:

```text
git -C <store> log \
  --find-renames \
  --diff-filter=A \
  --name-only \
  --format=ENTRY:%at \
  -z \
  -- \
  '*.gpg'
```

`%at` is the author timestamp. `ENTRY:` markers associate following NUL-delimited paths with that timestamp.

A path is selected when:

- its addition marker has an author timestamp greater than or equal to the cutoff;
- its path is relative and ends in `.gpg`;
- the file still exists in the current password-store working tree.

Paths are deduplicated and returned in sorted order. Rename detection prevents a detected rename from appearing as an addition. This design intentionally uses one bounded Git history scan rather than one `--follow` process per entry.

## Vault-wide URL indexing

`ItemSummary` gains a tuple of URL strings parsed from the non-secret `urls[].href` values returned by `op item list`.

Preflight builds:

- `summaries_by_title`: normalized title to item summaries;
- `summaries_by_url`: canonical URL to item summaries.

Malformed summary URLs or response shapes produce a sanitized preflight failure. Concealed fields are not present in the summary index.

## Candidate selection

For each parsed source entry, candidate IDs are the union of:

- summaries with the same normalized title;
- summaries containing any exact canonical source URL.

Same-title candidates are fetched in detail because `pass path`, username, and custom URL fields may be needed.

For vault-wide URL candidates:

- when the source has a username, fetch candidate details to compare normalized usernames;
- when the source has no username, construct a lightweight candidate from summary URLs without a detail request.

Candidates are deduplicated by immutable 1Password item ID. Existing detail caching remains in effect.

## Matching rules

Matching follows this order:

1. Within same-title candidates, exact `pass path` is terminal: one path match produces `SKIP`; multiple path matches produce `AMBIGUOUS`.
2. When no path matches, union these identifier matches:
   - within same-title candidates, a normalized username match;
   - across all candidates, an exact canonical URL plus at least one normalized username match when the source has usernames;
   - across all candidates, exact canonical URL alone when the source has no usernames;
   - normalized title when the source has neither usernames nor URLs.

Outcomes remain:

- no matching IDs: `CREATE` or `CREATED`;
- one matching ID: `SKIP`;
- multiple matching IDs: `AMBIGUOUS`, create nothing, continue, and exit nonzero.

A matching title plus URL does not override a differing username. Hostname-only equality is not a match.

## Security

- `op item list` supplies only item summaries and top-level URLs.
- Detailed retrieval is restricted to same-title candidates and URL candidates that require username comparison.
- Detailed retrieval does not use `--reveal`.
- Existing concealed fields are skipped before their values are accessed.
- No source or destination secret is written to argv, environment variables, temporary files, or output.
- Error messages contain static context rather than raw Git or 1Password output.

## Error handling

The following are preflight or discovery failures with exit status 2:

- `git rev-parse --since` does not return one valid `--max-age=<epoch>` value;
- the addition stream contains a path before an `ENTRY:` marker;
- an `ENTRY:` marker does not contain an integer timestamp;
- 1Password summary URLs have invalid container or field types.

Per-entry URL parsing failures remain sanitized entry errors and do not expose URL values.

## Testing strategy

Behavior-focused tests will prove:

- an old author timestamp with a recent committer timestamp is excluded;
- a recent author timestamp is included;
- recent modification of an old entry does not include it;
- deleted entries and detected renames are excluded;
- malformed cutoff and addition-stream output fails safely;
- a different-title 1Password item matches by exact URL and username;
- the same URL with a different username does not match;
- exact URL alone matches when the source has no username;
- hostname-only equality does not match;
- multiple vault-wide URL matches are ambiguous;
- unrelated vault items are not fetched in detail;
- summary-only candidates do not cause concealed-field access;
- the fake-CLI dry-run/apply/rerun workflow remains idempotent.

No automated test accesses the real password store or 1Password account.

## Acceptance criteria

- The user-provided old entries are absent from the default six-month preview because their author dates predate the cutoff.
- The preview contains only current entries whose addition author timestamps satisfy `--since`.
- Existing items with different titles are skipped when their canonical URL and required username match.
- Items sharing a URL but using different usernames are not falsely skipped.
- The focused suite, Python compilation, and repository flake check pass.
- No real 1Password item is created during verification.
