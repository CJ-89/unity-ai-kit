# Unity Android build rules (generic, kit-owned)

Scope: Unity projects only. Read this before touching Android/Gradle settings, plugins, or build scripts.
Project-specific facts live in `docs/ai/UNITY.local.md`; Editor (MCP) workflow rules in `docs/ai/UNITY-EDITOR.md`. See "Amending" below for who edits what.

## Hard rules
1. Target API Level is set explicitly in Player Settings (Android > Other Settings). Never "Automatic".
   The project's enforced floor is `UNITY_KIT_MIN_TARGET_API` in `.unity-kit.env` (kit default 36 = Google Play's requirement
   for new apps and updates from 2026-08-31; confirm current policy in Play Console). The floor is a minimum, not a pin.
2. Never put `androidx.*.aar` or `androidx.*.jar` files in `Assets/`. AndroidX comes from Maven through the
   External Dependency Manager (EDM4U / Android Resolver). The Preflight guard fails the build if it finds any.
3. Gradle templates: `compileSdk **APIVERSION**` only. No hard-coded `compileSdkVersion`, no
   `resolutionStrategy { force ... }` blocks. Fix versions at the source (`*Dependencies.xml`), not by forcing.
4. Never edit between `Android Resolver Dependencies Start` / `End` in `mainTemplate.gradle`.
5. Never read, print, or commit keystores (`*.keystore`, `*.jks`), passwords, or anything under `~/.config/unity-kit/`.
6. Unity cannot open the same project twice. Close the Editor before a batch build.
7. Work on a git branch. Commit before large changes. Show diffs of `ProjectSettings/` and `Assets/Plugins/Android/`.
8. Unity 6 Build Profiles (`Assets/Settings/Build Profiles/*.asset`) can hold their own copy of Player Settings, and that copy wins
   at build time. The Target API Level (and Bundle Version Code) must be correct in BOTH places. Verify on disk, not on screen:
   `grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset'`.
9. Unity rewrites `ProjectSettings/*.asset` from memory while it is open. Never edit them (by hand or by script) while the Editor is
   running; close it first. After changing settings: open Unity once, close it, and re-check the files still hold the new value.
10. Batch builds cannot type passwords: Unity does not save keystore passwords. Signing comes from `UNITY_KEYSTORE_*` in the
   per-project private env file. Never ask the user to paste passwords into chat.

## Build
```
./tools/build-aab.sh            # full build -> Builds/<productName>.aab, log in Logs/build.log
./tools/build-aab.sh --check    # seconds-long sanity check, no build
```
- Fix the FIRST error only, then rebuild. Never rerun an unchanged build.
- The script prints a short error summary. Read `Logs/build.log` only around the first `FAILURE`/`error`.
- Exit codes: 3 Unity open, 4 stray AndroidX, 5 Target API, 6 keystore file missing, 7 signing not configured.
- Reading `Logs/build.log`: it is mostly stack frames. Drop the lines containing `PluginImporter object at version` /
  `below the supported minimum` (harmless noise), then look for `UnityException`, `Unable to sign`, `error CS`, `FAILURE:`, and the
  final `Build Finished, Result:` line. The script prints this filtered summary for you.
- Settings precedence: environment variables > `~/.config/unity-kit/projects/<ProjectFolder>.env` (keystore, private)
  > `.unity-kit.env` (committed, no secrets) > `~/.config/unity-kit/env` (machine defaults).

## Raising the Target API Level (e.g. 36 -> 37)
1. Close Unity. `install.sh <project> --set-target N` (patches Player Settings AND any Android Build Profile override, and sets the floor
   in `.unity-kit.env`). If you change it by hand in the Editor, change it in Player Settings and in File > Build Profiles > Android.
2. Open Unity, close it again, and verify on disk: `grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset'`.
   Commit `ProjectSettings/ProjectSettings.asset`, `Assets/Settings/Build Profiles/` and `.unity-kit.env`.
3. Make sure the SDK platform exists cleanly: `<Unity>/PlaybackEngines/AndroidPlayer/SDK/platforms/android-N(.0)/android.jar`.
   Remove odd duplicates such as `android-N.0-2`; reinstall the Android module in Unity Hub if needed.
4. `./tools/build-aab.sh --check`, then a full build.
5. Test on a device/emulator at API N. Read Android's "behavior changes for apps targeting N" page.
   Typical game risks at 37: large-screen orientation/resizability restrictions are ignored, background audio needs a
   foreground service, LAN features need the local-network permission, Certificate Transparency is on by default.
6. Third-party SDKs (ads, Play Games, analytics) must be on versions that support N.

