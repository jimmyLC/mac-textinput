#!/usr/bin/env python3
"""Exercise restore against scratch app bundles; never touch installed input methods."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = 'com.jimmylc.inputmethod.ZhuyinLM'


def app(path, identity, connection='ZhuyinLM_1_Connection'):
    contents = path / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    executable = contents / 'MacOS' / 'fixture'
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
    modes = [identity + '.Bopomofo', identity + '.PlainBopomofo']
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identity, 'CFBundleExecutable': 'fixture',
        'CFBundlePackageType': 'APPL', 'TISInputSourceID': identity,
        'InputMethodConnectionName': connection,
        'ComponentInputModeDict': {'tsInputModeListKey': {m: {} for m in modes},
                                  'tsVisibleInputModeOrderedArrayKey': modes},
    }))
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)


def restore(source, target_dir, backup_dir):
    return subprocess.run(['bash', str(ROOT / 'scripts/update.sh'), '--restore', str(source),
                           '--target-dir', str(target_dir), '--backup-dir', str(backup_dir)],
                          capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory(prefix='zlm-update-test-') as scratch:
        temp = Path(scratch)
        target_dir = temp / 'target'
        target = target_dir / 'ZhuyinLM.app'
        app(target, IDENTITY)
        before = (target / 'Contents/Info.plist').read_bytes()
        for name, identity, connection in [('unrelated', 'com.example.Unrelated', 'Other'),
                                            ('wrong-connection', IDENTITY, 'Other')]:
            source = temp / (name + '.app')
            app(source, identity, connection)
            backups = temp / (name + '-backups')
            result = restore(source, target_dir, backups)
            assert result.returncode != 0, f'{name} restore incorrectly succeeded'
            assert (target / 'Contents/Info.plist').read_bytes() == before, 'target changed on rejection'
            assert not backups.exists(), 'rejection should precede backup or process changes'
        valid = temp / 'valid.app'
        app(valid, IDENTITY)
        result = restore(valid, target_dir, temp / 'valid-backups')
        assert result.returncode == 0, result.stderr
        assert len(list((temp / 'valid-backups').glob('*.app'))) == 1, 'valid restore needs a backup'
    print('Update/restore identity safety: OK')


if __name__ == '__main__':
    main()
