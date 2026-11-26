"""Release-APK checks using only the self-authored CSS EPUB on the QA AVD.

Preserves application data. Each stage records assertions and PNGs, never
account DOM, cookies or a full preferences/database export.
"""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

import qa_local_epub_android as e

q = e.q
ROOT = Path(__file__).resolve().parents[1]
e.OUT = ROOT / 'docs/qa/epub-css-volume-2026-10/android'
e.OUT.mkdir(parents=True, exist_ok=True)
if (e.OUT / 'checks.json').exists():
    e.RESULTS = json.loads((e.OUT / 'checks.json').read_text(encoding='utf-8'))


def labels():
    return [n.get('text') or n.get('content-desc') for n in q.tree().iter('node')
            if n.get('text') or n.get('content-desc')]


def body():
    values = labels()
    assert not any('加载失败' in v for v in values), values
    return '\n'.join(values)


def fingerprint():
    return hashlib.sha256(body().encode()).hexdigest()


def volume():
    result = q.adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--get')
    return int(re.search(r'volume is (\d+)', result).group(1))


def restore_volume(value=5):
    q.adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--set', str(value))


def key(code, long=False):
    args = ['shell', 'input', 'keyevent']
    if long:
        args.append('--longpress')
    q.adb(*args, str(code))
    time.sleep(.7)


def controls():
    result = []
    for node in q.tree().iter('node'):
        if node.get('class') != 'android.widget.Button':
            continue
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
        if x1 > 2200 and y2 < 190:
            result.append(node)
    return result


def settings():
    if q.matches(q.tree(), '阅读器类型'):
        return
    buttons = controls()
    if not buttons:
        # Offset from the exact book spine; native curl geometry excludes it.
        q.adb('shell', 'input', 'tap', '1550', '900')
        time.sleep(.4)
        buttons = controls()
    assert buttons, 'Reader gear button missing'
    # Scroll app bar: play, gear, catalog. Paged overlay: catalog, gear.
    q.tap_node(buttons[-2] if len(buttons) >= 3 else buttons[-1])
    q.require('阅读器类型')


def switch(label, enabled):
    nodes = q.matches(q.tree(), label)
    checked = [n for node in nodes for n in node.iter('node')
               if n.get('checkable') == 'true']
    if not checked:
        raise AssertionError(f'Cannot read switch state: {label}')
    before = checked[0].get('checked') == 'true'
    if before != enabled:
        q.tap_node(checked[0])
    after = [n for node in q.matches(q.tree(), label) for n in node.iter('node')
             if n.get('checkable') == 'true']
    assert after and (after[0].get('checked') == 'true') == enabled
    return before


def close_settings():
    key(4)
    # The reader controls behind the modal remain open.
    if len(controls()) == 2:
        q.adb('shell', 'input', 'tap', '1550', '900')
        time.sleep(.4)


def import_fixture():
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=1.0.0' in metadata and 'versionCode=4068' in metadata
    assert 'firstInstallTime=2026-09-27 14:47:16' in metadata
    fixture = ROOT / 'build/epub-css-volume/原书样式与音量键.epub'
    q.adb('push', str(fixture), '/sdcard/Download/' + fixture.name)
    q.restart()
    e.open_library()
    q.require('旧版导入的书籍')
    e.screenshot('01-legacy-library-after-upgrade-install')
    e.mark('version_1_0_0_preserves_install_and_legacy_books')
    e.picker(fixture.name)
    q.require('原书样式验收')
    e.screenshot('02-css-epub-imported')
    e.mark('system_picker_imports_css_epub_with_chinese_import_paths')
    q.tap('原书样式验收')
    q.tap('第一章·样式展示')
    time.sleep(2)
    e.screenshot('03-original-styles-native-curl')
    e.mark('css_epub_opens_existing_native_reader')


