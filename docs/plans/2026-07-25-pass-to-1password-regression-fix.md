# Pass to 1Password Regression Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recent-entry discovery use addition author timestamps and make duplicate detection search exact URLs across the entire 1Password vault with username qualification.

**Architecture:** Keep the approved single executable. Add pure parsers for the Git cutoff and author-timestamp stream, extend non-secret 1Password summaries with URLs, and build title plus URL indexes in preflight. Candidate detail retrieval remains bounded to same-title items and URL candidates that require username comparison.

**Tech Stack:** Python 3 standard library, Git CLI, `pass` 1.7.4, 1Password CLI 2.34.0, `unittest`, Nix flake checks.

## Global Constraints

- Work only in `/home/roche/nixdots/.worktrees/pass-migration-regression-fix` on `fix/pass-migration-regression-fix`.
- Follow `docs/specs/2026-07-25-pass-to-1password-regression-fix-design.md`.
- Keep the existing CLI flags and dry-run-first behavior.
- Use addition author timestamps, not committer timestamps.
- Use exact canonical URLs; do not add hostname-only or fuzzy matching.
- Require normalized username equality for URL candidates whenever the source has a username.
- Do not use `op item get --reveal`, inspect concealed field values, or fetch unrelated item details.
- Keep all tests synthetic; do not create or update real 1Password items.
- Use TDD red/green cycles, signed Conventional Commits, and enabled hooks.

## File Map

- Modify `scripts/migrate-pass-to-1password.py`: author-time discovery, URL-bearing summaries, dual indexes, candidate selection, and revised matching.
- Modify `scripts/tests/test_migrate_pass_to_1password.py`: rewritten-history, malformed-stream, vault-wide matching, detail-fetch bounding, and integration regressions.

---

### Task 1: Discover recent additions by author timestamp

**Files:**
- Modify: `scripts/migrate-pass-to-1password.py:197-228`
- Modify: `scripts/tests/test_migrate_pass_to_1password.py` (`DiscoveryAndCommandTests`)

**Interfaces:**
- Produces: `_parse_since_epoch(raw: str) -> int`.
- Produces: `_parse_added_paths(raw: str, cutoff: int) -> set[str]`.
- Preserves: `discover_entries(store: Path, since: str, *, runner=run_command) -> list[str]`.

- [ ] **Step 1: Rewrite the discovery command test for two commands and author markers**

Change `test_discovers_deduplicated_current_gpg_additions` so its fake runner returns a cutoff first and an author-timestamp stream second:

```python
responses = iter(
    [
        "--max-age=1760000000\n",
        "ENTRY:1760000001\0\nprivate/new.gpg\0"
        "private/new.gpg\0private/deleted.gpg\0"
        "ENTRY:1759999999\0\nprivate/old.gpg\0",
    ]
)


def fake_runner(args, **kwargs):
    calls.append((list(args), kwargs))
    return next(responses)
```

Assert:

```python
self.assertEqual(found, ["private/new"])
self.assertEqual(
    calls[0][0],
    ["git", "-C", str(store), "rev-parse", "--since=2026-01-01"],
)
self.assertEqual(
    calls[1][0],
    [
        "git",
        "-C",
        str(store),
        "log",
        "--find-renames",
        "--diff-filter=A",
        "--name-only",
        "--format=ENTRY:%at",
        "-z",
        "--",
        "*.gpg",
    ],
)
```

Create `private/old.gpg` and `private/new.gpg`; leave `private/deleted.gpg` absent.

- [ ] **Step 2: Make the real-Git regression reproduce rewritten committer dates**

In `test_real_git_history_selects_recent_additions_not_modifications`, create the initial commit with an old author timestamp but recent committer timestamp:

```python
old_author = int(datetime(2025, 1, 1, tzinfo=timezone.utc).timestamp())
rewritten_committer = int(
    datetime(2026, 2, 7, tzinfo=timezone.utc).timestamp()
)
recent = int(datetime(2026, 2, 10, tzinfo=timezone.utc).timestamp())
```

Use `old_author` on the `author` line and `rewritten_committer` on the first commit’s `committer` line. Add an old path that is renamed in the recent commit:

```text
M 100644 inline private/renamed-old.gpg
...
R private/renamed-old.gpg private/renamed-current.gpg
```

Keep the recent modification of `old.gpg`, recent addition of `private/new.gpg`, and deletion of `private/deleted.gpg`. Assert only `private/new` is returned.

