/* SOLIS reel, 9:16 timeline (data/timeline_9x16.json) */
window.buildSolisReel = function () {
  const K = window.SolisKit, D = window.SOLIS_DATA, $ = K.$, $$ = K.$$;
  const tl = gsap.timeline({ paused: true });
  const S = 0.95;
  const PCX = 540, PCY = 1060;
  const words = (id) => D.words.filter((w) => w.line === id);
  gsap.set("#phone", { scale: S, transformPerspective: 1800 });

  tl.fromTo("#bg", { opacity: 0.45 }, { opacity: 0.45, duration: 0.1 }, 0);
  tl.to("#bg", { opacity: 1, duration: 1.2, ease: "power2.out" }, 3.4);
  tl.fromTo("#blob1", { x: 0, y: 0 }, { x: 500, y: -300, duration: 42.5, ease: "sine.inOut" }, 0);
  tl.fromTo("#blob2", { x: 0, y: 0 }, { x: -400, y: -500, duration: 42.5, ease: "sine.inOut" }, 0);
  [3.3, 8.75, 26.55, 33.1, 36.1].forEach((t) => {
    tl.fromTo("#sweep", { x: 0, opacity: 1 }, { x: 2600, duration: 0.7, ease: "power2.inOut" }, t - 0.2);
    tl.set("#sweep", { opacity: 0 }, t + 0.5);
  });

  /* R1 hook */
  tl.fromTo("#clock", { opacity: 0, y: 40, filter: "blur(14px)" }, { opacity: 1, y: 0, filter: "blur(0px)", duration: 0.7, ease: "power3.out" }, 0.05);
  tl.to("#mins", { y: -270, duration: 0.5, ease: "back.inOut(1.6)" }, 0.7);
  K.wordsIn(tl, $("#hookline"), 1.8, { stagger: 0.09 });
  tl.to("#s1", { opacity: 0, scale: 0.94, filter: "blur(10px)", duration: 0.4, ease: "power2.in" }, 3.0);

  /* R2 brand */
  tl.set("#s3", { opacity: 1 }, 3.3);
  $("#tile1").innerHTML = K.markSVG();
  $("#tile2").innerHTML = K.markSVG();
  tl.fromTo("#flash", { opacity: 0 }, { keyframes: [{ opacity: 1, duration: 0.15 }, { opacity: 0, duration: 1.1, ease: "power2.out" }] }, 3.35);
  K.markIn(tl, $("#tile1"), 3.4, 1);
  tl.fromTo("#letters1", { clipPath: "inset(0% 100% 0% 0%)", y: 10 }, { clipPath: "inset(0% 0% 0% 0%)", y: 0, duration: 0.8, ease: "expo.out" }, 3.9);
  const trio = $$(".t3");
  const w4 = words("L04");
  [w4[1].s, w4[5].s, w4[9].s].forEach((t, i) => tl.fromTo(trio[i], { opacity: 0, y: 40, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.5, ease: "back.out(1.7)" }, t - 0.05));
  tl.fromTo("#onphone", { opacity: 0, y: 30, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.4, ease: "back.out(2)" }, w4[w4.length - 3].s - 0.1);
  tl.to("#s3", { opacity: 0, y: -140, scale: 0.92, filter: "blur(8px)", duration: 0.4, ease: "power2.in" }, 8.6);

  /* phone */
  tl.fromTo("#phone", { opacity: 0, y: 900, rotateX: 26 }, { opacity: 1, y: 0, rotateX: 0, duration: 0.85, ease: "power3.out" }, 8.8);
  [[9.7, 26.4], [27.3, 33.0], [33.6, 36.0]].forEach(([a, b]) => tl.to("#phone", { scale: S * 1.035, duration: b - a, ease: "sine.inOut" }, a));
  tl.to("#phone", { scale: S, duration: 0.3, ease: "power2.out" }, 26.45);
  tl.to("#phone", { scale: S, duration: 0.3, ease: "power2.out" }, 33.05);
  tl.to("#phone", { y: 1000, rotateX: -20, opacity: 0, duration: 0.6, ease: "power3.in" }, 35.95);
  function swap(from, to, at) {
    tl.to(from, { opacity: 0, x: -50, duration: 0.35, ease: "power2.in" }, at);
    tl.fromTo(to, { opacity: 0, x: 60 }, { opacity: 1, x: 0, duration: 0.45, ease: "power3.out" }, at + 0.2);
  }

  /* R3 talk + dialogue */
  tl.set("#s5", { opacity: 1 }, 8.9);
  tl.fromTo("#s5 .kicker", { opacity: 0 }, { opacity: 1, duration: 0.4 }, 9.0);
  K.wordsIn(tl, $("#t-h"), 9.05, { stagger: 0.07 });
  const updDoc = K.makeBars($("#laneDoc"), 50, 90, 6);
  const updPat = K.makeBars($("#lanePat"), 50, 90, 6);
  const updMini = K.makeBars($("#miniLane"), 30, 40, 4);
  tl.fromTo(["#laneDoc", "#lanePat"], { opacity: 0 }, { opacity: 1, duration: 0.5 }, 9.4);
  const w6 = words("L06");
  const splitAt = w6[5].s; // "tells"
  tl.fromTo("#laneDoc", { y: 0 }, { y: -58, duration: 0.9, ease: "expo.inOut" }, splitAt);
  tl.fromTo("#lanePat", { y: 0 }, { y: 58, duration: 0.9, ease: "expo.inOut" }, splitAt);
  tl.fromTo(["#lblDoc", "#lblPat"], { opacity: 0, y: 10 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out", stagger: 0.12 }, splitAt + 0.5);
  const envDoc = K.envelope(words("D01").concat(words("D03")));
  const envPat = K.envelope(words("D02").concat(words("D04")));
  const envNar = K.envelope(w6);
  K.drive(tl, 9.4, 17.2, (lt) => {
    const t = 9.4 + lt;
    let d, p;
    if (t < 12.6) { const e = Math.max(0.12, 0.75 * envNar(t)); d = e; p = e * 0.9; }
    else { d = Math.max(0.07, envDoc(t)); p = Math.max(0.07, envPat(t)); }
    updDoc(t, d); updPat(t + 3.3, p); updMini(t, Math.max(d, p));
    $("#recTimer").textContent = "00:" + String(Math.floor(lt + 0.4)).padStart(2, "0");
    $("#recDot").style.opacity = (0.35 + 0.65 * (0.5 + 0.5 * Math.cos(t * 5))).toFixed(2);
  });
  [["#bub1", "D01"], ["#bub2", "D02"], ["#bub3", "D03"], ["#bub4", "D04"]].forEach(([sel, id]) => {
    const spans = K.splitWords($(".txt", $(sel)));
    spans.forEach((s) => s.classList.add("tw"));
    const ws = words(id);
    tl.fromTo(sel, { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.3, ease: "power2.out" }, ws[0].s - 0.2);
    K.wordsAtTimes(tl, spans, spans.map((_, i) => (ws[i] || ws[ws.length - 1]).s));
  });
  tl.set("#ripFinish", { opacity: 0.9, scale: 0.3 }, 26.3);
  tl.to("#ripFinish", { opacity: 0, scale: 3.2, duration: 0.6, ease: "power2.out" }, 26.3 + 0.01);
  tl.to("#s5", { opacity: 0, y: -30, duration: 0.4, ease: "power2.in" }, 26.45);

  /* R4 note */
  swap("#scrRec", "#scrNote", 26.6);
  tl.set("#s6", { opacity: 1 }, 26.75);
  tl.fromTo("#s6 .kicker", { opacity: 0 }, { opacity: 1, duration: 0.4 }, 26.8);
  K.wordsIn(tl, $("#n-h"), 27.4, { stagger: 0.08 });
  K.typeOn(tl, $("#nl1"), 27.3, 1.0);
  K.typeOn(tl, $("#nl2"), 28.3, 0.7);
  K.typeOn(tl, $("#nl3"), 29.05, 0.85);
  const w7 = words("L07");
  tl.fromTo("#n-chip", { opacity: 0, scale: 0.7 }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2)" }, w7[7].s - 0.05);
  ["#dx1", "#dx2", "#dx3"].forEach((s, i) => tl.fromTo(s, { opacity: 0, x: 40 }, { opacity: 1, x: 0, duration: 0.45, ease: "power3.out" }, 30.0 + i * 0.3));
  tl.fromTo("#ringDx1", { opacity: 0, scale: 1.1 }, { opacity: 1, scale: 1, duration: 0.4, ease: "power3.out" }, w7[9].s);
  tl.to("#s6", { opacity: 0, y: -30, duration: 0.4, ease: "power2.in" }, 32.95);

  /* R5 checks (no VO; music + SFX) */
  swap("#scrNote", "#scrClaim", 33.1);
  tl.set("#s7", { opacity: 1 }, 33.2);
  tl.fromTo("#s7 .kicker", { opacity: 0 }, { opacity: 1, duration: 0.3 }, 33.2);
  K.wordsIn(tl, $("#k-h"), 33.25, { stagger: 0.05 });
  tl.fromTo("#ringBanner", { opacity: 0, scale: 1.12 }, { opacity: 1, scale: 1, duration: 0.4, ease: "power3.out" }, 33.6);
  tl.fromTo("#chk", { opacity: 0, y: 40, scale: 0.92 }, { opacity: 1, y: 0, scale: 1, duration: 0.45, ease: "back.out(1.5)" }, 33.7);
  tl.to("#chk", { keyframes: [{ x: -10, duration: 0.05 }, { x: 10, duration: 0.05 }, { x: -6, duration: 0.05 }, { x: 0, duration: 0.05 }] }, 34.2);
  tl.to("#ringBanner", { opacity: 0, duration: 0.3 }, 34.9);
  tl.to("#chkBad", { opacity: 0, scale: 0.5, transformOrigin: "50% 50%", duration: 0.25, ease: "power2.in" }, 35.0);
  tl.fromTo("#chkGood", { opacity: 0, scale: 0.3, transformOrigin: "50% 50%" }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2.5)" }, 35.15);
  tl.fromTo("#tick", { strokeDasharray: 40, strokeDashoffset: 40 }, { strokeDashoffset: 0, duration: 0.35, ease: "power2.out" }, 35.3);
  tl.to("#chkT1", { opacity: 0, y: -16, duration: 0.25, ease: "power2.in" }, 35.05);
  tl.fromTo("#chkT2", { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.35, ease: "power2.out" }, 35.25);
  tl.to("#s7", { opacity: 0, y: -40, duration: 0.4, ease: "power2.in" }, 35.95);

  /* R6 CTA */
  tl.set("#s10", { opacity: 1 }, 36.1);
  tl.fromTo("#flash2", { opacity: 0 }, { keyframes: [{ opacity: 1, duration: 0.12 }, { opacity: 0.35, duration: 1.6, ease: "power2.out" }] }, 36.25);
  K.markIn(tl, $("#tile2"), 36.3, 1);
  tl.fromTo("#letters2", { clipPath: "inset(0% 100% 0% 0%)", y: 10 }, { clipPath: "inset(0% 0% 0% 0%)", y: 0, duration: 0.8, ease: "expo.out" }, 36.7);
  K.wordsIn(tl, $("#tagline"), 37.3, { stagger: 0.1 });
  tl.fromTo("#ctaBtn", { opacity: 0, scale: 0.6, y: 20 }, { opacity: 1, scale: 1, y: 0, duration: 0.6, ease: "back.out(2)" }, 39.1);
  tl.to("#ctaBtn", { scale: 1.04, duration: 0.6, ease: "sine.inOut", yoyo: true, repeat: 3 }, 39.8);
  tl.fromTo("#pilot", { opacity: 0 }, { opacity: 1, duration: 0.6 }, 39.9);

  K.captions(tl, $("#captions"), D, { size: 50, bottom: 250, maxWidth: 940 });
  tl.set({}, {}, 42.5);
  return tl;
};
