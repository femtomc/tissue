# tissue

Fast, local issue tracker for agent workflows. Uses SQLite for queries and an
append-only JSONL log for sync.

- Source of truth: `.tissue/issues.jsonl` (commit this to GitHub).
- Local cache: `.tissue/issues.db*` (ignored by `.tissue/.gitignore`).

## Quick start

```sh
tissue init
tissue new "Fix flaky tests" -b "Seen in CI" -t build -p 2
tissue list --status open
tissue show <id>
tissue edit <id> --status closed
tissue comment <id> -m "Resolved in 8b7c0fe"
tissue dep add <id> blocks <target>
tissue ready
```

## Store location

- Default: `.tissue` in the current repo (walks up to find it).
- Override: `TISSUE_STORE=/absolute/or/relative/path`.

## Command reference (short)

- `tissue init [--json] [--prefix prefix]` create the store.
- `tissue new "title" [-b body] [-t tag] [-p 1-5] [--json|--quiet]`
- `tissue list [--status open|closed] [--tag tag] [--search query] [--limit N] [--json]`
- `tissue show <id> [--json]`
- `tissue edit <id> [--title t] [--body b] [--status open|closed] [--priority 1-5] [--add-tag t] [--rm-tag t] [--json|--quiet]`
- `tissue status <id> <open|closed> [--json|--quiet]`
- `tissue comment <id> -m "text" [--json|--quiet]`
- `tissue tag <add|rm> <id> <tag> [--json|--quiet]`
- `tissue dep <add|rm> <id> <blocks|relates|parent> <target> [--json|--quiet]`
- `tissue deps <id> [--json]`
- `tissue ready [--json]`

## IDs

- Issue IDs are `prefix-hash` (base36), e.g. `tissue-a3f8e9`.
- Prefix defaults to the repo name (normalized); override with `tissue init --prefix foo`.
- Hash length is fixed at 8 base36 characters and retries with nonces on collisions.
- You can reference issues by full ID, any unique leading prefix, or the hash prefix.
- Comments still use ULIDs.

## Search

`tissue list --search "query"` uses SQLite FTS5 with BM25 ranking.
Titles are weighted higher than bodies.

## Priority

- Range: 1 (highest) to 5 (lowest).
- Default for new issues: 2.

## Dependencies

- `blocks`: `A blocks B` means B is not ready while A is open (transitive).
- `parent`: directional parent/child edge.
- `relates`: undirected; stored once regardless of order.
- `tissue ready` lists open issues with no open blockers.

## JSON output (for agents)

Prefer `--json`/`--quiet` to avoid parsing human output.

- `tissue new --json` -> issue record.
- `tissue list --json` -> array of `{id, status, title, updated_at, priority, tags}` (tags is comma-separated).
- `tissue show --json` -> `{issue, comments, deps}`.
- `tissue deps --json` -> array of `{src_id, dst_id, kind, state, created_at, rev}`.
- `tissue comment --json` -> `{id, issue_id, body}`.

## Git-based sync

Source of truth is the JSONL log. Sync it with Git:

```sh
git pull --rebase
tissue list --status open
git add .tissue/issues.jsonl
git commit -m "tissue: update issues"
git push
```

If you hit a merge conflict in `issues.jsonl`, keep all valid JSON lines (one
JSON object per line) and rerun any `tissue` command to reimport.
