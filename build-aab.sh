#!/usr/bin/env bash
# Generic Unity -> Android App Bundle build. Works on any Unity project and any PC (macOS, Linux, Windows Git Bash).
# Usage: tools/build-aab.sh [--check] [project_dir]
#   --check   run all sanity checks (seconds) and exit without building
# Exit codes: 2 setup problem, 3 Unity is open, 4 stray AndroidX files, 5 Target API Level,
#             6 keystore file missing, 7 signing not configured, other = Unity's own exit code.
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
cd "${1:-$PWD}"
PROJECT_NAME="$(basename "$PWD")"

fail() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
warn() { echo "WARNING: $1" >&2; }

[ -f ProjectSettings/ProjectVersion.txt ] || fail "Not a Unity project: $PWD" 2

# ---- Configuration -----------------------------------------------------------
# Precedence (highest first): real environment variables > per-project secrets file >
# project .unity-kit.env (committed, no secrets) > machine-wide defaults.
# Files are parsed as KEY=VALUE lines (only UNITY_* keys) and are never executed as shell.
PRESET=" "
for v in $(env | cut -d= -f1 | grep '^UNITY_' || true); do PRESET="$PRESET$v "; done

CFG_MACHINE="${UNITY_KIT_ENV:-$HOME/.config/unity-kit/env}"
CFG_PROJECT=".unity-kit.env"
CFG_SECRETS="$HOME/.config/unity-kit/projects/$PROJECT_NAME.env"
LOADED=""

load_env() {
  [ -f "$1" ] || return 0
  LOADED="$LOADED $1"
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$key" in UNITY_[A-Z0-9_]*) ;; *) continue ;; esac
    case "$PRESET" in *" $key "*) continue ;; esac
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    case "$val" in "~/"*) val="$HOME/${val#\~/}" ;; esac
    export "$key=$val"
  done < "$1"
}
load_env "$CFG_MACHINE"
load_env "$CFG_PROJECT"
load_env "$CFG_SECRETS"

# ---- Unity executable --------------------------------------------------------
VER=$(grep -m1 'm_EditorVersion:' ProjectSettings/ProjectVersion.txt | awk '{print $2}')
case "$(uname -s)" in
  Darwin) DEFAULT_UNITY="/Applications/Unity/Hub/Editor/$VER/Unity.app/Contents/MacOS/Unity" ;;
  Linux)  DEFAULT_UNITY="$HOME/Unity/Hub/Editor/$VER/Editor/Unity" ;;
  *)      DEFAULT_UNITY="/c/Program Files/Unity/Hub/Editor/$VER/Editor/Unity.exe" ;;
esac
UNITY="${UNITY_PATH:-$DEFAULT_UNITY}"
[ -x "$UNITY" ] || fail "Unity $VER not found at: $UNITY (install it in Unity Hub, or set UNITY_PATH)" 2

if [ -f Temp/UnityLockfile ] && [ "${UNITY_KIT_FORCE:-0}" != "1" ]; then
  fail "Unity Editor seems open on this project (Temp/UnityLockfile). Close it first, or set UNITY_KIT_FORCE=1 if the lock is stale." 3
fi

# ---- Fast sanity checks (seconds, before a 15-minute build) ---------------------
STRAY=$(find Assets Packages -type f \( -name 'androidx.*.aar' -o -name 'androidx.*.jar' \) 2>/dev/null || true)
if [ -n "$STRAY" ]; then
  echo "ERROR: stray AndroidX files would duplicate Maven dependencies:" >&2
  echo "$STRAY" >&2
  fail "Delete them (and .meta files), then run Android Resolver > Force Resolve." 4
fi

# Target API Level. Unity 6 Build Profiles (Assets/Settings/Build Profiles/*.asset) can carry their own copy of the
# Player Settings, and that copy wins when you build. Seen in practice: Player Settings said 36, the Android profile
# said 30/31, and Unity kept putting the profile's value back. So both places are checked.
SETTINGS=ProjectSettings/ProjectSettings.asset
GLOBAL_TARGET=$(grep -m1 '^  AndroidTargetSdkVersion:' "$SETTINGS" 2>/dev/null | awk '{print $2}' || true)
GLOBAL_BVC=$(grep -m1 '^  AndroidBundleVersionCode:' "$SETTINGS" 2>/dev/null | awk '{print $2}' || true)
MIN_TARGET="${UNITY_KIT_MIN_TARGET_API:-36}"
TARGET="${GLOBAL_TARGET:-}"
BVC="${GLOBAL_BVC:-}"
PROFILE_NOTE=""
PROFILE_LOW=""
if [ -d "Assets/Settings/Build Profiles" ]; then
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    grep -q 'm_BuildTarget: 13' "$pf" 2>/dev/null || continue            # 13 = Android
    pt=$(grep -m1 -E 'AndroidTargetSdkVersion: [0-9]+' "$pf" 2>/dev/null | sed -E 's/.*AndroidTargetSdkVersion: ([0-9]+).*/\1/' || true)
    pv=$(grep -m1 -E 'AndroidBundleVersionCode: [0-9]+' "$pf" 2>/dev/null | sed -E 's/.*AndroidBundleVersionCode: ([0-9]+).*/\1/' || true)
    [ -z "$pv" ] || BVC="$pv"
    [ -n "$pt" ] || continue
    PROFILE_NOTE="$PROFILE_NOTE $(basename "$pf" .asset)=$pt"
    if [ -z "$PROFILE_LOW" ] || [ "$pt" -lt "$PROFILE_LOW" ]; then PROFILE_LOW="$pt"; PROFILE_LOW_FILE="$pf"; fi
  done < <(find "Assets/Settings/Build Profiles" -maxdepth 1 -type f -name '*.asset' 2>/dev/null)
