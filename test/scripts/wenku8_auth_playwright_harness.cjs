const path = require('node:path');
const assert = require('node:assert/strict');

async function main() {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  const input = JSON.parse(raw);
  const { chromium } = require(path.resolve(process.env.PLAYWRIGHT_MODULE_PATH));
  const browser = await chromium.launch({
    headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH,
  });
  try {
    const page = await browser.newPage();
    let omitCaptchaControls = false;
    const loginHtml = () => `<title>用户登录</title><form action="/login.php" method="post">
      <input name="username"><input name="password" type="password">
      ${omitCaptchaControls ? '' : '<input name="checkcode">'}<input name="action" type="hidden">
      ${omitCaptchaControls ? '<select name="usecookie"><option value="0">浏览器进程</option><option value="86400">一天</option><option value="2592000">一个月</option><option value="31536000">一年</option></select>' : '<input name="usecookie" type="hidden">'}</form>${omitCaptchaControls ? '' : '<img src="/checkcode.php">'}`;
    let posts = 0, images = 0, sameSessionCookie = true;
    let persistentSelectUsed = false;
    await page.route('**/*', async route => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.origin !== input.host) {
        // All requests are intercepted. This harness never contacts a website.
        await route.abort();
      } else if (url.pathname === '/checkcode.php') {
        images++;
        await route.fulfill({ status: 200, contentType: 'image/svg+xml',
          headers: { 'set-cookie': `qaCaptcha=${images}; Path=/; Secure; SameSite=Lax` },
          body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><rect width="2" height="1" fill="blue"/></svg>',
        });
      } else if (url.pathname === '/login.php' && request.method() === 'POST') {
        posts++;
        const headers = await request.allHeaders();
        sameSessionCookie = sameSessionCookie && (headers.cookie || '').includes(`qaCaptcha=${images}`);
        const form = new URLSearchParams(request.postData() || '');
        assert.equal(form.get('username'), 'qa-local');
        assert.equal(form.get('password'), 'qa-local-only');
        assert.equal(form.get('checkcode'), '1234');
        assert.equal(form.get('action'), 'login');
        assert.equal(form.get('usecookie'), omitCaptchaControls ? '31536000' : '315360000');
        if (omitCaptchaControls) persistentSelectUsed = form.get('usecookie') === '31536000';
        await route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8',
          body: '<title>文库8</title><div class="main"><a href="/logout.php">退出登录</a></div>',
        });
      } else if (url.pathname === '/login.php') {
        await route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: loginHtml() });
      } else {
        await route.fulfill({ status: 204, body: '' });
      }
    });
    await page.goto(`${input.host}/login.php`, { waitUntil: 'load' });
    assert.equal(await page.evaluate(input.refreshScript), true);
    await page.waitForFunction(() => document.images[0].complete && document.images[0].naturalWidth === 2);
    const image = JSON.parse(await page.evaluate(input.imageScript));
    const canvasPng = image.ready && image.data.startsWith('data:image/png;base64,');
    assert.ok(canvasPng);
    const navigation = page.waitForNavigation({ waitUntil: 'load' });
    assert.equal(await page.evaluate(input.loginScript), true);
    await navigation;
    const authenticated = JSON.parse(await page.evaluate(input.stateScript)).authenticated;
    assert.equal(posts, 1);
    // The live login form can omit both CAPTCHA controls. Still request the
    // official image in this document and submit only this safe POST form.
    omitCaptchaControls = true;
    await page.goto(`${input.host}/login.php`, { waitUntil: 'load' });
    assert.equal(await page.locator('input[name="checkcode"]').count(), 0);
    assert.equal(await page.locator('img').count(), 0);
    assert.equal(await page.evaluate(input.refreshScript), true);
    await page.waitForFunction(() => document.images[0].complete && document.images[0].naturalWidth === 2);
    const optionalImage = JSON.parse(await page.evaluate(input.imageScript));
    const optionalFormImage = optionalImage.ready && optionalImage.data.startsWith('data:image/png;base64,');
    const secondNavigation = page.waitForNavigation({ waitUntil: 'load' });
    assert.equal(await page.evaluate(input.loginScript), true);
    await secondNavigation;
    const optionalFormAuthenticated = JSON.parse(await page.evaluate(input.stateScript)).authenticated;
    await page.goto(`${input.host}/login.php`, { waitUntil: 'load' });
    await page.evaluate(() => document.forms[0].action = 'https://unrelated.invalid/login.php');
    const foreignActionRejected = await page.evaluate(input.loginScript) === false;
    const foreignRefreshRejected = await page.evaluate(input.refreshScript) === false;
    assert.equal(await page.locator('img').count(), 0);
    assert.equal(posts, 2);
    await page.setContent('<title>Just a moment...</title><form id="challenge-form"></form>');
    const challenge = JSON.parse(await page.evaluate(input.stateScript));
    process.stdout.write(JSON.stringify({
      canvasPng, posts, sameSessionCookie, authenticated, foreignActionRejected,
      optionalFormImage, optionalFormAuthenticated, persistentSelectUsed, foreignRefreshRejected,
      challengeRejected: challenge.challenge && !challenge.authenticated,
    }));
  } finally { await browser.close(); }
}
main().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
