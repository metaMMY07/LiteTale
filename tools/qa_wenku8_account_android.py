"""Check the user's authorised Wenku8 login once, without recording credentials.

Set LITETALE_QA_USERNAME and LITETALE_QA_PASSWORD only in the calling process.
Do not read or capture the form after filling it; restart destroys controllers
before any subsequent UI inspection. This script never retries a login POST.
"""
import argparse
import json
import os
import shlex
import time

import qa_full_width_android as ui
import qa_wenku8_navigation_android as checks

q = ui.q


def prepare():
    ui.more()
    ui.tap_visible('书源与账号', scroll=True)
    q.require('当前书源')
    if q.matches(q.tree(), '文库8 · 未登录'):
        ui.tap_visible('登录文库8')
    else:
        raise AssertionError('Prepare requires an unsigned Wenku8 session')
    q.require('欢迎来到 LiteTale')
    deadline = time.monotonic() + 65
    ready = False
    while time.monotonic() < deadline:
        root = q.tree()
        ready = any(n.get('enabled') == 'true' for n in q.matches(root, '登录'))
        if ready or q.matches(root, '无法获取验证码'):
            break
        time.sleep(1)
    checks.result['browserCaptcha'] = {'ready': ready, 'credentialsEntered': False}
    checks.shot('tablet-wenku8-browser-captcha-final')
    checks.save()
    if not ready:
        raise AssertionError('Browser CAPTCHA did not become ready')


def enter(node, value):
    q.tap_node(node)
    q.adb('shell', 'input text ' + shlex.quote(value))
    q.adb('shell', 'input', 'keyevent', '4')
    time.sleep(.5)


def login(code):
    username = os.environ.pop('LITETALE_QA_USERNAME', '')
    password = os.environ.pop('LITETALE_QA_PASSWORD', '')
    if not username or not password or not code.isdigit():
        raise AssertionError('Missing authorised input')
    root = q.tree()  # Empty form only; never dump after entering credentials.
    fields = [n for n in root.iter('node') if n.get('class') == 'android.widget.EditText']
    buttons = [n for n in q.matches(root, '登录') if n.get('enabled') == 'true']
    assert len(fields) == 3 and buttons, 'Open a ready, empty native login form'
    submitted = False
    try:
        enter(fields[0], username)
        enter(fields[1], password)
        enter(fields[2], code)
        q.tap_node(buttons[-1])
        submitted = True
        time.sleep(25)
    finally:
        username = password = ''
        q.adb('shell', 'am', 'force-stop', q.PACKAGE)
    ui.more()
    ui.tap_visible('书源与账号', scroll=True)
    saved = bool(q.matches(q.tree(), '文库8 · 已保存登录'))
    if previous := checks.result.get('authorisedAccount'):
        checks.result.setdefault('authorisedAccountHistory', []).append(previous)
    checks.result['authorisedAccount'] = {
        'loginSubmissionRequestedOnce': submitted,
        'loginFlagAfterRestart': saved,
        'homeReadAfterRestart': 'pending separate UI check',
        'credentialsRecorded': False,
    }
    checks.save()
    if not saved:
        raise AssertionError('Login was not saved; no POST retry was performed')
    checks.shot('tablet-wenku8-login-saved-final')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['prepare', 'login'])
    parser.add_argument('--code', default='')
    args = parser.parse_args()
    try:
        prepare() if args.phase == 'prepare' else login(args.code)
    except Exception as error:
        # subprocess exceptions can include the input command. Never print it.
        print('QA stopped safely: ' + type(error).__name__, flush=True)
        raise SystemExit(1) from None