- [ ] **Step 3: Add malformed cutoff and stream tests**

Add:

```python
def test_discovery_rejects_malformed_cutoff_and_author_stream(self) -> None:
    cases = {
        "missing cutoff": ["\n"],
        "invalid cutoff": ["--max-age=not-a-number\n"],
        "path before marker": ["--max-age=1\n", "private/new.gpg\0"],
        "invalid marker": ["--max-age=1\n", "ENTRY:nope\0\nprivate/new.gpg\0"],
    }
    with tempfile.TemporaryDirectory() as directory:
        store = Path(directory)
        for label, responses in cases.items():
            with self.subTest(label=label):
                answers = iter(responses)
                with self.assertRaises(migration.MigrationError):
                    migration.discover_entries(
                        store,
                        "6 months ago",
                        runner=lambda args, **kwargs: next(answers),
                    )
```

- [ ] **Step 4: Run discovery tests and verify the red state**

Run:

```sh
python3 -m unittest \
  scripts.tests.test_migrate_pass_to_1password.DiscoveryAndCommandTests -v
```

Expected: command assertions fail, the rewritten-date fixture incorrectly includes old paths, and malformed output does not consistently raise `MigrationError`.

- [ ] **Step 5: Implement cutoff and author-stream parsing**

Replace `discover_entries` with focused helpers and the two-command flow:

```python
def _parse_since_epoch(raw: str) -> int:
    lines = [line for line in raw.splitlines() if line]
    if len(lines) != 1 or not lines[0].startswith("--max-age="):
        raise CommandError("git returned an invalid --since cutoff")
    value = lines[0].removeprefix("--max-age=")
    try:
        return int(value)
    except ValueError as error:
        raise CommandError("git returned an invalid --since cutoff") from error


def _parse_added_paths(raw: str, cutoff: int) -> set[str]:
    selected: set[str] = set()
    author_timestamp: int | None = None
    for raw_token in raw.split("\0"):
        token = raw_token.lstrip("\n")
        if not token:
            continue
        if token.startswith("ENTRY:"):
            try:
                author_timestamp = int(token.removeprefix("ENTRY:"))
            except ValueError as error:
                raise CommandError("git returned an invalid addition timestamp") from error
            continue
        if author_timestamp is None:
            raise CommandError("git returned a path without an addition timestamp")
        if author_timestamp >= cutoff:
            selected.add(token)
    return selected


def discover_entries(
    store: Path,
    since: str,
    *,
    runner: Runner = run_command,
) -> list[str]:
    cutoff = _parse_since_epoch(
        runner(["git", "-C", str(store), "rev-parse", f"--since={since}"])
    )
    raw = runner(
        [
            "git",
            "-C",
            str(store),
            "log",
            "--find-renames",
            "--diff-filter=A",
            "--name-only",
            "--format=ENTRY:%at",
            "-z",
            "--",
            "*.gpg",
        ]
    )
    entries: set[str] = set()
    for relative in _parse_added_paths(raw, cutoff):
        if not relative.endswith(".gpg"):
            continue
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts:
            continue
        if store.joinpath(*path.parts).is_file():
            entries.add(relative.removesuffix(".gpg"))
    return sorted(entries)
```

- [ ] **Step 6: Run discovery and full tests to verify green**

Run:

```sh
python3 -m unittest \
  scripts.tests.test_migrate_pass_to_1password.DiscoveryAndCommandTests -v
python3 -m unittest discover \
  -s scripts/tests \
  -p 'test_migrate_pass_to_1password.py' \
  -v
```

Expected: all discovery tests and the full suite pass.

- [ ] **Step 7: Commit author-time discovery**

```sh
git add scripts/migrate-pass-to-1password.py scripts/tests/test_migrate_pass_to_1password.py
git commit -m "fix(1password): use author dates for pass discovery"
```

---

### Task 2: Match URLs across the whole vault

**Files:**
- Modify: `scripts/migrate-pass-to-1password.py` (`ItemSummary`, `list_item_summaries`, `MigrationContext`, `_index_summaries`, `preflight`, `_candidate_items`, `match_existing`)
- Modify: `scripts/tests/test_migrate_pass_to_1password.py` (`OnePasswordMappingTests`, `OrchestrationTests`, fake CLI)

