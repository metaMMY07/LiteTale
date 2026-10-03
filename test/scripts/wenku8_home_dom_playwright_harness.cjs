const path = require('node:path');
const fs = require('node:fs');

async function readStdin() {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  return JSON.parse(input);
}

async function main() {
  const input = await readStdin();
  const modulePath = process.env.PLAYWRIGHT_MODULE_PATH;
  if (!modulePath) throw new Error('PLAYWRIGHT_MODULE_PATH is required');
  const { chromium } = require(path.resolve(modulePath));
  const executablePath = process.env.PLAYWRIGHT_EXECUTABLE_PATH;
  if (!executablePath || !fs.existsSync(executablePath)) {
    throw new Error('PLAYWRIGHT_EXECUTABLE_PATH must point to an installed Chromium or Edge executable');
  }
  const browser = await chromium.launch({ headless: true, executablePath });
  try {
    const results = [];
    for (const item of input.cases) {
      const page = await browser.newPage();
      await page.route('**/*', async (route) => {
        const request = route.request();
        if (request.isNavigationRequest() && request.url() === item.url) {
          await route.fulfill({
            status: 200,
            contentType: 'text/html; charset=utf-8',
            body: item.html,
          });
        } else {
          // No external site or cover is fetched; only the document DOM is used.
          await route.fulfill({ status: 204, body: '' });
        }
      });
      await page.goto(item.url, { waitUntil: 'domcontentloaded' });
      results.push(await page.evaluate(input.script));
      await page.close();
    }
    process.stdout.write(JSON.stringify(results));
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
