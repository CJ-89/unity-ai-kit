#!/usr/bin/env bash
# Generic Unity -> Android App Bundle build. Works on any Unity project and any PC (macOS, Linux, Windows Git Bash).
# Usage: tools/build-aab.sh [--check] [project_dir]
#   --check   run all sanity checks (seconds) and exit without building
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

TARGET=$(grep -m1 'AndroidTargetSdkVersion:' ProjectSettings/ProjectSettings.asset 2>/dev/null | awk '{print $2}' || true)
MIN_TARGET="${UNITY_KIT_MIN_TARGET_API:-36}"
if [ -z "${TARGET:-}" ] || [ "$TARGET" = "0" ]; then
  fail "Target API Level is '${TARGET:-unknown}' (0 = Automatic). Set it explicitly to $MIN_TARGET or higher in Player Settings > Android." 5
fi
if [ "$TARGET" -lt "$MIN_TARGET" ] 2>/dev/null; then
  fail "Target API Level is $TARGET but this project requires at least $MIN_TARGET (UNITY_KIT_MIN_TARGET_API in .unity-kit.env). Raise it in Player Settings > Android, or lower the floor deliberately." 5
fi

if [ -n "${UNITY_KEYSTORE_PATH:-}" ]; then
  [ -f "$UNITY_KEYSTORE_PATH" ] || fail "UNITY_KEYSTORE_PATH points to a missing file: $UNITY_KEYSTORE_PATH" 6
  [ -n "${UNITY_KEYSTORE_PASS:-}" ] || warn "UNITY_KEYSTORE_PATH is set but UNITY_KEYSTORE_PASS is empty."
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

echo "Unity:      $VER"
echo "Executable: $UNITY"
echo "Target API: $TARGET (project floor $MIN_TARGET)"
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
  grep -m8 -B1 -A4 -E "What went wrong|FAILURE:|error CS[0-9]+|Duplicate class|requires libraries|BuildFailedException|Preflight" Logs/build.log \
    || tail -40 Logs/build.log
  exit "$CODE"
fi

OUT="${UNITY_BUILD_OUT:-}"
if [ -z "$OUT" ]; then OUT=$(ls -t Builds/*.aab 2>/dev/null | head -1 || true); fi
echo "Build succeeded: ${OUT:-Builds/*.aab}"
