#!/usr/bin/env bash
# Generic Unity -> Android App Bundle build. Works on any Unity project and any PC (macOS, Linux, Windows Git Bash).
# Usage: tools/build-aab.sh [--check] [project_dir]
#        tools/build-aab.sh --verify [file.aab]
#   --check   run all sanity checks (seconds) and exit without building
#   --verify  inspect a built bundle (default: newest Builds/*.aab): version, SDK levels, debuggable, ad App IDs,
#             providers, ABIs, app icon, signer SHA-1. Runs automatically after every successful build.
# Exit codes: 2 setup problem, 3 Unity is open, 4 stray AndroidX files, 5 Target API Level,
#             6 keystore file missing, 7 signing not configured, 8 bundle failed verification,
#             other = Unity's own exit code.
set -euo pipefail

CHECK_ONLY=0
VERIFY_ONLY=0
VERIFY_FILE=""
case "${1:-}" in
  --check)  CHECK_ONLY=1; shift ;;
  --verify) VERIFY_ONLY=1; shift
            case "${1:-}" in *.aab) VERIFY_FILE="$1"; shift ;; esac ;;
esac
if [ -n "$VERIFY_FILE" ]; then VERIFY_FILE="$(cd "$(dirname "$VERIFY_FILE")" && pwd)/$(basename "$VERIFY_FILE")"; fi
cd "${1:-$PWD}"
PROJECT_NAME="$(basename "$PWD")"

fail() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
warn() { echo "WARNING: $1" >&2; }

[ -f ProjectSettings/ProjectVersion.txt ] || [ -n "$VERIFY_FILE" ] || fail "Not a Unity project: $PWD" 2

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

