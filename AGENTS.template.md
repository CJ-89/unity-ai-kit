# AGENTS.md

Unity project (Android app bundle for Google Play).

- For anything about builds, Android, Gradle, plugins or signing: read `docs/ai/UNITY.md` (generic rules) and `docs/ai/UNITY.local.md` (this project's notes) first.
- Build: `./tools/build-aab.sh` (use `--check` first). Close the Unity Editor before building.
- Settings: Target API floor is in `.unity-kit.env`. Never read or print keystores, passwords, or anything under `~/.config/unity-kit/`.

## Project-specific notes
(Add notes that apply only to this project in `docs/ai/UNITY.local.md`, or below this line.)
