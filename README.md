# unity-ai-kit

Reusable Unity Android (AAB) build workflow for AI coding agents (Claude Code, Codex, Cursor, ...).

## What it does
- **Rules for the agent** (`docs/ai/UNITY.md`, `docs/ai/UNITY-EDITOR.md`): Android/Gradle/signing rules, an error -> cause -> fix
  table, device-testing pitfalls and a Google Play release checklist, all learned from shipping a real Unity game.
- **`tools/build-aab.sh`**: one command for a signed Android App Bundle from the command line. `--check` catches the usual
  mistakes in seconds (Target API, Build Profile overrides, signing, stray AndroidX files, empty app icons, data-sending SDKs, ...);
  `--verify` inspects the finished `.aab` (version, debuggable, ABIs, signer SHA-1).
- **`Packages/com.juicy.buildkit`**: a small Unity Editor package with the batch build entry point and preflight guards.
- **Claude Code <-> Unity Editor**: pins the [MCP for Unity](https://github.com/CoplayDev/unity-mcp) bridge so Claude Code can
  read the console, recompile and enter Play Mode in the open Editor.
- **`install.sh`**: installs or updates all of the above in any Unity project, without overwriting your own edits.

Requirements: Unity 6 (tested with 6000.x), Android build support, bash. Tested on macOS; Linux should work; Windows (Git Bash) is untested.
MCP for Unity is a third-party package with its own license; the kit only adds a pinned reference to it.

## Use in a new Unity project
```
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/NewGame            # safe: never overwrites your edits
~/Documents/GitHub/unity-ai-kit/install.sh /path/to/NewGame --min-target 37
```
Then, for a project that should ship to Google Play:
1. Fill in the signing lines in `~/.config/unity-kit/projects/<Folder>.env` (keystore path and passwords; Unity never saves the passwords).
2. Open the project once in Unity and confirm Target API Level; close Unity. Verify on disk (Unity 6 Build Profiles can override it):
   `grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset'`
3. `./tools/build-aab.sh --check`, then `./tools/build-aab.sh` (Unity must be closed). The bundle lands in `Builds/` and is checked
   by `--verify` (version, debuggable, signer SHA-1, ...). `./tools/build-aab.sh --verify some.aab` inspects any bundle.
4. Raise the Bundle Version Code for every Play upload (`UNITY_BUMP_VERSION_CODE=1` in `.unity-kit.env` does it automatically).

## Claude Code + Unity Editor (MCP for Unity)
`install.sh` adds the MCP for Unity bridge (pinned version) to `Packages/manifest.json`, so Claude Code can read the console,
inspect scenes and prefabs, recompile and enter Play Mode in the open Editor. The rules Claude follows are in `docs/ai/UNITY-EDITOR.md`.

**One-time per Mac** (not per project):
1. Install Claude Code and uv with their official installers. Both go to `~/.local/bin`, which Unity can see.
   Do not rely on a Homebrew in a custom prefix (e.g. `~/.homebrew`): Unity is a GUI app and does not read your shell PATH.
   ```
   curl -fsSL https://claude.ai/install.sh | bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
2. Register the bridge once for all projects (it always listens on the same local address):
   ```
   claude mcp add --transport http --scope user UnityMCP http://127.0.0.1:8080/mcp
   ```
3. In the first project: Window > MCP for Unity > Advanced > tick "Auto-Start Server on Editor Load" (saved for every project).

**Per project** (automatic after `install.sh`): open the project in Unity, then run `claude` in the project folder.
`/mcp` should show `UnityMCP` with a tick. Run `/context` to confirm `CLAUDE.md`, `UNITY.local.md` and `UNITY-EDITOR.md` loaded.

Do not press **Unregister** in the MCP for Unity window: it removes UnityMCP from every scope, including the user-wide one.
Keep one Unity project open at a time while working with Claude. Troubleshooting: `docs/ai/UNITY-EDITOR.md`.

## Change the Target API Level (for example to 37)
1. Close Unity. Run `install.sh /path/to/Game --set-target 37` (edits ProjectSettings, any Android Build Profile override, and the floor in `.unity-kit.env`),
   or change it in Player Settings and in File > Build Profiles, and set `UNITY_KIT_MIN_TARGET_API=37` in `.unity-kit.env`.
2. Open Unity, confirm the Target API Level shows 37, close it and grep the files (see above); commit them.
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
| `docs/ai/UNITY-EDITOR.md` | kit | Rules for working in the open Editor through MCP, plus troubleshooting. `--update` replaces it. |
| `docs/ai/UNITY.local.md` | project | Project notes the agent may amend. Never overwritten. |
| `Packages/manifest.json` (one line) | kit pin | MCP for Unity bridge; `--update` moves it to the kit's pinned version. `--no-mcp` skips it. |
| `.unity-kit.env` | project (committed) | Non-secret settings, e.g. `UNITY_KIT_MIN_TARGET_API`. |
| `~/.config/unity-kit/projects/<Folder>.env` | you (private) | Keystore settings for that game. |
| `~/.config/unity-kit/env` | you (private) | Machine-wide defaults such as `UNITY_PATH`. |
| `tools/build-aab.sh`, `Packages/com.juicy.buildkit` | kit | Build entry point and preflight checks. |

Settings precedence: real environment variables > per-project secrets > `.unity-kit.env` > machine defaults.
Windows: use Git Bash (Git for Windows). Not yet tested there.

## Known Unity 6 pitfalls (all seen on a real project)
- A Build Profile can override Player Settings: the Editor showed 36 while builds used 30/31. `--check` now scans the profiles.
- Unity rewrites settings files from memory: do not edit them while the Editor is open.
- Keystore passwords are not saved by Unity: batch builds need `UNITY_KEYSTORE_*` (`--check` stops with exit 7 otherwise).
- Old plugin `.meta` files (`PluginImporter ... version 1`) print many error lines but did not stop a build; `--check` lists them.
- The Build Profile's Player Settings copy also holds defines, version, icons and the Development Build flag; `--check` compares them.
- Empty Android icon slots ship Unity's default icon (a live game did); `--check` warns.
- An ads plugin imported over an older copy left old C# that broke ads at runtime; reinstall SDK plugins cleanly (`docs/ai/UNITY.md` rule 11).
- Unity Analytics / Cloud Diagnostics / unused Unity packages triggered a Play "Invalid data safety declaration"; `--check` lists data-sending SDKs.
- Release steps, device-testing pitfalls (two signing keys, `adb uninstall`, development vs release builds): `docs/ai/UNITY.md`.

## License
MIT, see [LICENSE](LICENSE). Provided as is, without warranty: review what it changes in your project (it shows diffs and never
commits for you), and keep your keystore and passwords out of git.
