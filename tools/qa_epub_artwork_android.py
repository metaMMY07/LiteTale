"""Production APK QA for two user-provided local books; keeps app/account data.

Only chosen artwork screenshots and assertion metadata are saved. No account
DOM, cookies, preferences export, or full novel text is written to reports.
"""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import time
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote
import qa_epub_css_fix_android as f

e, q, v = f.e, f.q, f.v
ROOT = Path(__file__).resolve().parents[1]
e.OUT = ROOT / 'docs/qa/epub-artwork-2026-10/android'
e.OUT.mkdir(parents=True, exist_ok=True)
e.RESULTS = json.loads((e.OUT / 'checks.json').read_text(encoding='utf-8')) if (e.OUT / 'checks.json').exists() else []
BOOKS = {
    '8': Path('C:/Users/30622/Downloads/末日时在做什么？能不能再见一面？ 08 (枯野瑛) (z-library.sk, 1lib.sk, z-lib.sk).epub'),
    '11': Path('C:/Users/30622/Downloads/末日时在做什么？能不能再见一面？.11(1).epub'),
}


def title(volume):
    with zipfile.ZipFile(BOOKS[volume]) as archive:
        root = ET.fromstring(archive.read('META-INF/container.xml'))
        opf = unquote(root.find('.//{*}rootfile').get('full-path'))
        return ET.fromstring(archive.read(opf)).find('.//{*}title').text.strip()


def wait_library(seconds=100):
    limit = time.monotonic() + seconds
    while time.monotonic() < limit:
        labels = v.labels()
        assert not any('导入失败' in label for label in labels), 'Import failed'
        if '本地书籍' in labels and not any('正在处理本地书籍' in label for label in labels):
            return
        time.sleep(.5)
    raise AssertionError('Import did not finish within its budget')


def import_book(volume):
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=1.0.0' in metadata and 'versionCode=4070' in metadata
    assert 'firstInstallTime=2026-09-27 14:47:16' in metadata
    q.adb('push', str(BOOKS[volume]), f'/sdcard/Download/title-v{volume}.epub')
    q.restart()
    e.open_library()
    e.picker(f'title-v{volume}.epub')
    wait_library()
    q.require(title(volume))
    e.mark(f'volume_{volume}_real_epub_imported',
           inputSha256=hashlib.sha256(BOOKS[volume].read_bytes()).hexdigest())


def open_book(volume):
    q.restart()
    e.open_library()
    q.tap(title(volume))
    q.require('小说详情')
    # Native TOC label in both user books, independent of current page history.
    q.tap('标题')
    time.sleep(2)
    assert '加载失败' not in v.body()
    e.screenshot(f'volume-{volume}-title-landscape')
    e.mark(f'volume_{volume}_title_opens_in_native_reader')


def portrait(volume):
    q.adb('shell', 'wm', 'size', '864x1920')
    time.sleep(2)
    assert '加载失败' not in v.body()
    e.screenshot(f'volume-{volume}-title-portrait')
    q.adb('shell', 'wm', 'size', '2560x1800')
    time.sleep(2)
    assert '加载失败' not in v.body()
    e.mark(f'volume_{volume}_designed_page_survives_rotation')


def curl(volume):
    v.settings()
    baseline = {'curl': v.switch('仿书翻页', True),
                'volume': v.switch('音量键翻页', True)}
    v.close_settings()
    baseline_file = e.OUT / 'reader-baseline.json'
    if not baseline_file.exists():
        baseline_file.write_text(json.dumps(baseline), encoding='utf-8')
    command = [q.ADB, '-s', q.DEVICE, 'shell', 'input', 'swipe',
               '2400', '1400', '650', '750', '2400']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(.95)
    e.screenshot(f'volume-{volume}-artwork-curl')
    assert process.wait(timeout=10) == 0
    time.sleep(1)
    # Adjacent illustration spreads can have identical accessibility captions.
    # Verify the actual painted pages and the exact reverse, not AX text alone.
    before = q.adb('exec-out', 'screencap', '-p', binary=True)
    v.key(25)
    time.sleep(1)
    after = q.adb('exec-out', 'screencap', '-p', binary=True)
    assert after != before, 'Volume turn did not leave artwork spread'
    v.key(24)
    time.sleep(1)
    reverse = q.adb('exec-out', 'screencap', '-p', binary=True)
    assert reverse == before, 'Reverse did not return to previous artwork spread'
    e.mark(f'volume_{volume}_artwork_participates_in_native_curl_and_volume_turns')


def restore():
    q.adb('shell', 'wm', 'size', '2560x1800')
    time.sleep(1)
    file = e.OUT / 'reader-baseline.json'
    if file.exists():
        baseline = json.loads(file.read_text(encoding='utf-8'))
        v.settings()
        v.switch('仿书翻页', baseline['curl'])
        v.switch('音量键翻页', baseline['volume'])
        v.close_settings()
    e.mark('qa_reader_switches_and_viewport_restored')


