"""Data-preserving checks of the installed API stability release.

Only screenshots of public reading/search/error pages and bounded booleans are
saved. Never exports account DOM, credentials, cookies, or raw network logs.
Does not install, clear data, change accounts, or submit a login form.
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

import qa_settings_android as q
import qa_source_reading_android as reading


def wait_for(label, timeout=65):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        root = q.tree()
        if q.matches(root, label):
            return root, round(time.monotonic() - started, 2)
        if any(q.matches(root, error) for error in
               ('搜索未完成', '加载失败:', '重试首页', '重新加载分类书目')):
            raise AssertionError('Read request reached an error state')
        time.sleep(.5)
    raise AssertionError('Read request did not settle within the QA deadline')


def dimensions():
    return tuple(map(int, re.findall(r'(\d+)x(\d+)', q.adb('shell', 'wm', 'size'))[-1]))


def cards(root):
    _, height = dimensions()
    found = []
    for node in root.iter('node'):
        bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
        if len(bounds) != 4:
            continue
        x1, y1, x2, y2 = bounds
        if (node.get('clickable') == 'true' and y1 > 190 and y2 < height*.94
                and x2-x1 > 150 and 160 < y2-y1 < height*.7
                and node.get('class') != 'android.widget.EditText'):
            label = node.get('text') or node.get('content-desc', '')
            if label:
                found.append(node)
    return found


def select_source(label):
    reading.tap_destination('我的')
    q.tap('书源与账号', scroll=True)
    fields = [n for n in q.tree().iter('node') if
              '当前书源' in (n.get('text', '')+'\n'+n.get('content-desc', '')).splitlines()]
    assert fields, 'Missing source field'
    def area(node):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
        return (x2-x1)*(y2-y1)
    field = min(fields, key=area)
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', field.get('bounds', '')))
    q.adb('shell', 'input', 'tap', str(round(x2-(x2-x1)*.053)), str((y1+y2)//2))
    q.tap(label)
    q.require('当前书源')
    retained = bool(q.matches(q.tree(), '已保存登录'))
    q.adb('shell', 'input', 'keyevent', '4')
    reading.tap_destination('发现')
    return retained


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['search', 'category', 'detail', 'shelf', 'restore'])
    parser.add_argument('--version', default='0.1.17')
    parser.add_argument('--code', type=int, default=4052)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert f'versionName={args.version}' in metadata and f'versionCode={args.code}' in metadata
    args.out.mkdir(parents=True, exist_ok=True)
    report = {'version': args.version, 'phase': args.phase, 'newLoginSubmitted': False,
              'credentialsExported': False, 'visualReview': 'pending root review'}

    def shot(name):
        path = args.out / f'{args.phase}-{name}.png'
        path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))

    try:
        if args.phase == 'search':
            q.restart()
            wait_for('新书风云榜')
            shot('home')
            q.tap('搜索书名、作者')
            fields = [n for n in q.tree().iter('node') if n.get('class') == 'android.widget.EditText']
            assert len(fields) == 1
            q.tap_node(fields[0])
            q.adb('shell', 'input', 'text', 'Re')
            q.adb('shell', 'input', 'keyevent', '66')
            _, seconds = wait_for('志乃与恋 Future')
            report.update(titleSearch=True, firstResultSeconds=seconds)
            shot('results')
            seen = {n.get('text') or n.get('content-desc', '') for n in cards(q.tree())}
            for _ in range(5):
                q.swipe()
                time.sleep(3)
                seen.update(n.get('text') or n.get('content-desc', '') for n in cards(q.tree()))
            root = q.tree()
            report['paginationError'] = bool(q.matches(root, '加载失败'))
            report['cardsAfterScrolling'] = len(cards(root))
            report['distinctCardsAcrossPages'] = len(seen)
            shot('pagination')
            assert not report['paginationError'] and len(seen) > 20
        elif args.phase == 'category':
            q.restart()
            wait_for('新书风云榜')
            q.tap('分类')
            _, seconds = wait_for('更新')
            report['categorySeconds'] = seconds
            # Flutter merges the selected tag label into the entire category
            # body. Its accessibility rectangle is not the dropdown button.
            # Locate the controls row through its sort radio button instead.
            controls = [n for n in q.tree().iter('node')
                        if n.get('class') == 'android.widget.RadioButton'
                        and n.get('content-desc') == '更新']
            assert len(controls) == 1
            _, y1, _, y2 = map(int, re.findall(r'\d+', controls[0].get('bounds', '')))
            width, _ = dimensions()
            q.adb('shell', 'input', 'tap', str(round(width*.955)), str((y1+y2)//2))
            # Pick a visible category; the menu also contains off-screen tags.
            wait_for('恋爱')
            shot('picker')
            q.tap('恋爱')
            time.sleep(10)
            root = q.tree()
            report['selectedTag'] = '恋爱'
            report['cards'] = len(cards(root))
            report['error'] = bool(q.matches(root, '加载失败'))
            shot('books')
            assert report['cards'] > 2 and not report['error']
        elif args.phase == 'detail':
            q.restart()
            wait_for('新书风云榜')
            q.tap('魔法少女育成计划', scroll=True)
            _, seconds = wait_for('人物简介')
            report['detailSeconds'] = seconds
            shot('loaded')
            q.tap('作者：远藤浅蜊')
            _, seconds = wait_for('魔法少女育成计划')
            report.update(authorSearch=True, authorSearchSeconds=seconds)
            shot('author-search')
            q.adb('shell', 'input', 'keyevent', '4')
            wait_for('人物简介')
            q.tap('序章')
            time.sleep(8)
            report['readerError'] = bool(q.matches(q.tree(), '加载失败'))
            shot('reader')
            assert not report['readerError']
        elif args.phase == 'shelf':
            report['shelfLoginMarkerBefore'] = select_source('轻书架')
            root, seconds = wait_for('重试首页', timeout=70)
            report.update(errorSettledSeconds=seconds,
                          service502=bool(q.matches(root, 'HTTP 502')),
                          misleadingSignIn=bool(q.matches(root, '登录已失效')))
            shot('service-error')
            report['shelfLoginMarkerAfter'] = select_source('轻书架')
            report['wenku8LoginMarker'] = select_source('文库8')
            wait_for('新书风云榜')
            shot('returned-wenku8')
            assert not report['misleadingSignIn']
            assert report['shelfLoginMarkerBefore'] == report['shelfLoginMarkerAfter']
        elif args.phase == 'restore':
            report['wenku8LoginMarker'] = select_source('文库8')
            q.restart()
            wait_for('新书风云榜')
            report['homeAfterRestart'] = True
            shot('home')
        report['passed'] = True
    except Exception as error:
        # Do not serialize arbitrary platform exceptions or account state.
        report.update(passed=False, failure=type(error).__name__)
        if args.phase not in ('shelf', 'restore'):
            shot('failed')
        raise
    finally:
        (args.out / f'{args.phase}-checks.json').write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
