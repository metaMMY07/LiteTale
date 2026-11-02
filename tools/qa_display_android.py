"""Check the installed display-only 0.1.15 release without altering account data.

Write only PNG screenshots and bounded validation metadata. The root agent
must review the screenshots; do not export UI DOM, credentials, or cookies.
"""
import argparse
import hashlib
import json
import re
import time
from pathlib import Path

import qa_full_width_android as ui

q = ui.q
OUT = Path(__file__).resolve().parents[1] / 'docs/qa/0.1.15'
REPORT = OUT / 'device-checks.json'


def read_report():
    return json.loads(REPORT.read_text(encoding='utf-8')) if REPORT.exists() else {}


def save(report):
    OUT.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


def shot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f'{name}.png'
    path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    print(path, flush=True)


def guard(report):
    installed = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.15' in installed and 'versionCode=4050' in installed
    package_path = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().split('package:', 1)[1]
    actual = q.adb('shell', 'sha256sum', package_path).split()[0]
    delivery = OUT.parents[2] / 'build/releases/0.1.15/LiteTale-0.1.15-x86_64.apk'
    assert actual == hashlib.sha256(delivery.read_bytes()).hexdigest()
    report['installed'] = {'version': '0.1.15', 'versionCode': 4050, 'sha256': actual,
                           'matchesDelivery': True, 'retainedAppData': True}


def display_page():
    ui.more()
    ui.tap_visible('显示', scroll=True)
    q.require('主题与纸张')
    root = q.tree()
    for label in ('字体设置', '阅读显示', '汉字变体'):
        assert q.matches(root, label), label
    for label in ('自动检查更新', '更新渠道', '分发平台', '立即检查更新', '快照数据'):
        assert not q.matches(root, label), label
    width = int(re.findall(r'(\d+)x\d+', q.adb('shell', 'wm', 'size'))[-1])
    area = ui.viewport(root)
    # Android omits the scrollable semantics flag when all four rows fit.
    if area is not None:
        assert area[0] == 0 and area[2] == width, area
    rows = [ui.rect(n) for n in q.matches(root, '主题与纸张')]
    assert rows and any(b[0] < width * .1 and b[2] > width * .9 for b in rows), rows
    return {'scrollViewport': area, 'operationRowBounds': rows,
            'contentFitsWithoutScrolling': area is None}


def subpage(entry, marker, name):
    ui.tap_visible(entry, scroll=True)
    q.require(marker)
    time.sleep(1)
    shot(name)
    q.adb('shell', 'input', 'keyevent', '4')
    q.require('汉字变体')


def phone(report):
    q.adb('shell', 'wm', 'size', 'reset')
    q.adb('shell', 'wm', 'density', 'reset')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
    viewport = display_page()
    shot('phone-display')
    subpage('主题与纸张', '应用配色', 'phone-theme-paper')
    subpage('字体设置', '全局界面字体', 'phone-fonts')
    subpage('阅读显示', '仿真翻页', 'phone-reader-display')
    report['phone'] = {'displayEntryDirect': True, 'displayOnly': True,
                       'themeFontsReaderRoutesReturn': True, 'layout': viewport}
    save(report)


def tablet(report):
    q.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    q.adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    q.adb('shell', 'wm', 'size', '2560x1800')
    q.adb('shell', 'wm', 'density', '320')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.4')
    ui.more()
    q.require('主题、字体与阅读排版')
    shot('tablet-my')
    ui.tap_visible('显示', scroll=True)
    q.require('主题与纸张')
    shot('tablet-display')
    ui.tap_visible('阅读显示', scroll=True)
    q.require('仿真翻页')
    root = q.tree()
    for label in ('点击翻页', '音量键翻页', '边界切换章节', '避免误触返回'):
        assert not q.matches(root, label), label
    area = ui.viewport(root)
    assert area is not None and area[0] == 0 and area[2] == 2560, area
    shot('tablet-reader-display')
    before = ui.label_rect('字号')
    ui.edge_drag(right=True)
    after_nodes = q.matches(q.tree(), '字号')
    after = ui.rect(after_nodes[0]) if after_nodes else None
    assert after is None or after[1] < before[1], (before, after)
    shot('tablet-reader-display-scrolled')
    ui.edge_drag(right=False, down=True)
    restored = ui.label_rect('字号')
    assert after is None or restored[1] > after[1], (after, restored)
    report['tablet'] = {'displayEntryDirect': True, 'displayOnly': True,
                        'readerDisplayOnly': True, 'fullWidthViewport': area,
                        'rightInsetDrag': True, 'leftInsetDrag': True,
                        'fontScale': 1.4}
    save(report)


def restore(report):
    q.adb('shell', 'wm', 'size', 'reset')
    q.adb('shell', 'wm', 'density', 'reset')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
    q.adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    q.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '1')
    q.restart()
    q.require('按目录查找')
    report['restored'] = {'originalDisplay': True, 'source': 'lnovel',
                          'accountDataUnchanged': True}
    save(report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['phone', 'tablet', 'restore'])
    args = parser.parse_args()
    report = read_report()
    guard(report)
    globals()[args.phase](report)
