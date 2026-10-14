import 'dart:convert';

String biliSubmitSearchScript(String keyword) => '''(() => {
  const field = document.querySelector('#searchkey[name="searchkey"]');
  const form = field && field.form;
  if (!form || form.method.toLowerCase() !== 'post' ||
      new URL(form.action, location.href).origin !== location.origin ||
      !['/S6/','/search.html'].includes(new URL(form.action, location.href).pathname)) return false;
  field.value = ${jsonEncode(keyword)};
  field.dispatchEvent(new Event('input', {bubbles:true}));
  // A POST may stay on /search.html. Ignore the previous document's suggested
  // books until real navigation replaces this window and its pending marker.
  window.__liteTaleBiliSearchPending = true;
  if (form.requestSubmit) form.requestSubmit();
  else {
    const button = form.querySelector('[type="submit"]');
    if (!button) return false;
    button.click();
  }
  return true;
})()''';

// Access state is identified in the site's error/challenge panels, never by
// scanning a novel's prose or search result text.
const _biliAccessGuard = r'''
  function biliCheckAccess(out) {
    const panel=document.querySelector('#cf-error-details');
    const outside=node=>node&&!node.closest('#acontent,#TextContent');
    const challenge=[...document.querySelectorAll('#challenge-form,#challenge-running,.cf-turnstile,iframe[src*="challenges.cloudflare.com"]')].some(outside);
    const headline=panel&&panel.querySelector('[data-translate="block_headline"],.cf-error-overview h1,h1');
    if (outside(panel) && ((headline && (headline.getAttribute('data-translate')==='block_headline' || /blocked|access denied|拒绝访问|拒絕存取/i.test(headline.textContent))) || (!challenge && /Attention Required/i.test(document.title)))) {
      out.ready=false;out.accessDenied=true;
      out.error='原站已拒绝访问此页面，当前没有可完成的验证';return true;
    }
    const pending=!document.querySelector('#acontent,#TextContent') && /Just a moment|Checking your browser/i.test(document.title);
    if (challenge || pending) {
      out.ready=false;out.verificationRequired=true;
      out.verificationPending=pending||!!document.querySelector('#challenge-running');
      out.error='原站要求浏览器验证，请完成验证后继续';return true;
    }
    return false;
  }
''';

const biliAccessProbeScript =
    r'''(() => {''' +
    _biliAccessGuard +
    r'''
  const out={url:location.href,ready:false};biliCheckAccess(out);return JSON.stringify(out);
})()''';

const biliHomeReadyScript =
    r'''(() => {''' +
    _biliAccessGuard +
    r'''
  const out={url:location.href,ready:!!document.querySelector('#searchkey[name="searchkey"]')};
  if (biliCheckAccess(out)) return JSON.stringify(out);
  return JSON.stringify(out);
})()''';

const biliDocumentProbeScript =
    r'''(() => {''' +
    _biliAccessGuard +
    r'''
  const out={url:location.href,ready:false,html:''};
  if (biliCheckAccess(out)) return JSON.stringify(out);
  const path=location.pathname;
  let nodes=[];
  if (path==='/') {
    nodes=[...document.querySelectorAll('.index_tpic_info')];
    if (!nodes.length) {
      nodes=[...document.querySelectorAll('li.module-slide-li')].slice(0,100);
      if (document.readyState==='loading' && nodes.length<100) return JSON.stringify(out);
    }
    if (document.querySelector('.index_tpic_info')) for(const a of document.querySelectorAll('a[href]')) {
      if (a.querySelector('img') && /\/novel\/[1-9]\d*\.html$/.test(new URL(a.getAttribute('href'),location.href).pathname)) nodes.push(a);
    }
  } else if (/\/catalog$/.test(path)) {
    if (document.readyState==='loading') return JSON.stringify(out);
    nodes=[...document.querySelectorAll('h1,#volume-list,#volumes')];
  } else if (/^\/novel\/[1-9]\d*\.html$/.test(path)) {
    const title=document.querySelector('h1.book-title');
    if (title) {
      const summary=document.querySelector('#bookSummary');
      const status=document.querySelector('a.book-status');
      if(!summary || !status) return JSON.stringify(out);
      nodes=[title.closest('.book-layout'),summary,status].filter(Boolean);
    } else nodes=[...document.querySelectorAll('h1.book-name,.book-html-box,.book-side')];
  } else {
    if (document.readyState==='loading') return JSON.stringify(out);
    nodes=[...document.querySelectorAll('.rank_d_list,.pagebar,#list_content,ol.book-ol,#pagelink')];
  }
  if(!nodes.length) return JSON.stringify(out);
  out.html=nodes.map(node=>{
    const clone=node.cloneNode(true);
    clone.querySelectorAll('script,style,form,input,button,iframe').forEach(n=>n.remove());
    for(const element of [clone,...clone.querySelectorAll('*')]) for(const attr of [...element.attributes]) {
      if(attr.name.startsWith('on')) element.removeAttribute(attr.name);
    }
    return clone.outerHTML;
  }).join('\n');
  out.ready=true;return JSON.stringify(out);
})()''';

