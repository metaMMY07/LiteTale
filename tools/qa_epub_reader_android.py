"""Offline/curl/rotation checks for the already imported self-authored EPUB2.

Run after qa_local_epub_android.py on emulator-5554. Does not clear app data;
restores the AVD radios and viewport even when a check fails.
"""
import json
import subprocess
import time
from PIL import Image
import qa_local_epub_android as e

q = e.q


def illustration_pixels(name):
    e.screenshot(name)
    im = Image.open(e.OUT / f'{name}.png').convert('RGB')
    # The fixture's blue/yellow checkerboard cannot be confused with text or
    # a spinner. Sampling a scaled image keeps this check inexpensive.
    im.thumbnail((640, 640))
    pixels = im.get_flattened_data() if hasattr(im, 'get_flattened_data') else im.getdata()
    return sum(1 for r, g, b in pixels
               if (r > 190 and g > 160 and b < 170)
               or (r < 160 and g > 150 and b > 170))


def main():
    e.RESULTS = json.loads((e.OUT / 'checks.json').read_text(encoding='utf-8'))
    baseline = {key: q.adb('shell', 'settings', 'get', 'global', key).strip()
                for key in ('airplane_mode_on', 'wifi_on', 'mobile_data')}
    (e.OUT / 'qa-radio-baseline.json').write_text(json.dumps(baseline), encoding='utf-8')
    try:
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
        q.adb('shell', 'svc', 'wifi', 'disable')
        q.adb('shell', 'svc', 'data', 'disable')
        time.sleep(2)
        connectivity = q.adb('shell', 'dumpsys', 'connectivity')
        assert 'Active default network: none' in connectivity, 'AVD still has a default network'
        q.restart()
        e.open_library()
        q.tap('远行日记 EPUB2')
        q.tap('序章·站台的风')
        time.sleep(2)
        assert illustration_pixels('14-offline-cold-curl-image') > 10000
        e.mark('offline_cold_start_native_curl_captures_decoded_illustration')

        q.adb('shell', 'wm', 'size', '1200x1920')
        time.sleep(2)
        e.screenshot('15-portrait-text-reflow')
        q.adb('shell', 'input', 'tap', '1100', '1000')
        time.sleep(2)
        assert illustration_pixels('16-portrait-illustration') > 10000
        e.mark('portrait_reflow_and_image_page_with_native_curl')

        q.adb('shell', 'wm', 'size', '2560x1800')
        time.sleep(4)
        assert illustration_pixels('17-landscape-anchor-restored') > 10000
        e.mark('rotation_restores_anchor_to_two_leaf_spread')

        for label, y in [('top', 200), ('middle', 900), ('bottom', 1600)]:
            gesture = subprocess.Popen([
                q.ADB, '-s', q.DEVICE, 'shell', 'input', 'swipe',
                '2400', str(y), '700', str(y), '2200',
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(.85)
            e.screenshot('18-curl-' + label)
            out, err = gesture.communicate(timeout=10)
            assert gesture.returncode == 0, err.decode(errors='replace')
            time.sleep(.6)
            q.adb('shell', 'input', 'tap', '160', '900')
            time.sleep(.8)
        # Screenshot review is required before treating these as visual passes.
        e.mark('native_curl_upper_middle_lower_gestures_captured')
    finally:
        q.adb('shell', 'wm', 'size', '2560x1800')
        q.adb('shell', 'cmd', 'connectivity', 'airplane-mode',
              'enable' if baseline['airplane_mode_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'wifi', 'enable' if baseline['wifi_on'] == '1' else 'disable')
        q.adb('shell', 'svc', 'data', 'enable' if baseline['mobile_data'] == '1' else 'disable')
        for _ in range(12):
            # Telephony applies svc data asynchronously on this API 35 AVD.
            restored = {key: q.adb('shell', 'settings', 'get', 'global', key).strip()
                        for key in baseline}
            if restored == baseline:
                break
            time.sleep(.5)
        assert restored == baseline, (restored, baseline)
        print('QA radio and viewport baseline restored', flush=True)


if __name__ == '__main__':
    main()