**Interfaces:**
- Extends: `ItemSummary.urls: tuple[str, ...] = ()`.
- Extends: `MigrationContext.summaries_by_url: dict[str, list[ItemSummary]]`.
- Produces: `_index_summaries_by_url(items) -> dict[str, list[ItemSummary]]`.
- Revises: `match_existing(entry, items) -> MatchResult` to allow title-independent exact URL matches.

- [ ] **Step 1: Add vault-wide URL matching tests**

Add focused cases to `OnePasswordMappingTests`:

```python
def test_vault_wide_url_matching_uses_username_when_available(self) -> None:
    source = migration.parse_pass_output(
        "private/source-title",
        "synthetic\nusername: alice@example.com\nurl: https://example.com/login\n",
    )
    matching = migration.ExistingItem(
        "match", "Different title", ("alice@example.com",),
        ("https://example.com/login",), (),
    )
    wrong_username = migration.ExistingItem(
        "wrong-user", "Different title", ("bob@example.com",),
        ("https://example.com/login",), (),
    )
    hostname_only = migration.ExistingItem(
        "wrong-path", "Different title", ("alice@example.com",),
        ("https://example.com/admin",), (),
    )

    self.assertEqual(
        migration.match_existing(source, [matching]).item_ids, ("match",)
    )
    self.assertEqual(
        migration.match_existing(source, [wrong_username]).kind,
        migration.MatchKind.NONE,
    )
    self.assertEqual(
        migration.match_existing(source, [hostname_only]).kind,
        migration.MatchKind.NONE,
    )
```

Add URL-only and ambiguity cases:

```python
def test_vault_wide_url_matches_without_source_username(self) -> None:
    source = migration.parse_pass_output(
        "private/source-title", "synthetic\nurl: https://example.com/login\n"
    )
    first = migration.ExistingItem(
        "first", "Other", (), ("https://example.com/login",), ()
    )
    second = migration.ExistingItem(
        "second", "Another", (), ("https://example.com/login",), ()
    )
    self.assertEqual(
        migration.match_existing(source, [first]).kind,
        migration.MatchKind.MATCH,
    )
    self.assertEqual(
        migration.match_existing(source, [first, second]).kind,
        migration.MatchKind.AMBIGUOUS,
    )
```

- [ ] **Step 2: Add summary URL parsing and bounded-detail tests**

Test `list_item_summaries` with different-title URL data:

```python
summary = migration.list_item_summaries(
    "Private",
    runner=lambda args, **kwargs: json.dumps(
        [{
            "id": "item-id",
            "title": "Different title",
            "category": "LOGIN",
            "urls": [{"href": "https://example.com/login", "primary": True}],
        }]
    ),
)[0]
self.assertEqual(summary.urls, ("https://example.com/login",))
```

Add malformed `urls` shape subtests and assert `MigrationError`.

For `_candidate_items`, construct a `MigrationContext` containing a URL-indexed different-title summary. Prove a source without username returns a lightweight candidate without calling the runner, while a source with username calls `op item get` exactly once.

- [ ] **Step 3: Update the fake CLI summary response**

In `FAKE_CLI`, preserve top-level summary URLs:

```python
{
    "id": item["id"],
    "title": item["title"],
    "category": item["category"],
    "urls": item.get("urls", []),
}
```

Add a different-title existing Login fixture with the same exact URL and username as a source entry. Verify dry-run emits `SKIP`, apply does not create it, and no concealed value appears in output.

- [ ] **Step 4: Run matching tests and verify the red state**

Run:

```sh
python3 -m unittest \
  scripts.tests.test_migrate_pass_to_1password.OnePasswordMappingTests \
  scripts.tests.test_migrate_pass_to_1password.OrchestrationTests \
  scripts.tests.test_migrate_pass_to_1password.EndToEndTests -v
```

Expected: different-title URL matching returns `NONE`, `ItemSummary` has no URL data, and candidate lookup cannot use a URL index.

- [ ] **Step 5: Extend summaries and preflight indexes**

Add a defaulted URL tuple so existing three-argument test construction remains valid:

```python
@dataclass(frozen=True)
class ItemSummary:
    id: str
    title: str
    category: str
    urls: tuple[str, ...] = ()
```

Parse summary URLs in `list_item_summaries`, validating that `urls` is a list of objects and every present `href` is a string. Add:

```python
def _index_summaries_by_url(
    items: list[ItemSummary],
) -> dict[str, list[ItemSummary]]:
    index: dict[str, list[ItemSummary]] = defaultdict(list)
    for item in items:
        for url in item.urls:
            index[canonicalize_url(url)].append(item)
    return dict(index)
```

