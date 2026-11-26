/* Controlled replay of the actual Anx 1.14.0 APK's shipped EPUB loader.
 * Self-authored EPUB resources only. No application account or external fetch.
 */
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE_PATH);
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'build/research/epub/anx-shipped-js');
const out = path.join(root, 'docs/qa/epub-css-volume-2026-10');
fs.mkdirSync(out, { recursive: true });
const hashes = {};
for (const name of ['epub.js', 'epubcfi.js', 'paginator.js', 'book.js']) {
  hashes[name] = crypto.createHash('sha256').update(fs.readFileSync(path.join(source, 'src', name))).digest('hex');
}
const server = http.createServer((req, res) => {
  if (req.url.split('?')[0] === '/') {res.setHeader('Content-Type', 'text/html'); return res.end('<!doctype html><meta charset="utf-8"><title>Controlled EPUB CSS replay</title>');}
  const file = path.resolve(source, '.' + decodeURIComponent(req.url.split('?')[0]));
  if (!file.startsWith(source + path.sep)) {res.writeHead(403); return res.end();}
  try {res.setHeader('Content-Type', 'text/javascript'); res.end(fs.readFileSync(file));}
  catch {res.writeHead(404); res.end();}
});
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH, headless: true});
  try {
    const page = await browser.newPage();
    await page.route('**/*', route => {
      const u = route.request().url();
      return u.startsWith(origin) || u.startsWith('blob:') || u.startsWith('data:') ? route.continue() : route.abort();
    });
    await page.goto(origin + '/?style=' + encodeURIComponent(JSON.stringify({allowScript:false})));
    const result = await page.evaluate(async () => {
      const { EPUB } = await import('/src/epub.js');
      const files = {
        'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'OPS/book.opf': '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">css-qa</dc:identifier><dc:title>CSS replay</dc:title><dc:language>en</dc:language></metadata><manifest><item id="c" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/><item id="main" href="Styles/main.css" media-type="text/css"/><item id="base" href="Styles/base.css" media-type="text/css"/></manifest><spine><itemref idref="c"/></spine></package>',
        'OPS/Text/chapter.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="../Styles/main.css"/><style>.note {text-align:left} #note {text-align:right !important}</style></head><body><h1 class="title">A journey</h1><p id="body">First line <em>emphasis</em> and <u>underline</u>.</p><p id="note" class="note" style="text-align:center">A note</p></body></html>',
        'OPS/Styles/base.css': 'h1 {font-size:28px;font-weight:bold}.title{text-align:center} p{text-indent:2em;line-height:1.8}',
        'OPS/Styles/main.css': '@import "base.css"; body{font-size:16px} .note{text-align:left}',
      };
      const loaded = [];
      const epub = await new EPUB({
        loadText: async p => {loaded.push(p); return files[p] ?? null;},
        loadBlob: async p => new Blob([files[p] ?? '']),
        getSize: p => (files[p] ?? '').length,
      }).init();
      const src = await epub.sections[0].load();
      const frame = document.createElement('iframe');
      frame.style.cssText = 'width:600px;height:500px';
      await new Promise((resolve, reject) => {
        frame.onload = resolve; frame.onerror = reject; frame.src = src; document.body.append(frame);
      });
      await frame.contentDocument.fonts.ready;
      const doc = frame.contentDocument;
      const style = q => {
        const x = frame.contentWindow.getComputedStyle(doc.querySelector(q));
        return {align:x.textAlign, size:x.fontSize, indent:x.textIndent, weight:x.fontWeight, italic:x.fontStyle, decoration:x.textDecorationLine};
      };
      const original = {title:style('h1'),body:style('#body'),emphasis:style('em'),underlined:style('u'),note:style('#note')};
      const user = doc.createElement('style'); user.textContent = '*{font-family:monospace!important;color:rgb(20,20,20)!important}';doc.head.append(user);
      const overridden = {title:style('h1'),body:style('#body'),emphasis:style('em')};
      const linkedCssIsBlob = doc.querySelector('link').href.startsWith('blob:');
      frame.remove(); epub.sections[0].unload();
      return {loaded,original,overridden,linkedCssIsBlob};
    });
    assert.equal(result.original.title.align, 'center');
    assert.equal(result.original.title.size, '28px');
    assert.equal(result.original.body.indent, '32px');
    assert.equal(result.original.emphasis.italic, 'italic');
    assert.equal(result.original.underlined.decoration, 'underline');
    assert.equal(result.original.note.align, 'right');
    assert.equal(result.overridden.title.align, 'center');
    assert.equal(result.overridden.emphasis.italic, 'italic');
    assert(result.linkedCssIsBlob && result.loaded.includes('OPS/Styles/base.css'));
    const record = {scope:'Controlled browser replay of released APK modules; not the full Anx app runtime', hashes, result, passed:true};
    fs.writeFileSync(path.join(out,'shipped-css-replay.json'),JSON.stringify(record,null,2));
    console.log(JSON.stringify(record));
  } finally {await browser.close(); server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
