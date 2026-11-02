// Inspect session health in an idle, installed Android WebView. Return booleans
// only; never read cookies, credentials, account labels or raw page content.
const fs = require('node:fs');
const path = require('node:path');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function main() {
  const watch = process.argv[2] === 'watch';
  const targets = await (await fetch('http://127.0.0.1:9335/json/list')).json();
  const target = targets.find(item => item.type === 'page' &&
    (item.url === 'about:blank' || (watch && item.url.startsWith('https://www.wenku8.net/'))));
  if (!target) throw new Error('No suitable WebView; do not interfere with an app request');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const pending = new Map();
  const events = [];
  const started = Date.now();
  const report = watch ? process.argv[3] : process.argv[2];
  const name = report || 'session-health';
  if (!/^[a-z0-9-]+$/.test(name)) throw new Error('Invalid report name');
  const destination = path.resolve(`build/wenku8-0.1.14/${name}.json`);
  let serial = 0;
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (watch && message.method === 'Network.requestWillBeSent' && message.params.type === 'Document') {
      const request = message.params.request;
      const url = new URL(request.url);
      const kind = url.origin === 'https://www.wenku8.net' ?
        url.pathname === '/' ? 'home' : url.pathname === '/login.php' ? 'login' :
        url.pathname === '/logout.php' ? 'logout' :
        url.pathname.startsWith('/book/') ? 'detail' :
        url.pathname.startsWith('/modules/article/') ? 'catalog' : 'other' : 'other-origin-or-blank';
      // Never serialize request URL, query, headers, postData or response body.
      events.push({ seconds: Number(((Date.now() - started) / 1000).toFixed(1)),
        kind, method: request.method });
      fs.writeFileSync(destination, JSON.stringify({ events, credentialsRecorded: false }, null, 2));
      return;
    }
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    if (message.error) waiter.reject(new Error('CDP request failed'));
    else waiter.resolve(message.result);
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timed out')); }, 10000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
  try {
    if (watch) {
      await call('Network.enable');
      console.log('Bounded document-event monitor connected; no credentials or cookies recorded');
      const seconds = Number(process.argv[4] || 60);
      if (!Number.isFinite(seconds) || seconds < 1 || seconds > 180) throw new Error('Invalid duration');
      await new Promise(resolve => {
        const timer = setTimeout(resolve, seconds * 1000);
        socket.addEventListener('close', () => { clearTimeout(timer); resolve(); }, { once: true });
      });
      fs.writeFileSync(destination, JSON.stringify({ events, credentialsRecorded: false }, null, 2));
      console.log(JSON.stringify({ documentEvents: events.length,
        logoutRequests: events.filter(event => event.kind === 'logout').length }));
      return;
    }
    await call('Page.navigate', { url: 'https://www.wenku8.net/' });
    let result;
    for (let attempt = 0; attempt < 60; attempt++) {
      await delay(500);
      const response = await call('Runtime.evaluate', { returnByValue: true, expression: `(() => {
        const sameOrigin = location.origin === 'https://www.wenku8.net';
        const loginForm = !!document.querySelector('form input[name="username"]') &&
                          !!document.querySelector('form input[name="password"]');
        const challenge = !!document.querySelector('#challenge-form,#cf-challenge-running,.cf-browser-verification,#cf-wrapper') ||
          /just a moment|attention required|sorry, you have been blocked/.test((document.title || '').toLowerCase());
        return { ready: document.readyState === 'complete' && location.href !== 'about:blank',
          sameOrigin, challenge, loginForm,
          authenticated: sameOrigin && !challenge && !loginForm && !!document.querySelector('a[href*="logout.php"]'),
          redirectedToLogin: sameOrigin && location.pathname === '/login.php',
          publicBookLinksPresent: !!document.querySelector('a[href*="/book/"]') };
      })()` });
      if (response.exceptionDetails) throw new Error('Session health inspection failed');
      result = response.result.value;
      if (result?.ready) break;
    }
    if (!result?.ready) throw new Error('Session health page timed out');
    fs.writeFileSync(destination, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  } finally {
    if (!watch) await call('Page.navigate', { url: 'about:blank' });
    else if (socket.readyState === WebSocket.OPEN) await call('Network.disable');
    socket.close();
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
