"""Check installed x-id persistence without exporting its value or account data.

Only the SHA-256 of the dedicated encrypted preference entry is compared. Real
HTTP/WebSocket header equality is covered by shelf_request_identity_test.dart.
Keeps app data, never submits credentials, and restores the original source.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import time

import qa_settings_android as q
import qa_source_reading_android as reading

ROOT = Path(__file__).resolve().parents[1]
LABELS = ['文库8', '轻书架', '轻小说百科', '哔哩轻小说', 'SF轻小说（公开目录）']


def wait(label, seconds=45):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if q.matches(q.tree(), label):
            return
        time.sleep(.4)
    raise AssertionError('Expected public UI did not settle')


def account():
    wait('我的')
    reading.tap_destination('我的')
    q.tap('书源与账号', scroll=True)
    wait('当前书源')


def source_field():
    fields = [n for n in q.tree().iter('node') if '当前书源' in
              (n.get('text', '')+'\n'+n.get('content-desc', '')).splitlines()]
    assert fields
    return min(fields, key=lambda n: area(n.get('bounds', '')))


def area(bounds):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', bounds))
    return (x2-x1)*(y2-y1)


def select_source(label):
    account()
    field = source_field()
    if label not in (field.get('text', '')+'\n'+field.get('content-desc', '')).splitlines():
        assert reading.viewport() == (2560, 1800)
        x1, y1, _, _ = map(int, re.findall(r'\d+', field.get('bounds', '')))
        # Flutter merges the dropdown semantics with this card. Its input is
        # left aligned; the card's far right is not the dropdown arrow.
        q.adb('shell', 'input', 'tap', str(x1+236), str(y1+208))
        options = [n for n in q.tree().iter('node') if label in
                   (n.get('text', '')+'\n'+n.get('content-desc', '')).splitlines()]
        assert len(options) == 1
        q.tap_node(options[0])
    wait('当前书源')


def discover():
    q.adb('shell', 'input', 'keyevent', '4')
    reading.tap_destination('发现')


def fingerprint():
    path = '/data/user/0/'+q.PACKAGE+'/shared_prefs/FlutterSecureStorage.xml'
    key = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_litetale.lns.deviceId'
    pattern = '<string name="'+re.escape(key)+'">[^<]*</string>'
    script = ('task_id_entry=$(grep -o '+shlex.quote(pattern)+' '+shlex.quote(path)
              +' 2>/dev/null); if [ -n "$task_id_entry" ]; then '
              'printf "%s" "$task_id_entry" | sha256sum; else printf absent; fi')
    result = q.adb('shell', 'su 0 sh -c '+shlex.quote(script)).strip()
    if result == 'absent':
        return None
    digest = result.split()[0]
    assert re.fullmatch(r'[0-9a-f]{64}', digest), 'Encrypted entry could not be checked'
    return digest


def metadata():
    raw = q.adb('shell', 'dumpsys', 'package', q.PACKAGE)
    return {
        'version': re.search(r'versionName=(\S+)', raw).group(1),
        'versionCode': int(re.search(r'versionCode=(\d+)', raw).group(1)),
        'firstInstallTime': re.search(r'firstInstallTime=(.*)', raw).group(1).strip(),
    }


def shelf_home():
    try:
        wait('近期录入', seconds=50)
        return True
    except AssertionError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['baseline', 'run'])
    parser.add_argument('--out', type=Path,
                        default=ROOT/'docs/qa/shelf-device-id-2026-10/device-4064')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = {'dataCleared': False, 'newLoginSubmitted': False,
              'deviceIdExported': False, 'credentialsRecorded': False,
              'headerValuesCapturedOnDevice': False}
    baseline_file = args.out/'before-install.json'
    file = baseline_file if args.phase == 'baseline' else args.out/'checks.json'
    baseline = None
    try:
        report.update(metadata())
        assert q.adb('shell', 'settings', 'get', 'global', 'http_proxy').strip() == 'null'
        report['defaultDirectNetwork'] = True
        if args.phase == 'baseline':
            q.restart()
            account()
            field = source_field()
            lines = (field.get('text', '')+'\n'+field.get('content-desc', '')).splitlines()
            sources = [s for s in LABELS if s in lines]
            assert len(sources) == 1
            report['originalSource'] = sources[0]
            report['originalSavedLogin'] = bool(q.matches(q.tree(), '已保存登录'))
            report['deviceEntryAlreadyPresent'] = fingerprint() is not None
            discover()
        else:
            baseline = json.loads(baseline_file.read_text(encoding='utf-8'))
            assert report['version'] == '0.1.22' and report['versionCode'] == 4064
            assert report['firstInstallTime'] == baseline['firstInstallTime']
            q.restart()
            select_source('轻书架')
            report['shelfLoginBeforeReads'] = bool(q.matches(q.tree(), '已保存登录'))
            discover()
            report['homeResults'] = [shelf_home()]
            first = fingerprint()
            assert first is not None
            report['deviceEntryPersisted'] = True
            report['sameEncryptedEntryAfterRestarts'] = []
            pids = [q.adb('shell', 'pidof', q.PACKAGE).strip()]
            if report['homeResults'][0]:
                (args.out/'shelf-home.png').write_bytes(q.adb('exec-out', 'screencap', '-p', binary=True))
            for _ in range(2):
                q.restart()
                wait('我的')
                reading.tap_destination('发现')
                report['homeResults'].append(shelf_home())
                pids.append(q.adb('shell', 'pidof', q.PACKAGE).strip())
                report['sameEncryptedEntryAfterRestarts'].append(fingerprint() == first)
            assert all(report['sameEncryptedEntryAfterRestarts'])
            report['distinctAppProcesses'] = len(set(pids)) == 3
            assert report['distinctAppProcesses']
            account()
            report['shelfLoginAfterReads'] = bool(q.matches(q.tree(), '已保存登录'))
            q.adb('shell', 'input', 'keyevent', '4')
            report['identityChecksPassed'] = True
    except Exception as error:
        report['errorType'] = type(error).__name__
        report['error'] = 'Installed APK identity QA did not complete'
    finally:
        if baseline is not None:
            try:
                q.restart()
                select_source(baseline['originalSource'])
                q.restart()
                account()
                report['originalSourceRestored'] = baseline['originalSource'] in (
                    source_field().get('text', '')+'\n'+source_field().get('content-desc', '')).splitlines()
                report['savedLoginPreserved'] = bool(q.matches(q.tree(), '已保存登录')) == baseline['originalSavedLogin']
                discover()
                if baseline['originalSource'] == '文库8':
                    wait('新书风云榜')
                    report['wenku8HomeRestored'] = True
                package_path = q.adb('shell', 'pm', 'path', q.PACKAGE).strip().splitlines()[0].removeprefix('package:')
                report['installedApkSha256'] = q.adb('shell', 'sha256sum', package_path).split()[0]
            except Exception:
                report['restoreError'] = 'Original source restoration did not complete'
        file.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(report, ensure_ascii=True), flush=True)
    assert 'error' not in report and 'restoreError' not in report


if __name__ == '__main__':
    main()