def cache(volume):
    """Read only this supplied book's private metadata/title asset on QA AVD."""
    digest = hashlib.sha256(BOOKS[volume].read_bytes()).hexdigest()
    folder = f'/data/user/0/{q.PACKAGE}/files/local_epub/{digest}'
    record = json.loads(q.adb('shell', 'cat', folder + '/book.json'))
    chapter = next(c for c in record['chapters'] if c['href'].endswith('/title.xhtml'))
    payload = json.loads(q.adb('shell', 'cat', folder + '/' + chapter['file']))
    resource = payload['document']['blocks'][0]['artwork']
    name = resource.split('/')[-1]
    assert re.fullmatch('[a-f0-9]{64}\\.png', name)
    assert any(asset['file'] == name for asset in record['assets'])
    png = q.adb('exec-out', 'cat', folder + '/' + name, binary=True)
    assert hashlib.sha256(png).hexdigest() == name.split('.')[0]
    (e.OUT / f'volume-{volume}-title-cache.png').write_bytes(png)
    summary = {'styleRevision': record['styleRevision'],
               'chapterCount': len(record['chapters']),
               'stableIds': [c['stableIndex'] for c in record['chapters']],
               'titleTextSha256': hashlib.sha256(payload['content'].encode()).hexdigest(),
               'titlePngSha256': name.split('.')[0],
               'warnings': record['warnings']}
    (e.OUT / f'volume-{volume}-cache.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    e.mark(f'volume_{volume}_title_png_is_owned_verified_local_asset',
           styleRevision=summary['styleRevision'], chapterCount=summary['chapterCount'])


def offline(volume):
    def anchor():
        # One local-book property only; never dump the preferences DB or cookies.
        digest = hashlib.sha256(BOOKS[volume].read_bytes()).hexdigest()
        path = f'/data/user/0/{q.PACKAGE}/files/database/properties.db'
        sql = "SELECT value FROM property WHERE key='epub_reader_position_v1:" + digest + "'"
        command = 'sqlite3 -readonly ' + shlex.quote(path) + ' ' + shlex.quote(sql)
        return json.loads(q.adb('shell', command))
    radio = {name: q.adb('shell', 'settings', 'get', 'global', name).strip()
             for name in ('airplane_mode_on', 'wifi_on', 'mobile_data')}
    time.sleep(1)
    before = anchor()
    try:
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
        q.adb('shell', 'svc', 'wifi', 'disable')
        q.adb('shell', 'svc', 'data', 'disable')
        time.sleep(1)
        assert 'Active default network: none' in q.adb('shell', 'dumpsys', 'connectivity')
        q.restart()
        e.open_library()
        q.tap(title(volume))
        q.require('继续阅读')
        q.tap('继续阅读')
        time.sleep(2)
        assert '加载失败' not in v.body()
        after = anchor()
        assert after == before, 'Cold resume did not retain the chapter-local anchor'
        e.screenshot(f'volume-{volume}-offline-resume')
        (e.OUT / f'volume-{volume}-offline-anchor.json').write_text(
            json.dumps({'before': before, 'after': after}, indent=2), encoding='utf-8')
        e.mark(f'volume_{volume}_offline_cold_resume_keeps_reading_anchor')
    finally:
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode',
              'enable' if radio['airplane_mode_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'wifi', 'enable' if radio['wifi_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'data', 'enable' if radio['mobile_data'] == '1' else 'disable')
        for _ in range(16):
            actual = {name: q.adb('shell', 'settings', 'get', 'global', name).strip() for name in radio}
            if actual == radio: break
            time.sleep(.5)
        assert actual == radio
        e.mark('qa_radios_restored', **radio)


def compare():
    from PIL import Image
    reference = Path('D:/Tencent Files/3062278642/nt_qq/nt_data/Pic/2026-10/Ori/41341e07eb884761a50a09bc8f2f7bf1.png')
    screen = e.OUT / 'volume-11-title-portrait.png'
    def bounds(file):
        image = Image.open(file).convert('RGB')
        assert image.size == (864, 1920)
        rows = {}
        for i, (r, g, b) in enumerate(image.getdata()):
            if 55 <= r <= 140 and 120 <= g <= 220 and 35 <= b <= 185 and g-r > 35 and g-b > 25:
                y, x = divmod(i, 864)
                rows.setdefault(y, []).append(x)
        runs = []
        for y, xs in rows.items():
            if len(xs) < 3: continue
            if not runs or y-runs[-1][-1] > 4: runs.append([])
            runs[-1].append(y)
        result = []
        for run in runs:
            if run[-1]-run[0] < 20: continue
            xs = [x for y in run for x in rows[y]]
            result.append([min(xs), run[0], max(xs), run[-1]])
        assert len(result) == 4
        return result
    expected, actual = bounds(reference), bounds(screen)
    # Same viewport; allow font outline/antialiasing differences, not lost rows.
    deltas = [a[1]-r[1] for a, r in zip(actual, expected)]
    assert all(abs(delta) <= 28 for delta in deltas), deltas
    result = {'referenceSha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
              'viewport': [864,1920], 'referenceGreenRows': expected,
              'actualGreenRows': actual, 'topDeltasPx': deltas}
    (e.OUT / 'reference-comparison.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    for volume in ('8', '11'):
        path = e.OUT / f'volume-{volume}-cache.json'
        if not path.exists(): continue
        current = json.loads(path.read_text())
        previous = json.loads((e.OUT / f'volume-{volume}-cache-before.json').read_text())
        assert current['stableIds'] == previous['stableIds']
        assert current['titleTextSha256'] == previous['titleTextSha256']
    e.mark('reference_title_rows_align_and_import_upgrade_keeps_ids_and_source_text',
           topDeltasPx=deltas)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['import', 'open', 'portrait', 'curl', 'restore', 'cache', 'offline', 'compare', 'inspect'])
    parser.add_argument('volume', choices=['8', '11'], nargs='?', default='11')
    args = parser.parse_args()
    if args.stage == 'import':
        import_book(args.volume)
    elif args.stage == 'open':
        open_book(args.volume)
    elif args.stage == 'portrait':
        portrait(args.volume)
    elif args.stage == 'curl':
        curl(args.volume)
    elif args.stage == 'restore':
        restore()
    elif args.stage == 'cache':
        cache(args.volume)
    elif args.stage == 'offline':
        offline(args.volume)
    elif args.stage == 'compare':
        compare()
    else:
        print(json.dumps(v.labels(), ensure_ascii=False))
