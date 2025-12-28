# tissue

A fast, portable issue tracker that lives in your git repo. Designed for AI agents and automation.

tissue combines the durability of an append-only JSONL log with the speed of an embedded SQLite cache, enabling git-friendly sync and zero-config setup. It is a non-interactive CLI with machine-readable JSON output and atomic file operations.

## Features

- **Agent-first**: Non-interactive CLI with JSON output, designed for automation
- **Git-friendly sync**: Append-only JSONL log that merges cleanly
- **Fast queries**: FTS5-enabled SQLite cache, rebuilt automatically
- **Zero dependencies**: Statically linked Zig binary, works anywhere
- **Atomic operations**: File locking and retry logic for concurrent access
- **Deterministic IDs**: Prefix-hash format (e.g., `tissue-a3f8e9`)
- **Ready queue**: Find unblocked work with `tissue ready`
- **Dependency tracking**: `blocks`, `relates`, and `parent` edges

## Why tissue?

Use tissue instead of GitHub Issues when you need:

- **Offline access**: Everything is local, no internet required
- **Agent workflows**: Built for Claude, Copilot, and other AI tools
- **Repo-local issues**: Issues travel with your code and branches
- **No overhead**: No API limits, no auth, no cloud latency
- **Git-native conflicts**: Standard merge tools work on the JSONL log

## Installation

### Quick install (macOS/Linux)

```sh
curl -fsSL https://github.com/femtomc/tissue/releases/latest/download/install.sh | sh
```

Or specify a version:

```sh
TISSUE_VERSION=v0.1.0 curl -fsSL https://github.com/femtomc/tissue/releases/latest/download/install.sh | sh
```

### Pre-built binaries

