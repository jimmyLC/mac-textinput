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


SHADOW_FILES = [
    *sorted((ROOT / 'Sources' / 'BilingualPrototype').glob('*.swift')),
    ROOT / 'Sources' / 'BilingualInput' / 'BilingualInput.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'BilingualInputController.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'UserDictionary.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'PhraseRepair.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'LearningStore.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'DebugLog.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'ScriptSpacing.swift',
    ROOT / 'Sources' / 'BilingualInput' / 'UserDictionaryWindow.swift',
]


def install_shadow_observer():
    """Compile the bilingual analyzer into the app and let it route English runs."""
    source = DEST / 'Source'
    for path in SHADOW_FILES:
        shutil.copy(path, source / path.name)
    pbx = DEST / 'McBopomofo.xcodeproj' / 'project.pbxproj'
    text = pbx.read_text()
    anchor_build = 'D44FB74527915565003C80A6 /* Preferences.swift in Sources */ = {isa = PBXBuildFile; fileRef = D44FB74427915555003C80A6 /* Preferences.swift */; };\n'
    anchor_ref = 'D44FB74427915555003C80A6 /* Preferences.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Preferences.swift; sourceTree = "<group>"; };\n'
    anchor_group = '\t\t\t\tD44FB74427915555003C80A6 /* Preferences.swift */,\n'
    anchor_phase = '\t\t\t\tD44FB74527915565003C80A6 /* Preferences.swift in Sources */,\n'
    for anchor in (anchor_build, anchor_ref, anchor_group, anchor_phase):
        if text.count(anchor) != 1:
            raise RuntimeError('project.pbxproj layout changed; cannot add shadow files')
    builds = refs = groups = phases = ''
    for index, path in enumerate(SHADOW_FILES):
        ref_id = f'5A1E0000000000000000{index:04X}'
        build_id = f'5A1E0000000000000001{index:04X}'
        name = path.name
        builds += f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n'
        refs += f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
        groups += f'\t\t\t\t{ref_id} /* {name} */,\n'
        phases += f'\t\t\t\t{build_id} /* {name} in Sources */,\n'
    text = (text.replace(anchor_build, anchor_build + builds).replace(anchor_ref, anchor_ref + refs)
            .replace(anchor_group, anchor_group + groups).replace(anchor_phase, anchor_phase + phases))
    pbx.write_text(text)
    controller = source / 'InputMethodController.swift'
    replace(controller, '        keyHandler.clear()\n        keyHandler.syncWithPreferences()\n',
            '        keyHandler.clear()\n        BilingualInput.shared.reset(capsLock: NSEvent.modifierFlags.contains(.capsLock))\n        keyHandler.syncWithPreferences()\n')
    replace(controller, '    override func deactivateServer(_ client: Any!) {\n        currentClient = nil\n',
            '    override func deactivateServer(_ client: Any!) {\n        showBilingualTooltip(nil, client: client)\n        BilingualInput.shared.reset()\n        currentClient = nil\n')
    replace(controller, '    override func handle(_ maybeEvent: NSEvent!, client: Any!) -> Bool {\n        // nil may be passed, applefeedback://FB11472618\n        guard let event = maybeEvent else {\n            commitComposition(client)\n            return false\n        }\n',
            '    override func handle(_ maybeEvent: NSEvent!, client: Any!) -> Bool {\n        // nil may be passed, applefeedback://FB11472618\n        guard let event = maybeEvent else {\n            commitComposition(client)\n            return false\n        }\n        if let handled = bilingualHandle(event, client: client) { return handled }\n')
    # Show Traditional Chinese UI regardless of the system language order (this app only).
    replace(source / 'main.swift', 'import InputSourceHelper\n',
            'import InputSourceHelper\n\nUserDefaults.standard.set(["zh-Hant"], forKey: "AppleLanguages")\n')
    replace(controller, '        menu.addItem(NSMenuItem.separator())\n        menu.addItem(\n            withTitle: NSLocalizedString("User Phrases", comment: ""), action: nil,',
            '        menu.addItem(withTitle: "個人詞典…", action: #selector(openUserDictionary(_:)), keyEquivalent: "")\n        menu.addItem(NSMenuItem.separator())\n        menu.addItem(\n            withTitle: NSLocalizedString("User Phrases", comment: ""), action: nil,')
    replace(controller, 'private static let tooltipController', 'static let tooltipController')
    replace(controller, '        return result\n    }\n\n    // MARK: - Menu Items',
            '        bilingualAfterKey(client: client)\n        return result\n    }\n\n    // MARK: - Menu Items')


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
    shutil.copy(ROOT / 'assets' / 'ui' / 'TooltipController.swift',
                DEST / 'Packages' / 'TooltipUI' / 'Sources' / 'TooltipUI' / 'TooltipController.swift')
    install_shadow_observer()
    print(f'Prepared {DEST} from {PIN}')


if __name__ == '__main__':
    main()
