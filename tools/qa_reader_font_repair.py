"""Use the user's actual font through DocumentsUI; preserve all app data."""
import argparse
from pathlib import Path
import tools.qa_settings_android as q

FONT = 'YanZhenQingDuoBaoTaBei-2.ttf'


def import_selected(index):
    q.tap('导入字体', index=index)
    for _ in range(12):
        root = q.tree()
        if any('documentsui' in n.get('package', '') for n in root.iter('node')):
            break
        q.time.sleep(.5)
    else:
        raise AssertionError('Android font picker did not open')
    # Search avoids opening a preview button whose filename is offscreen.
    q.tap('Search')
    q.adb('shell', 'input', 'text', 'YanZhenQingDuoBaoTaBei')
    q.time.sleep(2)
    q.tap(FONT)
    q.require(FONT)
    q.time.sleep(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default='docs/qa/0.1.11')
    parser.add_argument('--stage', default='baseline')
    args = parser.parse_args()
    q.OUT = Path(args.out)
    q.restart()
    q.tap('我的\n我的')
    q.tap('字体设置', scroll=True)
    import_selected(0)
    import_selected(-1)
    q.capture(f'{args.stage}-user-font-both-scopes')
    q.adb('shell', 'input', 'keyevent', '4')
    q.tap('发现\n发现')
    q.tap('一週一次買同學的那些事', scroll=True)
    q.tap('第一話 仙台的價格剛好五千元', scroll=True)
    q.time.sleep(4)
    q.capture(f'{args.stage}-user-font-lnovel-body')
    print('Actual user font imported and public LNovel chapter opened.')


if __name__ == '__main__':
    main()
