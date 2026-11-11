#!/bin/bash
# Prints the code-signing identity for local builds. A fixed identity keeps the app's
# Keychain permission (sentence-history key) across rebuilds; ad-hoc signing does not.
# Override with ZHIZHI_SIGN_IDENTITY (a certificate name or hash); "-" forces ad-hoc.
if [[ -n "${ZHIZHI_SIGN_IDENTITY:-}" ]]; then echo "$ZHIZHI_SIGN_IDENTITY"; exit 0; fi
hash="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
echo "${hash:--}"
