// Installed-release QA. Intercepts only a public Wenku8 detail GET in our app.
// Never reads/records cookies, headers, account DOM, passwords or book text.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const adb = 'D:/Codex-Migrated/Android/Sdk/platform-tools/adb.exe';
const python = 'C:/Users/30622/AppData/Local/Programs/Python/Python312/python.exe';
const packageName = 'io.github.metammy07.novels';
const out = path.resolve(process.argv[2] || 'build/qa/wenku8-rate-limit-fix5/android');
const mode = process.argv[3] || '429';
if(!['429','stall'].includes(mode)) throw new Error('Expected 429 or stall');
fs.mkdirSync(out,{recursive:true});
function device(...args) { return execFileSync(adb,['-s','emulator-5554',...args],{timeout:40000}); }
function ui(code) {
  return execFileSync(python,['-X','utf8','-c',`import sys;sys.path.insert(0,'tools');import qa_settings_android as q;${code}`],
    {cwd:path.resolve(__dirname,'..'),timeout:45000,encoding:'utf8'});
}
const pause = ms => new Promise(resolve => setTimeout(resolve,ms));
async function main() {
  const pid = device('shell','pidof',packageName).toString().trim();
  if(!/^\d+$/.test(pid)) throw new Error('Start LiteTale discovery before running this QA');
  device('forward','tcp:9335','localabstract:webview_devtools_remote_'+pid);
  const targets = await (await fetch('http://127.0.0.1:9335/json/list')).json();
  const target = targets.find(t => t.type==='page' && (t.url==='about:blank' || t.url.startsWith('https://www.wenku8.net/')));
  if(!target) throw new Error('No app Wenku8 renderer');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  const waiting = new Map(), requests = [];
  let serial=0, intercepted=0, faultEnabled=true, firstFaultAt;
  const started=performance.now();
  function call(method,params={}) {
    return new Promise((resolve,reject)=>{
      const id=++serial;
      const timer=setTimeout(()=>{waiting.delete(id);reject(new Error('CDP command timeout'));},5000);
      waiting.set(id,{resolve,reject,timer}); socket.send(JSON.stringify({id,method,params}));
    });
  }
  const jobs=[];
  socket.onmessage = event => {
    const message=JSON.parse(event.data), p=message.params;
    if(message.id) {
      const pending=waiting.get(message.id); if(!pending) return;
      waiting.delete(message.id);clearTimeout(pending.timer);
      message.error ? pending.reject(new Error(message.error.message)) : pending.resolve(message.result);
    } else if(message.method==='Fetch.requestPaused') {
      const url=new URL(p.request.url);
      if(url.origin!=='https://www.wenku8.net' || !/^\/book\/\d+\.htm$/.test(url.pathname) || p.request.method!=='GET') {
        jobs.push(call('Fetch.continueRequest',{requestId:p.requestId})); return;
      }
      requests.push({pathname:url.pathname,atMs:Math.round(performance.now()-started)});
      if(!faultEnabled) {jobs.push(call('Fetch.continueRequest',{requestId:p.requestId}));return;}
      intercepted++; firstFaultAt ??= performance.now();
      if(mode==='429') jobs.push(call('Fetch.fulfillRequest',{requestId:p.requestId,responseCode:429,
        responseHeaders:[{name:'Content-Type',value:'text/html; charset=utf-8'},{name:'Retry-After',value:'15'}],
        body:Buffer.from('<title>Too Many Requests</title><h1>429 Too Many Requests</h1>').toString('base64')}));
      // Stall mode deliberately withholds the public response. The app's
      // AbortController must end its own spinner; this is not a live outage.
    }
  };
  try {
    await call('Fetch.enable',{patterns:[{urlPattern:'https://www.wenku8.net/book/*',requestStage:'Request'}]});
    // UI calls run in a child process asynchronously: blocking exec here would
    // prevent this process from delivering the controlled HTTP response.
    const {spawn}=require('node:child_process');
    function asyncUi(code) {return new Promise((resolve,reject)=>{
      const child=spawn(python,['-X','utf8','-c',`import sys;sys.path.insert(0,'tools');import qa_settings_android as q;${code}`],{cwd:path.resolve(__dirname,'..')});
      let errors='';child.stderr.on('data',b=>{errors+=b.toString();});
      child.on('exit',code=>code===0?resolve():reject(new Error(errors || 'UI check failed')));
    });}
    await asyncUi("q.tap('魔法少女育成计划')");
    await asyncUi(`q.require('${mode==='429'?'HTTP 429':'文库8加载超时'}')`);
    const failedAfterMs=Math.round(performance.now()-firstFaultAt);
    if(intercepted!==1) throw new Error('A failed read repeated its GET');
    fs.writeFileSync(path.join(out,mode+'-error.png'),device('exec-out','screencap','-p'));
    if(mode==='429') {
      await asyncUi("q.tap('重新加载');q.require('HTTP 429')");
      if(intercepted!==1) throw new Error('Manual retry ignored Retry-After');
      const left=15000-(performance.now()-firstFaultAt)+1000;
      if(left>0) await pause(left);
    }
    faultEnabled=false;
    await call('Fetch.disable');
    await asyncUi("q.tap('重新加载');q.require('简介')");
    const result={mode,fixture:true,firstFailureAfterMs:failedAfterMs,intercepted,
      repeatedDuringCooldown:false,realRetryDetailLoaded:true,publicRequests:requests,
      testSubmittedLoginOrShelfWrite:false,appDataCleared:false};
    fs.writeFileSync(path.join(out,mode+'-checks.json'),JSON.stringify(result,null,2));
    console.log(JSON.stringify(result));
    fs.writeFileSync(path.join(out,mode+'-recovered-detail.png'),device('exec-out','screencap','-p'));
  } finally {
    await Promise.allSettled(jobs);
    try {await call('Fetch.disable');} catch(_) {}
    socket.close();device('forward','--remove','tcp:9335');
  }
}
main().catch(error=>{console.error(error.stack || error);process.exitCode=1;});
