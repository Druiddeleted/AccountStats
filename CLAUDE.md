# CLAUDE.md — AccountStatistics

This file gives project-specific guidance to Claude Code on top of the general addon guidance in `~/projects/addons/CLAUDE.md`.

## What this addon does

Adds an Account tab to the Achievements window that shows statistics summed across every character on the account. See `README.md` for the user-facing description.

## File layout

All Lua source lives under `src/`. The top-level addon directory holds only metadata (`.toc`, `.pkgmeta`, `LICENSE`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `.github/`).

- `src/core.lua` — slash commands, event registration, `ScrapeStats` (async coroutine), debounced scrape scheduler.
- `src/resolver.lua` — value parsers (money/numeric/labeled), category map + sibling lookup, max-style detection, `SummedStatistic` with strategy-based resolution (memoized), `PrimeCachesAsync`, per-character leader resolution. **All non-UI logic for turning a stat ID into a display string lives here.**
- `src/ui.lua` — Account tab creation, ElvUI skin integration, ScrollBox row rewrite hook, account-mode toggle, per-row breakdown tooltip. Calls into `resolver.lua` via `AS.SummedStatistic`, `AS.FormatPerCharValue`, `AS.IsCharDisabled`.
- `src/options.lua` — Settings panel (registered via `Settings.RegisterCanvasLayoutCategory`) with realm/character disable checkboxes plus a debug-logging toggle.
- `src/export.lua` — `/as export` window that emits a CSV of every stat × character.

`.toc` load order: `core` → `resolver` → `ui` → `options` → `export`. Resolver must load before `ui` (which calls `AS.SummedStatistic`).

## Releasing a new version

CurseForge: **Account Statistics**, project owned by `Druiddeleted`, project ID `1530942`. GitHub: `Druiddeleted/AccountStats`.

The GitHub Action (`.github/workflows/release.yml`) handles two flows:

- **Tag push** (`git push origin x.y.z`): auto-builds and uploads as **alpha** to CurseForge.
- **Manual dispatch** (Actions tab → "Release" → "Run workflow"): pick a tag and a release type (`alpha` / `beta` / `release`). Used to **promote** a previously-tagged alpha to release once it's tested.

To cut a new version:

1. Bump `## Version: x.y.z` in `AccountStatistics.toc`.
2. Add a `## x.y.z` section at the top of `CHANGELOG.md` summarizing changes since the last tag (use `git log <prev-tag>..HEAD` for the list).
3. Commit and tag:
   ```bash
   git commit -am "Release x.y.z"
   git tag x.y.z
   git push && git push origin x.y.z
   ```
4. The push triggers an alpha upload. Verify on CurseForge.
5. After testing, promote: Actions tab → Release → Run workflow → enter the tag, pick `release`. That re-runs the packager against the same tag and uploads as a Release file.

If a workflow run fails, the usual culprits are: missing `CF_API_KEY` secret, the project ID in the workflow getting out of sync, or the tag not matching the trigger pattern (`v*` or `[0-9]*`).

## Versioning conventions

Semver: bump patch for fixes, minor for features, major for breaking changes (e.g. SavedVariables format change that wipes existing data).

When SavedVariables format changes in a backwards-incompatible way, add a one-time migration in `core.lua`'s `ADDON_LOADED` handler so users don't lose their captured stats.

## When working on stat resolution logic

The trickiest area in this addon is `SummedStatistic` and the sibling-resolution logic in `ui.lua`. There are several different paths:

- **Money values** (contain `|T...|t` texture markers) → parse to copper, sum, format with `GetMoneyString`.
- **Plain numeric** stats → sum across characters.
- **"The most"-style stats** (detected by keywords in name like `most`, `highest`, `longest` via `IsMaxStyleStatistic`) — multiple sub-strategies:
  - Per-char values have labels matching sibling stat names → sum the matching siblings across chars (handles delves: `6 (Kriegval's Rest)` per char → sum of `Kriegval's Rest clears` siblings).
  - Per-char values have empty parens (`16 ()`) → sum siblings grouped by base name with difficulty filter (raid vs dungeon by detecting `Raid Finder`).
  - Per-char values are plain numbers (no parens) → take max across chars (e.g. *Highest 3v3 personal rating*).

Results are memoized via `_summedCache`; **do not** invalidate the cache on automatic scrapes (it kills performance — already discovered the hard way). Manual `/as scrape` and option toggles should invalidate.

The category map (`_catMap`) and per-stat sibling lists (`_siblingsCache`) are built lazily, then warmed in the background via `AS.PrimeCachesAsync` ~15s after entering world to avoid first-click freezes.

## Testing

Use `./sync AccountStatistics` then `/reload`. There's no automated test harness. For inspecting captured data, `/as export` produces a copy-pasteable CSV.
