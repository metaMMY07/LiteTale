"""Check the installed 0.1.14 release; keep data and never submit credentials.

Stores only screenshots and bounded pass/fail metadata. The root agent must
inspect screenshots; fixture tests cannot establish online Wenku8 availability.
"""
import argparse
import json
import re
import time
from pathlib import Path

import qa_full_width_android as ui

q = ui.q
OUT = Path(__file__).resolve().parents[1] / 'docs/qa/0.1.14'
OUT.mkdir(parents=True, exist_ok=True)
REPORT = OUT / 'device-checks.json'
result = json.loads(REPORT.read_text(encoding='utf-8')) if REPORT.exists() else {}


def save():
    REPORT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')


def shot(name):
    path = OUT / f'{name}.png'
    path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    print(path, flush=True)


def source(label):
    # Flutter merges the field, explanatory text and session label into a
    # large button node. Its centre is not the dropdown's actual hit target.
    root = q.tree()
    fields = [n for n in root.iter('node')
              if '当前书源' in (n.get('text', '') + '\n' +
                              n.get('content-desc', '')).splitlines()]
    assert fields, 'Source field is missing'
    field = min(fields, key=lambda n: (ui.rect(n)[2] - ui.rect(n)[0]) *
                (ui.rect(n)[3] - ui.rect(n)[1]))
    x1, y1, x2, y2 = ui.rect(field)
    arrow_x = round(x2 - (x2 - x1) * .053)
    q.adb('shell', 'input', 'tap', str(arrow_x), str((y1 + y2) // 2))
    deadline = time.monotonic() + 8
    choice = None
    while time.monotonic() < deadline:
        choices = [n for n in q.tree().iter('node')
                   if label in (n.get('text', ''), n.get('content-desc', ''))]
        if choices:
            choice = choices[0]
            break
        time.sleep(.4)
    assert choice is not None, 'Source dropdown did not open'
    q.tap_node(choice)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        current = q.matches(q.tree(), '当前书源')
        if any(label in (n.get('text', '') + n.get('content-desc', '')).splitlines()
               for n in current):
            return
        time.sleep(.4)
    raise AssertionError('Source selection was not reflected in its field')


def settled(label, timeout=55):
    """Wait for a real route marker; never treat a loading screenshot as success."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        root = q.tree()
        if q.matches(root, label):
            return root
        if any(q.matches(root, error) for error in
               ('搜索未完成', '重试首页', '加载失败 (下拉刷新)')):
            raise AssertionError(f'Application error while waiting for {label}')
        time.sleep(1)
    raise AssertionError(f'Route did not settle: {label}')


def delivery_search():
    q.tap('搜索书名、作者')
    q.require('搜索')
    fields = [n for n in q.tree().iter('node')
              if n.get('class') == 'android.widget.EditText']
    assert len(fields) == 1
    q.tap_node(fields[0])
    q.adb('shell', 'input', 'text', 'Re')
    q.adb('shell', 'input', 'keyevent', '66')
    root = settled('志乃与恋 Future')
    search = {'keyword': 'Re', 'resultsVisible': True,
              'errorVisible': bool(q.matches(root, '搜索未完成')),
              'submittedByKeyboard': True, 'installedDeliveryApk': True}
    old = result.setdefault('onlineRead', {}).get('search')
    if old and old != search:
        result['onlineRead'].setdefault('searchHistory', []).append(old)
    result['onlineRead']['search'] = search
    shot('tablet-wenku8-search-delivery')
    save()
    q.adb('shell', 'input', 'keyevent', '4')
    settled('新书风云榜')
    q.tap('搜索书名、作者')
    fields = [n for n in q.tree().iter('node')
              if n.get('class') == 'android.widget.EditText']
    assert len(fields) == 1
    q.tap_node(fields[0])
    q.adb('shell', 'input', 'text', 'LiteTaleNoResult20261003')
    q.adb('shell', 'input', 'keyevent', '66')
    settled('没有找到相关书籍，试试其他关键词')
    result['onlineRead']['emptySearch'] = {
        'keyword': 'LiteTaleNoResult20261003', 'emptyMessageVisible': True,
        'errorVisible': False, 'installedDeliveryApk': True}
    shot('tablet-wenku8-empty-search-delivery')
    save()
    q.adb('shell', 'input', 'keyevent', '4')
    settled('新书风云榜')


def book_cards(root):
    """Count bounded, visible book buttons instead of assuming a live ranking."""
    cards = []
    for node in root.iter('node'):
        label = node.get('text') or node.get('content-desc', '')
        x1, y1, x2, y2 = ui.rect(node)
        if (label and node.get('clickable') == 'true' and y1 > 470 and
                y2 < 1580 and x2 - x1 > 180 and 200 < y2 - y1 < 1000):
            cards.append(node)
    return cards


def settled_books():
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        root = q.tree()
        if q.matches(root, '加载失败 (下拉刷新)'):
            raise AssertionError('Book list returned an application error')
        cards = book_cards(root)
        if len(cards) >= 3:
            return root, cards
        time.sleep(1)
    raise AssertionError('Visible book list did not load')


def delivery_catalog():
    # Start from the campus category after selecting its actual popup control.
    q.require('校园')
    _, cards = settled_books()
    result['onlineRead']['category'] = {
        'tag': '校园', 'recordsVisible': True, 'visibleBookCards': len(cards),
        'errorVisible': False, 'installedDeliveryApk': True}
    shot('tablet-wenku8-category-delivery')
    save()
    q.tap('排行')
    q.require('总访问')
    _, cards = settled_books()
    result['onlineRead']['ranking'] = {
        'recordsVisible': True, 'visibleBookCards': len(cards),
        'errorVisible': False, 'installedDeliveryApk': True}
    shot('tablet-wenku8-ranking-delivery')
    save()
    q.tap('完结')
    _, cards = settled_books()
    result['onlineRead']['completed'] = {
        'recordsVisible': True, 'visibleBookCards': len(cards),
        'errorVisible': False, 'installedDeliveryApk': True}
    shot('tablet-wenku8-completed-delivery')
    save()


def delivery_settings_and_source():
    ui.more()
    shot('tablet-my-full-width-delivery')
    ui.tap_visible('设置', scroll=True)
    q.require('主题与纸张')
    root = q.tree()
    assert not q.matches(root, '数据')
    display = ui.rect(q.matches(root, '显示')[0])
    update = ui.rect(q.matches(root, '更新')[0])
    assert display[1] < update[1]
    area = ui.viewport(root)
    assert area and area[0] == 0 and area[2] == 2560
    result['settings'] = {
        'displayBeforeUpdates': True, 'dataGroupAbsent': True,
        'fullWidthScrollViewport': area, 'installedDeliveryApk': True}
    shot('tablet-settings-display-first-delivery')
    save()
    q.adb('shell', 'input', 'keyevent', '4')
    ui.tap_visible('书源与账号', scroll=True)
    q.require('当前书源')
    q.require('已保存登录')
    shot('tablet-wenku8-saved-source-delivery')
    source('轻小说百科')
    q.require('公开书源')
    q.restart()
    q.require('按目录查找繁体书名')
    ui.more()
    ui.tap_visible('书源与账号', scroll=True)
    source('文库8')
    q.require('已保存登录')
    q.restart()
    root = settled('新书风云榜')
    assert not q.matches(root, '选择书源')
    result['sourceSwitch'] = {
        'from': 'wenku8', 'via': 'lnovel', 'returnedTo': 'wenku8',
        'savedLoginVisible': True, 'bookFeedAfterRestart': True,
        'additionalLoginSubmission': False, 'installedDeliveryApk': True}
    shot('tablet-wenku8-source-switch-delivery')
    save()


def delivery_guest_source_entry():
    q.restart()
    q.require('选择书源')
    shot('tablet-wenku8-guest-source-entry-delivery')
    ui.tap_visible('选择书源')
    q.require('当前书源')
    q.require('文库8镜像')
    root = q.tree()
    assert not q.matches(root, '主题与纸张')
    result['homeSourceEntry'] = {
        'opensSourceSettingsDirectly': True, 'installedDeliveryApk': True}
    shot('tablet-direct-source-settings-delivery')
    save()


def navigation():
    info = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.14' in info and 'versionCode=4049' in info
    result['installed'] = {'version': '0.1.14', 'versionCode': 4049}
    result.setdefault('originalDisplay', {
        'size': q.adb('shell', 'wm', 'size').strip(),
        'density': q.adb('shell', 'wm', 'density').strip(),
        'fontScale': q.adb('shell', 'settings', 'get', 'system', 'font_scale').strip(),
        'rotation': q.adb('shell', 'settings', 'get', 'system', 'user_rotation').strip(),
        'autoRotation': q.adb('shell', 'settings', 'get', 'system', 'accelerometer_rotation').strip(),
    })
    save()
    ui.more()
    ui.tap_visible('设置', scroll=True)
    q.require('主题与纸张')
    root = q.tree()
    assert not q.matches(root, '数据')
    display, update = ui.rect(q.matches(root, '显示')[0]), ui.rect(q.matches(root, '更新')[0])
    assert display[1] < update[1]
    result['settings'] = {'displayBeforeUpdates': True, 'dataGroupAbsent': True}
    shot('phone-settings-display-first')
    q.adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    q.adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    q.adb('shell', 'wm', 'size', '2560x1800')
    q.adb('shell', 'wm', 'density', '320')
    q.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.4')
    time.sleep(3)
    q.require('主题与纸张')
    shot('tablet-settings-display-first')
    q.adb('shell', 'input', 'keyevent', '4')
    ui.tap_visible('书源与账号', scroll=True)
    q.require('当前书源')
    source('文库8')
    q.restart()
    q.require('选择书源')
    shot('tablet-wenku8-guest-source-entry')
    ui.tap_visible('选择书源')
    q.require('当前书源')
    q.require('文库8镜像')
    result['homeSourceEntry'] = {'opensSourceSettingsDirectly': True}
    shot('tablet-direct-source-settings')
    save()


def login():
    q.require('当前书源')
    ui.tap_visible('登录文库8')
    q.require('欢迎来到 LiteTale')
    deadline = time.monotonic() + 75
    failed = False
    while time.monotonic() < deadline:
        root = q.tree()
        failed = bool(q.matches(root, '验证码未加载') or q.matches(root, '无法获取验证码'))
        if failed:
            break
        buttons = q.matches(root, '登录')
        if any(n.get('enabled') == 'true' for n in buttons):
            break
        time.sleep(1)
    root = q.tree()
    result['onlineCaptcha'] = {
        'errorVisible': failed,
        'siteVerificationEntryVisible': bool(q.matches(root, '打开站点验证 / 登录')),
        'loginButtonEnabled': any(n.get('enabled') == 'true' for n in q.matches(root, '登录')),
        'credentialsEntered': False,
    }
    shot('tablet-wenku8-login-captcha')
    save()


def site():
    ui.tap_visible('打开站点验证 / 登录', scroll=True)
    q.require('文库8站点验证')
    time.sleep(15)
    shot('tablet-wenku8-visible-site')
    ui.tap_visible('验证完成并返回')
    time.sleep(2)
    root = q.tree()
    result['siteVerification'] = {
        'challengeVisible': bool(q.matches(root, 'Just a moment') or q.matches(root, 'Performing security verification')),
        'adoptionRejected': bool(q.matches(root, '文库8要求站点验证')),
        'credentialsEntered': False,
    }
    shot('tablet-wenku8-adoption-result')
    save()


def restore():
    original = result.get('originalDisplay')
    if original:
        for setting, key in [('font_scale', 'fontScale'), ('user_rotation', 'rotation'),
                             ('accelerometer_rotation', 'autoRotation')]:
            q.adb('shell', 'settings', 'put', 'system', setting, original[key])
        for kind in ['size', 'density']:
            value = original[kind]
            if 'Override' in value:
                q.adb('shell', 'wm', kind, value.split('Override')[1].split(':', 1)[1].strip())
            else:
                q.adb('shell', 'wm', kind, 'reset')
    ui.more()
    ui.tap_visible('书源与账号', scroll=True)
    source('轻小说百科')
    q.restart()
    result['restored'] = {'source': 'lnovel', 'displayRestored': True}
    save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['navigation', 'login', 'site', 'restore',
                                        'delivery_search', 'delivery_catalog',
                                        'delivery_settings_and_source',
                                        'delivery_guest_source_entry'])
    args = parser.parse_args()
    globals()[args.phase]()
