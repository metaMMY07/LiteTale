"""Data-preserving release APK checks, restricted to user-provided local books.

Uses the Android document picker and normal UI. Does not export accounts,
cookies, preferences databases, or full novel text.
"""
import argparse
import hashlib
import json
import re
import subprocess
import time
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET
from urllib.parse import unquote
import qa_epub_artwork_android as a

e, q, v, f = a.e, a.q, a.v, a.f
ROOT = Path(__file__).resolve().parents[1]
e.OUT = ROOT / 'docs/qa/epub-css-engine-2026-10/android'
e.OUT.mkdir(parents=True, exist_ok=True)
e.RESULTS = json.loads((e.OUT/'checks.json').read_text(encoding='utf-8')) if (e.OUT/'checks.json').exists() else []
FILES = [
    '创约 某魔法的禁书目录8 (1).epub', '浴缸生活(1).epub',
    '末日时在做什么？能不能再见一面？ 08 (枯野瑛) (z-library.sk, 1lib.sk, z-lib.sk).epub',
    '末日时在做什么？能不能再见一面？.11(1).epub', 'css_test.epub',
]


def title(index):
    with zipfile.ZipFile(Path('C:/Users/30622/Downloads') / FILES[index]) as z:
        c = ET.fromstring(z.read('META-INF/container.xml'))
        opf = unquote(c.find('.//{*}rootfile').get('full-path'))
        return ET.fromstring(z.read(opf)).find('.//{*}title').text.strip()


def assert_reader():
    deadline=time.monotonic()+45
    while time.monotonic()<deadline:
        labels=v.labels()
        assert not any(any(word in x for word in ('排版失败','排版超时','加载失败','页面加载失败','无法排版')) for x in labels), labels[:3]
        if any(len(x)>30 or x=='插图' for x in labels) and not any(x in ('小说详情','本地书籍') for x in labels):
            time.sleep(.5)
            return
        time.sleep(.5)
    raise AssertionError('Reader did not become ready')


def import_all():
    meta=q.adb('shell','dumpsys','package',q.PACKAGE)
    assert 'versionCode=4071' in meta and 'versionName=1.0.0' in meta
    assert 'firstInstallTime=2026-09-27 14:47:16' in meta
    q.adb('shell','wm','size','2560x1800')
    q.restart();e.open_library()
    for index,name in enumerate(FILES):
        source=Path('C:/Users/30622/Downloads')/name
        alias=f'engine-css-{index}.epub'
        q.adb('push',str(source),'/sdcard/Download/'+alias)
        started=time.monotonic();e.picker(alias);a.wait_library(70);q.require(title(index))
        e.mark(f'book_{index}_imported_in_final_apk',sha256=hashlib.sha256(source.read_bytes()).hexdigest(),elapsedSeconds=round(time.monotonic()-started,2))
    e.screenshot('01-five-books-imported')


def open_book(index, chapter):
    q.restart();e.open_library();q.tap(title(index));q.require('小说详情')
    q.tap(chapter,scroll=True);assert_reader();time.sleep(2)
    e.screenshot(f'book-{index}-{hashlib.sha256(chapter.encode()).hexdigest()[:6]}-landscape')
    e.mark(f'book_{index}_opens_{chapter}',scope='Actual installed x64 APK on API35 AVD')


def settings_baseline():
    v.settings()
    q.require('普通翻页')
    assert not q.matches(q.tree(),'仿书翻页'), 'Local books must not expose a curl switch'
    file=e.OUT/'reader-baseline.json'
    baseline=json.loads(file.read_text()) if file.exists() else {}
    old_volume=v.switch('音量键翻页',True)
    if not baseline:
        baseline={'volume':old_volume}
        file.write_text(json.dumps(baseline))
    v.close_settings();time.sleep(1.5)


def turns(index):
    assert_reader();settings_baseline()
    before=q.adb('exec-out','screencap','-p',binary=True)
    q.adb('shell','input','tap','2350','900');time.sleep(2)
    after=q.adb('exec-out','screencap','-p',binary=True)
    assert before!=after,'Tap did not turn the CSS spread'
    v.key(24);time.sleep(1)
    reverse=q.adb('exec-out','screencap','-p',binary=True)
    assert reverse==before,'Reverse volume key did not return to the same pixels'
    command=[q.ADB,'-s',q.DEVICE,'shell','input','swipe','2400','1400','650','750','2400']
    process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    time.sleep(1);e.screenshot(f'book-{index}-css-plain-swipe')
    assert process.wait(timeout=10)==0;time.sleep(1)
    e.screenshot(f'book-{index}-css-next-spread')
    assert_reader()
    e.mark(f'book_{index}_plain_tap_swipe_volume_and_reverse_with_css',curlSettingAbsent=True)