def keys():
    settings()
    original = {'volumeEnabled': switch('音量键翻页', True),
                'curlEnabled': switch('仿书翻页', False), 'musicVolume': volume()}
    baseline = e.OUT / 'reader-baseline.json'
    if not baseline.exists():
        baseline.write_text(json.dumps(original), encoding='utf-8')
    e.screenshot('04-reader-volume-switch')
    close_settings()
    first = body()
    assert '第一章·样式展示' in first and 'HIDDEN_CSS_MUST_NOT_APPEAR' not in first
    e.screenshot('05-styled-first-spread')
    before = fingerprint()
    music = volume()
    key(25)
    following = fingerprint()
    assert before != following and volume() == music
    e.screenshot('06-volume-next-spread')
    key(24)
    assert fingerprint() == before and volume() == music
    key(25, long=True)
    assert fingerprint() == following and volume() == music
    e.mark('volume_down_up_and_long_press_turn_exactly_one_spread_without_volume_change')
    settings()
    music = volume()
    key(25)
    audio_index_changed = volume() != music
    restore_volume(music)
    close_settings()
    assert fingerprint() == following
    e.mark('modal_does_not_turn_hidden_reader',
           musicIndexChanged=audio_index_changed,
           limitation='AVD injected volume keys also leave stream indices unchanged at Home; platform listen/cancel covered by widget tests')


def reopen():
    q.restart()
    e.open_library()
    q.tap('原书样式验收')
    q.tap('第一章·样式展示')
    time.sleep(2)
    e.screenshot('03-original-styles-native-curl')
    e.mark('final_apk_reopens_imported_css_document_after_process_restart')


def capture_curl():
    settings()
    switch('仿书翻页', True)
    close_settings()
    gesture = subprocess.Popen([q.ADB, '-s', q.DEVICE, 'shell', 'input', 'swipe',
                                '2400', '1400', '700', '950', '2200'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(.85)
    e.screenshot('07-styled-curl-in-motion')
    _, err = gesture.communicate(timeout=10)
    assert gesture.returncode == 0, err.decode(errors='replace')
    time.sleep(1)
    e.screenshot('08-styled-curl-settled')
    e.mark('original_css_raster_is_used_by_native_curl_capture',
           scope='Capture requires visual review; no physical-device frame-rate claim')


def offline_rotation():
    from qa_epub_reader_android import illustration_pixels
    radio = {name: q.adb('shell', 'settings', 'get', 'global', name).strip()
             for name in ('airplane_mode_on', 'wifi_on', 'mobile_data')}
    (e.OUT / 'radio-baseline.json').write_text(json.dumps(radio), encoding='utf-8')
    try:
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
        q.adb('shell', 'svc', 'wifi', 'disable')
        q.adb('shell', 'svc', 'data', 'disable')
        assert 'Active default network: none' in q.adb('shell', 'dumpsys', 'connectivity')
        reopen()
        for _ in range(10):
            key(24)
        e.screenshot('13-offline-css-spread')
        e.mark('offline_cold_start_preserves_css_and_volume_preference')
        q.adb('shell', 'wm', 'size', '1200x1920')
        time.sleep(2)
        before = illustration_pixels('14-portrait-original-css')
        key(25)
        after = illustration_pixels('15-portrait-illustration-volume-next')
        assert before < 2000 and after > 10000, (before, after)
        q.adb('shell', 'wm', 'size', '2560x1800')
        time.sleep(3)
        assert illustration_pixels('16-landscape-illustration-anchor') > 10000
        e.mark('portrait_volume_turn_and_rotation_restore_rich_image_anchor')
    finally:
        q.adb('shell', 'wm', 'size', '2560x1800')
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode',
              'enable' if radio['airplane_mode_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'wifi', 'enable' if radio['wifi_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'data', 'enable' if radio['mobile_data'] == '1' else 'disable')
        for _ in range(16):
            restored = {name: q.adb('shell', 'settings', 'get', 'global', name).strip()
                        for name in radio}
            if restored == radio:
                break
            time.sleep(.5)
        assert restored == radio
        e.mark('avd_radios_and_landscape_viewport_restored')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['import', 'reopen', 'keys', 'curl', 'offline', 'inspect'])
    args = parser.parse_args()
    if args.stage == 'import':
        import_fixture()
    elif args.stage == 'reopen':
        reopen()
    elif args.stage == 'keys':
        keys()
    elif args.stage == 'curl':
        capture_curl()
    elif args.stage == 'offline':
        offline_rotation()
    else:
        print('\n'.join(labels()))