# ---- Helpers for settings files ------------------------------------------------
# Android Build Profiles (Unity 6) embed a copy of Player Settings as lines like:   - line: '|   bundleVersion: 1.0.5'
# unwrap_settings prints such a file as plain YAML (ProjectSettings.asset passes through unchanged).
unwrap_settings() { sed -E "s/^[[:space:]]*- line: '\|//; s/'\$//" "$1"; }
# setting_value FILE KEY  -> first value of "KEY: value" (works on both formats)
setting_value() { unwrap_settings "$1" | grep -m1 -E "^[[:space:]]*$2:" | sed -E "s/^[[:space:]]*$2:[[:space:]]*//" || true; }
# android_defines FILE -> the Android line under scriptingDefineSymbols
android_defines() { unwrap_settings "$1" | awk '/^[[:space:]]*scriptingDefineSymbols:/{f=1;next} f&&/^[[:space:]]*Android:/{sub(/^[[:space:]]*Android:[[:space:]]*/,"");print;exit} f&&/^[[:space:]]*[A-Za-z]+:[[:space:]]*$/{exit}' || true; }
# android_icon_count FILE -> number of textures assigned to Android platform icons (0 = Unity's default icon ships)
android_icon_count() { unwrap_settings "$1" | awk '
  /m_BuildTargetPlatformIcons:/ {p=1; next}
  p && /m_BuildTarget: Android[[:space:]]*$/ {a=1; next}
  a && /m_BuildTarget:/ {exit}
  a && /\{fileID: [0-9]+, guid: [0-9a-f]+/ {n++}
  END {print n+0}'; }
# Android Build Profiles that carry their own Player Settings copy
android_profile_files() {
  [ -d "Assets/Settings/Build Profiles" ] || return 0
  find "Assets/Settings/Build Profiles" -maxdepth 1 -type f -name '*.asset' 2>/dev/null | while IFS= read -r f; do
    grep -q 'm_BuildTarget: 13' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}

# ---- Bundle verification ---------------------------------------------------------
# Reads the bundle's protobuf manifest without extra tools: printable runs become lines, and an attribute's value is the
# run right after its name. Good enough for the fields below, and needs only unzip (plus keytool for the signer).
# A keytool that really runs. On macOS /usr/bin/keytool is only a stub ("Unable to locate a Java Runtime") unless a JDK is
# installed, so prefer JAVA_HOME, then the JDK that ships with Unity's Android module, then PATH.
find_keytool() {
  local ver c cands=""
  [ -n "${JAVA_HOME:-}" ] && cands="$JAVA_HOME/bin/keytool"
  ver=$(grep -m1 'm_EditorVersion:' ProjectSettings/ProjectVersion.txt 2>/dev/null | awk '{print $2}' || true)
  if [ -n "${UNITY_PATH:-}" ]; then
    cands="$cands|$(dirname "$UNITY_PATH")/../../../PlaybackEngines/AndroidPlayer/OpenJDK/bin/keytool|$(dirname "$UNITY_PATH")/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin/keytool"
  fi
  if [ -n "$ver" ]; then
    cands="$cands|/Applications/Unity/Hub/Editor/$ver/PlaybackEngines/AndroidPlayer/OpenJDK/bin/keytool|$HOME/Unity/Hub/Editor/$ver/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin/keytool|/c/Program Files/Unity/Hub/Editor/$ver/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin/keytool.exe"
  fi
  cands="$cands|$(command -v keytool 2>/dev/null || true)"
  local IFS='|'
  for c in $cands; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    "$c" -help >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 0
}

verify_aab() {
  local aab="$1" bad=0 tmp man attr
  [ -f "$aab" ] || fail "No bundle to verify: ${aab:-Builds/*.aab}" 2
  command -v unzip >/dev/null 2>&1 || fail "unzip is required for --verify" 2
  tmp="$(mktemp -d 2>/dev/null || mktemp -d -t aabverify)"
  if ! unzip -q -o "$aab" base/manifest/AndroidManifest.xml -d "$tmp" 2>/dev/null; then
    rm -rf "$tmp"; fail "$aab has no base/manifest/AndroidManifest.xml (not an Android App Bundle?)" 8
  fi
  man="$tmp/strings.txt"
  LC_ALL=C tr -c '[:print:]' '\n' < "$tmp/base/manifest/AndroidManifest.xml" | grep -v '^$' > "$man" || true
  attr() { grep -m1 -A1 -x "$1" "$man" | tail -1 | grep -oE "$2" | head -1 || true; }
  local pkg vcode vname minsdk target dbg
  pkg=$(grep -m1 -A1 -x 'package' "$man" | tail -1 | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+' | head -1 || true)
  vcode=$(attr versionCode '^[0-9]+')
  vname=$(attr versionName '[0-9A-Za-z][0-9A-Za-z._+-]*')
  minsdk=$(attr minSdkVersion '^[0-9]+')
  target=$(attr targetSdkVersion '^[0-9]+')
  dbg=$(attr debuggable '(true|false)')
  echo "---- verify: $aab ($(du -h "$aab" | cut -f1 | tr -d ' '))"
  echo "Package:      ${pkg:-?}"
  echo "Version:      ${vname:-?} (code ${vcode:-?})"
  echo "SDK:          min ${minsdk:-?}, target ${target:-?} (project floor ${UNITY_KIT_MIN_TARGET_API:-36})"
  if [ -n "$target" ] && [ "$target" -lt "${UNITY_KIT_MIN_TARGET_API:-36}" ] 2>/dev/null; then
    echo "FAIL: targetSdkVersion $target is below the floor ${UNITY_KIT_MIN_TARGET_API:-36}."; bad=1
  fi
  if [ "$dbg" = "true" ]; then
    echo "FAIL: android:debuggable=true. This is a development build; Google Play rejects it."; bad=1
  else
    echo "Debuggable:   no"
  fi
  local ids; ids=$(grep -oE 'ca-app-pub-[0-9]+~[0-9]+' "$man" | sort -u | tr '\n' ' ' || true)
  if [ -n "$ids" ]; then
    echo "AdMob App ID: $ids"
    [ "$(printf '%s' "$ids" | wc -w | tr -d ' ')" -gt 1 ] && echo "WARNING: more than one AdMob App ID in the manifest."
  fi
  local auths; auths=$(grep -A1 -x 'authorities' "$man" | grep -v -x -e 'authorities' -e '--' \
                       | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_-]+)+' | sort -u | tr '\n' ' ' || true)
  [ -z "$auths" ] || echo "Providers:    $auths"
  local abis; abis=$(unzip -l "$aab" 2>/dev/null | grep -oE 'base/lib/[^/]+/' | sort -u | sed -E 's#base/lib/##; s#/##' | tr '\n' ' ' || true)
  echo "ABIs:         ${abis:-none}"
  case " $abis " in *" armeabi-v7a "*) case " $abis " in *" arm64-v8a "*) ;; *) echo "FAIL: 32-bit native code without arm64-v8a; Google Play requires 64-bit."; bad=1 ;; esac ;; esac
  local icons; icons=$(unzip -l "$aab" 2>/dev/null | grep -cE 'base/res/mipmap[^/]*/(app_icon|ic_launcher)' || true)
  if [ "${icons:-0}" -eq 0 ]; then echo "WARNING: no launcher icon resources found."; else echo "Icon files:   $icons (check the icon on a device: empty Android icon slots ship Unity's default icon)"; fi
  local kt cert
  kt=$(find_keytool)
  if [ -z "$kt" ]; then
    echo "Signer:       unknown (no working keytool: install a JDK or set JAVA_HOME; Unity's own JDK is used when found)"
  else
    cert=$("$kt" -printcert -jarfile "$aab" 2>&1 || true)
    if printf '%s' "$cert" | grep -q 'SHA1:'; then
      echo "Signer:       $(printf '%s\n' "$cert" | grep -m1 'Owner:' | sed -E 's/^[[:space:]]*Owner:[[:space:]]*//')"
      echo "Signer SHA-1: $(printf '%s\n' "$cert" | grep -m1 'SHA1:' | sed -E 's/^[[:space:]]*SHA1:[[:space:]]*//')"
      echo "              (must equal Play Console > App integrity > Upload key certificate)"
      if printf '%s' "$cert" | grep -qi 'Android Debug'; then echo "FAIL: signed with the Android debug key; Google Play rejects it."; bad=1; fi
    elif printf '%s' "$cert" | grep -qi 'not a signed jar'; then
      echo "FAIL: the bundle is not signed."; bad=1
    else
      echo "Signer:       unknown ($kt could not read the certificate: $(printf '%s' "$cert" | head -1))"
    fi
  fi
  rm -rf "$tmp"
  if [ "$bad" = "1" ]; then echo "Verify: FAILED"; return 8; fi
  echo "Verify: OK"
}