Download from [GitHub Releases](https://github.com/femtomc/tissue/releases):

| Platform | Architecture | Download |
|----------|--------------|----------|
| Linux    | x86_64       | [tissue-x86_64-linux.tar.gz](https://github.com/femtomc/tissue/releases/latest/download/tissue-x86_64-linux.tar.gz) |
| Linux    | aarch64      | [tissue-aarch64-linux.tar.gz](https://github.com/femtomc/tissue/releases/latest/download/tissue-aarch64-linux.tar.gz) |
| macOS    | x86_64       | [tissue-x86_64-macos.tar.gz](https://github.com/femtomc/tissue/releases/latest/download/tissue-x86_64-macos.tar.gz) |
| macOS    | aarch64      | [tissue-aarch64-macos.tar.gz](https://github.com/femtomc/tissue/releases/latest/download/tissue-aarch64-macos.tar.gz) |

### Build from source

Requirements: [Zig](https://ziglang.org/) 0.15.2 or later.

```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/tissue /usr/local/bin/
tissue --help
```

For development:

```sh
zig build run -- --help
```

## Quick Start

```sh
tissue init                                                # Initialize store
id=$(tissue new "Fix flaky tests" -b "Seen in CI" -t build -p 2 --quiet)
tissue list --status open                                  # List open issues
tissue show "$id"                                          # View issue details
tissue comment "$id" -m "Resolved in 8b7c0fe"              # Add a comment
tissue status "$id" closed                                 # Close the issue
tissue ready                                               # Show unblocked work
```

## Architecture

tissue uses a dual-storage architecture to balance durability with performance:

- **Source of truth (`.tissue/issues.jsonl`):** An append-only, line-delimited JSON file. This format is git-friendly and allows for easy conflict resolution via standard merge tools. Each operation appends a new record; the latest record for each entity wins.

- **Derived cache (`.tissue/issues.db`):** A local SQLite database with FTS5 enabled for full-text search. SQLite is statically linked (vendored) with no external dependencies.

On every command, tissue checks if the JSONL file has changed (via inode, size, or mtime). If changes are detected, the SQLite cache is automatically synced from the log. Writing to the store updates both files atomically using file locking to ensure safety in concurrent environments.

Because the SQLite database is derived from the JSONL log, it can be deleted at any time. Running any tissue command will rebuild it:

```sh
rm .tissue/issues.db*
tissue list  # rebuilds the cache
```

## Agent-first CLI contract

- Non-interactive; safe for automation.
- Success: exit code 0, output on stdout.
- Failure: exit code 1, error message on stderr.
- Prefer `--json` for machine parsing; output is minified JSON with a trailing newline.
- `--quiet` returns only an ID (issue id or comment id) and overrides `--json`.
- `--body` and `-m/--message` expand `\n`, `\t`, and `\\`.
- IDs accept full IDs, unique leading prefixes, or hash prefixes (when no dash is present).
- Store discovery: `--store` wins; then `TISSUE_STORE` env; then walk up from cwd to find `.tissue`.

## Store location and layout

- Default store: `.tissue` in the current repo (walks up).
- Override via CLI: `tissue --store <path> <command>` or `--store=<path>` (e.g., `--store .claude/.tissue`).
- Override via env: `TISSUE_STORE=/absolute/or/relative/path` (relative paths resolved from cwd).
- Parent directories are created automatically (e.g., `--store .claude/.tissue` creates `.claude/` if needed).
- Files:
  - `.tissue/issues.jsonl` append-only log (source of truth).
  - `.tissue/issues.db*` SQLite cache (derived).
  - `.tissue/lock` file lock for writes.
  - `.tissue/.gitignore` ignores the DB files and lock.

If the SQLite cache is missing or out of date, `tissue` auto-imports from
`issues.jsonl`. You can delete `.tissue/issues.db*` and rerun any command to
rebuild.

## IDs and prefixes

- Issue IDs are `prefix-hash` (base36), e.g. `tissue-a3f8e9`.
- Prefix defaults to the repo name (normalized); override with `tissue init --prefix foo`.
- Prefix normalization: lowercase letters, numbers, and hyphens; max length 32.
- Hash length is fixed at 8 base36 characters and retries with nonces on collisions.
- You can reference issues by full ID, any unique leading prefix, or the hash prefix
  (only when you omit the dash).
- Comments use ULIDs.

## JSON output reference (for agents)

All `--json` output is minified and newline-terminated.

Issue record (used by `new --json`, `edit --json`, `status --json`, `tag --json`):

```json
{"id":"tissue-a3f8e9","title":"...","body":"...","status":"open","priority":2,"created_at":1700000000000,"updated_at":1700000000000,"rev":"01J...","tags":["build","infra"]}
```

List/ready row (used by `list --json` and `ready --json`):

```json
{"id":"tissue-a3f8e9","status":"open","title":"...","updated_at":1700000000000,"priority":2,"tags":"build,infra","body":"..."}
```

Show response (`show --json`):

```json
{"issue":{...Issue...},"comments":[...Comment...],"deps":[...Dep...]}
```

Comment record (`show --json`):

```json
{"id":"01J...","issue_id":"tissue-a3f8e9","body":"...","created_at":1700000000000}
```

Comment response (`comment --json`):

```json
{"id":"01J...","issue_id":"tissue-a3f8e9","body":"..."}
```

Dependency record (`deps --json` / `show --json`):

```json
{"src_id":"tissue-a3f8e9","dst_id":"tissue-b19c2d","kind":"blocks","state":"active","created_at":1700000000000,"rev":"01J..."}
```

Dependency response (`dep --json`):

```json
{"action":"add","src_id":"tissue-a3f8e9","dst_id":"tissue-b19c2d","kind":"blocks"}
```

Init response (`init --json`):

```json
{"store":"/path/to/.tissue","prefix":"tissue"}
```

Clean response (`clean --json`):

```json
{"dry_run":true,"count":2,"issues":["tissue-a3f8e9","tissue-b19c2d"]}
```

Notes:
- Timestamps are Unix epoch milliseconds.
- Status values: `open`, `in_progress`, `paused`, `duplicate`, `closed`.
- `tags` is an array in Issue records, but a comma-separated string in list/ready rows.
- `comment --json` echoes the input body; to read stored comments (with escapes expanded), use `show --json`.
- `dep --json` uses the user-provided direction; for canonical order (especially for `relates`), use `deps --json`.
- If nothing matches, `clean --json` returns `{"removed":0,"issues":[]}`.

## Command reference (detailed)

### tissue init

Usage: `tissue init [--json] [--prefix prefix]`

Creates the store directory and files.

Options:
- `--prefix`: set or update the ID prefix (see "IDs and prefixes").
- `--json`: output the store path and prefix as JSON.

Output:
- Human: `initialized ...` or `already initialized ...`
- JSON: `{"store": "...", "prefix": "..."}` on stdout. If the store already exists,
  a note is printed to stderr.

Examples:
```sh
tissue init
tissue init --prefix acme --json
```

### tissue new

Usage: `tissue new "title" [-b body] [-t tag] [-p 1-5] [--json|--quiet]`

Creates a new issue.

Options:
- `-b, --body`: optional body. Supports `\n`, `\t`, `\\`.
- `-t, --tag`: add a tag (repeatable).
- `-p, --priority`: integer 1 (highest) to 5 (lowest). Default is 2.
- `--json`: output the Issue record.
- `--quiet`: output only the issue id.

Output:
- Default: issue id.
- JSON: Issue record.
- Quiet: issue id only (overrides `--json`).

Examples:
```sh
tissue new "Add caching layer" -b "Targets /v1/search" -t perf -t api -p 1
tissue new "Follow up" --quiet
```

### tissue list

Usage: `tissue list [--status open|in_progress|paused|duplicate|closed] [--tag tag] [--search query] [--limit N] [--json]`

Lists issues, newest first.

Options:
- `--status`: filter by `open`, `in_progress`, `paused`, `duplicate`, or `closed`.
- `--tag`: filter by exact tag match (case-sensitive).
- `--search`: SQLite FTS5 query; titles are weighted higher than bodies.
- `--limit`: max number of results.
- `--json`: output an array of list rows.

Output:
- Human: table with truncated title/body.
- JSON: list rows (includes full `body` and comma-separated `tags`).

Examples:
```sh
tissue list --status open --limit 20
tissue list --tag build --search "flake" --json
```

### tissue show

Usage: `tissue show <id> [--json]`

Shows full details for one issue.

Output:
- Human: full issue details, deps, and comments.
- JSON: `{issue, comments, deps}`.

Example:
```sh
tissue show tissue-a3f8e9 --json
```

### tissue edit

Usage: `tissue edit <id> [--title t] [--body b] [--status open|in_progress|paused|duplicate|closed] [--priority 1-5] [--add-tag t] [--rm-tag t] [--json|--quiet]`

Updates an issue. At least one change is required.

Options:
- `--title`: new title.
- `--body`: new body (supports `\n`, `\t`, `\\`).
- `--status`: `open`, `in_progress`, `paused`, `duplicate`, or `closed`.
- `--priority`: 1-5.
- `--add-tag`, `--rm-tag`: add/remove tags (repeatable).

Output: same as `tissue new`.

Examples:
```sh
tissue edit tissue-a3f8e9 --status closed --rm-tag build
tissue edit tissue-a3f8e9 --body "Line 1\nLine 2"
```

### tissue status

Usage: `tissue status <id> <open|in_progress|paused|duplicate|closed> [--json|--quiet]`

Shorthand for changing only the status.

Output: same as `tissue new`.

Example:
```sh
tissue status tissue-a3f8e9 closed
```

### tissue comment

Usage: `tissue comment <id> -m "text" [--json|--quiet]`

Adds a comment to an issue.

Options:
- `-m, --message`: required; supports `\n`, `\t`, `\\`.

Output:
- Default: comment id (ULID).
- JSON: `{id, issue_id, body}`.
- Quiet: comment id only (overrides `--json`).

Example:
```sh
tissue comment tissue-a3f8e9 -m "Investigating root cause\nWorking on fix"
```

### tissue tag

Usage: `tissue tag <add|rm> <id> <tag> [--json|--quiet]`

Adds or removes a single tag.

Output: same as `tissue new`.

Examples:
```sh
tissue tag add tissue-a3f8e9 backlog
tissue tag rm tissue-a3f8e9 backlog
```

### tissue dep

Usage: `tissue dep <add|rm> <id> <blocks|relates|parent> <target> [--json|--quiet]`

Adds or removes a dependency edge.

Notes:
- `blocks` and `parent` are directional (`src -> dst`).
- `relates` is undirected; the stored order is normalized by id.

Output:
- Default: source issue id.
- JSON: `{action, src_id, dst_id, kind}`.

Examples:
```sh
tissue dep add tissue-a3f8e9 blocks tissue-b19c2d
tissue dep rm tissue-a3f8e9 relates tissue-b19c2d
```

### tissue deps

Usage: `tissue deps <id> [--json]`

Lists active dependencies that involve the issue.

Output:
- Human: `kind src -> dst` per line.
- JSON: array of Dep records.

Example:
```sh
tissue deps tissue-a3f8e9 --json
```

### tissue ready

Usage: `tissue ready [--json]`

Lists open issues (status `open`) with no active blockers (`open`, `in_progress`, `paused`).

Output: same shape as `tissue list`.

Example:
```sh
tissue ready --json
```

### tissue clean

Usage: `tissue clean [--older-than Nd] [--force] [--json]`

Removes closed or duplicate issues from the JSONL log (and rebuilds the cache).

Options:
- `--older-than`: only remove issues updated more than N days ago (`30` or `30d`).
- `--force`: perform the removal; without it, the command is a dry run.
- `--json`: output a summary object.

Output:
- Human: list of issues to be removed and a summary.
- JSON: see "Clean response" in JSON output reference.

Examples:
```sh
tissue clean --older-than 30d
tissue clean --older-than 30 --force --json
```

## Search details

`tissue list --search "query"` uses SQLite FTS5 with BM25 ranking.
Titles are weighted higher than bodies. Use quotes for phrase queries.

## Priority

- Range: 1 (highest) to 5 (lowest).
- Default for new issues: 2.

## Status

- Allowed: `open`, `in_progress`, `paused`, `duplicate`, `closed`.
- Active statuses: `open`, `in_progress`, `paused` (these can block other issues).
- Terminal statuses: `closed`, `duplicate` (eligible for `tissue clean`).
- `tissue ready` lists issues with status `open` only.

## Dependencies and ready queue

- `blocks`: `A blocks B` means B is not ready while A is active (`open`, `in_progress`, `paused`) (transitive).
- `parent`: directional parent/child edge, no effect on readiness.
- `relates`: undirected; stored once regardless of order.
- `tissue ready` lists issues with status `open` and no active blockers.

## Common agent workflows

Create, log, and close:

```sh
id=$(tissue new "Fix flaky tests" --quiet)
tissue comment "$id" -m "Investigating"
tissue status "$id" closed
```

Find work that is unblocked:

```sh
tissue ready --json
```

Link issues:

```sh
tissue dep add "$id" blocks "$other"
tissue dep add "$id" relates "$other"
```

Use a custom store location (e.g., for AI agent isolation):

```sh
tissue --store .claude/.tissue init
tissue --store .claude/.tissue new "Agent task" --quiet
tissue --store .claude/.tissue list --json
```

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