fi
if [ -n "$PROFILE_LOW" ]; then
  if [ "$PROFILE_LOW" = "0" ] || [ "$PROFILE_LOW" -lt "$MIN_TARGET" ]; then
    fail "Build Profile '$PROFILE_LOW_FILE' sets Target API Level $PROFILE_LOW (0 = Automatic), below the required $MIN_TARGET, and a profile overrides Player Settings. Close Unity, then run: install.sh <this project> --set-target $MIN_TARGET   (or edit it in File > Build Profiles > Android > Player Settings and verify with: grep -rn AndroidTargetSdkVersion ProjectSettings Assets --include='*.asset')." 5
  fi
  if [ -n "$GLOBAL_TARGET" ] && [ "$GLOBAL_TARGET" != "$PROFILE_LOW" ]; then
    warn "Player Settings says Target API $GLOBAL_TARGET but a Build Profile says $PROFILE_LOW. Keep them equal, or Unity may switch between them."
  fi
  TARGET="$PROFILE_LOW"
fi
if [ -z "${TARGET:-}" ] || [ "$TARGET" = "0" ]; then
  fail "Target API Level is '${TARGET:-unknown}' (0 = Automatic). Set it explicitly to $MIN_TARGET or higher in Player Settings > Android." 5
fi
if [ "$TARGET" -lt "$MIN_TARGET" ] 2>/dev/null; then
  fail "Target API Level is $TARGET but this project requires at least $MIN_TARGET (UNITY_KIT_MIN_TARGET_API in .unity-kit.env). Raise it in Player Settings > Android, or lower the floor deliberately." 5
fi

# Signing. Unity never saves keystore passwords in the project, so a batch build can only sign when the passwords come
# from the environment (~/.config/unity-kit/projects/<Project>.env). Seen in practice: the build ran for a minute and then
# failed with "Unable to sign the Android application / No keystore passwords were found".
USE_CUSTOM=$(grep -m1 -i '^  androidUseCustomKeystore:' "$SETTINGS" 2>/dev/null | awk '{print $2}' || true)
KS_NAME=$(grep -m1 '^  AndroidKeystoreName:' "$SETTINGS" 2>/dev/null | sed -E 's/^  AndroidKeystoreName: *//' || true)
SIGNING=""
if [ -n "${UNITY_KEYSTORE_PATH:-}" ]; then
  [ -f "$UNITY_KEYSTORE_PATH" ] || fail "UNITY_KEYSTORE_PATH points to a missing file: $UNITY_KEYSTORE_PATH" 6
  [ -n "${UNITY_KEYSTORE_PASS:-}" ] || fail "UNITY_KEYSTORE_PATH is set but UNITY_KEYSTORE_PASS is empty. Fill it in $CFG_SECRETS (private, outside git)." 7
  [ -n "${UNITY_KEYALIAS_NAME:-}" ] || warn "UNITY_KEYALIAS_NAME is empty; Unity will use the alias saved in Player Settings."
  [ -n "${UNITY_KEYALIAS_PASS:-}" ] || warn "UNITY_KEYALIAS_PASS is empty; the build fails if the key has its own password."
  SIGNING="keystore $(basename "$UNITY_KEYSTORE_PATH") from environment"
elif [ "${USE_CUSTOM:-0}" = "1" ] && [ "${UNITY_KIT_ALLOW_UNSIGNED:-0}" != "1" ]; then
  fail "Player Settings uses a custom keystore (${KS_NAME:-unnamed}) but Unity does not save keystore passwords, so a batch build cannot sign. Set UNITY_KEYSTORE_PATH (full path to the .keystore file), UNITY_KEYSTORE_PASS, UNITY_KEYALIAS_NAME and UNITY_KEYALIAS_PASS in $CFG_SECRETS (private, outside git). To skip this check: UNITY_KIT_ALLOW_UNSIGNED=1." 7
else
  SIGNING="none configured"
  warn "No release keystore configured: the bundle would be signed with Unity's debug key, which Google Play rejects."
fi

