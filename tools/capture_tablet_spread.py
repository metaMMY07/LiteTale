"""Capture live Android spread gestures after installing tablet_reader_demo.

The demo uses local fixture data and the production reader/curl. Integration
test bindings do not accept normal hardware touches after the test completes;
use this live entrypoint for visual acceptance instead.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import time
from PIL import Image, ImageChops

parser = argparse.ArgumentParser()
parser.add_argument('--device', default='emulator-5554')
parser.add_argument('--out', type=Path, default=Path('docs/qa/0.1.7'))
args = parser.parse_args()
adb = r'D:\Codex-Migrated\Android\Sdk\platform-tools\adb.exe'
args.out.mkdir(parents=True, exist_ok=True)


def capture(name):
    png = subprocess.check_output([adb, '-s', args.device, 'exec-out', 'screencap', '-p'])
    (args.out / f'{name}.png').write_bytes(png)
    return struct.unpack('>II', png[16:24])


# This is a cached-gesture visual check. The separate PTQ device test covers
# the immediate Flutter fallback when the very first page PNG is still cold.
time.sleep(3)
width, height = capture('final-spread-idle')
checks = {}


def body_changed(first, second, right):
    # Exclude the minute clock and gutter. Compare the actual paper pixels so
    # a horizontal gesture that only animates on finger-up cannot pass QA.
    margin = int(width * .055)
    half = width // 2
    x0, x1 = (half + margin, width - margin) if right else (margin, half - margin)
    box = (x0, int(height * .06), x1, int(height * .90))
    with Image.open(args.out / f'{first}.png') as a, Image.open(args.out / f'{second}.png') as b:
        return ImageChops.difference(a.convert('RGB').crop(box), b.convert('RGB').crop(box)).getbbox() is not None


for label, next_page, start_y, end_y, cancel in [
    ('next-top', True, .18, .62, False),
    ('previous-top', False, .18, .62, False),
    ('next-middle', True, .50, .50, False),
    ('previous-middle', False, .50, .50, False),
    ('next-bottom', True, .82, .38, False),
    ('previous-bottom', False, .82, .38, False),
    ('cancel-right', True, .70, .68, True),
    ('cancel-left', False, .30, .32, True),
]:
    capture(f'final-{label}-before')
    start_x = .92 if next_page else .08
    end_x = (.82 if next_page else .18) if cancel else (.34 if next_page else .66)
    process = subprocess.Popen([adb, '-s', args.device, 'shell', 'input', 'swipe',
                               str(int(width * start_x)), str(int(height * start_y)),
                               str(int(width * end_x)), str(int(height * end_y)), '2400'])
    time.sleep(1.35)
    capture(f'final-{label}-fold')
    process.wait(timeout=10)
    time.sleep(.8)
    capture(f'final-{label}-after')
    before = f'final-{label}-before'
    fold = f'final-{label}-fold'
    after = f'final-{label}-after'
    checks[label] = {
        'followsFingerBeforeRelease': body_changed(before, fold, next_page),
        'settledOnExpectedPage': body_changed(before, after, next_page) != cancel,
    }
    print(f'Captured {label}')

(args.out / 'gesture-checks.json').write_text(json.dumps(checks, indent=2), encoding='utf-8')
if not all(all(result.values()) for result in checks.values()):
    raise RuntimeError('Gesture pixels failed verification; inspect gesture-checks.json and screenshots')
