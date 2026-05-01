# Account Statistics

A World of Warcraft addon that adds an **Account** tab to the Achievements window showing your statistics summed across every character on your account.

## Features

- Account tab on the Achievements window mirroring Blizzard's Statistics layout but with account-wide values.
- Automatically captures stats per character on login and during play (boss kills, dungeon completions, achievements, deaths, money, etc.).
- Hover any row for a per-character breakdown.
- Smart aggregation for "the most"-style stats: resolves the true account-wide leader from per-instance sibling stats when the API exposes them (delves, raid bosses by difficulty, dungeon bosses).
- Settings panel to exclude entire realms or specific characters from sums.
- CSV export of all stats × characters.

## Slash commands

- `/as` — open settings panel
- `/as help` — list every command
- `/as scrape` — capture this character's stats now
- `/as list` — list known characters
- `/as export` — open a CSV view of all stats × characters
- `/as stat <id>` — show one stat across all characters
- `/as forget <Realm-Name>` — remove a character from the database
- `/as debug` — toggle debug logging

## Privacy

All data is stored locally in your `WTF/Account/.../SavedVariables/AccountStatistics.lua`. Nothing is transmitted anywhere.

## License

[MIT](LICENSE)
