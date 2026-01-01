# tissue

**Issue tracking for agents.** Non-interactive, git-native, machine-first.

A machine-first issue tracker optimized for agents, featuring a git-native data structure for conflict-free collaboration.

## Why?

- **Machine-First** — Designed for automation: JSON output, strict exit codes, no prompts
- **Git-Native** — Append-only log merges cleanly without conflicts
- **Fast** — SQLite + FTS5 for instant queries
- **Portable** — Single static binary, zero dependencies

## Install

```sh
curl -fsSL https://github.com/evil-mind-evil-sword/tissue/releases/latest/download/install.sh | sh
```

<details>
<summary>Other methods</summary>

**Pre-built binaries:** [GitHub Releases](https://github.com/evil-mind-evil-sword/tissue/releases)

**From source** (requires [Zig](https://ziglang.org/) 0.15.2+):
```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/tissue /usr/local/bin/
```
</details>

## Quick start

```sh
# Initialize in current repo
tissue init

# Create an issue
id=$(tissue new "Fix flaky tests" -p 1 --quiet)

# Add context and close
tissue comment "$id" -m "Root cause: race condition"
tissue status "$id" closed

# Find unblocked work
tissue ready
```

Example output:
```
$ tissue list --status open
ID              STATUS  PRI  TITLE
tissue-a3f8e9   open    1    Fix flaky tests
tissue-b19c2d   open    2    Add caching layer
```

## Commands

| Command | Description |
|---------|-------------|
| `init` | Create `.tissue/` store |
| `new "title"` | Create issue (returns ID) |
| `list` | List issues (filter with `--status`, `--tag`, `--search`) |
| `show <id>` | View issue details |
| `edit <id>` | Update title, body, status, priority, tags |
| `status <id> <status>` | Change status (`open`, `in_progress`, `closed`, ...) |
| `comment <id> -m "text"` | Add comment |
| `tag add/rm <id> <tag>` | Add or remove tag |
| `dep add/rm <id> <kind> <target>` | Link issues (`blocks`, `relates`, `parent`) |
| `ready` | List open issues with no blockers |
| `clean` | Remove old closed issues |

All commands support `--json` for machine output and `--quiet` for ID-only output.

## Agent contract

- Non-interactive; safe for automation
- Success: exit 0, output on stdout
- Failure: exit 1, error on stderr
- `--json`: minified JSON with trailing newline
- `--quiet`: returns only the ID (overrides `--json`)
- Store discovery: `--store` flag → `TISSUE_STORE` env → walk up to find `.tissue/`

## Architecture

```
.tissue/
├── issues.jsonl   # Append-only log (source of truth, git-tracked)
├── issues.db      # SQLite cache (derived, git-ignored)
└── .gitignore
```

The JSONL log is the source of truth. The SQLite cache is rebuilt automatically when stale—delete it anytime.

## Name

**t**racking **issue**s.
