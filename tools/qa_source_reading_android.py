"""Small, data-preserving checks against the installed release.

Run only on a public reading page selected by the operator. PNGs need a human
review; changed hashes do not prove correct text or animation performance.
Never reads app storage, account forms, cookies, or logcat payloads.
"""
import argparse
import hashlib
import json
import re
import time
from pathlib import Path

import qa_settings_android as q


def viewport():
    return tuple(map(int, re.findall(r'(\d+)x(\d+)', q.adb('shell', 'wm', 'size'))[-1]))


def tap_destination(label):
    """Match the bottom destination, never a title such as 我的书架."""
    _, height = viewport()
    nodes = [n for n in q.tree().iter('node')
             if label in (n.get('text', '') + '\n' + n.get('content-desc', '')).splitlines()
             and int(re.findall(r'\d+', n.get('bounds', ''))[1]) > height*.75]
    assert len(nodes) == 1, 'Expected one visible bottom destination'
    q.tap_node(nodes[0])


def reading_check(out, prefix, version='0.1.16', code=4051):
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert f'versionName={version}' in metadata and f'versionCode={code}' in metadata
    assert re.fullmatch(r'[a-z0-9-]+', prefix)
    root = q.tree()
    # Refuse to turn pages on a menu, account form, or failed request.
    assert not any(n.get('class') == 'android.widget.EditText' for n in root.iter('node'))
    assert not any(q.matches(root, label) for label in
                   ('小说详情', '阅读历史', '加载失败', '重新加载', '当前书源',
                    '登录轻书架', '欢迎来到 LiteTale', '搜索未完成', '离线下载'))
    width, height = viewport()
    out.mkdir(parents=True, exist_ok=True)
    snapshots = {}

    def shot(label):
        time.sleep(2)
        data = q.adb('exec-out', 'screencap', '-p', binary=True)
        path = out / f'{prefix}-{label}.png'
        path.write_bytes(data)
        snapshots[label] = {'file': path.name, 'sha256': hashlib.sha256(data).hexdigest()}

    def tap(x):
        q.adb('shell', 'input', 'tap', str(round(width*x)), str(round(height*.45)))

    shot('before')
    tap(.88)
    shot('tap-next')
    q.adb('shell', 'input', 'swipe', str(round(width*.87)), str(round(height*.28)),
          str(round(width*.18)), str(round(height*.38)), '420')
    shot('swipe-next')
    tap(.12)
    shot('tap-previous')
    report = {
        'installedVersion': version, 'viewportPixels': [width, height],
        'tapChangedImage': snapshots['before']['sha256'] != snapshots['tap-next']['sha256'],
        'swipeChangedImage': snapshots['tap-next']['sha256'] != snapshots['swipe-next']['sha256'],
        'previousReturnedToTapPage': snapshots['tap-next']['sha256'] == snapshots['tap-previous']['sha256'],
        'snapshots': snapshots, 'visualReview': 'pending root review',
        'performanceMeasurement': False, 'credentialsRecorded': False,
    }
    (out / f'{prefix}-checks.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'snapshots'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--version', default='0.1.16')
    parser.add_argument('--code', type=int, default=4051)
    args = parser.parse_args()
    reading_check(args.out, args.prefix, args.version, args.code)