def rotate(index):
    assert_reader();before=hashlib.sha256(v.body().encode()).hexdigest()
    q.adb('shell','wm','size','1200x1920');time.sleep(5);assert_reader()
    e.screenshot(f'book-{index}-portrait')
    q.adb('shell','wm','size','2560x1800');time.sleep(5);assert_reader()
    e.screenshot(f'book-{index}-landscape-restored')
    e.mark(f'book_{index}_portrait_landscape_reflow',initialSemanticDigest=before,
           scope='DOM anchor and no failed pages; page cuts may change with insets')


def restore():
    file=e.OUT/'reader-baseline.json'
    if file.exists():
        baseline=json.loads(file.read_text());v.settings()
        v.switch('音量键翻页',baseline['volume']);v.close_settings()
    q.adb('shell','wm','size','2560x1800')
    e.mark('reader_volume_switch_and_viewport_restored')


def global_curl(enabled):
    q.restart();q.tap('我的',index=-1);q.tap('显示',scroll=True);q.tap('阅读显示',scroll=True)
    v.switch('仿真翻页',enabled)
    e.mark('global_online_curl_'+str(enabled).lower())


def reader_font(reset=False):
    q.restart();q.tap('我的',index=-1);q.tap('字体设置',scroll=True)
    q.require('全局界面字体')
    current=v.labels()
    app_name=next(x for x in current if '全局界面字体' in x).splitlines()[1]
    file=e.OUT/'font-baseline.json'
    if not reset:
        assert any('默认 · 霞鹜新致宋' in x for x in current), 'Unexpected reader font baseline'
        file.write_text(json.dumps({'appName':app_name,'readerDefault':True},ensure_ascii=False),encoding='utf-8')
    q.swipe()
    q.tap('恢复默认' if reset else '导入字体',index=-1,scroll=True)
    if not reset:
        for _ in range(8):
            nodes=q.tree()
            if any('documentsui' in n.get('package','') for n in nodes.iter('node')):break
            time.sleep(.5)
        else:raise AssertionError('Native font picker did not open')
        if not q.matches(nodes,'engine-reader-font.ttf'):
            downloads=q.matches(nodes,'Downloads') or q.matches(nodes,'下载')
            if not downloads:
                menu=q.matches(nodes,'Show roots') or q.matches(nodes,'Open navigation drawer')
                if not menu:menu=[n for n in nodes.iter('node') if n.get('resource-id')=='android:id/home']
                assert menu,'Native picker navigation missing'
                q.tap_node(menu[0]);nodes=q.tree()
                downloads=q.matches(nodes,'Downloads') or q.matches(nodes,'下载')
            assert downloads,'Downloads root missing'
            q.tap_node(downloads[-1])
        q.tap('engine-reader-font.ttf',scroll=True)
        q.require('engine-reader-font.ttf')
    else:
        q.require('默认 · 霞鹜新致宋')
    baseline=json.loads(file.read_text(encoding='utf-8'))
    q.swipe(down=True)
    q.require(baseline['appName'])
    e.screenshot('reader-font-restored' if reset else 'reader-font-imported')
    e.mark('reader_font_reset_keeps_global_font' if reset else 'reader_font_import_keeps_global_font')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('stage',choices=['import','open','turns','rotate','restore','global-curl','font','font-reset'])
    p.add_argument('--book',type=int,default=0);p.add_argument('--chapter',default='封面');args=p.parse_args()
    if args.stage=='import':import_all()
    elif args.stage=='open':open_book(args.book,args.chapter)
    elif args.stage=='turns':turns(args.book)
    elif args.stage=='rotate':rotate(args.book)
    elif args.stage=='global-curl':global_curl(True)
    elif args.stage=='font':reader_font()
    elif args.stage=='font-reset':reader_font(reset=True)
    else:restore()
