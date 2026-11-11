#!/usr/bin/env python3
"""Check the identities and privacy-related configuration of the built app."""
from pathlib import Path
import plistlib
import sys
from check_bundle_identity import check_identity

root = Path(__file__).resolve().parents[1]
app = root / '.build/products/ZhuyinLM.app'
info = check_identity(app)
identity = 'com.jimmylc.inputmethod.ZhuyinLM'
assert info['CFBundleIdentifier'] == identity
assert info['TISInputSourceID'] == identity
assert info['InputMethodConnectionName'] == 'ZhuyinLM_1_Connection'
modes = info['ComponentInputModeDict']
expected = {identity + '.Bopomofo', identity + '.PlainBopomofo'}
assert set(modes['tsInputModeListKey']) == expected
assert set(modes['tsVisibleInputModeOrderedArrayKey']) == expected
assert 'UpdateInfoEndpoint' not in info and 'UpdateInfoSite' not in info
source = root / '.build/McBopomofo/Source'
assert 'appendingPathComponent("ZhuyinLM")' in (source / 'Preferences.swift').read_text()
assert identity in (source / 'KeyHandler.mm').read_text()
assert (app / 'Contents/Resources/data.txt').is_file()
print('Build identity, update endpoints, data path and core dictionary: OK')
