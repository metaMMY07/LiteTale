// App-owned import probe. Book scripts and event handlers are removed and CSP
// forbids scripts. This file is shared by Android and the offline geometry QA.
(() => {
  if (document.body.hasAttribute('data-litetale-title-typography') &&
      !window.__ltTitleNormalized) {
    window.__ltTitleNormalized = true;
    const adjusted = new Set();
    for (const element of document.body.querySelectorAll('*')) {
      const transform = getComputedStyle(element).transform;
      const match = /^matrix\(([^)]+)\)$/.exec(transform);
      if (!match) continue;
      const m = match[1].split(',').map(Number);
      // Only a quarter-turn, with no perspective/scale. Rotated labels paint
      // in a much narrower column than their unrotated intrinsic line box.
      if (m.length !== 6 || Math.abs(m[0]) > .01 || Math.abs(m[3]) > .01 ||
          Math.abs(Math.abs(m[1]) - 1) > .01 || Math.abs(Math.abs(m[2]) - 1) > .01) continue;
      let parent = element.parentElement;
      for (let depth = 0; parent && depth < 24; depth++, parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        if (style.cssFloat !== 'right') continue;
        if (!adjusted.has(parent)) {
          adjusted.add(parent);
          const margin = parseFloat(style.marginLeft) || 0;
          parent.style.setProperty('margin-left',
            (margin - parseFloat(style.fontSize) * .75) + 'px', 'important');
        }
        break;
      }
    }
    // A short unrotated credit between vertical labels has its own top margin.
    // Remove one inherited line of excess leading without changing the left
    // title column or the later label's natural float/clear decision.
    if (adjusted.size) {
      for (const element of document.body.querySelectorAll('*')) {
        const style = getComputedStyle(element);
        if (style.cssFloat !== 'right' || adjusted.has(element)) continue;
        const margin = parseFloat(style.marginTop) || 0;
        element.style.setProperty('margin-top',
          Math.max(0, margin - parseFloat(style.fontSize)) + 'px', 'important');
      }
    }
  }
  if (!window.__ltFonts) {
    window.__ltFonts = document.fonts ? 'waiting' : 'ready';
    if (document.fonts) document.fonts.ready.then(() => window.__ltFonts = 'ready');
  }
  const images = Array.from(document.images).filter(i => i.getAttribute('src'));
  const ready = window.__ltFonts === 'ready' &&
    images.every(i => i.complete && i.naturalWidth > 0);
  let height = Math.max(800, document.documentElement.scrollHeight);
  let width = Math.max(360, document.documentElement.scrollWidth);
  for (const el of document.body.querySelectorAll('*')) {
    const box = el.getBoundingClientRect();
    height = Math.max(height, box.bottom);
    width = Math.max(width, box.right);
  }
  return {ready, height, width};
})()
