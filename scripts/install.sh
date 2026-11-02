#!/bin/bash
# Installs a fresh development build without replacing an existing input method.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$ROOT/.build/products/ZhuyinLM.app"
target_dir="$HOME/Library/Input Methods"
register=1
while (($#)); do
  case "$1" in
    --target-dir) [[ $# -ge 2 ]] || { echo 'Missing target directory' >&2; exit 2; }; target_dir="$2"; shift 2 ;;
    --no-register) register=0; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -d "$source_app" ]] || { echo 'Build first: ./scripts/build.sh' >&2; exit 1; }
python3 "$ROOT/scripts/check_build.py"
codesign --verify --deep --strict "$source_app"
mkdir -p "$target_dir"
target="$target_dir/ZhuyinLM.app"
if [[ -e "$target" || -L "$target" ]]; then
  echo "Refusing to overwrite existing installation: $target" >&2
  exit 1
fi
stage="$(mktemp -d "$target_dir/.zhuyinlm-install.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$source_app" "$stage/ZhuyinLM.app"
codesign --verify --deep --strict "$stage/ZhuyinLM.app"
# Create the final directory exclusively, so a concurrent install is never replaced.
mkdir "$target"
if ! /usr/bin/ditto "$stage/ZhuyinLM.app" "$target"; then
  echo "Install interrupted; inspect the newly created directory: $target" >&2
  exit 1
fi
codesign --verify --deep --strict "$target"
echo "Installed: $target"
if (( register )); then
  if ! swift "$ROOT/scripts/register_input.swift" "$target"; then
    echo 'The app is installed, but registration failed.' >&2
    exit 1
  fi
  if ! swift "$ROOT/scripts/check_registration.swift"; then
    echo 'Not active yet. Log out and back in, then add it in Keyboard settings if available.' >&2
    exit 2
  fi
fi
