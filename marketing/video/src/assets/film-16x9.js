/* SOLIS launch film, 16:9 timeline. Times are seconds on the root timeline and
   line up with data/timeline_16x9.json (voice and dialogue placement). */
window.buildSolisFilm = function () {
  const K = window.SolisKit, D = window.SOLIS_DATA, $ = K.$, $$ = K.$$;
  const tl = gsap.timeline({ paused: true });
  const S = 0.86; // phone scale
  const PCX = 960, PCY = 505; // phone base center
  const words = (id) => D.words.filter((w) => w.line === id);

  gsap.set("#phone", { scale: S, transformPerspective: 1800 });
  gsap.set(["#bar1", "#bar2", "#bar3"], { transformOrigin: "0% 50%" });

  /* ---------- background drift (whole film) ---------- */
  tl.fromTo("#bg", { opacity: 0.45 }, { opacity: 0.45, duration: 0.1 }, 0);
  tl.to("#bg", { opacity: 1, duration: 1.2, ease: "power2.out" }, 13.2);
  tl.fromTo("#blob1", { x: 0, y: 0 }, { x: 700, y: -150, duration: 79.5, ease: "sine.inOut" }, 0);
  tl.fromTo("#blob2", { x: 0, y: 0 }, { x: -600, y: -250, duration: 79.5, ease: "sine.inOut" }, 0);

  /* light sweep transitions */
  [13.1, 18.9, 26.95, 45.25, 51.95, 61.4, 65.05, 72.4].forEach((t) => {
    tl.fromTo("#sweep", { x: 0, opacity: 1 }, { x: 3300, duration: 0.75, ease: "power2.inOut" }, t - 0.2);
    tl.set("#sweep", { opacity: 0 }, t + 0.56);
  });

  /* ---------- S1 hook 0 - 3.3 ---------- */
  tl.fromTo("#ehr", { opacity: 0, scale: 1.08 }, { opacity: 0.35, scale: 1, duration: 1.4, ease: "power2.out" }, 0);
  tl.fromTo(".ehr-line", { scaleX: 0, transformOrigin: "0% 50%" }, { scaleX: 1, duration: 0.5, ease: "power2.out", stagger: 0.35 }, 0.2);
  tl.fromTo("#clock", { opacity: 0, y: 40, filter: "blur(14px)" }, { opacity: 1, y: 0, filter: "blur(0px)", duration: 0.7, ease: "power3.out" }, 0.05);
  tl.to("#mins", { y: -250, duration: 0.5, ease: "back.inOut(1.6)" }, 0.75);
  K.wordsIn(tl, $("#hookline"), 1.9, { stagger: 0.09 });
  tl.to("#s1", { opacity: 0, scale: 0.94, filter: "blur(10px)", duration: 0.45, ease: "power2.in" }, 3.0);

  /* ---------- S2 pain 3.35 - 13.1 ---------- */
  tl.set("#s2", { opacity: 1 }, 3.35);
  tl.fromTo("#p-kick", { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.5, ease: "power2.out" }, 3.4);
  K.wordsIn(tl, $("#p-h"), 3.5, { stagger: 0.07 });
  tl.fromTo("#row1", { opacity: 0, x: -40 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 4.0);
  tl.fromTo("#bar1", { scaleX: 0 }, { scaleX: 1, duration: 0.8, ease: "power3.out" }, 4.2);
  tl.fromTo("#row2", { opacity: 0, x: -40 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 5.2);
  tl.fromTo("#bar2", { scaleX: 0 }, { scaleX: 1, duration: 1.5, ease: "power3.out" }, 5.4);
  tl.fromTo("#p-src", { opacity: 0 }, { opacity: 1, duration: 0.6, ease: "power1.out" }, 6.2);
  tl.fromTo("#row3", { opacity: 0, x: -40 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 8.7);
  tl.fromTo("#bar3", { scaleX: 0 }, { scaleX: 1, duration: 1.1, ease: "power3.out" }, 8.9);
  tl.to(["#bars", "#p-h", "#p-kick", "#p-src"], { opacity: 0, x: -80, filter: "blur(8px)", duration: 0.5, ease: "power2.in", stagger: 0.04 }, 10.75);
  tl.fromTo("#claimcard", { opacity: 0, y: 80, rotate: -4, scale: 0.94 }, { opacity: 1, y: 0, rotate: -2, scale: 1, duration: 0.7, ease: "power3.out" }, 11.0);
  tl.fromTo("#stamp", { opacity: 0, scale: 2.6, rotate: -24 }, { opacity: 1, scale: 1, rotate: -14, duration: 0.28, ease: "power4.in" }, 12.2);
  tl.to("#claimcard", { keyframes: [{ x: -12, duration: 0.05 }, { x: 10, duration: 0.05 }, { x: -6, duration: 0.05 }, { x: 0, duration: 0.05 }] }, 12.48);
  tl.to("#claimcard", { opacity: 0, y: 260, rotate: 10, duration: 0.5, ease: "power2.in" }, 12.95);
  tl.set("#s2", { opacity: 0 }, 13.5);

  /* ---------- S3 intro 13.1 - 19.0 ---------- */
  tl.set("#s3", { opacity: 1 }, 13.15);
  $("#tile1").innerHTML = K.markSVG();
  $("#tile2").innerHTML = K.markSVG();
  tl.fromTo("#flash", { opacity: 0 }, { keyframes: [{ opacity: 1, duration: 0.15 }, { opacity: 0, duration: 1.1, ease: "power2.out" }] }, 13.2);
  K.markIn(tl, $("#tile1"), 13.25, 1);
  tl.fromTo("#letters1", { clipPath: "inset(0% 100% 0% 0%)", x: -30 }, { clipPath: "inset(0% 0% 0% 0%)", x: 0, duration: 0.8, ease: "expo.out" }, 13.75);
  const trio = $$(".t3");
  [14.35, 15.45, 16.55].forEach((t, i) => tl.fromTo(trio[i], { opacity: 0, y: 40, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.55, ease: "back.out(1.7)" }, t));
  tl.fromTo("#onphone", { opacity: 0, y: 30, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.4, ease: "back.out(2)" }, 17.95);
  tl.to("#s3", { opacity: 0, y: -140, scale: 0.92, filter: "blur(8px)", duration: 0.4, ease: "power2.in" }, 18.3);

  /* ---------- PHONE path ---------- */
  tl.fromTo("#phone", { opacity: 0, x: 0, y: 820, rotateX: 28, rotateY: 0 }, { opacity: 1, y: 0, rotateX: 0, duration: 0.85, ease: "power3.out" }, 18.5);
  tl.to("#phone", { x: 430, rotateY: -10, scale: S, duration: 0.8, ease: "power3.inOut" }, 19.25);
  tl.to("#phone", { x: -470, rotateY: 10, scale: S, duration: 0.9, ease: "power3.inOut" }, 26.95);
  tl.to("#phone", { scale: S, duration: 0.3, ease: "power2.out" }, 45.0);
  tl.to("#phone", { x: 450, rotateY: -10, scale: S, duration: 0.9, ease: "power3.inOut" }, 51.95);
  tl.to("#phone", { x: 430, rotateY: -8, scale: S, duration: 0.6, ease: "power2.inOut" }, 61.4);
  tl.to("#phone", { y: 900, rotateX: -20, opacity: 0, duration: 0.6, ease: "power3.in" }, 72.05);
  // slow camera push while stationary (each move above eases the scale back)
  [[19.9, 26.9], [27.9, 44.95], [45.3, 51.9], [52.9, 61.35], [62.0, 72.0]].forEach(([a, b]) => {
    tl.to("#phone", { scale: S * 1.035, duration: b - a, ease: "sine.inOut" }, a);
  });

  /* screen switcher */
  function swap(from, to, at) {
    tl.to(from, { opacity: 0, x: -50, duration: 0.35, ease: "power2.in" }, at);
    tl.fromTo(to, { opacity: 0, x: 60 }, { opacity: 1, x: 0, duration: 0.45, ease: "power3.out" }, at + 0.2);
  }

  /* ---------- S4 consent 19.0 - 26.9 ---------- */
  tl.set("#s4", { opacity: 1 }, 19.0);
  tl.fromTo("#c-kick", { opacity: 0, x: -30 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 19.2);
  K.wordsIn(tl, $("#c-h"), 20.75, { stagger: 0.06 });
  tl.fromTo("#chipEn", { opacity: 0, scale: 0.6 }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2)" }, 22.75);
  tl.fromTo("#chipEs", { opacity: 0, scale: 0.6 }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2)" }, 23.3);
  K.wordsIn(tl, $("#c-h3"), 24.0, { stagger: 0.05, y: 30 });
  tl.fromTo("#ringConsent", { opacity: 0, scale: 1.15 }, { opacity: 1, scale: 1, duration: 0.4, ease: "power3.out" }, 24.3);
  tl.set("#ripConsent", { opacity: 0.9, scale: 0.3 }, 25.6);
  tl.to("#ripConsent", { opacity: 0, scale: 3.2, duration: 0.7, ease: "power2.out" }, 25.6 + 0.01);
  tl.to("#ringConsent", { opacity: 0, duration: 0.3 }, 26.0);
  tl.fromTo("#c-body", { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.5, ease: "power2.out" }, 25.8);
  tl.to("#s4", { opacity: 0, x: -60, duration: 0.45, ease: "power2.in" }, 26.85);

  /* ---------- S5 talk + dialogue 27.0 - 45.2 ---------- */
  swap("#scrConsent", "#scrRec", 26.95);
  tl.set("#s5", { opacity: 1 }, 27.1);
  tl.fromTo("#t-kick", { opacity: 0, x: 30 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 27.3);
  K.wordsIn(tl, $("#t-h"), 27.35, { stagger: 0.07 });
  // lanes: start merged, split when "tells your voice from the patient's"
  const updDoc = K.makeBars($("#laneDoc"), 42, 140, 8);
  const updPat = K.makeBars($("#lanePat"), 42, 140, 8);
  const updMini = K.makeBars($("#miniLane"), 30, 40, 4);
  tl.fromTo(["#laneDoc", "#lanePat"], { opacity: 0 }, { opacity: 1, duration: 0.5, ease: "power1.out" }, 27.6);
  tl.fromTo("#laneDoc", { y: 0 }, { y: -75, duration: 0.9, ease: "expo.inOut" }, 28.5);
  tl.fromTo("#lanePat", { y: 0 }, { y: 175, duration: 0.9, ease: "expo.inOut" }, 28.5);
  tl.fromTo(["#lblDoc", "#lblPat"], { opacity: 0, x: -20 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out", stagger: 0.12 }, 29.1);
  const envDoc = K.envelope(words("D01").concat(words("D03")));
  const envPat = K.envelope(words("D02").concat(words("D04")));
  const envNar = K.envelope(words("L06"));
  K.drive(tl, 27.6, 18.0, (lt) => {
    const t = 27.6 + lt;
    const idle = 0.12;
    let d, p;
    if (t < 30.9) { const e = Math.max(idle, 0.75 * envNar(t)); d = e; p = e * 0.9; }
    else { d = Math.max(idle * 0.6, envDoc(t)); p = Math.max(idle * 0.6, envPat(t)); }
    updDoc(t, d); updPat(t + 3.3, p);
    updMini(t, Math.max(d, p));
    const s = Math.floor(lt + 0.4);
    $("#recTimer").textContent = "00:" + String(s).padStart(2, "0");
    $("#recDot").style.opacity = (0.35 + 0.65 * (0.5 + 0.5 * Math.cos(t * 5))).toFixed(2);
  });
  // live transcript bubbles, word-synced
  [["#bub1", "D01"], ["#bub2", "D02"], ["#bub3", "D03"], ["#bub4", "D04"]].forEach(([sel, id]) => {
    const txt = $(".txt", $(sel));
    const spans = K.splitWords(txt);
    spans.forEach((s) => s.classList.add("tw"));
    const ws = words(id);
    tl.fromTo(sel, { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.3, ease: "power2.out" }, ws[0].s - 0.2);
    K.wordsAtTimes(tl, spans, spans.map((_, i) => (ws[i] || ws[ws.length - 1]).s));
  });
  tl.set("#ripFinish", { opacity: 0.9, scale: 0.3 }, 44.85);
  tl.to("#ripFinish", { opacity: 0, scale: 3.2, duration: 0.6, ease: "power2.out" }, 44.85 + 0.01);
  tl.to(["#laneDoc", "#lanePat", "#lblDoc", "#lblPat", "#t-h", "#t-kick"], { opacity: 0, y: "+=30", duration: 0.45, ease: "power2.in", stagger: 0.03 }, 45.0);
  tl.set("#s5", { opacity: 0 }, 45.6);

  /* ---------- S6 note 45.3 - 52.0 ---------- */
  swap("#scrRec", "#scrNote", 45.2);
  tl.set("#s6", { opacity: 1 }, 45.3);
  tl.fromTo("#n-kick", { opacity: 0, x: 30 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out" }, 45.45);
  K.wordsIn(tl, $("#n-h"), 46.1, { stagger: 0.08 });
  K.typeOn(tl, $("#nl1"), 46.0, 1.0);
  K.typeOn(tl, $("#nl2"), 47.0, 0.7);
  K.typeOn(tl, $("#nl3"), 47.75, 0.85);
  tl.fromTo("#n-chip", { opacity: 0, scale: 0.7 }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2)" }, 47.75);
  tl.fromTo("#n-body", { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.5, ease: "power2.out" }, 48.1);
  ["#dx1", "#dx2", "#dx3"].forEach((s, i) => tl.fromTo(s, { opacity: 0, x: 40 }, { opacity: 1, x: 0, duration: 0.45, ease: "power3.out" }, 48.5 + i * 0.3));
  tl.fromTo("#quote", { opacity: 0, y: 40, scale: 0.95 }, { opacity: 1, y: 0, scale: 1, duration: 0.55, ease: "power3.out" }, 49.1);
  // connector: quote card -> R05.9 row on the phone (phone center x = 960-470)
  const rowX = PCX - 470 + (12 + 394 - 218) * S, rowY = PCY + (12 + 507 - 469.5) * S;
  const qx = 1080, qy = 700;
  const path = $("#linkPath");
  path.setAttribute("d", `M${qx} ${qy} C ${qx - 180} ${qy}, ${rowX + 160} ${rowY}, ${rowX + 6} ${rowY}`);
  const plen = 640;
  path.style.strokeDasharray = plen;
  tl.fromTo(path, { strokeDashoffset: plen, opacity: 1 }, { strokeDashoffset: 0, duration: 0.7, ease: "power2.inOut" }, 49.55);
  tl.fromTo("#linkDot", { attr: { cx: rowX + 6, cy: rowY }, scale: 0, opacity: 0, transformOrigin: "50% 50%" }, { scale: 1, opacity: 1, duration: 0.3, ease: "back.out(3)" }, 50.2);
  tl.fromTo("#ringDx1", { opacity: 0, scale: 1.1 }, { opacity: 1, scale: 1, duration: 0.4, ease: "power3.out" }, 50.2);
  tl.to(["#link", "#quote", "#n-chip", "#n-body", "#n-h", "#n-kick", "#ringDx1"], { opacity: 0, duration: 0.4, ease: "power2.in" }, 51.75);
  tl.set("#s6", { opacity: 0 }, 52.2);

  /* ---------- S7 codes + checks 52.0 - 61.4 ---------- */
  swap("#scrNote", "#scrClaim", 51.95);
  tl.set("#s7", { opacity: 1 }, 52.0);
  tl.fromTo("#k-a", { opacity: 0 }, { opacity: 1, duration: 0.3 }, 52.2);
  K.wordsIn(tl, $("#k-h"), 52.25, { stagger: 0.06 });
  tl.fromTo("#k-body", { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.5, ease: "power2.out" }, 53.0);
  K.popout($("#popRow"), "assets/shots/09_claim_uncertain.png", 20, 628, 375, 96, 1.5);
  tl.fromTo("#popRow", { opacity: 0, x: 120, scale: 0.7 }, { opacity: 1, x: 0, scale: 1, duration: 0.6, ease: "back.out(1.4)" }, 53.3);
  tl.to(["#k-a", "#popRow"], { opacity: 0, x: -60, duration: 0.4, ease: "power2.in" }, 54.6);
  tl.set("#k-b", { opacity: 1 }, 54.9);
  tl.fromTo("#k-b .kicker, #k-b .h3", { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out", stagger: 0.1 }, 54.9);
  tl.fromTo(".kc", { opacity: 0, y: 24, scale: 0.85 }, { opacity: 1, y: 0, scale: 1, duration: 0.4, ease: "back.out(2)", stagger: 0.26 }, 55.5);
  tl.fromTo("#k-count", { opacity: 0 }, { opacity: 1, duration: 0.3 }, 56.9);
  K.counter(tl, $("#cnt26"), 0, 59, 56.9, 1.3);
  tl.to("#k-b", { opacity: 0, x: -60, duration: 0.4, ease: "power2.in" }, 58.55);
  tl.set("#k-c", { opacity: 1 }, 58.85);
  tl.fromTo("#k-c .kicker, #k-c .h2", { opacity: 0, y: 24 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out", stagger: 0.1 }, 58.85);
  tl.fromTo("#chk", { opacity: 0, y: 50, scale: 0.92 }, { opacity: 1, y: 0, scale: 1, duration: 0.5, ease: "back.out(1.5)" }, 59.2);
  tl.fromTo("#ringBanner", { opacity: 0, scale: 1.12 }, { opacity: 1, scale: 1, duration: 0.4, ease: "power3.out" }, 59.1);
  tl.to("#chk", { keyframes: [{ x: -10, duration: 0.05 }, { x: 10, duration: 0.05 }, { x: -6, duration: 0.05 }, { x: 0, duration: 0.05 }] }, 59.75);
  tl.to("#ringBanner", { opacity: 0, duration: 0.3 }, 60.3);
  tl.to("#chkBad", { opacity: 0, scale: 0.5, transformOrigin: "50% 50%", duration: 0.25, ease: "power2.in" }, 60.55);
  tl.fromTo("#chkGood", { opacity: 0, scale: 0.3, transformOrigin: "50% 50%" }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(2.5)" }, 60.7);
  tl.fromTo("#tick", { strokeDasharray: 40, strokeDashoffset: 40 }, { strokeDashoffset: 0, duration: 0.35, ease: "power2.out" }, 60.85);
  tl.to("#chkT1", { opacity: 0, y: -16, duration: 0.25, ease: "power2.in" }, 60.6);
  tl.fromTo("#chkT2", { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.35, ease: "power2.out" }, 60.8);
  tl.to("#s7", { opacity: 0, x: -60, duration: 0.4, ease: "power2.in" }, 61.3);

  /* ---------- S8 scan + send 61.45 - 65.1 ---------- */
  swap("#scrClaim", "#scrScan", 61.4);
  tl.set("#s8", { opacity: 1 }, 61.45);
  K.wordsIn(tl, $("#b-h1"), 61.55, { stagger: 0.06 });
  tl.fromTo("#s8 .kicker", { opacity: 0 }, { opacity: 1, duration: 0.4 }, 61.5);
  tl.fromTo("#inscard", { opacity: 0, x: -520, y: 120, rotate: -14 }, { opacity: 1, x: 0, y: 0, rotate: -4, duration: 0.7, ease: "power3.out" }, 61.6);
  tl.fromTo("#scanline", { opacity: 1, y: 0 }, { y: 334, duration: 0.6, ease: "sine.inOut" }, 62.25);
  tl.to("#scanline", { opacity: 0, duration: 0.1 }, 62.85);
  tl.fromTo("#ringChips", { opacity: 0, scale: 1.2 }, { opacity: 1, scale: 1, duration: 0.35, ease: "power3.out" }, 62.75);
  tl.to("#inscard", { x: 760, y: -60, scale: 0.35, rotate: 0, opacity: 0, duration: 0.55, ease: "power3.in" }, 62.95);
  tl.fromTo("#b-h2", { opacity: 0, y: 30 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }, 63.2);
  swap("#scrScan", "#scrSend", 63.15);
  tl.fromTo("#chNode", { opacity: 0, y: 30 }, { opacity: 1, y: 0, duration: 0.45, ease: "power3.out" }, 63.55);
  tl.set("#ripSend", { opacity: 0.95, scale: 0.3 }, 63.95);
  tl.to("#ripSend", { opacity: 0, scale: 3.4, duration: 0.6, ease: "power2.out" }, 63.95 + 0.01);
  tl.to("#sendBtn", { scale: 0.96, duration: 0.08, yoyo: true, repeat: 1 }, 63.95);
  tl.call(() => {}, [], 64.1);
  K.drive(tl, 63.9, 1.5, (lt) => {
    $("#sendLbl").textContent = lt < 0.25 ? "Send claim" : "Claim sent";
    $("#sentTxt").textContent = lt < 0.85 ? "sending" : "sent";
  });
  // token: from send button (phone x +430) to clearinghouse node
  const bx = PCX + 430 + (12 + 206 - 218) * S, by = PCY + (12 + 862 - 469.5) * S;
  tl.set("#token", { x: bx - 45, y: by - 55, opacity: 0, scale: 0.5, rotate: 0 }, 64.1);
  tl.to("#token", { opacity: 1, scale: 1, y: by - 220, duration: 0.25, ease: "power2.out" }, 64.15);
  tl.to("#token", { x: 640, y: 610, rotate: -8, scale: 0.6, duration: 0.5, ease: "power3.inOut" }, 64.4);
  tl.to("#token", { opacity: 0, duration: 0.12 }, 64.9);
  tl.to("#s8", { opacity: 0, x: -60, duration: 0.4, ease: "power2.in" }, 64.95);

  /* ---------- S9 privacy 65.1 - 72.3 ---------- */
  swap("#scrSend", "#scrDevice", 65.05);
  tl.set("#s9", { opacity: 1 }, 65.15);
  tl.fromTo("#s9 .kicker", { opacity: 0 }, { opacity: 1, duration: 0.4 }, 65.2);
  K.wordsIn(tl, $("#v-h"), 65.3, { stagger: 0.06 });
  tl.set("#ripDevice", { opacity: 0.95, scale: 0.3 }, 67.6);
  tl.to("#ripDevice", { opacity: 0, scale: 3, duration: 0.6, ease: "power2.out" }, 67.6 + 0.01);
  tl.fromTo("#radioDot", { opacity: 0, scale: 0 }, { opacity: 1, scale: 1, duration: 0.3, ease: "back.out(3)" }, 67.7);
  tl.fromTo("#optDevice", { boxShadow: "0 0 0 0 rgba(152,15,134,0)" }, { boxShadow: "0 0 0 3px rgba(152,15,134,1)", duration: 0.3 }, 67.7);
  tl.fromTo("#devShield", { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.6, ease: "back.out(1.8)" }, 68.0);
  tl.fromTo(".vrow", { opacity: 0, x: -40 }, { opacity: 1, x: 0, duration: 0.5, ease: "power3.out", stagger: 0.55 }, 68.1);
  tl.to("#s9", { opacity: 0, y: -40, duration: 0.45, ease: "power2.in" }, 71.95);

  /* ---------- S10 CTA 72.4 - 79.5 ---------- */
  tl.set("#s10", { opacity: 1 }, 72.35);
  tl.fromTo("#flash2", { opacity: 0 }, { keyframes: [{ opacity: 1, duration: 0.12 }, { opacity: 0.35, duration: 1.6, ease: "power2.out" }] }, 72.55);
  K.markIn(tl, $("#tile2"), 72.6, 1);
  tl.fromTo("#letters2", { clipPath: "inset(0% 100% 0% 0%)", y: 10 }, { clipPath: "inset(0% 0% 0% 0%)", y: 0, duration: 0.8, ease: "expo.out" }, 73.0);
  K.wordsIn(tl, $("#tagline"), 73.6, { stagger: 0.1 });
  tl.fromTo("#ctaBtn", { opacity: 0, scale: 0.6, y: 20 }, { opacity: 1, scale: 1, y: 0, duration: 0.6, ease: "back.out(2)" }, 75.45);
  tl.to("#ctaBtn", { scale: 1.04, duration: 0.6, ease: "sine.inOut", yoyo: true, repeat: 3 }, 76.2);
  tl.fromTo("#pilot", { opacity: 0 }, { opacity: 1, duration: 0.6, ease: "power1.out" }, 76.4);
  tl.fromTo("#tile2", { y: 0 }, { y: -8, duration: 3, ease: "sine.inOut" }, 76.0);

  /* ---------- captions ---------- */
  K.captions(tl, $("#captions"), D, { size: 44, bottom: 34 });

  tl.set({}, {}, 79.5);
  return tl;
};
