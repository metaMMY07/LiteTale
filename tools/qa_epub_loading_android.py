"""Data-preserving local EPUB checks on the explicitly selected x64 AVD.

Native timings/call counts are separate from UI automation wall time. No
accounts, cookies, databases or full chapter prose are exported.
"""
import hashlib
import json
import re
import sys
import time
from pathlib import Path

import qa_epub_engine_android as engine

e, q, v = engine.e, engine.q, engine.v
ROOT = Path(__file__).resolve().parents[1]
e.OUT = ROOT / 'docs/qa/epub-loading-fix4-2026-10/android'
e.OUT.mkdir(parents=True, exist_ok=True)
e.RESULTS = json.loads((e.OUT / 'checks.json').read_text(encoding='utf-8')) if (e.OUT / 'checks.json').exists() else []
_mark = e.mark
_apk_sha = hashlib.sha256((ROOT / 'build/app/outputs/flutter-apk/app-x86_64-release.apk').read_bytes()).hexdigest()


def mark_current(name, **details):
    details.setdefault('installedApkSha256', _apk_sha)
    _mark(name, **details)


e.mark = mark_current


def assert_css_reader():
    # Valid title/tail pages may have fewer than 30 characters. Do not confuse
    # them with a still-loading route just because the body is short.
    deadline = time.monotonic() + 45
    routes = {'小说详情', '本地书籍', '发现', '书架', '字体设置', '阅读器类型'}
    loading = {'加载中', '加载中…', '加载中...', '正在排版', '正在加载'}
    while time.monotonic() < deadline:
        labels = v.labels()
        assert not any(any(word in x for word in ('排版失败', '排版超时', '加载失败', '页面加载失败', '无法排版')) for x in labels), labels[:3]
        if labels and not routes.intersection(labels) and any(x.strip() and x not in loading for x in labels):
            time.sleep(.5)
            return
        time.sleep(.5)
    raise AssertionError('CSS reader did not expose its visible page semantics')


engine.assert_reader = assert_css_reader


def events():
    raw = q.adb('logcat', '-d', '-s', 'LiteTaleEpub:D', '*:S')
    return [dict(operation=m[0], ms=int(m[1]), pool=int(m[2]))
            for m in re.findall(r'(prepare|capture) ms=(\d+) pool=(\d+)', raw)]


def capture_phases():
    raw = q.adb('logcat', '-d', '-s', 'LiteTaleEpub:D', '*:S')
    return [dict(drawMs=int(m[0]), encodeMs=int(m[1]), bytes=int(m[2]), format=m[3])
            for m in re.findall(r'capture-detail drawMs=(\d+) encodeMs=(\d+) bytes=(\d+) format=(\w+)', raw)]


def back_to_details():
    for _ in range(2):
        q.adb('shell', 'input', 'keyevent', '4')
        time.sleep(.35)
        if '小说详情' in v.labels():
            return
    q.require('小说详情')


def native_delta(start):
    return events()[start:]


