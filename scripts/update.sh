#!/bin/bash
# Replaces an installed ZhuyinLM.app with the current build, keeping a backup.
# Touches only ZhuyinLM.app; other input methods are never modified.
#   ./scripts/update.sh                      back up the installed app, install the new build
#   ./scripts/update.sh --restore <backup>   put a backup back (the current app is backed up first)
# Test against a scratch directory with --target-dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$ROOT/.build/products/ZhuyinLM.app"
target_dir="$HOME/Library/Input Methods"
backup_dir="$HOME/Library/Application Support/ZhuyinLM-backups"
restore=""
while (($#)); do
  case "$1" in
    --target-dir) [[ $# -ge 2 ]] || { echo 'Missing target directory' >&2; exit 2; }; target_dir="$2"; shift 2 ;;
    --backup-dir) [[ $# -ge 2 ]] || { echo 'Missing backup directory' >&2; exit 2; }; backup_dir="$2"; shift 2 ;;
    --restore) [[ $# -ge 2 ]] || { echo 'Missing backup path' >&2; exit 2; }; restore="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
target="$target_dir/ZhuyinLM.app"
new_app="$source_app"
if [[ -n "$restore" ]]; then
  [[ -d "$restore/Contents" ]] || { echo "Not an app bundle: $restore" >&2; exit 1; }
  new_app="$restore"
else
  [[ -d "$source_app" ]] || { echo 'Build first: ./scripts/build.sh' >&2; exit 1; }
  python3 "$ROOT/scripts/check_build.py"
fi
python3 "$ROOT/scripts/check_bundle_identity.py" "$new_app"
codesign --verify --deep --strict "$new_app"
[[ -d "$target" ]] || { echo "Nothing installed at $target; use ./scripts/install.sh for a first install." >&2; exit 1; }

mkdir -p "$backup_dir"
backup="$backup_dir/ZhuyinLM-$(date +%Y%m%d-%H%M%S)-$$.app"
[[ ! -e "$backup" ]] || { echo "Backup already exists: $backup" >&2; exit 1; }
/usr/bin/ditto "$target" "$backup"
echo "Backup: $backup"

stage="$(mktemp -d "$target_dir/.zhuyinlm-update.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$new_app" "$stage/ZhuyinLM.app"
python3 "$ROOT/scripts/check_bundle_identity.py" "$stage/ZhuyinLM.app"
codesign --verify --deep --strict "$stage/ZhuyinLM.app"

# Stop only this app's running process so the next key press launches the new build.
pkill -f "$target/Contents/MacOS/" 2>/dev/null || true
mv "$target" "$stage/old.app"
if ! mv "$stage/ZhuyinLM.app" "$target"; then
  mv "$stage/old.app" "$target"
  echo 'Install failed; the previous app was put back.' >&2
  exit 1
fi
echo "Updated: $target"
echo "Restore with: ./scripts/update.sh --restore \"$backup\""
echo 'If the new build is not picked up, log out and back in, or switch input source once.'
