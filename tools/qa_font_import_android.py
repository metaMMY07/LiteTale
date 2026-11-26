"""Exercise the production APK through Android DocumentsUI, without test mocks.

Prepare the four named fixture fonts in /sdcard/Download, install the main APK,
then run this script. Test fonts are local QA inputs, not app assets.
"""
import argparse
import json
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--device', default='emulator-5554')
parser.add_argument('--out', default='docs/qa/0.1.9/system-picker')
args = parser.parse_args()
adb_path = r'D:\Codex-Migrated\Android\Sdk\platform-tools\adb.exe'
package = 'io.github.metammy07.novels'
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []


def adb(*command, binary=False):
    result = subprocess.run([adb_path, '-s', args.device, *command], capture_output=True, timeout=30, check=True)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace')


width, height = map(int, re.findall(r'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1])


def swipe_scroll(down=False):
    y1, y2 = (.33, .85) if down else (.81, .37)
    adb('shell', 'input', 'swipe', str(round(width * .8)), str(round(height * y1)),
        str(round(width * .8)), str(round(height * y2)), '300')
    time.sleep(.4)


def tree():
    adb('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/litetale-font-qa.xml')
    raw = adb('shell', 'cat', '/sdcard/litetale-font-qa.xml')
    return ET.fromstring(raw[raw.index('<hierarchy'):])


def matches(root, label):
    exact = [n for n in root.iter('node') if label in (n.get('text', ''), n.get('content-desc', ''))]
    return exact or [n for n in root.iter('node') if label in n.get('text', '') or label in n.get('content-desc', '')]


def tap_node(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
    assert x2 > x1 and y2 > y1, node.attrib
    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
    time.sleep(.6)


def tap(label, index=0, scroll=False):
    for attempt in range(6 if scroll else 3):
        root = tree()
        nodes = matches(root, label)
        if nodes:
            tap_node(nodes[index if index < len(nodes) else -1])
            return
        if scroll:
            swipe_scroll()
        time.sleep(.5)
    raise AssertionError(f'Cannot find {label}')


def require(label):
    for _ in range(8):
        if matches(tree(), label):
            return
        time.sleep(.6)
    raise AssertionError(f'Missing UI text: {label}')


def capture(name):
    time.sleep(.5)
    (out / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    ET.ElementTree(tree()).write(out / f'{name}.xml', encoding='utf-8', xml_declaration=True)


def mark(name):
    checks.append({'check': name, 'passed': True})
    print(f'PASS: {name}', flush=True)


def open_fonts():
    tap('我的', index=-1)
    tap('字体设置', scroll=True)
    require('全局界面字体')


def restart_app():
    # Clear only the activity task, preserving preferences and imported files.
    # This also closes an orphaned DocumentsUI task left by a failed QA run.
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'am', 'start', '-W', '-f', '0x10008000', '-n', f'{package}/opensource.wild.MainActivity')
    time.sleep(7)


def scroll_top():
    swipe_scroll(down=True)


def begin_import(scope):
    scroll_top()
    if scope == 'reader':
        swipe_scroll()
        tap('导入字体', index=-1)
    else:
        tap('导入字体', index=0 if scope == 'app' else -1)
    # DocumentsUI's first cold start can take several seconds on the emulator.
    for _ in range(8):
        root = tree()
        if any('documentsui' in n.get('package', '') for n in root.iter('node')):
            return
        time.sleep(.6)
    raise AssertionError('Native picker did not open')


def pick(name):
    root = tree()
    nodes = matches(root, name)
    if not nodes:
        downloads = matches(root, 'Downloads') or matches(root, '下载')
        if not downloads:
            menu = matches(root, 'Show roots') or matches(root, 'Open navigation drawer')
            if not menu:
                menu = [n for n in root.iter('node') if n.get('resource-id') == 'android:id/home']
            assert menu, 'DocumentsUI navigation menu missing'
            tap_node(menu[0])
            root = tree()
            downloads = matches(root, 'Downloads') or matches(root, '下载')
        assert downloads, 'Downloads root missing'
        tap_node(downloads[-1])
    tap(name)


def import_font(scope, name):
    begin_import(scope)
    pick(name)
    require(name)
    mark(f'{scope}: system picker imported {name}')


renamed = []
try:
    restart_app()
    open_fonts()
    capture('01-default-fonts')
    import_font('app', 'LiteTale-UI-Kai.ttf')
    capture('02-ui-kai')
    import_font('reader', 'LiteTale-Reader-Deng.ttf')
    capture('03-separate-cjk-fonts')

    begin_import('reader')
    adb('shell', 'input', 'keyevent', '4')
    require('LiteTale-Reader-Deng.ttf')
    mark('picker cancellation preserves reader font')
    begin_import('reader')
    pick('LiteTale-Broken.ttf')
    require('字体文件已损坏')
    require('LiteTale-Reader-Deng.ttf')
    capture('04-invalid-font-rejected')
    mark('invalid font is rejected without replacing the active choice')
    import_font('reader', 'LiteTale-Reader-Sans.otf')
    capture('05-otf-latin-and-cjk-fallback')
    import_font('reader', 'LiteTale-Reader-Deng.ttf')

    # Move only the two explicit fixture inputs, proving persistence is private.
    for name in ['LiteTale-UI-Kai.ttf', 'LiteTale-Reader-Deng.ttf']:
        source = f'/sdcard/Download/{name}'
        destination = f'/sdcard/Download/{name}.qa-original'
        adb('shell', 'mv', source, destination)
        renamed.append((source, destination))
    restart_app()
    open_fonts()
    require('LiteTale-UI-Kai.ttf')
    require('LiteTale-Reader-Deng.ttf')
    capture('06-after-process-restart-without-original-files')
    mark('process restart restores both app-private fonts after originals were moved')

    scroll_top()
    tap('恢复默认', index=0)
    require('默认 · 系统界面字体')
    require('LiteTale-Reader-Deng.ttf')
    capture('07-reset-ui-only')
    mark('resetting UI font preserves reader font')
    swipe_scroll()
    tap('恢复默认', index=-1, scroll=True)
    require('默认 · 霞鹜新致宋')
    capture('08-reset-both')
    mark('reader reset restores the bundled font')
except Exception:
    capture('failure')
    raise
finally:
    for source, destination in renamed:
        adb('shell', 'mv', destination, source)
    (out / 'checks.json').write_text(json.dumps(checks, ensure_ascii=False, indent=2), encoding='utf-8')
