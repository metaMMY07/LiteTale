"""Public Wenku8 cache/prefetch scenario for the installed LiteTale QA AVD.

Keeps app data. Does not log headers, cookies, account XML or chapter text.
The CDP timing probe captures only allowlisted public paths/status/timestamps.
"""
import json
import re
import subprocess
from pathlib import Path

import qa_settings_android as q

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'wenku8-reuse'
NODE = Path(r'C:\Users\30622\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
FIRST = '序章 魔女与失恋的迷情药'
BOOK_PATH = '/book/4343.htm'
FIRST_PATH = '/novel/4/4343/177990.htm'
NEXT_PATH = '/novel/4/4343/177991.htm'


def probe(name, seconds, x, y):
    path = OUT / (name + '.json')
    subprocess.run([str(NODE), str(ROOT / 'tools' / 'qa_wenku8_latency_android.cjs'),
                    str(path), str(seconds), '--tap', str(x), str(y)],
                   cwd=ROOT, check=True, capture_output=True, timeout=50)
    events = json.loads(path.read_text(encoding='utf-8'))['events']
    requests = [e['pathname'] for e in events if e['event'] == 'request']
    responses = [e for e in events if e['event'] == 'response']
    assert all(e['status'] == 200 for e in responses), name + ': non-200 read'
    print(json.dumps({'scenario': name, 'requests': requests}, ensure_ascii=False))
    return requests


def back_to_detail():
    q.adb('shell', 'input', 'keyevent', '4')
    q.require('小说详情')
    q.require(FIRST)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    q.restart()
    q.require('发现')
    app_pid = q.adb('shell', 'pidof', q.PACKAGE).strip()
    assert re.fullmatch(r'\d+', app_pid)
    q.adb('forward', 'tcp:9335', 'localabstract:webview_devtools_remote_' + app_pid)
    results = {}
    results['detailFirst'] = probe('after-detail-first', 3, 220, 838)
    q.require(FIRST)
    q.adb('shell', 'input', 'keyevent', '4')
    q.require('发现')
    results['detailReopen'] = probe('after-detail-reopen', 2, 220, 838)
    q.require(FIRST)
    results['chapterAndPrefetch'] = probe('after-chapter-prefetch', 6, 1280, 1392)
    (OUT / 'after-reader.png').write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    back_to_detail()
    results['nextChapter'] = probe('after-next-chapter', 4, 1280, 1480)
    back_to_detail()
    results['chapterReturn'] = probe('after-chapter-return', 3, 1280, 1392)
    (OUT / 'after-return-reader.png').write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
    back_to_detail()
    q.adb('shell', 'input', 'keyevent', '4')
    q.require('发现')
    (OUT / 'reuse-results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    assert results['detailFirst'] == [BOOK_PATH, '/novel/4/4343/index.htm']
    assert results['detailReopen'] == []
    assert results['chapterAndPrefetch'] == [FIRST_PATH, NEXT_PATH]
    assert NEXT_PATH not in results['nextChapter']
    assert results['chapterReturn'] == []
    print('Public cache/prefetch flow passed; discovery restored.')


if __name__ == '__main__':
    main()
