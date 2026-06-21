# cleanthemac

A safe, interactive developer-cache cleaner for macOS.

`clean.sh` scans the disk-hungry caches that pile up on a developer machine
(Docker, Go, npm, uv, pnpm, Homebrew, Playwright, and more), prints a detailed
report, and deletes **only the categories you approve**. Where a tool ships its
own cleanup command it is preferred (`docker system prune`, `go clean -modcache`,
`npm cache clean`, …); otherwise only well-known cache paths are removed with
`rm -rf`.

It never touches real data — iCloud Drive, project source, or browser profiles
are out of scope, and `/` or `$HOME` are never deleted.

## Features

- **Detailed analysis** — every cache category with its size and a safety tag
  (`safe` / `caution`), sorted largest-first, with a grand total.
- **Approve before delete** — per-category `y/N` prompt, defaulting to **No**.
- **Native cleanup commands** — uses each tool's own pruner when available, so
  cache indexes stay consistent and only unused entries are removed.
- **Reclaim summary** — reports the disk space freed and writes a log to
  `reports/`.
- **Dry-run mode** — see the full report without deleting anything.
- **Non-interactive mode** — `--yes` / `--only` for scripted use.

## Safety model

| Treated as cleanable cache                                                                                         | Never touched                                                                                           |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Docker images / build cache, Go/npm/uv/pnpm/Homebrew/pip caches, Playwright browsers, tool caches under `~/.cache` | iCloud Drive (`Mobile Documents`, `CloudDocs`), project directories, Chrome/JetBrains profiles & config |

- Default answer to every prompt is **No** — nothing is removed unless you type `e`/`y`.
- Docker volumes are preserved unless you explicitly opt in (`--docker-volumes` or
  prune level `3`).
- Paths equal to `/` or `$HOME` are refused as a guard against accidents.

## Requirements

- macOS with **zsh** (the default shell since Catalina).
- Optional tools — each category is only offered if its tool/path exists:
  `docker`, `go`, `npm`, `uv`, `pnpm`, `brew`.

## Installation

```sh
git clone https://github.com/ensarkovankaya/cleanthemac.git
cd cleanthemac
chmod +x clean.sh
```

## Usage

```sh
./clean.sh                          # interactive: analyze → report → approve → delete
./clean.sh --dry-run                # report only, deletes nothing
./clean.sh --only go_modcache,npm   # restrict to specific categories
./clean.sh --yes                    # approve all available (Docker volumes excluded)
./clean.sh --docker-volumes         # also prune Docker named volumes (risky)
./clean.sh --help
```

### Flags

| Flag               | Effect                                                                              |
| ------------------ | ----------------------------------------------------------------------------------- |
| `--dry-run`        | Analyze and print the report; delete nothing.                                       |
| `--yes`, `-y`      | Approve every available category without prompting (Docker volumes still excluded). |
| `--only k1,k2`     | Limit the run to the listed category keys.                                          |
| `--docker-volumes` | Allow Docker named-volume pruning in `--yes` mode.                                  |
| `--help`, `-h`     | Show usage.                                                                         |

## Categories

| Key           | What it cleans                                                      | Cleanup method            | Safety  |
| ------------- | ------------------------------------------------------------------- | ------------------------- | ------- |
| `docker`      | Unused images, stopped containers, build cache                      | `docker system prune`     | caution |
| `claude_vm`   | Claude local-agent VM bundles                                       | `rm -rf`                  | caution |
| `go_modcache` | Downloaded Go modules                                               | `go clean -modcache`      | safe    |
| `npm`         | npm package cache (`_cacache`)                                      | `npm cache clean --force` | safe    |
| `uv`          | Python `uv` package cache                                           | `uv cache prune`          | safe    |
| `pnpm`        | pnpm content-addressable store                                      | `pnpm store prune`        | safe    |
| `playwright`  | Downloaded Playwright browsers                                      | `rm -rf`                  | safe    |
| `codex`       | `codex-runtimes` cache                                              | `rm -rf`                  | safe    |
| `copilot`     | `github-copilot` cache                                              | `rm -rf`                  | safe    |
| `brew`        | Homebrew download cache                                             | `brew cleanup -s`         | safe    |
| `pip`         | pip wheel/download cache                                            | `rm -rf`                  | safe    |
| `misc`        | `golangci-lint`, `outlines`, `node`, `nvim` caches under `~/.cache` | `rm -rf`                  | safe    |

> Categories whose tool or path is absent are skipped automatically and listed
> under "Skipped" in the report.

### Docker prune levels

When you approve Docker, the script asks for a level:

1. **dangling** — dangling images + stopped containers only.
2. **all unused images** — everything unused, volumes preserved (recommended).
3. **+ named volumes** — also removes unused volumes (**risky**: can delete
   database data).

## Reports

After each run a log is appended to `reports/clean-<timestamp>.log` with the
approved categories and the space reclaimed. The `reports/` directory is
git-ignored.

## Disclaimer

This tool deletes cache data. Although every category is recreatable and the
defaults are conservative, review the report before approving. Use at your own
risk.

## License

MIT — see [LICENSE](LICENSE).