const biliSearchProbeScript =
    r'''(() => {''' +
    _biliAccessGuard +
    r'''
  const result = {url:location.href, ready:false, books:[], next:null};
  const body = document.body ? document.body.innerText : '';
  if (biliCheckAccess(result)) return JSON.stringify(result);
  if (window.__liteTaleBiliSearchPending) return JSON.stringify(result);
  if (document.readyState === 'loading' || location.pathname === '/' || !document.body) return JSON.stringify(result);
  const image = root => {
    const img = root.querySelector('img');
    return img && (img.getAttribute('data-original') || img.getAttribute('data-src') || img.getAttribute('src')) || '';
  };
  const detail = location.pathname.match(/^\/novel\/([1-9]\d*)\.html$/);
  const title = document.querySelector('h1.book-name,h1.book-title');
  if (detail && title) {
    result.books = [{nid:detail[1],title:title.innerText.trim(),image:
      (document.querySelector('meta[property="og:image"]')||{}).content ||
      ((document.querySelector('img.book-cover')||{}).src) ||
      image(document.querySelector('.book-img,.book-cover,.book-info')||document)}];
    result.ready = true; return JSON.stringify(result);
  }
  if (!['/S6/','/search.html'].includes(location.pathname)) return JSON.stringify(result);
  const seen = new Set();
  const scopes = [...document.querySelectorAll('.search-list,.search-result,.bookbox,.rank_d_list,table.grid,.book-list,#searchResult,#list_content')];
  for (const root of (scopes.length ? scopes : [document.body])) {
    if (!root) continue;
    for (const a of root.querySelectorAll('a[href]')) {
      const url = new URL(a.getAttribute('href'),location.href);
      const m = url.origin === location.origin && url.pathname.match(/^\/novel\/([1-9]\d*)\.html$/);
      const card=a.closest('.bookbox,.rank_d_list,tr,li')||a;
      const text = (card.querySelector('h4.book-title,.rank_d_b_name')||a).innerText.trim();
      if (!m || !text || seen.has(m[1])) continue;
      seen.add(m[1]); result.books.push({nid:m[1],title:text,image:image(card)});
      if (result.books.length >= 100) break;
    }
  }
  const next = [...document.querySelectorAll('a[href]')].find(a =>
    a.rel === 'next' || /^(下一页|下页|下一頁|›|»)$/.test(a.innerText.trim()));
  if (next) result.next = new URL(next.getAttribute('href'),location.href).href;
  if (/搜索间隔|搜索频繁|请.*秒后.*搜索/.test(body)) result.error='原站暂时限制搜索频率，请稍后重试';
  result.ready = result.books.length > 0 || /没有找到|未找到|无搜索结果|没有相关|查无|未搜索到|没有搜到/.test(body);
  return JSON.stringify(result);
})()''';

const biliChapterProbeScript =
    r'''(() => {''' +
    _biliAccessGuard +
    r'''
  const out = {url:location.href,ready:false,content:'',next:null};
  if (biliCheckAccess(out)) return JSON.stringify(out);
  if (document.readyState === 'loading') return JSON.stringify(out);
  const root = document.querySelector('#TextContent,#acontent');
  if (!root) return JSON.stringify(out);
  if (/[（(](?:內容加載失敗|内容加载失败)[！!]?\s*[請请](?:刷新|重新整理)(?:或(?:更換瀏覽器|更换浏览器))?[）)]\s*$/.test(root.innerText.trim().slice(-140))) {
    out.contentIncomplete=true;return JSON.stringify(out);
  }
  let count=0;
  function read(node) {
    if (++count > 30000) throw new Error('正文节点过多');
    if (node.nodeType === 3) {
      const text=node.textContent;
      return !text.trim() && /[\r\n]/.test(text) ? '' : text;
    }
    if (node.nodeType !== 1) return '';
    const tag=node.tagName.toLowerCase(), css=getComputedStyle(node);
    if (['script','style','iframe','noscript','button','form'].includes(tag) ||
        css.display==='none' || css.visibility==='hidden' || css.opacity==='0' || css.fontSize==='0px' ||
        /(?:google|ad-slot|dag)/i.test(node.className||'') ||
        /hidden-images|show-more-images/.test(node.id||'')) return '';
    if (tag==='br') return '\n';
    if (tag==='p' && css.position==='absolute') {
      const bounds=node.getBoundingClientRect();
      // The site renders decoy copies at zero size. They have normal color and
      // display values, so display:none alone does not describe visible prose.
      // Keep genuine repeated paragraphs; filter only this unpainted geometry.
      if (bounds.width===0 && bounds.height===0) return '';
    }
    if (tag==='img') {
      const raw=node.getAttribute('data-src')||node.getAttribute('data-original')||node.getAttribute('src');
      if (!raw) return '';
      const url=new URL(raw,location.href);
      return /^https?:$/.test(url.protocol)&&!url.username&&!url.password
        ? '<!--image-->'+url.href+'<!--image-->' : '';
    }
    const text=[...node.childNodes].map(read).join('');
    return text + (['p','div','section'].includes(tag)?'\n':'');
  }
  try { out.content=read(root).trim(); } catch (_) { out.error='章节结构过大'; }
  const match=location.pathname.match(/^\/novel\/([1-9]\d*)\/([1-9]\d*)(?:_\d+)?\.html$/);
  if (match) {
    const next=[...document.querySelectorAll('a[href]')].find(a=>{
      if (!/^(下一页|下一頁)$/.test(a.innerText.trim())) return false;
      const url=new URL(a.getAttribute('href'),location.href);
      return url.origin===location.origin &&
        new RegExp('^/novel/'+match[1]+'/'+match[2]+'_[1-9][0-9]*\.html$').test(url.pathname);
    });
    if (next) out.next=new URL(next.getAttribute('href'),location.href).href;
    if (!out.next && typeof ReadParams!=='undefined' && typeof ReadParams.url_next==='string') {
      const url=new URL(ReadParams.url_next,location.href);
      if (url.origin===location.origin &&
          new RegExp('^/novel/'+match[1]+'/'+match[2]+'_[1-9][0-9]*\.html$').test(url.pathname)) out.next=url.href;
    }
  }
  out.ready=!!out.content; return JSON.stringify(out);
})()''';
