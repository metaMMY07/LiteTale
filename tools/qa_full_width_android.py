"""Inspect the installed 0.1.13 APK without clearing its data or exporting DOM.

Operation rows must be fully visible before they can be tapped. Page-specific
assertions prevent an offscreen semantics node from clicking bottom navigation.
The root agent reviews the PNGs; screenshots alone are not automatic visual QA.
"""
import argparse
import json
import re
import subprocess
import time
from pathlib import Path

import qa_settings_android as q

OUT = Path(__file__).resolve().parents[1] / 'docs' / 'qa' / '0.1.13'
q.OUT = OUT
RESULTS = {}


def rect(node):
    return list(map(int, re.findall(r'\d+', node.get('bounds', ''))))


def viewport(root):
    candidates = [rect(node) for node in root.iter('node')
                  if node.get('scrollable') == 'true']
    return max(candidates, key=lambda b: (b[2]-b[0])*(b[3]-b[1])) if candidates else None


def tap_node(node):
    # Android's input service can briefly restart after emulator size changes.
    # Retry only a rejected shell injection, not failed application navigation.
    for attempt in range(3):
        try:
            q.tap_node(node)
            return
        except subprocess.CalledProcessError as error:
            print(f'Input injection rejected on attempt {attempt + 1}: '
                  f'{error.stderr.decode("utf-8", errors="replace")[:240]}', flush=True)
            if attempt == 2:
                raise
            time.sleep(1)


def tap_visible(label, scroll=False):
    for _ in range(16 if scroll else 3):
        root = q.tree()
        area = viewport(root)
        # My uses extendBody for the glass navigation bar. Its semantics scroll
        # viewport extends underneath the bar, which must not receive row taps.
        navigation_tops = []
        if area:
            for destination in ('发现', '书架', '历史', '我的'):
                lower_nodes = [rect(n) for n in root.iter('node')
                               if destination in (n.get('text', '') + '\n' +
                                                  n.get('content-desc', '')).splitlines()
                               and rect(n)[1] > area[3] * .75]
                if not lower_nodes:
                    navigation_tops = []
                    break
                navigation_tops.append(min(b[1] for b in lower_nodes))
            if len(navigation_tops) == 4:
                area = [area[0], area[1], area[2], min(navigation_tops)]
        for node in q.matches(root, label):
            x1, y1, x2, y2 = rect(node)
            if x2 <= x1 or y2 <= y1:
                continue
            if area and not (area[1] + 6 <= y1 and y2 <= area[3] - 6):
                continue
            tap_node(node)
            return
        if scroll:
            q.swipe()
        time.sleep(.4)
    raise AssertionError(f'No fully visible operation row: {label}')


def capture(name, marker, expect_scroll=True):
    q.require(marker)
    time.sleep(1.5)
    area = viewport(q.tree())
    width = int(re.findall(r'(\d+)x\d+', q.adb('shell', 'wm', 'size'))[-1])
    if expect_scroll and area:
        assert area[0] == 0 and area[2] == width, (name, area, width)
    RESULTS[name] = {'markerFound': True, 'scrollViewport': area}
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f'{name}.png'
    path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    (OUT / 'route-checks.json').write_text(json.dumps(RESULTS, indent=2), encoding='utf-8')
    print(path, flush=True)


def more():
    q.restart()
    nodes = q.matches(q.tree(), '我的')
    assert nodes, 'Missing My navigation destination'
    tap_node(nodes[-1])
    q.require('离线下载')


def edge_drag(right=True, down=False):
    width, height = map(int, re.findall(r'(\d+)x(\d+)', q.adb('shell', 'wm', 'size'))[-1])
    x = width - 20 if right else 20
    y1, y2 = (.3, .8) if down else (.8, .3)
    q.adb('shell', 'input', 'swipe', str(x), str(round(height*y1)),
          str(x), str(round(height*y2)), '450')
    time.sleep(.8)


def label_rect(label):
    nodes = q.matches(q.tree(), label)
    assert nodes, label
    return rect(nodes[0])


def open_from_more(entry, marker):
    more()
    tap_visible(entry, scroll=True)
    q.require(marker)


