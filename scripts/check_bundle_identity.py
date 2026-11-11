#!/usr/bin/env python3
"""Reject bundles that cannot be a ZhuyinLM input method, including signed other apps."""
from pathlib import Path
import plistlib
import sys

IDENTITY = 'com.jimmylc.inputmethod.ZhuyinLM'


def check_identity(app):
    with (Path(app) / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    expected = {IDENTITY + '.Bopomofo', IDENTITY + '.PlainBopomofo'}
    modes = info.get('ComponentInputModeDict', {})
    if not (info.get('CFBundleIdentifier') == IDENTITY
            and info.get('TISInputSourceID') == IDENTITY
            and info.get('InputMethodConnectionName') == 'ZhuyinLM_1_Connection'
            and set(modes.get('tsInputModeListKey', {})) == expected
            and set(modes.get('tsVisibleInputModeOrderedArrayKey', [])) == expected):
        raise ValueError('Not a ZhuyinLM input method: bundle, input modes or IMK connection do not match')
    return info


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: check_bundle_identity.py /path/to/ZhuyinLM.app')
    try:
        check_identity(sys.argv[1])
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
        sys.exit(f'Bundle identity validation failed: {error}')
