# unity-ai-kit

Reusable Unity Android (AAB) build workflow for AI coding agents (Claude Code, Codex, Cursor, ...).

## Use in a new Unity project
```
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/NewGame            # safe: never overwrites your edits
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/NewGame --min-target 37
```
Then open the project once in Unity, close it, and run `./tools/build-aab.sh --check`, then `./tools/build-aab.sh`.

## Change the Target API Level (for example to 37)
1. Close Unity. Run `install.sh /path/to/Game --set-target 37` (edits ProjectSettings and the floor in `.unity-kit.env`),
   or change it in Player Settings and set `UNITY_KIT_MIN_TARGET_API=37` in `.unity-kit.env`.
2. Open Unity, confirm Player Settings > Android > Target API Level shows 37, commit both files.
3. `./tools/build-aab.sh --check`, build, test on an API 37 device or emulator.

## Update a project to a newer kit
```
git -C ~/Documents/GitHub/unity-ai-kit pull
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/Game --status     # what differs
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/Game --update     # replaces kit-owned files (backups: *.bak-kit)
```

## What is where
| File | Owner | Purpose |
|---|---|---|
| `docs/ai/UNITY.md` | kit | Generic rules and error table. `--update` replaces it (old copy saved as `.bak-kit`). |
| `docs/ai/UNITY.local.md` | project | Project notes the agent may amend. Never overwritten. |
| `.unity-kit.env` | project (committed) | Non-secret settings, e.g. `UNITY_KIT_MIN_TARGET_API`. |
| `~/.config/unity-kit/projects/<Folder>.env` | you (private) | Keystore settings for that game. |
| `~/.config/unity-kit/env` | you (private) | Machine-wide defaults such as `UNITY_PATH`. |
| `tools/build-aab.sh`, `Packages/com.juicy.buildkit` | kit | Build entry point and preflight checks. |

Settings precedence: real environment variables > per-project secrets > `.unity-kit.env` > machine defaults.
Windows: use Git Bash (Git for Windows). Not yet tested there.
