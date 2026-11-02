"""Installed-APK QA for the user-supplied CSS EPUB; preserves app/account data."""
import argparse
import hashlib
import json
import re
import time
from pathlib import Path
import qa_epub_css_volume_android as v

e, q = v.e, v.q
ROOT = Path(__file__).resolve().parents[1]
e.OUT = ROOT / 'docs/qa/epub-css-fix-2026-10/android'
e.OUT.mkdir(parents=True, exist_ok=True)
e.RESULTS = json.loads((e.OUT / 'checks.json').read_text(encoding='utf-8')) if (e.OUT / 'checks.json').exists() else []
TITLE = 'EPUB CSS 排版测试小书'
SAMPLE = Path('C:/Users/30622/Downloads/css_test.epub')


def reader_controls():
    width,height = map(int,re.findall(r'(\d+)x(\d+)',q.adb('shell','wm','size'))[-1])
    result = []
    for node in q.tree().iter('node'):
        if node.get('class') != 'android.widget.Button': continue
        x1,y1,x2,y2 = map(int,re.findall(r'\d+',node.get('bounds','')))
        if x1 > width*.83 and y2 < height*.3: result.append(node)
    return result


v.controls = reader_controls


def tap_exact(label, scroll=False):
    for _ in range(16 if scroll else 3):
        root = q.tree()
        nodes = [n for n in root.iter('node')
                 if label in (n.get('text', ''), n.get('content-desc', ''))]
        if nodes:
            if label in ('自动', '浅色', '深色'):
                file = e.OUT / 'reader-baseline.json'
                baseline = json.loads(file.read_text(encoding='utf-8'))
                if 'theme' not in baseline:
                    selected = [n.get('text') or n.get('content-desc') for n in root.iter('node')
                                if n.get('selected') == 'true' and
                                (n.get('text') or n.get('content-desc')) in ('自动','浅色','深色')]
                    baseline['theme'] = selected[0] if selected else None
                    file.write_text(json.dumps(baseline, ensure_ascii=False), encoding='utf-8')
            q.tap_node(nodes[0])
            return
        if scroll:
            q.swipe()
    raise AssertionError('Exact label missing: ' + label)


def open_sample(chapter='封面'):
    q.restart()
    e.open_library()
    q.tap(TITLE)
    q.require('小说详情')
    q.tap(chapter)
    time.sleep(1.5)


def import_sample():
    package = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=1.0.0' in package and 'versionCode=4069' in package
    assert 'firstInstallTime=2026-09-27 14:47:16' in package
    q.adb('push', str(SAMPLE), '/sdcard/Download/css_test.epub')
    q.restart()
    e.open_library()
    e.picker('css_test.epub')
    q.require(TITLE)
    e.screenshot('01-user-epub-imported')
    q.tap(TITLE)
    for label in ('封面', '第一章：基本排版', '第二章：列表与表格', '第三章：分页与样式覆盖'):
        q.require(label)
    e.mark('actual_user_epub_imports_with_four_spine_entries',
           sampleSha256=hashlib.sha256(SAMPLE.read_bytes()).hexdigest())
    q.tap('封面')
    time.sleep(2)
    e.screenshot('02-first-book-spread-native-curl')


def plain_turns():
    v.settings()
    baseline = {'curl': v.switch('仿书翻页', False), 'volume': v.switch('音量键翻页', True)}
    file = e.OUT / 'reader-baseline.json'
    if not file.exists():
        file.write_text(json.dumps(baseline), encoding='utf-8')
    v.close_settings()
    # Return through the book's pages without reopening the reader at boundaries.
    for _ in range(12):
        v.key(24)
    views, previous = [], None
    for i in range(16):
        text = v.body()
        digest = hashlib.sha256(text.encode()).hexdigest()
        if digest == previous:
            break
        assert '下一章' not in text and '加载中' not in text and '加载失败' not in text
        views.append(text)
        e.screenshot(f'03-plain-spread-{i:02d}')
        previous = digest
        q.adb('shell', 'input', 'tap', '2350', '900')
        time.sleep(.55)
    combined = '\n'.join(views)
    for marker in ('基本排版', '列表与表格', '分页与样式覆盖', '提示卡片'):
        assert marker in combined, (marker, combined)
    e.mark('tap_turns_cross_all_local_sections_without_next_chapter_controls', spreads=len(views))
    assert len(views) >= 3
    last = v.fingerprint()
    v.key(24)
    assert v.fingerprint() != last
    v.key(25)
    assert v.fingerprint() == last
    e.mark('volume_keys_cross_local_sections_and_reverse_to_same_content')


