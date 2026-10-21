/* LiteTale offline adapter for foliate-js Paginator (MIT, pinned in NOTICE).
 * Only this parent document runs JavaScript. The chapter CSP forbids scripts.
 * One engine instance owns one spine resource, allowing mixed-layout books.
 */
(() => {
  const state = window.EpubEngine = {ready: false, error: null, pages: []};
  const frames = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const waitResources = async doc => {
    await doc.fonts.ready;
    await Promise.all([...doc.images].map(img => img.complete ? null : new Promise(resolve => {
      img.addEventListener('load', resolve, {once: true});
      img.addEventListener('error', resolve, {once: true});
    })));
    await frames();
  };
  // Named publisher fonts are often Latin-only subsets. Chromium's Android
  // generic serif has no CJK serif fallback on some devices. Keep every source
  // face first, then use our bundled Song for missing glyphs. Explicit sans,
  // monospace and decorative generic families keep their original fallback.
  const fontFallbacks = doc => {
    const styleFallback = style => {
      const family=style.getPropertyValue('font-family');
      if(!family || /LiteTaleDefault|sans-serif|monospace|cursive|fantasy/i.test(family) ||
        /^(inherit|initial|unset|revert(?:-layer)?)$/i.test(family.trim())) return;
      const value=family.replace(/(?:^|,)\s*serif\s*(?=,|$)/ig,'').trim().replace(/^,\s*|\s*,$/g,'');
      style.setProperty('font-family', `${value?value+', ':''}LiteTaleDefault, serif`,style.getPropertyPriority('font-family'));
    };
    const visit = rules => {
      for(const rule of rules) {
        if(rule.type===1) styleFallback(rule.style);
        else if(rule.cssRules) visit(rule.cssRules);
      }
    };
    for(const sheet of doc.styleSheets) visit(sheet.cssRules);
    for(const el of doc.querySelectorAll('[style]')) styleFallback(el.style);
  };
  window.startEpub = async options => {
    try {
      document.body.style.cssText = `margin:0;overflow:hidden;background:${options.paper};color:${options.ink}`;
      const host = document.createElement('div');
      Object.assign(host.style, {position:'absolute', inset:'0', overflow:'hidden'});
      document.body.append(host);
      const before = `@font-face{font-family:LiteTaleDefault;src:url('https://litetale-epub.invalid/reader-serif.ttf')}
        html{font-size:${options.fixed?16:options.fontSize}px;color:${options.ink};-webkit-text-size-adjust:100%;}
        body{font-family:LiteTaleDefault,serif;line-height:${options.fixed?'normal':options.lineHeight};}
        img,svg{max-width:100%;} p{margin-block:0 ${options.paragraphGap}px;}`;
      const after = `html,body{background-color:transparent!important;}body{color:${options.ink}!important;}
        ${options.fixed ? '' : `html{font-size:${options.fontSize}px!important;}`}
        *{animation:none!important;transition:none!important;caret-color:transparent!important;}
        ${options.userFont && !options.fixed ? "@font-face{font-family:LiteTaleUser;src:url('https://litetale-epub.invalid/user-font')} body,p,li{font-family:LiteTaleUser,LiteTaleDefault,serif!important;}" : ''}`;
      const applyStyle = doc => {
        const first = doc.createElement('style'); first.textContent=before; doc.head.prepend(first);
        const last = doc.createElement('style'); last.textContent=after; doc.head.append(last);
        fontFallbacks(doc);
        doc.addEventListener('click', e => e.preventDefault());
      };
      let paginator, fixedFrame, doc, lastRange;
      if (options.fixed) {
        fixedFrame = document.createElement('iframe');
        fixedFrame.setAttribute('sandbox','allow-same-origin');
        fixedFrame.style.cssText='position:absolute;border:0;transform-origin:0 0;';
        host.append(fixedFrame);
        await new Promise(resolve => {fixedFrame.onload=resolve;fixedFrame.src=options.chapterUrl;});
        doc=fixedFrame.contentDocument;
        applyStyle(doc);
        const viewport=doc.querySelector('meta[name=viewport]')?.content || '';
        const box=doc.querySelector('svg')?.getAttribute('viewBox')?.split(/[ ,]+/).map(Number);
        const width=Number(viewport.match(/width\s*=\s*([\d.]+)/)?.[1]) || box?.[2] || options.width;
        const height=Number(viewport.match(/height\s*=\s*([\d.]+)/)?.[1]) || box?.[3] || options.height;
        if (!(width>0 && height>0 && width<=20000 && height<=20000)) throw Error('invalid fixed viewport');
        fixedFrame.style.width=`${width}px`;fixedFrame.style.height=`${height}px`;
        const scale=Math.min(options.width/width,options.height/height);
        fixedFrame.style.transform=`translate(${(options.width-width*scale)/2}px,${(options.height-height*scale)/2}px) scale(${scale})`;
        await waitResources(doc);
        state.text=doc.body.textContent;
        state.textLength=state.text.length;
        state.pages=[{start:0,end:state.textLength}];
      } else {
        paginator=document.createElement('foliate-paginator');
        paginator.style.cssText=`position:absolute;left:${options.left}px;top:${options.top}px;width:${options.contentWidth}px;height:${options.contentHeight}px;`;
        for(const [key,value] of Object.entries({'flow':'paginated','gap':'0%','margin':'0px','max-column-count':'1',
          'max-inline-size':`${options.contentWidth}px`,'max-block-size':`${options.contentHeight}px`})) paginator.setAttribute(key,value);
        host.append(paginator);
        paginator.setStyles([before,after]);
        // The upstream EPUB loader normally emits the CSS transformation event.
        // Our sanitized, self-contained chapter bypasses that loader, so apply
        // the same paged-media/viewport normalization before its first layout.
        const normalize = css => css.replace(/(?<=[{\s;])-epub-/gi,'')
          .replace(/(\d*\.?\d+)vw/gi,(_,n)=>`${Number(n)*options.contentWidth/100}px`)
          .replace(/(\d*\.?\d+)vh/gi,(_,n)=>`${Number(n)*options.contentHeight/100}px`)
          .replace(/page-break-(after|before|inside)\s*:/gi,(_,p)=>`-webkit-column-break-${p}:`)
          .replace(/break-(after|before|inside)\s*:\s*(avoid-)?page/gi,(_,p,a)=>`break-${p}:${a||''}column`);
        paginator.addEventListener('load',e=>{
          for(const style of e.detail.doc.querySelectorAll('style')) style.textContent=normalize(style.textContent);
          for(const el of e.detail.doc.querySelectorAll('[style]')) el.setAttribute('style',normalize(el.getAttribute('style')));
          fontFallbacks(e.detail.doc);
        });
        paginator.addEventListener('relocate', e => {lastRange=e.detail.range;});
        paginator.open({dir: options.direction || 'ltr', sections:[{id:'chapter',linear:'yes',load:()=>options.chapterUrl}]});
        await paginator.goTo({index:0,anchor:()=>0});
        doc=paginator.getContents()[0].doc;
        await waitResources(doc);
        await paginator.goTo({index:0,anchor:()=>0});
        await frames();
        const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT,{acceptNode(node){
          return node.parentElement.closest('rt,rp,style,script') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
        }});
        const nodes=[]; const prefix=new Map(); let total=0,node;
        while((node=walker.nextNode())) {prefix.set(node,total);nodes.push(node);total+=node.length;}
        const offset=(container,position)=>{
          if(prefix.has(container)) return prefix.get(container)+position;
          const point=doc.createRange();point.setStart(container,position);point.collapse(true);
          let result=0;
          for(const node of nodes) {
            if(point.comparePoint(node,node.length)>0) break;
            result=prefix.get(node)+node.length;
          }
          return result;
        };
        const count=Math.max(1,paginator.pages-2);
        if(count>12000) throw Error('too many pages');
        for(let i=0;i<count;i++) {
          await paginator.goTo({index:0,anchor:()=>count===1?0:i/(count-1)});
          state.pages.push(lastRange ? {start:offset(lastRange.startContainer,lastRange.startOffset),
            end:offset(lastRange.endContainer,lastRange.endOffset)} : {start:0,end:0});
        }
        // Absolute positioning / nested columns can have a visible page while
        // the upstream text-range probe is empty. Keep those pages and give
        // them a distinct trailing anchor instead of resuming on page zero.
        let previousStart=-1, previousEnd=0;
        for(let i=0;i<state.pages.length;i++) {
          const p=state.pages[i];
          if(p.end<=p.start || p.start<previousStart) {
            p.start=Math.max(previousEnd,previousStart+1);
            p.end=Math.max(p.start+1,i===state.pages.length-1?total:0);
          }
          previousStart=p.start;previousEnd=p.end;
        }
        state.textLength=total;
        state.text=nodes.map(node=>node.data).join('');
      }
      state.select=async index=>{
        state.selected=false;
        if(!Number.isInteger(index) || index<0 || index>=state.pages.length) throw Error('invalid page');
        if(paginator) await paginator.goTo({index:0,anchor:()=>state.pages.length===1?0:index/(state.pages.length-1)});
        await frames(); state.selected=true;
      };
      await state.select(0);
      state.ready=true;
    } catch(error) {state.error=String(error);}
  };
})();