## Error -> cause -> fix
| Symptom | Cause | Fix |
|---|---|---|
| `Duplicate class androidx.* found in modules ...aar (:androidx.x:) and ... (androidx.x:x:ver)` | Loose AAR/JAR in `Assets/` plus the same library from Maven | Delete `Assets/**/androidx.*.aar/.jar` (+ `.meta`); EDM4U > Delete Resolved Libraries > Force Resolve; `rm -rf Library/Bee/Android` |
| `:unityLibrary is currently compiled against android-32` / `requires ... compile against version 3x` | Target API Level too low or Automatic with a broken SDK platform folder | Set Target API Level explicitly; verify the platform folder (see above) |
| `attribute android:enableOnBackInvokedCallback not found` (e.g. unity-ads) | Compile SDK older than 33 | Raise Target API Level; remove unused ad SDKs |
| `checkReleaseAarMetadata SKIPPED` then odd AAPT errors | Unity skips the metadata check, so a low compileSdk surfaces late | Check compileSdk in `Library/Bee/Android/Prj/IL2CPP/Gradle/*/build.gradle` |
| Build only worked because a template hard-codes `compileSdkVersion N` | The hard-coded line masked a wrong Target API Level | Remove it; fix the Target API Level instead (`--check` warns about this) |
| Preflight says `Target API Level is 31` (or 30, or 0) although Player Settings shows 36/37 | An Android Build Profile overrides Player Settings, or unsaved edits exist only in the Editor's memory | `grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset'`; with Unity closed run `install.sh <project> --set-target N` (patches both); open Unity, close it, grep again |
| Value in ProjectSettings keeps changing back (36 -> 0 -> 30) while the Editor is open | Unity rewrites settings from memory / from the active profile on save and on open | Fix the profile first (see above); never edit settings files with the Editor open. If it still flips to Automatic, check `Assets/GooglePlayPlugins/**/AndroidSdkPlatform.cs` (it can set Automatic; unverified suspect) |
| `UnityException: Unable to sign the Android application` / `No keystore passwords were found` | Custom keystore enabled but Unity saved no passwords; batch mode cannot ask | Fill `UNITY_KEYSTORE_PATH/_PASS`, `UNITY_KEYALIAS_NAME/_PASS` in `~/.config/unity-kit/projects/<Project>.env` (`--check` and Preflight now stop early with exit 7) |
| Many `Serialized file ... .meta contains a PluginImporter object at version 1, below the supported minimum (2)` | Old plugins (e.g. Google Mobile Ads, EasyMobile) ship import settings in a pre-Unity-2019 format | Usually noise: they were logged as errors but did not stop a real build. Clean up with Assets > Reimport All (Editor open) or update the plugin. Do not hand-edit metas without a backup |
| Stray files return after a branch switch or plugin update | Generated files were committed or restored | Delete them; commit the deletion; Force Resolve after every plugin update |

Harmless warnings (ignore unless something else breaks): `package=` attribute ignored in plugin manifests,
`minSdkVersion > targetSdkVersion` in GooglePlayGamesManifest, `android.enableJetifier` deprecated (turn off only after a green build),
namespace `com.google.unity.ads` used twice.

## After any plugin / SDK update
1. EDM4U: Assets > External Dependency Manager > Android Resolver > Delete Resolved Libraries, then Force Resolve.
2. `rm -rf Library/Bee/Android`
3. `./tools/build-aab.sh --check`, then a full build.

## Amending
- This file (`docs/ai/UNITY.md`) is generic and owned by the kit. `install.sh --update` replaces it (the old copy is saved as `UNITY.md.bak-kit`).
  Do not put project-specific notes here; they would be lost on update.
- Project-specific notes go in `docs/ai/UNITY.local.md`. Edit it only when the user asks; show the diff; never add secrets.
- A lesson that applies to any Unity project: edit `UNITY.md` in the kit repo (`unity-ai-kit`), commit, tag, then run `install.sh <project> --update` in each project.
- Never delete a rule without asking.

## Changelog
- 1.3.0 (2026-10-13): Claude Code <-> Unity Editor: `install.sh` pins the MCP for Unity bridge in `Packages/manifest.json`, installs `docs/ai/UNITY-EDITOR.md` (editor workflow rules + troubleshooting), and `CLAUDE.md` now auto-loads `UNITY.local.md` and `UNITY-EDITOR.md`. `UNITY.local.md` template gains code map / known issues sections.
- 1.2.0 (2026-10-11): lessons from the Jumoji build: Build Profile overrides are scanned (`--check`) and patched (`--set-target`); early signing check (exit 7, plus Preflight in batch mode); filtered error summary; old plugin import files reported; version code and output path printed.
- 1.1.0 (2026-10-11): floor-based Target API (raise to 37 without editing the kit), per-project secrets, local-notes split, Gradle/SDK-platform warnings.
- 1.0.0 (2026-10-11): initial version (lessons from a real Android build: duplicate AndroidX classes, low Target API Level).
