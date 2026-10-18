import 'dart:convert';

const wenku8EmptyReadContextHtml =
    '<!DOCTYPE html><html><head>'
    '<meta charset="utf-8"></head><body><script>'
    'window.__liteTaleReadContext=true;</script></body></html>';

String wenku8DocumentContextReadyScript(String host) => '''
// litetale-document-context-ready
location.origin===${jsonEncode(host)} && window.__liteTaleReadContext===true
''';

/// Fetch only public reading documents in an already established browser
/// session. Parse in an inert document: no covers, stylesheets or site scripts
/// are loaded, and only the existing validated book payload leaves WebView.
String wenku8DocumentReadScript({
  required String host,
  required Uri target,
  required String extraction,
  required int timeoutMs,
}) => '''
(function(host, target, timeoutMs) {
  // litetale-document-start
  if (location.origin !== host || !window.__liteTaleReadContext ||
      new URL(target).origin !== host || typeof fetch !== 'function' ||
      typeof TextDecoder !== 'function' || typeof AbortController !== 'function') return false;
  var controller = new AbortController();
  var state = {pending:true, cancel:function(){controller.abort();}};
  window.__liteTaleDocumentRead = state;
  var timer = setTimeout(function(){controller.abort();}, timeoutMs);
  (async function() {
    try {
      var response = await fetch(target, {method:'GET', mode:'same-origin',
        credentials:'same-origin', redirect:'error', signal:controller.signal});
      if (response.url !== target) { state.error='navigation'; return; }
      if (!response.ok) {state.status=response.status; return;}
      if (!/text\\/html/i.test(response.headers.get('content-type') || '')) {
        state.error='document'; return;
      }
      var reader=response.body.getReader(), chunks=[], length=0;
      while (true) {
        var part=await reader.read();
        if (part.done) break;
        length+=part.value.byteLength;
        if (length>1024*1024) {controller.abort();state.error='size';return;}
        chunks.push(part.value);
      }
      var bytes=new Uint8Array(length), offset=0;
      chunks.forEach(function(chunk){bytes.set(chunk,offset);offset+=chunk.byteLength;});
      var header=response.headers.get('content-type') || '';
      var prefix=new TextDecoder('gbk').decode(bytes.subarray(0,4096));
      var charset=/charset\\s*=\\s*["']?([a-zA-Z0-9-]+)/i.exec(header) ||
        /<meta[^>]*charset\\s*=\\s*["']?([a-zA-Z0-9-]+)/i.exec(prefix);
      var encoding=charset ? charset[1].toLowerCase() : 'gbk';
      if (!['gbk','gb2312','gb18030','utf-8','utf8'].includes(encoding)) {
        state.error='encoding';return;
      }
      var html=new TextDecoder(encoding).decode(bytes);
      var parsed=new DOMParser().parseFromString(html,'text/html');
      state.payload=(function(document,location) {return $extraction; })(parsed,new URL(target));
      state.url=target;
      // Keep the real site's form in the browser, including its hidden fields.
      // It is sanitized when parked and never sent through the Dart bridge.
      var form=Array.from(parsed.forms).find(function(f) {
        if(!f.querySelector('[name="searchkey"]') || !f.querySelector('[name="searchtype"]') ||
           f.querySelector('input[type="password"]')) return false;
        var action=new URL(f.getAttribute('action') || target,target);
        return action.origin===host && !action.search && !action.hash &&
          ['/so.php','/modules/article/search.php'].includes(action.pathname);
      });
      if(form) {
        var kept=form.cloneNode(true);
        kept.setAttribute('action',new URL(form.getAttribute('action') || target,target).href);
        window.__liteTaleSearchForm=kept;
      }
    } catch (error) {
      state.error=error.name==='AbortError' ? 'timeout' : 'navigation';
    } finally {
      clearTimeout(timer);state.pending=false;delete state.cancel;
    }
  })();
  return true;
})(${jsonEncode(host)},${jsonEncode(target.toString())},$timeoutMs)
''';

const wenku8DocumentReadStateScript = '''
(function() {
  // litetale-document-state
  var state=window.__liteTaleDocumentRead;
  if (!state) return JSON.stringify({error:'navigation'});
  return JSON.stringify({pending:state.pending,error:state.error,
    status:state.status,url:state.url,payload:state.payload});
})()
''';

/// Keep a tiny same-origin document for the next GET. Retain only the site's
/// actual search form, inside WebView, so GBK searches still follow its normal
/// form/redirect flow without an extra home visit. Authentication pages never
/// use this path. Navigations, logout and CAPTCHA still drain to about:blank.
String wenku8ParkDocumentScript(String host) => '''
(function(host) {
  // litetale-document-park
  if (location.origin!==host) return false;
  var active=window.__liteTaleDocumentRead;
  if(active && active.cancel) active.cancel();
  var form=window.__liteTaleSearchForm || Array.from(document.forms).find(function(f) {
    if (!f.querySelector('[name="searchkey"]') || !f.querySelector('[name="searchtype"]') ||
        f.querySelector('input[type="password"]')) return false;
    var action=new URL(f.getAttribute('action') || location.href,location.href);
    return action.origin===host && !action.search && !action.hash &&
      ['/so.php','/modules/article/search.php'].includes(action.pathname);
  });
  var kept=form ? form.cloneNode(true) : null;
  if(kept) {
    kept.setAttribute('action',new URL(form.getAttribute('action') || location.href,location.href).href);
    kept.querySelector('[name="searchkey"]').value='';
    kept.querySelectorAll('script,style,link,img,iframe,object,embed').forEach(function(n){n.remove();});
    [kept].concat(Array.from(kept.querySelectorAll('*'))).forEach(function(n){
      Array.from(n.attributes).forEach(function(a){
        if (/^on/i.test(a.name) || a.name==='style') n.removeAttribute(a.name);
      });
    });
    kept.hidden=true;
  }
  window.stop();
  document.open();
  document.write('<!DOCTYPE html><html><head><meta charset="utf-8"></head><body></body></html>');
  document.close();
  if(kept) document.body.appendChild(kept);
  window.__liteTaleDocumentRead=null;
  window.__liteTaleSearchForm=null;
  window.__liteTaleNavigating=false;
  window.__liteTaleReadContext=true;
  return true;
})(${jsonEncode(host)})
''';
