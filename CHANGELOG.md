# Changelog

## 0.1.2-alpha2

- Now targets the current client (12.1.0). The interface number still said 12.0.5, so the addon showed as out of date in the in-game list and was published against the wrong game version on CurseForge. No functional change.

## 0.1.2-alpha1

- Internal restructure, no intended change in behaviour. SavedVariables now has a single owner: every read and write goes through one module instead of five modules poking the global across ~40 sites. The rule that toggling a character or realm has to invalidate the account-sum cache — previously copy-pasted at three call sites — now lives inside the toggle itself, so it can't be forgotten, and the matching rule that a routine stat scrape must *not* invalidate it (that recompute is expensive enough to feel) is enforced in the same place.
- Internal: the stat scrape and the cache priming shared no code despite doing the same thing — each carried its own copy of the frame-budgeted coroutine plumbing, and the two copies had drifted apart. Both now use one scheduler.
- Worth watching in this alpha: that realm/character checkboxes still take effect immediately, and that the first click on a "the most"-style statistic category is still smooth rather than hitching.

## 0.1.1

- Fixed a taint error ("attempt to compare a secret number value (execution tainted by 'AccountStatistics')") that could surface elsewhere in the UI — most visibly on the World Map — after hovering the account breakdown tooltip. The breakdown tooltip now uses a dedicated, addon-owned tooltip frame instead of the shared `GameTooltip`, keeping our taint from spreading into Blizzard's Secret Values.

## 0.1.0

- Initial release.
- Adds an Account tab to the Achievements window with statistics summed across every character on the account.
- Per-character breakdown tooltip on hover.
- Settings panel for excluding realms or characters from sums.
- Smart aggregation for "the most"-style stats (resolves the actual account-wide leader from per-instance kill stats where the API exposes them).
- CSV export via `/as export`.
