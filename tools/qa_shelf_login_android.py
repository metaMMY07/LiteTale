"""Test the authorised account via UI without saving credentials or login forms."""
import getpass
import shlex
from pathlib import Path

import tools.qa_settings_android as q


def enter(node, value):
    q.tap_node(node)
    q.adb('shell', 'input text ' + shlex.quote(value))
    q.adb('shell', 'input', 'keyevent', '4')
    q.time.sleep(.5)


def main():
    # Read only the empty form. Do not dump/capture after either field is filled.
    root = q.tree()
    fields = [n for n in root.iter('node')
              if n.get('class') == 'android.widget.EditText']
    assert len(fields) == 2, 'Open the empty native Shelf login page first'
    buttons = [n for n in root.iter('node')
               if n.get('text') == '登录' or n.get('content-desc') == '登录']
    assert buttons, 'Login action missing'
    email = getpass.getpass('QA email (hidden): ')
    password = getpass.getpass('QA password (hidden): ')
    try:
        enter(fields[0], email)
        enter(fields[1], password)
        q.tap_node(buttons[0])
        q.time.sleep(15)
    finally:
        email = password = ''
        # Destroy the form before any further UI XML or screenshots are saved.
        q.adb('shell', 'am', 'force-stop', q.PACKAGE)
    q.restart()
    q.tap('我的\n我的')
    q.tap('书源与账号')
    q.require('轻书架 · 已保存登录')
    q.OUT = Path('D:/Projects/LiteTale/docs/qa/0.1.11')
    q.capture('final-shelf-login-saved')
    print('Shelf login and restart retention passed; no credential form saved.')


if __name__ == '__main__':
    main()
