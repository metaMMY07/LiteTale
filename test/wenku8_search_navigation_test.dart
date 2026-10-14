import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/utils/wenku8_search_navigation.dart';

String? modulePath() {
  final path =
      Platform.environment['PLAYWRIGHT_MODULE_PATH'] ??
      '${Platform.environment['APPDATA']}/npm/node_modules/@playwright/cli/node_modules/playwright';
  return Directory(path).existsSync() ? path : null;
}

String? browserPath() {
  for (final path in [
    Platform.environment['PLAYWRIGHT_EXECUTABLE_PATH'],
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
  ]) {
    if (path != null && File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  test(
    'real Chromium form preserves GBK and refuses unrelated navigation',
    () async {
      final process = await Process.start(
        'node',
        [
          '-e',
          r'''
const {chromium}=require(process.env.PLAYWRIGHT_MODULE_PATH);
let input='';process.stdin.on('data',b=>input+=b);process.stdin.on('end',async()=>{
  const scripts=JSON.parse(input);
  const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH});
  try {
    const context=await browser.newContext({offline:true,serviceWorkers:'block'});
    const page=await context.newPage();const posts=[];
    const first='https://www.wenku8.net/modules/article/search.php?searchtype=articlename&searchkey=%C4%A7%B7%A8';
    const second=first+'&page=2';
    const form=action=>`<meta charset="gbk"><form method="post" action="${action}"><select name="searchtype"><option value="articlename">title</option><option value="author">author</option></select><input name="searchkey"><input type="hidden" name="charset" value="gbk"></form>`;
    await page.route('**/*',async route=>{
      const r=route.request();
      if(r.url()==='https://www.wenku8.net/so.php') {
        // Playwright does not route the redirected request in an HTTP 302
        // chain. Model the same new-document navigation without any live I/O.
        posts.push(r.postData());return route.fulfill({contentType:'text/html',body:`<script>location.replace(${JSON.stringify(first)})</script>`});
      }
      if(r.url().includes('/modules/article/search.php'))return route.fulfill({contentType:'text/html',body:`<div id="pagelink"><a href="${second}">next</a></div>`});
      return route.fulfill({contentType:'text/html',body:form('/so.php')});
    });
    await page.goto('https://www.wenku8.net/');
    const submitted=await page.evaluate(s=>window.eval(s),scripts.submit);
    await page.waitForURL(first,{timeout:5000});
    await page.waitForSelector('#pagelink a',{timeout:5000});
    const nextUrl=await page.evaluate(s=>window.eval(s),scripts.nextUrl);
    const turned=await page.evaluate(s=>window.eval(s),scripts.page);
    await page.waitForURL(second,{timeout:5000});
    const after=page.url();
    await page.goto('https://www.wenku8.net/');
    await page.setContent(form('https://unrelated.invalid/so.php'));
    const external=await page.evaluate(s=>window.eval(s),scripts.submit);
    await page.setContent(form('/logout.php'));
    const wrongPath=await page.evaluate(s=>window.eval(s),scripts.submit);
    await page.goto(first);
    await page.setContent('<div id="pagelink"><a href="https://unrelated.invalid/modules/article/search.php?page=2">bad</a></div>');
    const badPage=await page.evaluate(s=>window.eval(s),scripts.page);
    await page.setContent(`<div id="pagelink"><a href="${second}&page=3">bad</a></div>`);
    const duplicate=await page.evaluate(s=>window.eval(s),scripts.nextUrl);
    await page.setContent('<div id="content">对不起，两次搜索的间隔时间不得少于5秒！</div>');
    const interval=await page.evaluate(s=>window.eval(s),scripts.interval);
    await page.setContent('<table class="grid"><tr><td>两次搜索的间隔时间不得少于5秒</td></tr></table>');
    const bookIsNotInterval=await page.evaluate(s=>window.eval(s),scripts.interval);
    console.log(JSON.stringify({submitted,turned,after,nextUrl,nextMatches:nextUrl===second,duplicate,interval,bookIsNotInterval,gbk:posts[0]?.includes('searchkey=%C4%A7%B7%A8'),posts:posts.length,external,wrongPath,badPage}));
  }finally{await browser.close();}
}).on('error',e=>{console.error(e.message);process.exitCode=1;});
''',
        ],
        environment: {
          'PLAYWRIGHT_MODULE_PATH': modulePath()!,
          'PLAYWRIGHT_EXECUTABLE_PATH': browserPath()!,
        },
      );
      process.stdin.write(
        jsonEncode({
          'submit': wenku8SearchSubmitScript(
            'https://www.wenku8.net',
            '魔法',
            'articlename',
          ),
          'page': wenku8SearchPageScript('https://www.wenku8.net', 2),
          'nextUrl': wenku8SearchNextPageUrlScript('https://www.wenku8.net', 2),
          'interval': wenku8SearchIntervalScript('https://www.wenku8.net'),
        }),
      );
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      expect(exit, 0, reason: await stderr);
      final result = jsonDecode((await stdout).trim()) as Map;
      expect(result['submitted'], isTrue);
      expect(result['turned'], isTrue);
      expect(result['gbk'], isTrue);
      expect(result['posts'], 1);
      expect(result['external'], isFalse);
      expect(result['wrongPath'], isFalse);
      expect(result['badPage'], isFalse);
      expect(result['nextMatches'], isTrue);
      expect(result['duplicate'], '');
      expect(result['interval'], 5);
      expect(result['bookIsNotInterval'], 0);
    },
    skip: modulePath() == null || browserPath() == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