def main(after_statistics=False, after_trends=False):
    installed = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.13' in installed and 'versionCode=4048' in installed, (
        'Install the 0.1.13 x86_64 production APK first; do not downgrade it'
    )
    expected = next(item['sha256'] for item in json.loads(
        (OUT.parents[2] / 'build' / 'releases' / '0.1.13' /
         'apk-verification.json').read_text(encoding='utf-8')
    ) if item['abi'] == 'x86_64')
    package_path = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().split('package:', 1)[1]
    installed_hash = q.adb('shell', 'sha256sum', package_path).split()[0]
    assert installed_hash == expected, 'Installed APK differs from the verified delivery APK'
    RESULTS['installedApk'] = {'version': '0.1.13', 'versionCode': 4048,
                               'sha256': installed_hash}
    q.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    q.adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    q.adb('shell', 'wm', 'size', '2560x1800')
    q.adb('shell', 'wm', 'density', '320')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.4')
    if after_trends:
        pass
    elif after_statistics:
        open_from_more('阅读统计', '统计书源：')
    else:
        more()
        capture('tablet-my-full-width', '离线下载')
        before = label_rect('设置')
        edge_drag()
        after = label_rect('设置')
        assert after[1] < before[1] - 60, (before, after)
        capture('tablet-my-right-inset-drag', '设置')
        edge_drag(right=False, down=True)
        restored = label_rect('设置')
        assert restored[1] > after[1] + 60, (after, restored)
        RESULTS['edgeGestures'] = {'rightInset': [before, after], 'leftInset': [after, restored]}

        tap_visible('设置', scroll=True)
        capture('tablet-settings-full-width', '自动检查更新')
        tap_visible('主题与纸张', scroll=True)
        capture('tablet-theme-paper-full-width', '保持浅色')
        edge_drag()
        capture('tablet-theme-paper-scrolled', '纸张')
        q.adb('shell', 'input', 'keyevent', '4')
        tap_visible('阅读设置', scroll=True)
        capture('tablet-reader-settings-full-width', '字号')

        open_from_more('字体设置', '选择你喜欢的字形')
        capture('tablet-font-settings-full-width', '全局界面字体')
        edge_drag()
        capture('tablet-font-settings-scrolled', '小说阅读字体')

        open_from_more('阅读统计', '统计书源：')
        capture('tablet-statistics-full-width', '阅读活动')
    if not after_trends:
        tap_visible('查看详情', scroll=True)
        capture('tablet-statistics-trends-full-width', '按书籍堆叠的阅读时长')

    open_from_more('关于 LiteTale', '版本 0.1.13')
    capture('tablet-about-full-width', '版本 0.1.13')

    open_from_more('书源与账号', '一次使用一个书源。切换后保留各自的登录状态。')
    capture('tablet-source-settings-full-width', '文库8镜像')

    # No credentials are entered. The full-width form and local introduction
    # are checked independently of the server's captcha response.
    tap_visible('登录文库8', scroll=True)
    capture('tablet-wenku8-login-full-width', '下一段故事，从这里开始')

    open_from_more('设置', '自动检查更新')
    tap_visible('快照数据', scroll=True)
    capture('tablet-data-settings-full-width', '保存到文件')
    q.adb('shell', 'input', 'keyevent', '4')
    tap_visible('应用日志', scroll=True)
    capture('tablet-logs-full-width', '应用日志')

    open_from_more('离线下载', '下载')
    capture('tablet-download-empty', '暂无下载内容', expect_scroll=False)

    q.adb('shell', 'wm', 'size', '720x1600')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.8')
    more()
    capture('phone-my-large-font', '离线下载')
    tap_visible('字体设置', scroll=True)
    capture('phone-font-settings-large-font', '选择你喜欢的字形')
    edge_drag()
    capture('phone-font-settings-large-font-scrolled', '小说阅读字体')
    print('Installed-APK routes, full-width viewports and both inset gestures passed.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--after-statistics', action='store_true')
    parser.add_argument('--after-trends', action='store_true')
    args = parser.parse_args()
    if args.after_statistics or args.after_trends:
        RESULTS.update(json.loads((OUT / 'route-checks.json').read_text(encoding='utf-8')))
    initial = {name: q.adb('shell', 'settings', 'get', 'system', name).strip()
               for name in ('font_scale', 'accelerometer_rotation', 'user_rotation')}
    initial_size = re.search(r'Override size: (\d+x\d+)', q.adb('shell', 'wm', 'size'))
    initial_density = re.search(r'Override density: (\d+)', q.adb('shell', 'wm', 'density'))
    try:
        main(after_statistics=args.after_statistics, after_trends=args.after_trends)
    finally:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / 'route-checks.json').write_text(json.dumps(RESULTS, indent=2), encoding='utf-8')
        q.adb('shell', 'wm', 'size', initial_size.group(1) if initial_size else 'reset')
        q.adb('shell', 'wm', 'density', initial_density.group(1) if initial_density else 'reset')
        for name, value in initial.items():
            if value != 'null':
                q.adb('shell', 'settings', 'put', 'system', name, value)
        q.restart()
