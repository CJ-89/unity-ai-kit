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
   at build time. It covers far more than the Target API Level: version and version code, scripting defines, app icons, keystore,
   Development Build, Unity cloud services. Every Player Settings change must be correct in BOTH places; `--check` compares the
   release-relevant ones. Verify on disk, not on screen, e.g. `grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset'`.
9. Unity rewrites `ProjectSettings/*.asset` from memory while it is open. Never edit them (by hand or by script) while the Editor is
   running; close it first. After changing settings: open Unity once, close it, and re-check the files still hold the new value.
10. Batch builds cannot type passwords: Unity does not save keystore passwords. Signing comes from `UNITY_KEYSTORE_*` in the
   per-project private env file. Never ask the user to paste passwords into chat.
11. SDK plugins (ads, Play Games, consent, ...) are updated by a CLEAN reinstall: delete the old plugin folders (keep a commit to roll
   back), import the new release, Force Resolve. Never import a new version over an old one: files the new version no longer ships
   stay behind and still compile (seen: 2018 ad C# source next to 2025 DLLs, so ads never ran). Use the `.unitypackage` when EDM4U
   lives in `Assets/ExternalDependencyManager` (the UPM/OpenUPM package would add a second EDM4U).
12. Keep the Android app icon set (Player Settings > Android > Icon; in Unity 6 only the Adaptive slots exist: foreground + background,
   432 px, artwork inside the centre 66%). Empty Android slots ship Unity's default icon, even if a Default Icon is set.

## Build
```
./tools/build-aab.sh            # full build -> Builds/<productName>.aab, log in Logs/build.log, then --verify
./tools/build-aab.sh --check    # seconds-long sanity check, no build
./tools/build-aab.sh --verify [file.aab]   # inspect a bundle (default: newest Builds/*.aab), no Unity needed
```
- `--verify` prints package, version name/code, min/target SDK, debuggable, AdMob App ID(s), content providers, ABIs, icon files
  and the signer SHA-1. It fails (exit 8) on a debuggable or unsigned bundle, a target SDK below the floor, or 32-bit-only native code.
  The signer SHA-1 must equal Play Console > App integrity > Upload key certificate.
- Fix the FIRST error only, then rebuild. Never rerun an unchanged build.
- The script prints a short error summary. Read `Logs/build.log` only around the first `FAILURE`/`error`.
- Exit codes: 3 Unity open, 4 stray AndroidX, 5 Target API, 6 keystore file missing, 7 signing not configured, 8 bundle failed `--verify`.
- `--check` also warns about: Build Profile vs Player Settings differences, empty Android icon slots, Development Build ticked in
  a profile, SDKs/Unity services that send data off the device (Data safety), and Google Mobile Ads installed over an older copy.
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
| Launcher shows Unity's grey logo instead of the game icon | Android icon slots empty (only the Default Icon set) | Assign Player Settings > Android > Icon > Adaptive (foreground + background) in Player Settings and the Build Profile; `--check` warns |
| Ads never load; logcat `NoSuchMethodError` / `MobileAds.initialize(activity, appId)` | Plugin C# from an old version compiled against a new Android SDK (in-place import) | Clean reinstall (rule 11); `--check` warns about mixed plugin folders |
| Play Console: "Invalid data safety declaration" | An SDK sends data the Data safety form does not declare (ads SDK, Unity Analytics/Cloud Diagnostics, an unused Unity Ads package) | Declare every SDK's data, or remove what is unused (`--check` lists them). The form must cover every version still installed by players |
| Play Games sign-in fails on a Build And Run / sideloaded build but works from Play (or the reverse) | Play Games credential exists only for one signing key | Add an Android credential for BOTH SHA-1s (upload key and app signing key, Play Console > App integrity), in the Google Cloud project linked to Play Games; publish the Play Games changes |
| Google Cloud: "Android package name and fingerprint are already in use" | That package + SHA-1 pair already has an OAuth client (pairs are unique across ALL projects) | Find it (it may be the existing credential, or in another project); delete the one in the wrong project, wait, recreate in the Play Games project |
| Play Store: "another user has already installed an incompatible version" | A Build And Run copy (upload-key signed) still exists in another user / work profile / Secure Folder | `adb uninstall <package>` (removes it for all users); check with `adb shell pm list packages --user all` |
| Consent (UMP) form never shows while testing | Release build (no debug geography), device hash missing/old build, or consent cached | Test with a Development Build, the device hash in the debug settings, and cleared app storage. Outside the EEA/UK a release build correctly shows nothing |

Harmless warnings (ignore unless something else breaks): `package=` attribute ignored in plugin manifests,
`minSdkVersion > targetSdkVersion` in GooglePlayGamesManifest, `android.enableJetifier` deprecated (turn off only after a green build),
namespace `com.google.unity.ads` used twice.

## After any plugin / SDK update
0. It was a clean reinstall (rule 11): no files from the old version remain (`git status` shows the old ones deleted).
1. EDM4U: Assets > External Dependency Manager > Android Resolver > Delete Resolved Libraries, then Force Resolve.
2. `rm -rf Library/Bee/Android`
3. `./tools/build-aab.sh --check`, then a full build (it runs `--verify`).

## Device testing
- Build And Run (Editor) is signed with the upload key and is usually a Development Build; a Play install (internal testing or later)
  is signed with Play's app signing key and is a release build. Anything keyed to the signature (Play Games, Google sign-in, API key
  restrictions) needs both SHA-1s registered.