# ---- Warnings (do not stop the build) -------------------------------------------
for f in Assets/Plugins/Android/*.gradle; do
  [ -f "$f" ] || continue
  if grep -nE '^[[:space:]]*compileSdk(Version)?[[:space:]]+[0-9]+' "$f" >/dev/null 2>&1; then
    warn "$f hard-codes compileSdk. Use 'compileSdk **APIVERSION**' so it follows the Target API Level."
  fi
  if grep -nE 'resolutionStrategy|[[:space:]]force[[:space:]]+.' "$f" >/dev/null 2>&1; then
    warn "$f forces dependency versions. Fix versions at the source (Dependencies.xml) instead."
  fi
done

EDITOR_ROOT=""
UDIR="$(dirname "$UNITY")"
for cand in "$UDIR/../../.." "$UDIR/Data" "$UDIR/.."; do
  if [ -d "$cand/PlaybackEngines/AndroidPlayer/SDK/platforms" ]; then EDITOR_ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -n "$EDITOR_ROOT" ]; then
  PLAT="$EDITOR_ROOT/PlaybackEngines/AndroidPlayer/SDK/platforms"
  if [ ! -f "$PLAT/android-$TARGET/android.jar" ] && [ ! -f "$PLAT/android-$TARGET.0/android.jar" ]; then
    warn "No android.jar found for API $TARGET under $PLAT. Reinstall the Android SDK module in Unity Hub if the build fails."
  fi
  ODD=$(ls "$PLAT" 2>/dev/null | grep -E '^android-[0-9.]+-[0-9]+$' || true)
  if [ -n "$ODD" ]; then
    warn "Unusual SDK platform folder(s) in $PLAT: $(echo $ODD). Unity may mis-detect the installed SDK; remove them if you see SDK errors."
  fi
fi

# Old-format plugin import files (Unity 6 logs them as errors, but they did not stop a real build). Informational only.
OLD_META=$(find Assets Packages -type f -name '*.meta' -print0 2>/dev/null | xargs -0 -r grep -l '^PluginImporter:' 2>/dev/null \
           | tr '\n' '\0' | xargs -0 -r grep -l '^  serializedVersion: 1$' 2>/dev/null || true)
if [ -n "$OLD_META" ]; then
  warn "$(printf '%s\n' "$OLD_META" | wc -l | tr -d ' ') plugin import file(s) use an old format (Unity logs 'PluginImporter object at version 1' and may print errors, usually harmless). Fix with Assets > Reimport All or by updating the plugin. First: $(printf '%s\n' "$OLD_META" | head -3 | tr '\n' ' ')"
fi

echo "Unity:      $VER"
echo "Executable: $UNITY"
echo "Target API: $TARGET (project floor $MIN_TARGET)${PROFILE_NOTE:+  [Build Profile:$PROFILE_NOTE]}"
echo "Version:    code ${BVC:-?}$( [ "${UNITY_BUMP_VERSION_CODE:-0}" = "1" ] && printf ' (will be raised by 1 for this build)' )"
echo "Signing:    $SIGNING"
echo "Project:    $PWD"
echo "Config:    ${LOADED:- (none; defaults)}"

if [ "$CHECK_ONLY" = "1" ]; then echo "Check OK."; exit 0; fi

# ---- Build ---------------------------------------------------------------------
mkdir -p Logs Builds
echo "Building... (full log: Logs/build.log)"
set +e
"$UNITY" -batchmode -nographics -quit -projectPath "$PWD" -buildTarget Android \
  -executeMethod JuicyBuildKit.BuildScript.BuildAab -logFile Logs/build.log
CODE=$?
set -e
echo "exit code: $CODE"

if [ "$CODE" -ne 0 ]; then
  echo "---- first errors ----"
  # The log is full of harmless 'PluginImporter ... version 1' lines and stack frames; filter them out first.
  grep -v -E 'PluginImporter object at version|below the supported minimum' Logs/build.log \
    | grep -m6 -B1 -A3 -E "UnityException|Unable to sign|What went wrong|FAILURE:|error CS[0-9]+|Duplicate class|requires libraries|BuildFailedException|Preflight" \
    || tail -40 Logs/build.log
  if grep -q -E 'No keystore passwords were found|Unable to sign the Android' Logs/build.log; then
    echo "HINT: signing failed. Put UNITY_KEYSTORE_PATH / _PASS / UNITY_KEYALIAS_NAME / _PASS in $CFG_SECRETS (private, outside git)."
  fi
  echo "(full log: Logs/build.log; 'Build Finished, Result:' near the end shows the final result)"
  exit "$CODE"
fi

OUT="${UNITY_BUILD_OUT:-}"
if [ -z "$OUT" ]; then OUT=$(ls -t Builds/*.aab 2>/dev/null | head -1 || true); fi
echo "Build succeeded: ${OUT:-Builds/*.aab}"
if [ -n "${OUT:-}" ] && [ -f "$OUT" ]; then
  echo "File: $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")  ($(du -h "$OUT" | cut -f1))"
fi
echo "Reminder: Google Play rejects a Bundle Version Code it has already seen (was ${BVC:-?} before this build). Set UNITY_BUMP_VERSION_CODE=1 to raise it automatically."
