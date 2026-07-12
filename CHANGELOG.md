# Changelog

## 0.1.1

- Fixed a taint error ("attempt to compare a secret number value (execution tainted by 'AccountStatistics')") that could surface elsewhere in the UI — most visibly on the World Map — after hovering the account breakdown tooltip. The breakdown tooltip now uses a dedicated, addon-owned tooltip frame instead of the shared `GameTooltip`, keeping our taint from spreading into Blizzard's Secret Values.

## 0.1.0

- Initial release.
- Adds an Account tab to the Achievements window with statistics summed across every character on the account.
- Per-character breakdown tooltip on hover.
- Settings panel for excluding realms or characters from sums.
- Smart aggregation for "the most"-style stats (resolves the actual account-wide leader from per-instance kill stats where the API exposes them).
- CSV export via `/as export`.
