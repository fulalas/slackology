# About

A Bash script that compares every package in a Slackware repository (or just the packages installed on your machine) against the latest upstream release known to [Repology](https://repology.org), and can optionally fetch the newest source and rebuild outdated packages from their SlackBuilds.

## How it works

1. Downloads the `FILE_LIST` of a Slackware repository (default: `slackware64-current`) — or reads a local listing, or your installed package database.
2. Queries the Repology API for each package, translating Slackware package names to Repology project names where they differ.
3. Reports each package as up to date, outdated, ahead of the tracker, snapshot/rolling, or not tracked, with a color-coded summary.
4. With `--build` (experimental), fetches the latest upstream source for each outdated package (from git forges, PyPI, RubyGems, SourceForge, or plain HTTP/FTP directory listings) into your local Slackware source tree and runs the package's `<pkg>.SlackBuild`.

Repology lookups are cached for 24 hours under `~/.cache/slackology` to keep repeat runs fast and API-friendly. Requests are rate-limited and parallelized with a configurable number of workers.

## Requirements

`bash`, `curl`, `jq`, `xargs`, `nproc`, `flock` — plus `git` if you use `--build` against git forges.

## Usage

```bash
# Check all of slackware64-current against upstream
./slackology.sh

# Check only what's installed on this machine
./slackology.sh --installed

# Check a single package
./slackology.sh -p mozilla-firefox

# Fetch latest sources and rebuild outdated packages from a local source tree
./slackology.sh --build --source-dir /path/to/source
```

Run `./slackology.sh --help` for the full list of options (custom repo URL, parallelism, API rate limiting, cache control, etc.).

## Files

| File | Purpose |
|------|---------|
| `slackology.sh` | The main script. |
| `repologyNames.map` | Maps Slackware package names to Repology project names (e.g. `mozilla-firefox` → `firefox`). Case and `_`/`-` differences are normalized automatically, so only genuine renames need entries. Auto-detected next to the script; override with `-R`. |
| `upstreamLinks.tsv` | TSV of `package<TAB>upstream_url`, used by `--build` to locate each package's upstream source. Auto-detected next to the script; override with `-U`. |

## Notes

- The Slackware repo listing itself is never cached — it's fetched fresh every run. Only per-package Repology lookups are cached (clear them with `-c/--clear-cache`, bypass with `-n/--no-cache`).
- Please be considerate of the Repology API: the defaults (3 concurrent requests, 1.1 s spacing) are chosen to stay well within polite limits.
