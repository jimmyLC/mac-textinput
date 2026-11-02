#!/usr/bin/env python3
"""Prepare a uniquely identified development copy of the pinned upstream IME."""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor' / 'McBopomofo'
DEST = ROOT / '.build' / 'McBopomofo'
PIN = '257da536ddaf590aae0e74e6adb9b415988344f6'
OLD = 'org.openvanilla.inputmethod.McBopomofo'
NEW = 'com.jimmylc.inputmethod.ZhuyinLM'


def replace(path, old, new):
    text = path.read_text()
    if old not in text:
        raise RuntimeError(f'Expected text missing in {path}: {old}')
    path.write_text(text.replace(old, new))


def main():
    if not (UPSTREAM / 'McBopomofo.xcodeproj').exists():
        sys.exit('Run: git submodule update --init --recursive')
    revision = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        sys.exit(f'Unexpected upstream revision {revision}; expected {PIN}')
    if subprocess.check_output(['git', '-C', str(UPSTREAM), 'status', '--porcelain'], text=True).strip():
        sys.exit('Upstream has local changes; refusing to discard or silently include them.')
    if DEST.exists():
        shutil.rmtree(DEST)
    shutil.copytree(UPSTREAM, DEST, ignore=shutil.ignore_patterns('.git', '.DS_Store', 'build', '.build', 'xcuserdata'))
    for rel in ['Source/McBopomofo-Info.plist', 'Source/KeyHandler.mm',
                'Source/Base.lproj/InfoPlist.strings', 'Source/en.lproj/InfoPlist.strings',
                'Source/zh-Hant.lproj/InfoPlist.strings', 'McBopomofo.xcodeproj/project.pbxproj']:
        replace(DEST / rel, OLD, NEW)
    for rel in ['Source/McBopomofo-Info.plist', 'Source/main.swift']:
        replace(DEST / rel, 'McBopomofo_1_Connection', 'ZhuyinLM_1_Connection')
    replace(DEST / 'Source/Preferences.swift', 'appendingPathComponent("McBopomofo")', 'appendingPathComponent("ZhuyinLM")')
    plist = DEST / 'Source/McBopomofo-Info.plist'
    replace(plist, '<key>UpdateInfoEndpoint</key>', '<key>UpstreamUpdateInfoEndpointDisabled</key>')
    replace(plist, '<key>UpdateInfoSite</key>', '<key>UpstreamUpdateInfoSiteDisabled</key>')
    for locale in ['Base', 'en', 'zh-Hant']:
        path = DEST / f'Source/{locale}.lproj/InfoPlist.strings'
        text = path.read_text()
        text = text.replace('CFBundleName = "McBopomofo";', 'CFBundleName = "ZhuyinLM";')
        text = text.replace('CFBundleDisplayName = "McBopomofo";', 'CFBundleDisplayName = "ZhuyinLM";')
        text = text.replace('CFBundleName = "小麥注音";', 'CFBundleName = "ZhuyinLM 測試版";')
        text = text.replace('CFBundleDisplayName = "小麥注音";', 'CFBundleDisplayName = "ZhuyinLM 測試版";')
        text = text.replace('= "小麥注音";', '= "ZhuyinLM 測試版";')
        text = text.replace('= "傳統注音";', '= "ZhuyinLM 傳統注音測試版";')
        text = text.replace('= "Bopomofo";', '= "ZhuyinLM - Bopomofo";')
        text = text.replace('= "Plain Bopomofo";', '= "ZhuyinLM - Plain Bopomofo";')
        path.write_text(text)
    for icon in (ROOT / 'assets' / 'icons').glob('*.tiff'):
        shutil.copy(icon, DEST / 'Source' / 'Images' / icon.name)
    appicons = DEST / 'Source' / 'Images' / 'Images.xcassets' / 'AppIcon.appiconset'
    for icon in (ROOT / 'assets' / 'icons' / 'AppIcon.appiconset').glob('*.png'):
        if not (appicons / icon.name).exists():
            raise RuntimeError(f'Unexpected app icon name {icon.name}')
        shutil.copy(icon, appicons / icon.name)
    print(f'Prepared {DEST} from {PIN}')


if __name__ == '__main__':
    main()
