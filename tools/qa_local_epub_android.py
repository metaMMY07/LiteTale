"""Exercise local EPUB imports with Android DocumentsUI on the QA AVD.

Uses self-authored fixtures only; preserves application data and account state.
Does not save account XML, credentials, cookies or chapter text from the web.
"""
import json
import re
import shlex
import struct
import subprocess
import time
from pathlib import Path
import qa_settings_android as q
from qa_source_reading_android import tap_destination

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs' / 'qa' / 'epub-local-2026-10' / 'android'
FIXTURES = ROOT / 'build' / 'epub-local' / 'fixtures'
RESULTS = []
_original_tree = q.tree


def stable_tree():
    # Android's accessibility dump may fail while a cold route is settling.
    for attempt in range(4):
        try:
            return _original_tree()
        except (subprocess.CalledProcessError, ValueError):
            if attempt == 3:
                raise
            time.sleep(.7)


q.tree = stable_tree


def mark(name, **details):
    RESULTS[:] = [item for item in RESULTS if item['check'] != name]
    RESULTS.append({'check': name, 'passed': True, **details})
    print(json.dumps(RESULTS[-1], ensure_ascii=False), flush=True)
    (OUT / 'checks.json').write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2), encoding='utf-8')


def screenshot(name):
    png = q.adb('exec-out', 'screencap', '-p', binary=True)
    (OUT / f'{name}.png').write_bytes(png)
    return struct.unpack('>II', png[16:24])


def picker(name=None):
    nodes = q.tree()
    import_buttons = q.matches(nodes, '导入 EPUB')
    if import_buttons:
        q.tap_node(import_buttons[0])
    else:
        # In the populated grid the action is an icon in the top app bar.
        # Some release Flutter semantics omit tooltip-only icon labels.
        assert q.matches(nodes, '本地书籍')
        width, _ = map(int, re.findall(r'(\d+)x(\d+)', q.adb('shell', 'wm', 'size'))[-1])
        q.adb('shell', 'input', 'tap', str(width-64), '158')
    for _ in range(8):
        nodes = q.tree()
        if any('documentsui' in n.get('package', '') for n in nodes.iter('node')):
            break
        time.sleep(.5)
    else:
        raise AssertionError('Android document picker did not open')
    if name is None:
        q.adb('shell', 'input', 'keyevent', '4')
        q.require('本地书籍')
        return
    if not q.matches(nodes, name):
        downloads = q.matches(nodes, 'Downloads') or q.matches(nodes, '下载')
        if not downloads:
            menu = q.matches(nodes, 'Show roots') or q.matches(nodes, 'Open navigation drawer')
            if not menu:
                menu = [n for n in nodes.iter('node') if n.get('resource-id') == 'android:id/home']
            assert menu, 'Document picker navigation menu missing'
            q.tap_node(menu[0])
            nodes = q.tree()
            downloads = q.matches(nodes, 'Downloads') or q.matches(nodes, '下载')
        assert downloads, 'Downloads location missing'
        q.tap_node(downloads[-1])
    q.tap(name, scroll=True)


def open_library():
    tap_destination('书架')
    q.tap('本地书籍')
    q.require('本地书籍')
    assert any(n.get('class') == 'android.widget.EditText' for n in q.tree().iter('node')), 'Local library search missing'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.25' in metadata and 'versionCode=4067' in metadata
    assert 'firstInstallTime=2026-09-27 14:47:16' in metadata
    for name in ('旅途·中文与插图 EPUB3.epub', '旅途·中文与插图 EPUB2.epub', '损坏文件.epub'):
        q.adb('push', str(FIXTURES / name), '/sdcard/Download/' + name)
    q.restart()
    open_library()
    screenshot('01-empty-library')
    picker()
    mark('system_picker_cancel_preserves_library')
    picker('旅途·中文与插图 EPUB3.epub')
    q.require('远行日记 EPUB3')
    screenshot('02-epub3-imported')
    mark('epub3_unicode_filename_and_cover_import')
    picker('旅途·中文与插图 EPUB3.epub')
    q.require('已在本地书籍中')
    mark('same_file_duplicate_is_not_added')
    picker('损坏文件.epub')
    q.require('有效的 EPUB')
    q.require('远行日记 EPUB3')
    mark('invalid_epub_does_not_replace_imported_book')
    picker('旅途·中文与插图 EPUB2.epub')
    q.require('远行日记 EPUB2')
    screenshot('03-epub2-and-epub3')
    mark('epub2_ncx_import')
    # Do not depend on the system picker's temporary file remaining available.
    original = '/sdcard/Download/旅途·中文与插图 EPUB3.epub'
    hidden = original + '.qa-original'
    q.adb('shell', f'mv {shlex.quote(original)} {shlex.quote(hidden)}')
    try:
        q.restart()
        open_library()
        q.require('远行日记 EPUB3')
        q.tap('远行日记 EPUB3')
        q.require('小说详情')
        q.require('序章·站台的风')
        q.require('后记·海边来信')
        screenshot('04-private-copy-catalog')
        mark('restart_without_original_preserves_private_book_and_spine_order')
        q.tap('序章·站台的风')
        time.sleep(3)
        root = q.tree()
        assert not q.matches(root, '加载失败')
        assert not q.matches(root, '小说详情')
        screenshot('05-landscape-reader')
        mark('opens_existing_native_reader')
    finally:
        q.adb('shell', f'mv {shlex.quote(hidden)} {shlex.quote(original)}')


if __name__ == '__main__':
    main()
