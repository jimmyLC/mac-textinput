#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "$ROOT/.build/McBopomofo/McBopomofo.xcodeproj" ]]; then
  echo "Run ./scripts/build.sh first." >&2
  exit 1
fi
python3 "$ROOT/scripts/check_build.py"
# The upstream update API test requires a live network service and is unrelated
# to the input engine. Run it separately when checking upstream update services.
xcodebuild -project "$ROOT/.build/McBopomofo/McBopomofo.xcodeproj" \
  -scheme McBopomofo -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -skip-testing:McBopomofoTests/VersionUpdateApiTests CODE_SIGNING_ALLOWED=NO test

# Standalone bilingual prototype (not yet wired into the IME).
BIN="$(mktemp -d)"
swiftc "$ROOT"/Sources/BilingualPrototype/*.swift "$ROOT/tests/bilingual_resolver.swift" -o "$BIN/resolver"
swiftc "$ROOT"/Sources/BilingualPrototype/*.swift "$ROOT/tests/bilingual_analyzer.swift" -o "$BIN/analyzer"
"$BIN/resolver"
"$BIN/analyzer" "$ROOT"
rm -rf "$BIN"
