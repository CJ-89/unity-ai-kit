#!/usr/bin/env bash
# Install or update the unity-ai-kit in a Unity project. Safe to run repeatedly: never overwrites your edits
# unless you pass --update, and then only kit-owned files (with .bak-kit backups where content could be yours).
#
# Usage: install.sh /path/to/UnityProject [options]
#   --status            show kit/project versions, target API, floor and differences; change nothing
#   --update            overwrite kit-owned files (UNITY.md [backup kept], tools/build-aab.sh, Packages/com.juicy.buildkit)
#   --min-target N      set the project's Target API floor (UNITY_KIT_MIN_TARGET_API) in .unity-kit.env
#   --set-target N      also set the Target API Level in ProjectSettings.asset (Unity must be closed); implies --min-target N
#   --dry-run           print what would change, write nothing
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_VERSION="$(cat "$KIT/VERSION" 2>/dev/null || echo unknown)"
PROJECT=""
UPDATE=0; DRY=0; STATUS=0; MIN_TARGET=""; SET_TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --update)     UPDATE=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    --status)     STATUS=1; shift ;;
    --min-target) [ -n "${2:-}" ] || { echo "--min-target needs a number" >&2; exit 2; }; MIN_TARGET="$2"; shift 2 ;;
    --set-target) [ -n "${2:-}" ] || { echo "--set-target needs a number" >&2; exit 2; }; SET_TARGET="$2"; MIN_TARGET="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)  PROJECT="$1"; shift ;;
  esac
done
[ -n "$PROJECT" ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
PROJECT="$(cd "$PROJECT" && pwd)"
[ -f "$PROJECT/ProjectSettings/ProjectVersion.txt" ] || { echo "Not a Unity project: $PROJECT" >&2; exit 2; }
PROJECT_NAME="$(basename "$PROJECT")"
for n in "$MIN_TARGET" "$SET_TARGET"; do
  case "$n" in ''|*[!0-9]*) [ -z "$n" ] || { echo "Target must be a number, got: $n" >&2; exit 2; } ;; esac
done

say()   { printf '%s\n' "$*"; }
rel()   { printf '%s' "${1#$PROJECT/}"; }
do_it() { if [ "$DRY" = "1" ]; then say "  [dry-run] $*"; else "$@"; fi; }

SA="$PROJECT/ProjectSettings/ProjectSettings.asset"
CURRENT_TARGET="$(grep -m1 '^  AndroidTargetSdkVersion:' "$SA" 2>/dev/null | awk '{print $2}' || true)"
FLOOR_NOW="$(grep -m1 '^UNITY_KIT_MIN_TARGET_API=' "$PROJECT/.unity-kit.env" 2>/dev/null | cut -d= -f2 || true)"
INSTALLED_VERSION="$(cat "$PROJECT/docs/ai/.kit-version" 2>/dev/null || echo none)"

# ---------------------------------------------------------------- status
if [ "$STATUS" = "1" ]; then
  say "Project:            $PROJECT"
  say "Kit version:        $KIT_VERSION"
  say "Installed version:  $INSTALLED_VERSION"
  say "Target API Level:   ${CURRENT_TARGET:-unknown} (0 = Automatic)"
  say "Project floor:      ${FLOOR_NOW:-not set (kit default 36)}"
  chk() { # label src dst
    if [ ! -e "$3" ]; then say "  missing   $1"
    elif diff -rq "$2" "$3" >/dev/null 2>&1; then say "  same      $1"
    else say "  differs   $1"; fi
  }
  chk "docs/ai/UNITY.md"                 "$KIT/UNITY.md"                      "$PROJECT/docs/ai/UNITY.md"
  chk "tools/build-aab.sh"               "$KIT/build-aab.sh"                  "$PROJECT/tools/build-aab.sh"
  chk "Packages/com.juicy.buildkit"      "$KIT/package/com.juicy.buildkit"    "$PROJECT/Packages/com.juicy.buildkit"
  [ -f "$PROJECT/docs/ai/UNITY.local.md" ] && say "  present   docs/ai/UNITY.local.md (project-owned)" || say "  missing   docs/ai/UNITY.local.md"
  [ -f "$PROJECT/.unity-kit.env" ]         && say "  present   .unity-kit.env" || say "  missing   .unity-kit.env"
  say "Run with --update to replace kit-owned files that differ."
  exit 0
