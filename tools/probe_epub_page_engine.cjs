// Local Chromium evidence for the exact adapter shipped in the APK.
const fs=require('fs'),path=require('path');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE_PATH);
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH});
 const root=path.resolve('build/research/epub-css-engine-runtime');
 const books=JSON.parse(fs.readFileSync(path.join(root,'index.json')));
 const report=[];
 const userFontTest=process.argv.includes('--user-font');
 const fallbackTest=process.argv.includes('--font-fallback');
 for(let b=0;b<books.length;b++) {
  if(userFontTest && b!==1)continue;
  if(fallbackTest && b!==3)continue;
  const indexes=fallbackTest ? [1] : userFontTest ? [11] : process.argv.includes('--all') ? books[b].chapters.map(c=>c.index) : [0,1,2,3,4];
  for(const i of indexes) {
   const chapter=books[b].chapters[i]; if(!chapter)continue;
   const page=await browser.newPage({viewport:{width:640,height:900}});
   const errors=[],requests=[],fontDiagnostics=[];page.on('pageerror',e=>errors.push(String(e)));
   page.on('console',m=>{if(/OTS parsing error|Failed to decode downloaded font|Access to font/.test(m.text()))fontDiagnostics.push(m.text());});
   await page.route('**/*',async route=>{
    const url=new URL(route.request().url());
    if(url.origin!=='https://litetale-epub.invalid'){requests.push(url.href);return route.abort();}
    let file;
    if(url.pathname==='/chapter') file=path.join(chapter.path,'chapter.html');
    else if(url.pathname.startsWith('/resource/'))file=path.join(chapter.path,path.basename(url.pathname));
    else if(url.pathname==='/reader-serif.ttf')file=path.resolve('lib/assets/fonts/LXGWNeoZhiSongPlus.ttf');
    else if(url.pathname==='/paginator.js')file=path.resolve('lib/assets/epub_foliate_paginator.js');
    else if(url.pathname==='/engine.js')file=path.resolve('lib/assets/epub_page_engine.js');
    else if(url.pathname==='/user-font' && userFontTest)file=path.resolve('build/qa/epub-css-engine/user-font.ttf');
    else if(url.pathname==='/index')return route.fulfill({contentType:'text/html',body:`<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><script type=module src=/paginator.js></script><script src=/engine.js></script>`});
    if(!file || !fs.existsSync(file))return route.fulfill({status:404,body:''});
    const ext=path.extname(file);const mime=({'.html':'text/html','.js':'text/javascript','.ttf':'font/ttf','.otf':'font/otf','.jpg':'image/jpeg','.png':'image/png','.woff':'font/woff','.woff2':'font/woff2'})[ext]||'application/octet-stream';
    return route.fulfill({contentType:mime,body:fs.readFileSync(file),headers:{'access-control-allow-origin':'https://litetale-epub.invalid'}});
   });
   await page.goto('https://litetale-epub.invalid/index');
   await page.waitForFunction(()=>window.startEpub && customElements.get('foliate-paginator'));
   const start=Date.now();
   await page.evaluate(options=>{startEpub(options)}, {fixed:chapter.fixed,width:640,height:900,left:76,top:48,
    contentWidth:488,contentHeight:814,fontSize:20,lineHeight:1.6,paragraphGap:12,paper:'#ffffff',ink:'#222222',userFont:userFontTest,chapterUrl:'https://litetale-epub.invalid/chapter'});
   await page.waitForFunction(()=>window.EpubEngine.ready||window.EpubEngine.error,{},{timeout:30000});
   const result=await page.evaluate(()=>{
    const p=document.querySelector('foliate-paginator');
    const doc=p?.getContents()[0]?.doc || document.querySelector('iframe')?.contentDocument;
    const rect=p?{width:p.size,height:doc.defaultView.innerHeight}:null;
    return {ready:EpubEngine.ready,error:EpubEngine.error,pages:EpubEngine.pages,textLength:EpubEngine.textLength,
     geometry:rect?{width:rect.width,height:rect.height}:null,
     fonts:doc?[...doc.fonts].map(f=>({family:f.family,status:f.status})):[],
     bundledFontFamilies:doc?[...doc.styleSheets].flatMap(s=>[...s.cssRules]).filter(r=>r.type===CSSRule.FONT_FACE_RULE && r.style.getPropertyValue('src').includes('/resource/')).map(r=>r.style.getPropertyValue('font-family').replace(/["']/g,'')):[],
     brokenImages:doc?[...doc.images].filter(i=>!i.complete||!i.naturalWidth).length:0,
     ruby:doc?.querySelectorAll('ruby').length || 0};
   });
   if(result.ready) await page.screenshot({path:path.join(root,`${b}-${i}.png`)});
   if(result.geometry && (Math.abs(result.geometry.width-488)>1 || Math.abs(result.geometry.height-814)>1)) errors.push('incorrect content viewport');
   if(result.brokenImages) errors.push('unloaded publication image');
   if(result.fonts.some(f=>f.status==='error' && result.bundledFontFamilies.includes(f.family.replace(/["']/g,'')))) errors.push('bundled font failed');
   if(userFontTest && !result.fonts.some(f=>f.family==='LiteTaleUser' && f.status==='loaded'))errors.push('custom reader font did not load');
   if(fallbackTest && !result.fonts.some(f=>f.family==='LiteTaleDefault' && f.status==='loaded'))errors.push('Song glyph fallback did not load');
   if(result.pages.some((p,i)=>p.end<p.start || i&&p.start<result.pages[i-1].start)) errors.push('invalid content anchors');
   if(result.pages.length>1) {
    const first=await page.screenshot();
    await page.evaluate(index=>EpubEngine.select(index),Math.floor(result.pages.length/2));
    const middle=await page.screenshot({path:path.join(root,`${b}-${i}-middle.png`)});
    if(first.equals(middle))errors.push('distinct pages painted identically');
   }
   report.push({book:b,chapter:i,href:chapter.href,fixed:chapter.fixed,ms:Date.now()-start,...result,errors,requests,fontDiagnostics});
   console.log(JSON.stringify({book:b,chapter:i,ready:result.ready,error:result.error,count:result.pages.length,ms:Date.now()-start,errors}));
   await page.close();
  }
 }
 fs.writeFileSync(path.join(root,fallbackTest?'font-fallback-report.json':userFontTest?'user-font-report.json':'browser-report.json'),JSON.stringify(report,null,2));
 await browser.close();
 if(report.some(x=>!x.ready||x.errors.length||x.requests.length))process.exitCode=1;
})().catch(e=>{console.error(e);process.exit(1)});