def theme(label):
    v.settings()
    tap_exact(label, scroll=True)
    v.close_settings()
    time.sleep(1)


def rotation_offline():
    v.settings()
    v.switch('仿书翻页', False)
    v.close_settings()
    anchors = ('提示\t黄色底色', '表格\t边框及交替底色')
    assert all(anchor in v.body() for anchor in anchors)
    q.adb('shell', 'wm', 'size', '1200x1920')
    time.sleep(2)
    assert all(anchor in v.body() for anchor in anchors)
    e.screenshot('09-portrait-styled-anchor')
    q.adb('shell', 'wm', 'size', '2560x1800')
    time.sleep(2)
    assert all(anchor in v.body() for anchor in anchors)
    e.screenshot('10-landscape-anchor-restored')
    e.mark('portrait_landscape_reflow_keeps_saved_table_text_visible',
           scope='wm resize may change system insets and page cuts; assert content anchor, not identical page text')
    radio = {name: q.adb('shell','settings','get','global',name).strip()
             for name in ('airplane_mode_on','wifi_on','mobile_data')}
    (e.OUT / 'radio-baseline.json').write_text(json.dumps(radio), encoding='utf-8')
    try:
        q.adb('shell','cmd','connectivity','airplane-mode','enable')
        q.adb('shell','svc','wifi','disable')
        q.adb('shell','svc','data','disable')
        time.sleep(1)
        assert 'Active default network: none' in q.adb('shell','dumpsys','connectivity')
        q.restart()
        e.open_library()
        q.tap(TITLE)
        q.require('继续阅读 - 第二章：列表与表格')
        q.tap('继续阅读')
        time.sleep(1)
        assert all(anchor in v.body() for anchor in anchors)
        e.screenshot('11-offline-reopen-same-reading-position')
        e.mark('offline_process_restart_resumes_saved_chapter_and_table_text_anchor')
    finally:
        q.adb('shell','wm','size','2560x1800')
        q.adb('shell','cmd','connectivity','airplane-mode',
              'enable' if radio['airplane_mode_on']=='1' else 'disable')
        q.adb('shell','svc','wifi','enable' if radio['wifi_on']=='1' else 'disable')
        q.adb('shell','svc','data','enable' if radio['mobile_data']=='1' else 'disable')
        for _ in range(16):
            actual = {name:q.adb('shell','settings','get','global',name).strip() for name in radio}
            if actual==radio: break
            time.sleep(.5)
        assert actual==radio
        e.mark('qa_radios_restored_after_offline_check')


def restore():
    q.adb('shell', 'wm', 'size', '2560x1800')
    time.sleep(1)
    v.settings()
    baseline = json.loads((e.OUT / 'reader-baseline.json').read_text(encoding='utf-8'))
    v.switch('仿书翻页', baseline['curl'])
    v.switch('音量键翻页', baseline['volume'])
    tap_exact(baseline.get('theme') or '自动', scroll=True)
    v.close_settings()
    e.mark('qa_volume_curl_switches_and_viewport_restored',
           readerTheme=baseline.get('theme') or '自动')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('stage', choices=['import','open','turns','light','dark','offline','restore','inspect'])
    args = p.parse_args()
    if args.stage == 'import': import_sample()
    elif args.stage == 'open': open_sample()
    elif args.stage == 'turns': plain_turns()
    elif args.stage == 'light': theme('浅色')
    elif args.stage == 'dark': theme('深色')
    elif args.stage == 'offline': rotation_offline()
    elif args.stage == 'restore': restore()
    else: print('\n'.join(v.labels()))
