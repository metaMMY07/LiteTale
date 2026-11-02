"""Check the installed APK's operation pages; keep its account/font data.

Screenshots are for the root agent's visual review. Gestures run in the blank
right/left margins of the full-width scroll viewport. No login fields are filled.
"""
import argparse
import json
import re
import time
from pathlib import Path

import qa_settings_android as q

OUT = Path(__file__).resolve().parents[1] / 'docs' / 'qa' / '0.1.12'
q.OUT = OUT


def screenshot(name):
    time.sleep(1.5)
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f'{name}.png'
    path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    print(path)


def bounds(label):
    nodes = q.matches(q.tree(), label)
    assert nodes, f'Missing visible label: {label}'
    return list(map(int, re.findall(r'\d+', nodes[0].get('bounds', ''))))


def tap_visible(label, scroll=False):
    # Flutter semantics can retain an offscreen row at the navigation bar.
    # Only tap a row whose centre is inside the operation scroll viewport.
    for _ in range(12 if scroll else 3):
        root = q.tree()
        viewports = [list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
                     for node in root.iter('node') if node.get('scrollable') == 'true']
        viewport = max(viewports, key=lambda b: (b[2]-b[0])*(b[3]-b[1])) if viewports else None
        for node in q.matches(root, label):
            x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
            centre = ((x1+x2)//2, (y1+y2)//2)
            if viewport and not (viewport[0] < centre[0] < viewport[2] and
                                 viewport[1] < centre[1] < viewport[3]):
                continue
            q.tap_node(node)
            return
        if scroll:
            q.swipe()
        time.sleep(.4)
    raise AssertionError(f'Cannot find a visible operation row: {label}')


def edge_swipe(right=True, down=False):
    x = 2350 if right else 40
    y1, y2 = (500, 1430) if down else (1430, 500)
    q.adb('shell', 'input', 'swipe', str(x), str(y1), str(x), str(y2), '450')
    time.sleep(.8)


def check_more_edges():
    q.require('我的')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.4')
    q.restart()
    q.tap('我的')
    before = bounds('设置')
    screenshot('tablet-my-start')
    edge_swipe()
    after = bounds('设置')
    assert after[1] < before[1] - 60, (before, after)
    screenshot('tablet-my-right-edge-scroll')
    edge_swipe(right=False, down=True)
    restored = bounds('设置')
    assert restored[1] > after[1] + 60, (after, restored)
    return {'rightMarginSwipe': [before, after], 'leftMarginSwipe': [after, restored]}


def main(resume_from_source=False):
    installed = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.12' in installed and 'versionCode=4047' in installed, (
        'Install the 0.1.12 x86_64 production APK before running this scenario'
    )
    # Configuration changes are emulator display settings, not application data.
    q.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    q.adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    q.adb('shell', 'wm', 'size', '2560x1800')
    q.adb('shell', 'wm', 'density', '320')
    q.restart()
    q.tap('我的')
    result = check_more_edges()
    (OUT / 'edge-gesture-results.json').write_text(json.dumps(result, indent=2), encoding='utf-8')

    if not resume_from_source:
        tap_visible('设置', scroll=True)
        screenshot('tablet-settings-start')
        edge_swipe()
        screenshot('tablet-settings-right-edge-scroll')
        edge_swipe(down=True)
        tap_visible('主题与纸张', scroll=True)
        screenshot('tablet-theme-paper-start')
        edge_swipe()
        screenshot('tablet-theme-paper-right-edge-scroll')
        q.adb('shell', 'input', 'keyevent', '4')
        tap_visible('阅读设置', scroll=True)
        screenshot('tablet-reader-settings-start')
        edge_swipe()
        screenshot('tablet-reader-settings-right-edge-scroll')
        q.adb('shell', 'input', 'keyevent', '4')
        q.adb('shell', 'input', 'keyevent', '4')

        tap_visible('字体设置', scroll=True)
        screenshot('tablet-font-settings-start')
        edge_swipe()
        screenshot('tablet-font-settings-right-edge-scroll')
        q.adb('shell', 'input', 'keyevent', '4')
        tap_visible('阅读统计', scroll=True)
        screenshot('tablet-statistics-start')
        edge_swipe()
        screenshot('tablet-statistics-right-edge-scroll')
        q.adb('shell', 'input', 'keyevent', '4')
        tap_visible('关于 LiteTale', scroll=True)
        q.require('0.1.12')
        screenshot('tablet-about')
        q.adb('shell', 'input', 'keyevent', '4')
    # The list retains its position after returning from a lower entry.
    # Return to its top before looking for the earlier source/account row.
    for _ in range(3):
        edge_swipe(right=False, down=True)
    tap_visible('书源与账号', scroll=True)
    screenshot('tablet-source-settings')
    tap_visible('登录文库8', scroll=True)
    screenshot('tablet-wenku8-login')
    q.adb('shell', 'input', 'keyevent', '4')
    q.adb('shell', 'input', 'keyevent', '4')

    q.adb('shell', 'wm', 'size', '720x1600')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.8')
    q.restart()
    q.tap('我的')
    screenshot('phone-my-large-font')
    tap_visible('字体设置', scroll=True)
    screenshot('phone-font-settings-large-font')
    q.adb('shell', 'input', 'swipe', '680', '1250', '680', '500', '450')
    screenshot('phone-font-settings-large-font-scrolled')
    OUT.mkdir(parents=True, exist_ok=True)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--resume-from-source', action='store_true')
    args = parser.parse_args()
    initial_display = {}
    for property_name in ('font_scale', 'accelerometer_rotation', 'user_rotation'):
        initial_display[property_name] = q.adb(
            'shell', 'settings', 'get', 'system', property_name
        ).strip()
    size_output = q.adb('shell', 'wm', 'size')
    density_output = q.adb('shell', 'wm', 'density')
    initial_size = re.search(r'Override size: (\d+x\d+)', size_output)
    initial_density = re.search(r'Override density: (\d+)', density_output)
    try:
        main(resume_from_source=args.resume_from_source)
    finally:
        q.adb('shell', 'wm', 'size', initial_size.group(1) if initial_size else 'reset')
        q.adb('shell', 'wm', 'density', initial_density.group(1) if initial_density else 'reset')
        for property_name, value in initial_display.items():
            if value != 'null':
                q.adb('shell', 'settings', 'put', 'system', property_name, value)
        q.restart()