Extend `MigrationContext` with a defaulted `summaries_by_url` field using `dataclasses.field(default_factory=dict)`. In preflight, list summaries once and build both indexes.

- [ ] **Step 6: Revise candidate selection and matching**

Candidate selection must union title and canonical-URL summaries by ID. Fetch detail when a candidate has the same title or the source has usernames; otherwise use:

```python
def _summary_as_existing(summary: ItemSummary) -> ExistingItem:
    return ExistingItem(summary.id, summary.title, (), summary.urls, ())
```

Revise `match_existing` to union:

```python
def match_existing(entry: SourceEntry, items: list[ExistingItem]) -> MatchResult:
    same_title = [
        item
        for item in items
        if normalize_title(item.title) == normalize_title(entry.title)
    ]
    source_usernames = {normalize_username(value) for value in entry.usernames}
    source_urls = {canonicalize_url(value) for value in entry.urls}

    path_ids = tuple(
        sorted({item.id for item in same_title if entry.path in item.pass_paths})
    )
    if path_ids:
        kind = MatchKind.MATCH if len(path_ids) == 1 else MatchKind.AMBIGUOUS
        return MatchResult(kind, path_ids)

    title_username_ids = {
        item.id
        for item in same_title
        if source_usernames.intersection(
            normalize_username(value) for value in item.usernames
        )
    }
    url_ids = {
        item.id
        for item in items
        if source_urls.intersection(canonicalize_url(value) for value in item.urls)
        and (
            not source_usernames
            or source_usernames.intersection(
                normalize_username(value) for value in item.usernames
            )
        )
    }
    if not source_usernames and not source_urls:
        title_username_ids.update(item.id for item in same_title)
    ids = tuple(sorted(title_username_ids | url_ids))
    if not ids:
        return MatchResult(MatchKind.NONE)
    if len(ids) == 1:
        return MatchResult(MatchKind.MATCH, ids)
    return MatchResult(MatchKind.AMBIGUOUS, ids)
```

- [ ] **Step 7: Run focused and full tests to verify green**

Run:

```sh
python3 -m unittest discover \
  -s scripts/tests \
  -p 'test_migrate_pass_to_1password.py' \
  -v
python3 -m py_compile scripts/migrate-pass-to-1password.py
scripts/migrate-pass-to-1password.py --help
```

Expected: all tests pass; compilation and help exit 0.

- [ ] **Step 8: Commit vault-wide URL matching**

```sh
git add scripts/migrate-pass-to-1password.py scripts/tests/test_migrate_pass_to_1password.py
git commit -m "fix(1password): match URLs across the vault"
```

---

### Task 3: Verify against the reported regression and finish

**Files:**
- Modify only if a failing regression test requires a production correction.

**Interfaces:**
- Consumes all Task 1–2 behavior.
- Produces completion evidence and adversarial review.

- [ ] **Step 1: Verify discovery against the real store without decrypting entries**

Run a Python probe that imports the script, calls only `discover_entries`, and prints the count plus membership for the user-reported paths. It must not call `pass` or `op`.

Expected: all reported old paths return `selected=False`.

- [ ] **Step 2: Run final automated verification**

Run:

```sh
python3 -m unittest discover \
  -s scripts/tests \
  -p 'test_migrate_pass_to_1password.py' \
  -v
python3 -m py_compile scripts/migrate-pass-to-1password.py
git diff --check
nix flake check --accept-flake-config --print-build-logs
```

Expected: all tests pass, compilation and whitespace checks exit 0, and the flake check ends with `all checks passed!`.

- [ ] **Step 3: Request fresh-context review**

Review the base-to-head diff against the regression-fix spec. Require explicit attention to author versus committer dates, malformed Git output, vault-wide URL matching, username qualification, bounded detail retrieval, ambiguity, and secret exposure.

Fix every Critical or Important finding with a new failing test before implementation, then rerun Step 2.

- [ ] **Step 4: Commit any review fixes**

If review changes are needed:

```sh
git add scripts/migrate-pass-to-1password.py scripts/tests/test_migrate_pass_to_1password.py
git commit -m "fix(1password): address migration review findings"
```

If no changes are needed, do not create an empty commit.

- [ ] **Step 5: Run final signed-commit and cleanliness checks**

Run:

```sh
git status --short --branch
git log -5 --show-signature --format='%h %G? %s'
```

Expected: clean worktree and good signatures for every new commit.
