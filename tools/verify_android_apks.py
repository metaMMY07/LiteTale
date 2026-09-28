"""Verify release APK metadata, signatures, ZIP integrity and 16 KB alignment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--version', default='0.1.3')
parser.add_argument('--build-number', type=int, default=38)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sdk = Path(os.environ.get('ANDROID_HOME', 'D:/Codex-Migrated/Android/Sdk'))
build_tools = sdk / 'build-tools/35.0.0'
os.environ.setdefault('JAVA_HOME', r'D:\CodexToolchains\jdk17\jdk-17.0.16+8')
os.environ['PATH'] = str(Path(os.environ['JAVA_HOME']) / 'bin') + os.pathsep + os.environ['PATH']


def run(tool, *params):
    result = subprocess.run([str(build_tools / tool), *map(str, params)],
                            capture_output=True, text=True, encoding='utf-8', errors='replace')
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


reports = []
for abi, code, machine in [('arm64-v8a', 2000, 183), ('x86_64', 4000, 62)]:
    apk = root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
    badging = run('aapt.exe', 'dump', 'badging', apk)
    assert f"versionName='{args.version}'" in badging
    assert f"versionCode='{code + args.build_number}'" in badging
    assert "name='io.github.metammy07.novels'" in badging
    assert "application-label:'LiteTale'" in badging
    manifest = run('aapt.exe', 'dump', 'xmltree', apk, 'AndroidManifest.xml')
    assert 'enableOnBackInvokedCallback' not in manifest, 'Experimental back opt-in must be removed'
    signature = run('apksigner.bat', 'verify', '--verbose', '--print-certs', apk)
    run('zipalign.exe', '-c', '-P', '16', '4', apk)
    with zipfile.ZipFile(apk) as archive:
        assert archive.testzip() is None
        libraries = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('.so')]
        assert all(f'lib/{abi}/{name}' in libraries for name in
                   ['libapp.so', 'libflutter.so', 'librust_lib_wild.so', 'libc++_shared.so'])
        for name in libraries:
            data = archive.read(name)
            assert data[:6] == b'\x7fELF\x02\x01'
            assert struct.unpack_from('<H', data, 18)[0] == machine
            phoff = struct.unpack_from('<Q', data, 32)[0]
            entsize, count = struct.unpack_from('<HH', data, 54)
            for i in range(count):
                offset = phoff + i * entsize
                if struct.unpack_from('<I', data, offset)[0] == 1:
                    assert struct.unpack_from('<Q', data, offset + 48)[0] >= 16384, name
    reports.append({'abi': abi, 'version': args.version, 'versionCode': code + args.build_number,
                    'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                    'bytes': apk.stat().st_size, 'experimentalPredictiveBack': False,
                    'zipIntegrity': 'passed', 'alignment16KB': 'passed',
                    'certificate': next(line for line in signature.splitlines()
                                        if 'certificate SHA-256 digest' in line)})

output = root / f'build/reader-curl/{args.version}-apk-verification.json'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(reports, indent=2), encoding='utf-8')
print(json.dumps(reports, indent=2))
