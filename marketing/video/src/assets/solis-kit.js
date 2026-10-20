/* SOLIS film kit: deterministic, seek-safe helpers shared by both cuts.
   Everything is driven from the paused root GSAP timeline; no clocks, no
   randomness (a fixed hash stands in for noise). */
(function () {
  const K = {};
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  K.$ = $; K.$$ = $$;

  K.hash = function (i, j) {
    const x = Math.sin(i * 127.1 + j * 311.7) * 43758.5453;
    return x - Math.floor(x);
  };

  /* Split an element's text into word spans (class .w) and return them */
  K.splitWords = function (el) {
    const words = el.textContent.trim().split(/\s+/);
    el.innerHTML = words.map((w) => '<span class="w">' + w + "</span>").join(" ");
    return $$(".w", el);
  };

  /* Kinetic headline: words rise in with a soft blur */
  K.wordsIn = function (tl, el, at, opts) {
    const o = Object.assign({ stagger: 0.07, dur: 0.6, y: 50 }, opts || {});
    const ws = el.querySelectorAll(".w").length ? $$(".w", el) : K.splitWords(el);
    tl.fromTo(ws, { y: o.y, opacity: 0, filter: "blur(10px)" },
      { y: 0, opacity: 1, filter: "blur(0px)", duration: o.dur, ease: "power3.out", stagger: o.stagger }, at);
    return ws;
  };
  K.out = function (tl, el, at, opts) {
    const o = Object.assign({ dur: 0.45, y: -30 }, opts || {});
    tl.to(el, { y: o.y, opacity: 0, filter: "blur(8px)", duration: o.dur, ease: "power2.in" }, at);
  };

  /* Typing: split into char spans (.ch, hidden) and reveal across [at, at+dur] */
  K.typeOn = function (tl, el, at, dur) {
    const text = el.textContent;
    el.innerHTML = Array.from(text).map((c) => '<span class="ch">' + (c === " " ? " " : c.replace("<", "&lt;")) + "</span>").join("");
    const chs = $$(".ch", el);
    tl.to(chs, { opacity: 1, duration: 0.01, stagger: dur / Math.max(chs.length, 1), ease: "none" }, at);
    return chs;
  };

  /* Reveal pre-split word spans at exact spoken times */
  K.wordsAtTimes = function (tl, spans, times) {
    spans.forEach((s, i) => {
      tl.fromTo(s, { opacity: 0, y: 6 }, { opacity: 1, y: 0, duration: 0.18, ease: "power2.out" }, times[i]);
    });
  };

  /* Numeric counter */
  K.counter = function (tl, el, from, to, at, dur, fmt) {
    const p = { v: from };
    const f = fmt || ((v) => String(Math.round(v)));
    el.textContent = f(from);
    tl.to(p, { v: to, duration: dur, ease: "power2.out", onUpdate: () => { el.textContent = f(p.v); } }, at);
  };

  /* Generic time driver: fn(localTime) called on every render inside [at, at+dur] */
  K.drive = function (tl, at, dur, fn) {
    const p = { t: 0 };
    tl.to(p, { t: dur, duration: dur, ease: "none", onUpdate: () => fn(p.t) }, at);
  };

  /* Speech envelope from word timings: 0..1 */
  K.envelope = function (words) {
    return function (t) {
      let v = 0;
      for (let i = 0; i < words.length; i++) {
        const w = words[i];
        if (t < w.s - 0.12 || t > w.e + 0.12) continue;
        const a = Math.min(1, (t - (w.s - 0.12)) / 0.12);
        const b = Math.min(1, ((w.e + 0.12) - t) / 0.12);
        v = Math.max(v, Math.min(a, b));
      }
      return v;
    };
  };

  /* Build waveform bars in a lane; returns an updater(t_abs, energy) */
  K.makeBars = function (lane, n, maxH, minH) {
    lane.innerHTML = "";
    const bars = [];
    for (let i = 0; i < n; i++) {
      const b = document.createElement("div");
      b.className = "bar";
      lane.appendChild(b);
      bars.push(b);
    }
    return function (t, energy) {
      for (let i = 0; i < n; i++) {
        const shape = Math.sin((i / (n - 1)) * Math.PI); // taller in the middle
        const nz = 0.55 + 0.45 * Math.sin(i * 1.7 + t * 13.1) * Math.sin(i * 0.63 + t * 7.3 + 1.1);
        const h = minH + (maxH - minH) * energy * nz * (0.35 + 0.65 * shape);
        bars[i].style.height = h.toFixed(1) + "px";
      }
    };
  };

  /* Captions from SOLIS_DATA.captions; spoken words brighten as they are said */
  K.captions = function (tl, root, data, opts) {
    const o = Object.assign({ size: 44, bottom: 60 }, opts || {});
    root.style.bottom = o.bottom + "px";
    root.style.height = o.size * 2.2 + "px";
    data.captions.forEach((c) => {
      const d = document.createElement("div");
      d.className = "cap";
      d.style.fontSize = o.size + "px";
      d.style.bottom = "0px";
      if (o.maxWidth) { d.style.whiteSpace = "normal"; d.style.width = o.maxWidth + "px"; d.style.lineHeight = "1.25"; }
      const tag = c.spk === "doctor" ? '<span class="tag doctor">DOCTOR</span>' : c.spk === "patient" ? '<span class="tag patient">PATIENT</span>' : "";
      d.innerHTML = '<span class="inner">' + tag + c.words.map((w) => '<span class="cw">' + w.w + "</span>").join(" ") + "</span>";
      root.appendChild(d);
      const ws = $$(".cw", d);
      tl.set(d, { autoAlpha: 1 }, c.s);
      tl.fromTo(d, { y: 14 }, { y: 0, duration: 0.25, ease: "power2.out" }, c.s);
      c.words.forEach((w, i) => tl.to(ws[i], { opacity: 1, duration: 0.08, ease: "power1.out" }, Math.max(c.s, w.s)));
      tl.set(d, { autoAlpha: 0 }, c.e);
    });
  };

  /* Pop-out: a lifted, enlarged crop of a screenshot region */
  K.popout = function (el, src, x, y, w, h, scale) {
    el.style.width = w * scale + "px";
    el.style.height = h * scale + "px";
    el.style.backgroundImage = "url(" + src + ")";
    el.style.backgroundSize = 412 * scale + "px " + 915 * scale + "px";
    el.style.backgroundPosition = -x * scale + "px " + -y * scale + "px";
  };

  /* Split Sun mark SVG (geometry from docs/BRAND.md) */
  K.markSVG = function () {
    return '<svg viewBox="0 0 1024 1024"><g class="dome"><path fill="#fff" d="M358.4 486.4A235.52 235.52 0 0 1 829.44 486.4Z"/></g><g class="bowl"><path fill="#fff" d="M665.6 537.6A235.52 235.52 0 0 1 194.56 537.6Z"/></g></svg>';
  };

  /* Animate the mark: one disc that splits into the offset halves */
  K.markIn = function (tl, tile, at, scale) {
    const dome = $(".dome", tile), bowl = $(".bowl", tile);
    // Start as a whole disc: dome shifted left/down, bowl right/up (by 0.08 / 0.025 of the tile)
    tl.fromTo(tile, { scale: 0.2 * (scale || 1), opacity: 0, rotate: -12 }, { scale: scale || 1, opacity: 1, rotate: 0, duration: 0.9, ease: "back.out(1.6)" }, at);
    tl.fromTo(dome, { x: -81.92, y: 25.6 }, { x: 0, y: 0, duration: 0.8, ease: "expo.out" }, at + 0.55);
    tl.fromTo(bowl, { x: 81.92, y: -25.6 }, { x: 0, y: 0, duration: 0.8, ease: "expo.out" }, at + 0.55);
  };

  window.SolisKit = K;
})();