def main():
    assert q.DEVICE == 'emulator-5554', 'This tool is limited to the QA emulator'
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionCode=4072' in metadata and 'versionName=1.0.0' in metadata
    installed = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().split(':', 1)[1]
    installed_sha = q.adb('shell', 'sha256sum', installed).split()[0]
    expected = ROOT / 'build/app/outputs/flutter-apk/app-x86_64-release.apk'
    assert installed_sha == hashlib.sha256(expected.read_bytes()).hexdigest()
    old_log = q.adb('shell', 'getprop', 'log.tag.LiteTaleEpub').strip()
    q.adb('shell', 'setprop', 'log.tag.LiteTaleEpub', 'DEBUG')
    report = dict(installedApkSha256=installed_sha, versionCode=4072,
                  scope='API35 x64 AVD; native RPC durations are not first frame latency', cases=[])
    try:
        for bi, chapter in [(0, '封面'), (1, '第一章'), (2, '标题'), (3, '标题'), (4, '第一章')]:
            q.restart()
            e.open_library()
            q.tap(engine.title(bi))
            q.require('小说详情')
            before = len(events())
            before_capture = len(capture_phases())
            q.tap(chapter, scroll=True)
            engine.assert_reader()
            time.sleep(2)
            cold = native_delta(before)
            phases = capture_phases()[before_capture:]
            assert any(x['operation'] == 'prepare' for x in cold), 'Native timing diagnostics did not observe the cold preparation'
            e.screenshot(f'book-{bi}-prepared')
            body_digest = hashlib.sha256(v.body().encode()).hexdigest()
            back_to_details()
            before = len(events())
            q.tap(chapter, scroll=True)
            engine.assert_reader()
            time.sleep(2)
            hot = native_delta(before)
            assert hashlib.sha256(v.body().encode()).hexdigest() == body_digest, 'Reopen changed visible anchor'
            assert not any(x['operation'] == 'prepare' for x in hot), hot
            assert all(x['pool'] <= 3 for x in cold + hot)
            e.screenshot(f'book-{bi}-reused')
            report['cases'].append(dict(book=bi, cold=cold, hot=hot, coldCapturePhases=phases, visibleAnchorUnchanged=True))
            print(json.dumps(dict(book=bi, coldCalls=len(cold), hotCalls=len(hot)), ensure_ascii=False), flush=True)
            e.mark(f'book_{bi}_reuses_layout_without_prepare', cold=cold, hot=hot)
        # Leave the last reader and confirm its three bounded native views are
        # released after the grace period. This is not a claim about total PSS.
        release_pattern = r'release pool=[1-3]'
        before_idle = len(re.findall(release_pattern, q.adb('logcat', '-d', '-s', 'LiteTaleEpub:D', '*:S')))
        back_to_details()
        time.sleep(48)
        raw = q.adb('logcat', '-d', '-s', 'LiteTaleEpub:D', '*:S')
        assert len(re.findall(release_pattern, raw)) > before_idle, 'Idle native pool did not release'
        report['idleNativePoolReleased'] = True
        e.mark('idle_native_pool_released_after_grace_period')
    finally:
        q.adb('shell', 'setprop', 'log.tag.LiteTaleEpub', old_log or "''")
        report['diagnosticPropertyRestored'] = q.adb('shell', 'getprop', 'log.tag.LiteTaleEpub').strip() == old_log
        (e.OUT / 'latency-checks.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


def regression():
    assert q.DEVICE == 'emulator-5554'
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionCode=4072' in metadata
    assert 'firstInstallTime=2026-09-27 14:47:16' in metadata
    installed = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().split(':', 1)[1]
    assert q.adb('shell', 'sha256sum', installed).split()[0] == _apk_sha
    try:
        engine.open_book(4, '第一章')
        engine.turns(4)
        engine.rotate(4)
    finally:
        # The older gear locator uses landscape coordinates; restore them even
        # if a portrait assertion failed, before trying to restore preferences.
        q.adb('shell', 'wm', 'size', '2560x1800')
        time.sleep(3)
        engine.restore()
    try:
        engine.reader_font()
        engine.open_book(1, '第一章')
        e.screenshot('reader-custom-font')
        e.mark('custom_font_remains_readable_after_cached_layout')
    finally:
        if (e.OUT / 'font-baseline.json').exists():
            engine.reader_font(reset=True)
    engine.open_book(1, '第一章')
    e.screenshot('reader-default-font-restored')
    e.mark('default_font_restored_without_stale_custom_glyphs')
    back_to_details()
    e.mark('regression_complete_preserving_installation_and_reader_preferences')


def encoding():
    assert q.DEVICE == 'emulator-5554'
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionCode=4072' in metadata
    installed = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().split(':', 1)[1]
    assert q.adb('shell', 'sha256sum', installed).split()[0] == _apk_sha
    tags = ['log.tag.LiteTaleEpub', 'log.tag.LiteTaleEpubPixels']
    original = {tag: q.adb('shell', 'getprop', tag).strip() for tag in tags}
    pattern = r'capture-verify identical=(true|false) format=(\w+) encodeMs=(\d+) bytes=(\d+) pngMs=(\d+) pngBytes=(\d+) sameBitmap=(true|false) sourceAlpha=(true|false) decodedAlpha=(true|false|null)'

    def samples():
        return re.findall(pattern, q.adb('logcat', '-d', '-s', 'LiteTaleEpub:D', '*:S'))

    report = dict(installedApkSha256=_apk_sha, scope='Same source bitmap: native lossless decode pixel equality and encoder-only timings', cases=[])
    try:
        for tag in tags:
            q.adb('shell', 'setprop', tag, 'DEBUG')
        for bi, chapter in [(0, '封面'), (4, '第一章')]:
            before = len(samples())
            engine.open_book(bi, chapter)
            time.sleep(3)
            observed = samples()[before:]
            assert observed and all(x[0] == 'true' and x[1] == 'WEBP_LOSSLESS' for x in observed), observed
            case = dict(book=bi, captures=[dict(identical=x[0] == 'true', format=x[1], encodeMs=int(x[2]), bytes=int(x[3]), pngMs=int(x[4]), pngBytes=int(x[5]), bitmapStorageIdentical=x[6] == 'true', sourceHasAlpha=x[7] == 'true', decodedHasAlpha=x[8] == 'true') for x in observed])
            report['cases'].append(case)
            e.mark(f'book_{bi}_lossless_capture_pixels_identical', captures=case['captures'])
    finally:
        for tag, value in original.items():
            q.adb('shell', 'setprop', tag, value or "''")
        report['diagnosticPropertiesRestored'] = all(q.adb('shell', 'getprop', tag).strip() == value for tag, value in original.items())
        (e.OUT / 'encoding-checks.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    if '--encoding' in sys.argv:
        encoding()
    elif '--regression' in sys.argv:
        regression()
    else:
        main()
