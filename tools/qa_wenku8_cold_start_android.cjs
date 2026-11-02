// Time a fresh LiteTale process using only public document timing metadata.
// Never read cookies, login forms, response bodies, account data or user IDs.
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const adbPath = 'D:/Codex-Migrated/Android/Sdk/platform-tools/adb.exe';
const adb = (...args) => execFileSync(adbPath, ['-s', 'emulator-5554', ...args], { encoding: 'utf8', timeout: 15000 }).trim();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function main() {
  const output = process.argv[2];
  if (!output) throw Error('Report path required');
  const started = performance.now();
  adb('shell', 'am', 'force-stop', 'io.github.metammy07.novels');
  adb('shell', 'am', 'start', '-W', '-n', 'io.github.metammy07.novels/opensource.wild.MainActivity');
  const appPid = adb('shell', 'pidof', 'io.github.metammy07.novels');
  if (!/^\d+$/.test(appPid)) throw Error('Expected one app process');
  let target;
  for (let i = 0; i < 50; i++) {
    try {
      adb('forward', 'tcp:9335', 'localabstract:webview_devtools_remote_' + appPid);
      const targets = await (await fetch('http://127.0.0.1:9335/json/list')).json();
      target = targets.find(t => t.type === 'page' && (t.url === 'about:blank' || t.url.startsWith('https://www.wenku8.net/')));
      if (target) break;
    } catch (_) {}
    await pause(100);
  }
  if (!target) throw Error('App public reader context not found');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const pending = new Map(); let serial = 0;
  socket.onmessage = event => { const m = JSON.parse(event.data), p = pending.get(m.id); if (!p) return;
    pending.delete(m.id); clearTimeout(p.timer); m.error ? p.reject(Error('CDP command failed')) : p.resolve(m.result); };
  const call = (method, params) => new Promise((resolve, reject) => { const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(Error('CDP command timeout')); }, 6000);
    pending.set(id, { resolve, reject, timer }); socket.send(JSON.stringify({ id, method, params })); });
  let state, ready = false;
  try {
    for (let i = 0; i < 160; i++) {
      const r = await call('Runtime.evaluate', { returnByValue: true, expression: `JSON.stringify({
        parked:window.__liteTaleReadContext===true && window.__liteTaleDocumentRead===null,
        navigation:performance.getEntriesByType('navigation').map(n=>({responseMs:Math.round(n.responseStart),bodyMs:Math.round(n.responseEnd),domMs:Math.round(n.domContentLoadedEventEnd)})),
        homeFetches:performance.getEntriesByType('resource').filter(n=>{try{var u=new URL(n.name);return u.origin==='https://www.wenku8.net'&&u.pathname==='/'&&n.initiatorType==='fetch'}catch(_){return false}}).map(n=>({durationMs:Math.round(n.duration),responseEndMs:Math.round(n.responseEnd)}))
      })` });
      if (typeof r.result?.value === 'string') state = JSON.parse(r.result.value);
      if (state?.parked) { ready = true; break; }
      await pause(150);
    }
    const report = { ready, startupUntilBrowserReadyMs: Math.round(performance.now() - started), ...state };
    fs.writeFileSync(output, JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
    if (!ready) process.exitCode = 1;
  } finally { socket.close(); }
}
main().catch(e => { console.error(e.message); process.exitCode = 1; });
