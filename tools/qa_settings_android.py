"""ADB helpers for checking the installed settings UI and Android DocumentsUI.

Uses the production APK, keeps app data, and writes screenshots for human review.
The scenario and results are recorded in docs/qa/0.1.10/device-checks.md.
"""
import argparse
import re
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = r'D:\Codex-Migrated\Android\Sdk\platform-tools\adb.exe'
PACKAGE = 'io.github.metammy07.novels'
DEVICE = 'emulator-5554'
OUT = Path(__file__).resolve().parents[1] / 'docs' / 'qa' / '0.1.10'


def adb(*command, binary=False):
    result = subprocess.run([ADB, '-s', DEVICE, *command], capture_output=True,
                            check=True, timeout=40)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace')


def tree():
    adb('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/litetale-settings-qa.xml')
    raw = adb('shell', 'cat', '/sdcard/litetale-settings-qa.xml')
    return ET.fromstring(raw[raw.index('<hierarchy'):])


def matches(root, label):
    exact = [n for n in root.iter('node')
             if label in (n.get('text', ''), n.get('content-desc', ''))]
    return exact or [n for n in root.iter('node')
                     if label in n.get('text', '') or label in n.get('content-desc', '')]


def tap_node(node):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
    assert x2 > x1 and y2 > y1, 'UI node is outside the screen'
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
    time.sleep(.5)


def swipe(down=False):
    width, height = map(int, re.findall(r'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1])
    y1, y2 = (.3, .8) if down else (.8, .35)
    adb('shell', 'input', 'swipe', str(round(width*.5)), str(round(height*y1)),
        str(round(width*.5)), str(round(height*y2)), '280')
    time.sleep(.4)


def tap(label, scroll=False, index=0):
    for attempt in range(8 if scroll else 3):
        nodes = matches(tree(), label)
        if nodes:
            tap_node(nodes[index])
            return
        if scroll:
            swipe()
        time.sleep(.4)
    raise AssertionError(f'Cannot find UI label: {label}')


def require(label):
    for _ in range(8):
        if matches(tree(), label):
            return
        time.sleep(.5)
    raise AssertionError(f'Cannot find expected UI label: {label}')


def capture(name):
    # Headless software rendering can outlast the route's nominal duration.
    # Capture settled layouts; animation frames require a separate recording.
    time.sleep(1.5)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
    ET.ElementTree(tree()).write(OUT / f'{name}.xml', encoding='utf-8', xml_declaration=True)
    print(OUT / f'{name}.png')


def restart():
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'am', 'start', '-W', '-f', '0x10008000', '-n',
        f'{PACKAGE}/opensource.wild.MainActivity')
    time.sleep(6)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['restart', 'tap', 'require', 'swipe', 'capture', 'dump', 'back'])
    parser.add_argument('label', nargs='?', default='')
    parser.add_argument('--scroll', action='store_true')
    parser.add_argument('--index', type=int, default=0)
    args = parser.parse_args()
    if args.action == 'restart':
        restart()
    elif args.action == 'tap':
        tap(args.label, scroll=args.scroll, index=args.index)
    elif args.action == 'require':
        require(args.label)
    elif args.action == 'swipe':
        swipe(args.label == 'down')
    elif args.action == 'capture':
        capture(args.label)
    elif args.action == 'back':
        adb('shell', 'input', 'keyevent', '4')
    else:
        for node in tree().iter('node'):
            label = node.get('text') or node.get('content-desc')
            if label:
                print(label.replace('\n', ' | '), node.get('bounds'))