if [ "$VERIFY_ONLY" = "1" ]; then
  [ -n "$VERIFY_FILE" ] || VERIFY_FILE=$(ls -t Builds/*.aab 2>/dev/null | head -1 || true)
  set +e; verify_aab "$VERIFY_FILE"; rc=$?; set -e
  exit "$rc"
fi

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

# Build Profile vs Player Settings. A Unity 6 Android Build Profile keeps its own copy of Player Settings (version,
# defines, icons, keystore, cloud services ...). Seen in practice: values set through the API landed only in the active
# profile's copy, and the two drifted apart. Compare the fields that matter for a release.
while IFS= read -r pf; do
  [ -n "$pf" ] || continue
  grep -q 'AndroidBundleVersionCode' "$pf" 2>/dev/null || continue     # profile without a Player Settings copy
  pname="$(basename "$pf" .asset)"
  for key in bundleVersion AndroidBundleVersionCode; do
    a=$(setting_value "$SETTINGS" "$key"); b=$(setting_value "$pf" "$key")
    [ "$a" = "$b" ] || warn "$key differs: Player Settings '$a', Build Profile '$pname' '$b'. The profile wins at build time; make them equal."
  done
  a=$(android_defines "$SETTINGS"); b=$(android_defines "$pf")
  [ "$a" = "$b" ] || warn "Android scripting defines differ: Player Settings '$a', Build Profile '$pname' '$b'. Code under the missing defines compiles differently."
  if [ "$(android_icon_count "$pf")" = "0" ]; then
    warn "Build Profile '$pname': no Android app icon assigned (Player Settings > Android > Icon is empty), so the game ships Unity's default icon. Assign the Adaptive (foreground + background) icons in the profile and in Player Settings."
  fi
  if grep -qE '^[[:space:]]+m_Development: 1' "$pf" 2>/dev/null; then
    warn "Build Profile '$pname' has Development Build ticked. tools/build-aab.sh still builds a release bundle, but Build And Run from the Editor makes a development build (Debug.isDebugBuild = true: test ad units, debug consent geography). Untick it before committing."
  fi
done < <(android_profile_files)
if [ "$(android_icon_count "$SETTINGS")" = "0" ]; then
  warn "Player Settings: no Android app icon assigned, so the game ships Unity's default icon. Set Player Settings > Android > Icon (Adaptive: foreground + background)."
fi

# Data leaving the device. Google Play's SDK scan flags undeclared data ("Invalid data safety declaration").
DATA_SDKS=""
UCS=ProjectSettings/UnityConnectSettings.asset
if [ -f "$UCS" ]; then
  awk '/UnityAnalyticsSettings:/{f=1} f&&/m_Enabled: 1/{print "x";exit} f&&/^  [A-Za-z]+Settings:/&&!/UnityAnalyticsSettings/{exit}' "$UCS" | grep -q x && DATA_SDKS="$DATA_SDKS Unity-Analytics"
  grep -qE 'm_EnableCloudDiagnosticsReporting: 1' "$UCS" && DATA_SDKS="$DATA_SDKS Cloud-Diagnostics(crash-reports)"
fi
[ "$(setting_value "$SETTINGS" submitAnalytics)" = "1" ] && DATA_SDKS="$DATA_SDKS Hardware-statistics"
for pkg in com.unity.ads com.unity.analytics com.unity.purchasing; do
  grep -q "\"$pkg\"" Packages/manifest.json 2>/dev/null && DATA_SDKS="$DATA_SDKS $pkg"
done
if [ -n "$DATA_SDKS" ]; then
  warn "These send data off the device:$DATA_SDKS. Declare them in Play Console > Data safety, or turn them off / remove the packages if the game does not use them (unused Unity Ads still ships its SDK)."
fi

# Google Mobile Ads installed over an older copy (seen in practice: old C# source next to new DLLs, so ads never ran).
GMA_SRC=""
if [ -d Assets/GoogleMobileAds ] && ls Assets/GoogleMobileAds/GoogleMobileAds*.dll >/dev/null 2>&1; then
  GMA_SRC=$(find Assets/GoogleMobileAds -path '*/Editor' -prune -o -name '*.cs' -print 2>/dev/null | head -3 || true)
fi
if [ -n "$GMA_SRC" ]; then
  warn "Assets/GoogleMobileAds mixes runtime C# source (e.g. $(echo $GMA_SRC | cut -d' ' -f1)) with the plugin DLLs: two plugin versions are installed. Reinstall cleanly: delete Assets/GoogleMobileAds and the plugin's Android folders, import the current .unitypackage, Force Resolve."
fi
if [ -d Assets/Plugins/Android/GoogleMobileAdsPlugin ]; then
  warn "Legacy Assets/Plugins/Android/GoogleMobileAdsPlugin/ folder found (pre-.androidlib copy). Delete it; current plugins use GoogleMobileAdsPlugin.androidlib."
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
if [ -n "${OUT:-}" ] && [ -f "$OUT" ]; then
  set +e; verify_aab "$OUT"; VRC=$?; set -e
  [ "$VRC" = "0" ] || exit "$VRC"
fi