fi

# ---------------------------------------------------------------- helpers
# place SRC DST MODE BACKUP
#   MODE 0 = editable by you: if it differs, keep yours and write DST.new
#   MODE 1 = kit-owned: --update overwrites it (BACKUP=1 keeps the old copy as DST.bak-kit)
#   MODE 2 = project-owned: created once if missing, then never touched
place() {
  local src="$1" dst="$2" mode="${3:-0}" backup="${4:-0}"
  if [ ! -e "$dst" ]; then
    do_it mkdir -p "$(dirname "$dst")"; do_it cp "$src" "$dst"; say "  created   $(rel "$dst")"
  elif [ "$mode" = "2" ]; then
    say "  kept      $(rel "$dst")  (project-owned)"
  elif cmp -s "$src" "$dst"; then
    [ -e "$dst.new" ] && do_it rm -f "$dst.new"
    say "  unchanged $(rel "$dst")"
  elif [ "$mode" = "1" ] && [ "$UPDATE" = "1" ]; then
    if [ "$backup" = "1" ]; then do_it cp "$dst" "$dst.bak-kit"; fi
    do_it cp "$src" "$dst"; do_it rm -f "$dst.new"
    say "  updated   $(rel "$dst")$( [ "$backup" = "1" ] && printf '  (old copy: %s.bak-kit)' "$(basename "$dst")" )"
    if [ "$backup" = "1" ]; then say "            If you or an agent added project-specific lines to the old copy, move them into docs/ai/UNITY.local.md."; fi
  else
    do_it cp "$src" "$dst.new"; say "  DIFFERS   $(rel "$dst")  (kept yours; kit version saved as $(basename "$dst").new; use --update to replace)"
  fi
}

ensure_line() { # file line
  if [ ! -f "$1" ] || ! grep -qxF -- "$2" "$1"; then
    if [ "$DRY" = "0" ]; then printf '%s\n' "$2" >> "$1"; fi
    say "  appended  $(basename "$1"): $2"
  fi
}

