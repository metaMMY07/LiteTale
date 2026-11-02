"""Check the installed optimization release without clearing user data.

Only public source/settings/reader screenshots and bounded results are saved.
No account forms, storage, cookies, tokens or network payloads are exported.
"""
import argparse
import base64
import json
import re
import time
from pathlib import Path

import qa_settings_android as q
import qa_source_reading_android as reading
import qa_api_stability_android as stability


def screenshot(out, name):
    time.sleep(1)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f'{name}.png'
    path.write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    print(str(path), flush=True)


def visible(label):
    return bool(q.matches(q.tree(), label))


def wait(label, seconds=45):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if visible(label):
            return
        time.sleep(.5)
    raise AssertionError(f'Public page did not show {label} within deadline')


def restart_home():
    q.restart()
    wait('我的')


def source(label):
    restart_home()
    # select_source already returns to discovery; a second Back exits Android.
    stability.select_source(label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['sources', 'import-file', 'import-link', 'import-retained', 'read-classic', 'read-sf', 'restore'])
    parser.add_argument('--code', type=int, default=4055)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] / 'docs/qa/optimization-2026-10/device')
    args = parser.parse_args()
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.18' in metadata and f'versionCode={args.code}' in metadata
    report = {'action': args.action, 'version': '0.1.18', 'versionCode': args.code, 'dataCleared': False,
              'credentialsRecorded': False, 'visualReview': 'pending', 'performanceMeasured': False}
    if args.action == 'sources':
        restart_home()
        reading.tap_destination('我的')
        q.tap('书源与账号', scroll=True)
        q.require('当前书源')
        q.require('添加与管理书源')
        screenshot(args.out, 'source-management')
        report['sourceManagerVisible'] = True
    elif args.action == 'import-file':
        restart_home()
        reading.tap_destination('我的')
        q.tap('书源与账号', scroll=True)
        q.tap('本地文件', scroll=True)
        # Only our explicitly named public JSON fixture is selected.
        if not visible('LiteTale-SF-example.json'):
            if visible('Downloads'):
                q.tap('Downloads')
            elif visible('下载'):
                q.tap('下载')
        q.tap('LiteTale-SF-example.json', scroll=True)
        q.require('确认导入书源')
        q.require('SF轻小说（导入示例）')
        screenshot(args.out, 'import-preview')
        q.tap('导入所选书源', scroll=True)
        q.require('当前书源')
        restart_home()
        reading.tap_destination('我的')
        q.tap('书源与账号', scroll=True)
        q.tap('SF轻小说（导入示例）', scroll=True)
        q.require('当前书源')
        screenshot(args.out, 'import-persisted-selected')
        report['fileImportAndRestartPassed'] = True
    elif args.action == 'import-link':
        # A public echo endpoint returns our non-sensitive JSON over real TLS.
        # This checks HTTPS download/UI integration without publishing a file.
        fixture_path = Path(__file__).resolve().parents[1] / 'docs/book_sources/SF-lightnovel-example.json'
        fixture = json.loads(fixture_path.read_text(encoding='utf-8-sig'))
        fixture['source']['id'] = 'sfacg_https_import_example'
        fixture['source']['name'] = 'SF轻小说（链接示例）'
        raw = json.dumps(fixture, ensure_ascii=False, separators=(',', ':')).encode()
        url = 'https://httpbingo.org/base64/' + base64.b64encode(raw).decode()
        restart_home()
        reading.tap_destination('我的')
        q.tap('书源与账号', scroll=True)
        q.tap('链接导入', scroll=True)
        fields = [n for n in q.tree().iter('node') if n.get('class') == 'android.widget.EditText']
        assert len(fields) == 1
        # The field autofocuses. Retapping old bounds while the keyboard opens
        # can hit the modal barrier after Android resizes the dialog.
        q.require('确定')
        # Long input bursts can lose key events on the software emulator.
        for offset in range(0, len(url), 80):
            q.adb('shell', 'input', 'text', url[offset:offset + 80])
            time.sleep(.08)
        typed = [n.get('text', '') for n in q.tree().iter('node') if n.get('class') == 'android.widget.EditText']
        report['typedUrlMatchesFixture'] = typed == [url]
        assert len(typed) == 1 and typed[0] == url, 'URL input differs from the public fixture'
        q.tap('确定')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            root = q.tree()
            if q.matches(root, '确认导入书源'):
                break
            errors = [n.get('text') or n.get('content-desc', '') for n in root.iter('node')
                      if any(term in (n.get('text', '') + n.get('content-desc', ''))
                             for term in ('书源下载失败', 'FormatException', 'TimeoutException', 'HandshakeException'))]
            if errors:
                print(json.dumps({'httpsDownloadError': errors}, ensure_ascii=False), flush=True)
                raise AssertionError('HTTPS import reached a download error')
            time.sleep(.5)
        else:
            raise AssertionError('HTTPS import did not show a preview')
        q.require('SF轻小说（链接示例）')
        screenshot(args.out, 'link-import-preview')
        q.tap('导入所选书源', scroll=True)
        q.require('当前书源')
        restart_home()
        reading.tap_destination('我的')
        q.tap('书源与账号', scroll=True)
        q.tap('SF轻小说（链接示例）', scroll=True)
        q.require('当前书源')
        screenshot(args.out, 'link-import-persisted-selected')
        report.update(httpsImportAndRestartPassed=True, remoteFixtureHost='httpbingo.org')
    elif args.action == 'import-retained':
        restart_home()
        for label, prefix in [('SF轻小说（导入示例）', 'file'), ('SF轻小说（链接示例）', 'link')]:
            stability.select_source(label)
            wait(label)
            restart_home()
            wait(label)
            screenshot(args.out, f'{prefix}-source-after-upgrade')
        report.update(importSourcesRetainedAfterUpgrade=True, selectedSourceSurvivesRestart=True)
    elif args.action.startswith('read-'):
        classic = args.action == 'read-classic'
        label = '读书之家（古典作品）' if classic else 'SF轻小说（公开目录）'
        source(label)
        wait('红楼梦' if classic else 'SF轻小说（公开目录）')
        screenshot(args.out, 'classic-discovery' if classic else 'sf-discovery')
        if classic:
            q.tap('红楼梦')
        else:
            cards = stability.cards(q.tree())
            assert cards, 'No public SF cards'
            q.tap_node(cards[0])
        q.require('小说详情')
        wait('目录')
        screenshot(args.out, 'classic-detail' if classic else 'sf-detail')
        # This reader opens chapters from directory rows, not a start button.
        width, height = reading.viewport()
        chapters = []
        for _ in range(5):
            for node in q.tree().iter('node'):
                bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
                label_text = node.get('text') or node.get('content-desc', '')
                if len(bounds) == 4:
                    x1, y1, x2, y2 = bounds
                    if (node.get('clickable') == 'true' and label_text and
                            x2-x1 > width*.6 and 40 < y2-y1 < height*.13 and
                            y1 > height*.2 and y2 < height*.94):
                        chapters.append(node)
            if chapters:
                break
            q.swipe()
        assert chapters, 'No selectable chapter row'
        q.tap_node(chapters[0])
        time.sleep(5)
        reading.reading_check(args.out, 'classic-reader' if classic else 'sf-reader', version='0.1.18', code=args.code)
        report['readingInteractionsExecuted'] = True
    else:
        source('文库8')
        report['restoredWenku8'] = True
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / f'{args.action}-result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
