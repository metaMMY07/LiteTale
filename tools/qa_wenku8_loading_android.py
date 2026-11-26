"""Read-only online QA of installed 0.1.16; no login submission or account dump."""
import json
import time
from pathlib import Path

import qa_settings_android as q

OUT = Path(__file__).resolve().parents[1] / 'build/wenku8-0.1.16'


def wait_for(label, timeout=55):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        root = q.tree()
        if q.matches(root, label):
            return round(time.monotonic() - started, 2)
        if q.matches(root, '加载失败:') or q.matches(root, '搜索未完成'):
            raise AssertionError('Read route returned an error')
        time.sleep(.5)
    raise AssertionError('Read route remained unsettled')


def shot(name):
    (OUT / f'{name}.png').write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))


def main():
    metadata = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    assert 'versionName=0.1.16' in metadata
    q.restart()
    wait_for('新书风云榜')
    q.tap('魔法少女育成计划')
    detail = wait_for('人物简介')
    shot('release-detail')
    q.tap('序章')
    # Reader text is painted on Canvas; keep a screenshot for root visual QA.
    time.sleep(10)
    shot('release-reader')
    q.restart()
    wait_for('新书风云榜')
    q.tap('搜索书名、作者')
    fields = [n for n in q.tree().iter('node') if n.get('class') == 'android.widget.EditText']
    assert len(fields) == 1
    q.tap_node(fields[0])
    q.adb('shell', 'input', 'text', 'Re')
    q.adb('shell', 'input', 'keyevent', '66')
    search = wait_for('志乃与恋 Future')
    shot('release-search')
    q.tap('志乃与恋 Future')
    searched_detail = wait_for('简介')
    shot('release-search-detail')
    (OUT / 'device-checks.json').write_text(json.dumps({
        'version': '0.1.16', 'device': 'Android 35 x86_64 emulator',
        'homeLoaded': True, 'detailLoaded': True, 'searchLoaded': True,
        'searchDetailLoaded': True, 'readerVisualCheck': 'pending root inspection',
        'pollSeconds': {'detail': detail, 'search': search, 'searchDetail': searched_detail},
        'newLoginSubmitted': False,
    }, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Online home, detail, search and search-to-detail passed; inspect reader image.')


if __name__ == '__main__':
    main()