set_kv() { # file key value  (replace an uncommented KEY=... line, else append)
  local f="$1" k="$2" v="$3" tmp
  if grep -q "^$k=" "$f" 2>/dev/null; then
    tmp="$f.tmp.$$"
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$f" > "$tmp" && mv "$tmp" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

[ "$DRY" = "1" ] && say "DRY RUN: nothing is written; the lines below show what would happen."
say "Installing unity-ai-kit $KIT_VERSION into: $PROJECT"

# ---------------------------------------------------------------- rules and build script
say "- Rules and build script"
place "$KIT/UNITY.md"                 "$PROJECT/docs/ai/UNITY.md"       1 1
place "$KIT/UNITY.local.template.md"  "$PROJECT/docs/ai/UNITY.local.md" 2 0
place "$KIT/build-aab.sh"             "$PROJECT/tools/build-aab.sh"     1 0
[ "$DRY" = "1" ] || chmod +x "$PROJECT/tools/build-aab.sh"

# ---------------------------------------------------------------- agent entry points
say "- Agent entry points"
if [ ! -e "$PROJECT/AGENTS.md" ]; then
  place "$KIT/AGENTS.template.md" "$PROJECT/AGENTS.md" 0 0
else
  if ! grep -q 'docs/ai/UNITY.md' "$PROJECT/AGENTS.md"; then
    [ "$DRY" = "1" ] || printf '\n## Unity build workflow\nFor builds, Android, Gradle, plugins or signing: read `docs/ai/UNITY.md` (generic rules) and `docs/ai/UNITY.local.md` (this project) first. Build with `./tools/build-aab.sh` (use `--check` first). Never read or print keystores or passwords.\n' >> "$PROJECT/AGENTS.md"
    say "  appended  AGENTS.md (pointer to docs/ai/UNITY.md)"
  elif ! grep -q 'UNITY.local.md' "$PROJECT/AGENTS.md"; then
    [ "$DRY" = "1" ] || printf '\nProject-specific Unity notes: `docs/ai/UNITY.local.md`. Target API floor: `.unity-kit.env`.\n' >> "$PROJECT/AGENTS.md"
    say "  appended  AGENTS.md (pointer to UNITY.local.md)"
  else
    say "  unchanged AGENTS.md"
  fi
fi
if [ ! -e "$PROJECT/CLAUDE.md" ]; then
  place "$KIT/CLAUDE.template.md" "$PROJECT/CLAUDE.md" 0 0
elif ! grep -q '@AGENTS.md' "$PROJECT/CLAUDE.md"; then
  if [ "$DRY" = "0" ]; then
    { printf '@AGENTS.md\n\n'; cat "$PROJECT/CLAUDE.md"; } > "$PROJECT/CLAUDE.md.tmp" && mv "$PROJECT/CLAUDE.md.tmp" "$PROJECT/CLAUDE.md"
  fi
  say "  prepended CLAUDE.md (@AGENTS.md import; existing content kept)"
else
  say "  unchanged CLAUDE.md"
fi

# ---------------------------------------------------------------- unity package
say "- Unity package (embedded copy, no network needed)"
PKG_SRC="$KIT/package/com.juicy.buildkit"; PKG_DST="$PROJECT/Packages/com.juicy.buildkit"
if [ ! -d "$PKG_DST" ]; then
  do_it mkdir -p "$PROJECT/Packages"; do_it cp -R "$PKG_SRC" "$PKG_DST"; say "  created   Packages/com.juicy.buildkit"
elif diff -rq "$PKG_SRC" "$PKG_DST" >/dev/null 2>&1; then
  say "  unchanged Packages/com.juicy.buildkit"
elif [ "$UPDATE" = "1" ]; then
  do_it rm -rf "$PKG_DST"; do_it cp -R "$PKG_SRC" "$PKG_DST"; say "  updated   Packages/com.juicy.buildkit"
else
  say "  DIFFERS   Packages/com.juicy.buildkit  (rerun with --update to replace it)"
fi

# ---------------------------------------------------------------- project config (committed, non-secret)
say "- Project config (.unity-kit.env)"
PCFG="$PROJECT/.unity-kit.env"
if [ ! -f "$PCFG" ]; then
  do_it cp "$KIT/project-env.template" "$PCFG"
  if [ -n "$MIN_TARGET" ] && [ "$DRY" = "0" ]; then set_kv "$PCFG" UNITY_KIT_MIN_TARGET_API "$MIN_TARGET"; fi
  say "  created   .unity-kit.env  (floor ${MIN_TARGET:-36})"
elif [ -n "$MIN_TARGET" ]; then
  if [ "$FLOOR_NOW" = "$MIN_TARGET" ]; then say "  unchanged .unity-kit.env  (floor already $MIN_TARGET)"
  else
    if [ "$DRY" = "0" ]; then set_kv "$PCFG" UNITY_KIT_MIN_TARGET_API "$MIN_TARGET"; fi
    say "  updated   .unity-kit.env  (floor ${FLOOR_NOW:-unset} -> $MIN_TARGET)"
  fi
else
  say "  unchanged .unity-kit.env"
fi

# ---------------------------------------------------------------- optional: set Target API Level
if [ -n "$SET_TARGET" ]; then
  say "- Target API Level -> $SET_TARGET"
  if [ -f "$PROJECT/Temp/UnityLockfile" ]; then
    say "  SKIPPED   Unity seems open on this project. Close it and rerun with --set-target $SET_TARGET (or change it in Player Settings)."
  elif ! grep -q '^  AndroidTargetSdkVersion:' "$SA" 2>/dev/null; then
    say "  SKIPPED   AndroidTargetSdkVersion not found in ProjectSettings.asset (binary serialization?). Set it in Player Settings instead."
  elif [ "$CURRENT_TARGET" = "$SET_TARGET" ]; then
    say "  unchanged ProjectSettings.asset (already $SET_TARGET)"
  else
    if [ "$DRY" = "0" ]; then
      cp "$SA" "$SA.bak-kit"
      sed -E "s/^(  AndroidTargetSdkVersion: )[0-9]+/\1$SET_TARGET/" "$SA" > "$SA.tmp.$$" && mv "$SA.tmp.$$" "$SA"
    fi
    say "  updated   ProjectSettings.asset  (${CURRENT_TARGET:-?} -> $SET_TARGET; backup ProjectSettings.asset.bak-kit)"
    say "            Open Unity and confirm Player Settings > Android > Target API Level shows $SET_TARGET."
  fi
fi

# ---------------------------------------------------------------- git hygiene
say "- .gitignore / .gitattributes"
MARK="# unity-ai-kit"
if [ ! -f "$PROJECT/.gitignore" ] || ! grep -qxF -- "$MARK" "$PROJECT/.gitignore"; then
  [ "$DRY" = "1" ] || printf '\n%s\n' "$MARK" >> "$PROJECT/.gitignore"
  say "  appended  .gitignore marker"
fi
for pat in 'Builds/' 'Logs/' '*.keystore' '*.jks' '.env*' '*.new' '*.bak-kit'; do ensure_line "$PROJECT/.gitignore" "$pat"; done
if [ ! -f "$PROJECT/.gitattributes" ] || ! grep -q '^\*\.sh' "$PROJECT/.gitattributes"; then
  [ "$DRY" = "1" ] || printf '*.sh text eol=lf\n' >> "$PROJECT/.gitattributes"
  say "  appended  .gitattributes (*.sh text eol=lf)"
fi

# ---------------------------------------------------------------- per-machine settings (outside git)
say "- Per-machine settings (outside git)"
CFG="$HOME/.config/unity-kit"
if [ ! -f "$CFG/env" ]; then
  do_it mkdir -p "$CFG/projects"; do_it cp "$KIT/machine-env.template" "$CFG/env"; [ "$DRY" = "1" ] || chmod 600 "$CFG/env"
  say "  created   $CFG/env"
fi
if [ ! -f "$CFG/projects/$PROJECT_NAME.env" ]; then
  do_it mkdir -p "$CFG/projects"; do_it cp "$KIT/secrets.template" "$CFG/projects/$PROJECT_NAME.env"
  [ "$DRY" = "1" ] || chmod 600 "$CFG/projects/$PROJECT_NAME.env"
  say "  created   $CFG/projects/$PROJECT_NAME.env  (this game's keystore settings go here)"
else
  say "  unchanged $CFG/projects/$PROJECT_NAME.env"
fi
if [ -f "$CFG/env" ] && grep -qE '^UNITY_KEY(STORE|ALIAS)_[A-Z]+=.' "$CFG/env"; then
  say "  NOTE      $CFG/env contains keystore settings, which would apply to EVERY project."
  say "            Move them into $CFG/projects/$PROJECT_NAME.env (one file per game)."
fi

# ---------------------------------------------------------------- scan
say "- Scan for stray AndroidX files (reported, never deleted)"
STRAY="$(find "$PROJECT/Assets" "$PROJECT/Packages" -type f \( -name 'androidx.*.aar' -o -name 'androidx.*.jar' \) 2>/dev/null || true)"
if [ -n "$STRAY" ]; then
  say "  WARNING: these will fail the build until deleted (with their .meta files):"
  printf '%s\n' "$STRAY" | sed "s#$PROJECT/#    #"
else
  say "  none found"
fi

if [ "$DRY" = "0" ]; then
  mkdir -p "$PROJECT/docs/ai"; printf '%s\n' "$KIT_VERSION" > "$PROJECT/docs/ai/.kit-version"
fi
say ""
say "Done. Nothing was committed. Review with:  git -C \"$PROJECT\" status"