- `Debug.isDebugBuild` is true in the Editor and in Development Builds, false in release builds. Code that switches on it (test ad units,
  consent debug geography) behaves differently on Play. Untick Development Build after device tests and check the Build Profile diff.
- Before installing from Play over a Build And Run copy: `adb uninstall <package>` (all users), or Play refuses the install.
- Never tap live ads. Register test phones in the ad network (AdMob > Settings > Test devices) so release builds show labelled test ads.
- Useful: `adb logcat -c`, reproduce, then `adb logcat -d | grep -iE "<your log prefix>|UserMessagingPlatform|GamesServices|AndroidRuntime"`.

## Release checklist (Google Play)
1. `--check` clean (or warnings understood); version name and code raised in Player Settings AND the Build Profile.
2. Development build on a phone: the release's features, back button, restart, ads/consent if any.
3. Release build: `./tools/build-aab.sh` (runs `--verify`); signer SHA-1 = upload key.
4. Internal testing track; install from Play on a test phone (uninstall the Build And Run copy first); repeat the key checks; read the
   pre-launch report.
5. Play Console: Data safety matches the SDKs in the build; no open policy issues; Play Games / other credential changes published.
6. Production with a staged rollout (e.g. 20% -> 50% -> 100%); watch Android vitals (crash rate < 1%, ANR < 0.47%) and the ad network
   between steps. A bad release is halted, not rolled back: fix forward with a higher version code.
7. Merge the release branch, tag `vX.Y.Z`, note the release in `docs/ai/UNITY.local.md`.

## Amending
- This file (`docs/ai/UNITY.md`) is generic and owned by the kit. `install.sh --update` replaces it (the old copy is saved as `UNITY.md.bak-kit`).
  Do not put project-specific notes here; they would be lost on update.
- Project-specific notes go in `docs/ai/UNITY.local.md`. Edit it only when the user asks; show the diff; never add secrets.
- A lesson that applies to any Unity project: edit `UNITY.md` in the kit repo (`unity-ai-kit`), commit, tag, then run `install.sh <project> --update` in each project.
- Never delete a rule without asking.

## Changelog
- 1.4.1 (2026-10-14): `--verify` finds a working keytool (JAVA_HOME, then Unity's bundled OpenJDK, then PATH). On macOS without a JDK,
  `/usr/bin/keytool` is only a stub, which made 1.4.0 report a signed bundle as "not signed". No keytool now means "Signer: unknown", not a failure.
- 1.4.0 (2026-10-14): lessons from Jumoji 1.0.4/1.0.5: `--verify` (bundle inspection, also after every build, exit 8); `--check` warns
  about Build Profile vs Player Settings drift, empty Android icons, Development Build in a profile, data-sending SDKs/services and
  mixed ad-plugin installs; rules 11 (clean SDK reinstall) and 12 (app icon); sections "Device testing" and "Release checklist";
  new error-table rows (icon, ads, Data safety, Play Games credentials, OAuth "already in use", incompatible install, consent testing);
  `install.sh` ignores `UserSettings/`.
- 1.3.0 (2026-10-13): Claude Code <-> Unity Editor: `install.sh` pins the MCP for Unity bridge in `Packages/manifest.json`, installs `docs/ai/UNITY-EDITOR.md` (editor workflow rules + troubleshooting), and `CLAUDE.md` now auto-loads `UNITY.local.md` and `UNITY-EDITOR.md`. `UNITY.local.md` template gains code map / known issues sections.
- 1.2.0 (2026-10-11): lessons from the Jumoji build: Build Profile overrides are scanned (`--check`) and patched (`--set-target`); early signing check (exit 7, plus Preflight in batch mode); filtered error summary; old plugin import files reported; version code and output path printed.
- 1.1.0 (2026-10-11): floor-based Target API (raise to 37 without editing the kit), per-project secrets, local-notes split, Gradle/SDK-platform warnings.
- 1.0.0 (2026-10-11): initial version (lessons from a real Android build: duplicate AndroidX classes, low Target API Level).
