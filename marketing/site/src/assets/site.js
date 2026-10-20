// SOLIS site behaviour: header, menu, reveal, visit steps, optional media,
// early-access form, guide table of contents. No dependencies.
(function () {
  "use strict";
  var doc = document;
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var printMode = /[?&]print=1/.test(location.search);

  // Header border on scroll
  var header = doc.querySelector(".site-header");
  if (header) {
    var onScroll = function () { header.classList.toggle("scrolled", window.scrollY > 8); };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  // Mobile menu
  var menuBtn = doc.querySelector(".menu-btn");
  var links = doc.getElementById("nav-links");
  if (menuBtn && links) {
    var setMenu = function (open) {
      links.classList.toggle("open", open);
      menuBtn.setAttribute("aria-expanded", String(open));
      menuBtn.setAttribute("aria-label", open ? "Close menu" : "Open menu");
      var use = menuBtn.querySelector("use");
      if (use) use.setAttribute("href", use.getAttribute("href").replace(/#.*$/, "#" + (open ? "close" : "menu")));
    };
    menuBtn.addEventListener("click", function () { setMenu(!links.classList.contains("open")); });
    links.addEventListener("click", function (e) { if (e.target.closest("a")) setMenu(false); });
    doc.addEventListener("keydown", function (e) { if (e.key === "Escape") setMenu(false); });
  }

  // Reveal on scroll
  var reveals = doc.querySelectorAll(".reveal");
  if (printMode || reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) { io.observe(el); });
  }

  // Visit steps (tabs that swap the phone screen)
  var tabs = Array.prototype.slice.call(doc.querySelectorAll(".step-tab"));
  var shots = doc.querySelectorAll("#visit-shot .stack img");
  if (tabs.length && shots.length) {
    var select = function (i, focus) {
      tabs.forEach(function (t, j) {
        var on = i === j;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        if (on && focus) t.focus();
      });
      shots.forEach(function (img, j) {
        if (j === i) img.loading = "eager";
        img.classList.toggle("on", j === i);
      });
      var panel = doc.getElementById("visit-shot");
      if (panel) panel.setAttribute("aria-labelledby", tabs[i].id);
    };
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { select(i, false); });
      t.addEventListener("keydown", function (e) {
        var k = e.key, n = tabs.length;
        if (k === "ArrowDown" || k === "ArrowRight") { e.preventDefault(); select((i + 1) % n, true); }
        if (k === "ArrowUp" || k === "ArrowLeft") { e.preventDefault(); select((i - 1 + n) % n, true); }
        if (k === "Home") { e.preventDefault(); select(0, true); }
        if (k === "End") { e.preventDefault(); select(n - 1, true); }
      });
    });
    // Warm the other screens once the section is near.
    if ("IntersectionObserver" in window) {
      var warm = new IntersectionObserver(function (en) {
        if (en[0].isIntersecting) { shots.forEach(function (img) { img.loading = "eager"; }); warm.disconnect(); }
      }, { rootMargin: "400px" });
      warm.observe(doc.getElementById("visit-shot"));
    }
    select(0, false);
  }

  // Optional media: sections stay hidden unless the file really exists.
  function exists(url, type) {
    if (location.protocol === "file:") return Promise.resolve(false);
    return fetch(url, { method: "HEAD", cache: "no-store" }).then(function (r) {
      if (!r.ok) return false;
      var ct = (r.headers.get("content-type") || "").toLowerCase();
      return ct.indexOf(type) !== -1;
    }).catch(function () { return false; });
  }
  var film = doc.getElementById("film");
  var video = doc.getElementById("film-video");
  if (film && video) {
    var src = "media/solis-launch-16x9.mp4";
    exists(src, "video").then(function (ok) {
      if (!ok) return;
      exists("media/poster.jpg", "image").then(function (hasPoster) {
        if (hasPoster) video.poster = "media/poster.jpg";
        var s = doc.createElement("source");
        s.src = src; s.type = "video/mp4";
        video.appendChild(s);
        film.hidden = false;
        var r = film.querySelectorAll(".reveal");
        r.forEach(function (el) { el.classList.add("in"); });
      });
    });
  }
  var brochure = doc.getElementById("brochure-card");
  if (brochure) exists(brochure.getAttribute("href"), "pdf").then(function (ok) { if (ok) { brochure.hidden = false; brochure.classList.add("in"); } });
  var guidePdf = doc.querySelectorAll("[data-pdf-check]");
  guidePdf.forEach(function (a) { exists(a.getAttribute("href"), "pdf").then(function (ok) { if (!ok) a.hidden = true; }); });

  // Early-access form
  var form = doc.getElementById("access-form");
  if (form) {
    var alertBox = doc.getElementById("form-alert");
    var alertText = doc.getElementById("form-alert-text");
    var submit = doc.getElementById("access-submit");
    var success = doc.getElementById("access-success");
    var fields = ["name", "email", "practice", "role", "specialty", "phone", "message"];
    var emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

    var setError = function (name, msg) {
      var input = form.elements[name];
      var err = doc.getElementById("e-" + name);
      if (!input || !err) return;
      if (msg) {
        input.setAttribute("aria-invalid", "true");
        input.setAttribute("aria-describedby", "e-" + name);
        err.textContent = msg;
        err.classList.add("show");
      } else {
        input.removeAttribute("aria-invalid");
        input.removeAttribute("aria-describedby");
        err.textContent = "";
        err.classList.remove("show");
      }
    };
    var showAlert = function (msg) {
      alertText.textContent = msg || "";
      alertBox.classList.toggle("show", !!msg);
    };
    var validate = function (data) {
      var errors = {};
      if (data.name.length < 2) errors.name = "Please enter your name.";
      if (!emailRe.test(data.email)) errors.email = "Please enter a valid email address.";
      if (data.practice.length < 2) errors.practice = "Please enter your practice or organization.";
      if (!data.role) errors.role = "Please choose your role.";
      if (data.specialty.length < 2) errors.specialty = "Please enter your specialty.";
      if (data.phone && !/^[0-9+().\-\s]{7,40}$/.test(data.phone)) errors.phone = "Please enter a valid phone number, or leave it empty.";
      return errors;
    };

    fields.forEach(function (f) {
      var el = form.elements[f];
      if (el) el.addEventListener("input", function () { setError(f, ""); });
    });

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      showAlert("");
      var data = {};
      fields.concat(["website"]).forEach(function (f) { data[f] = ((form.elements[f] && form.elements[f].value) || "").trim(); });
      var errors = validate(data);
      fields.forEach(function (f) { setError(f, errors[f] || ""); });
      var first = Object.keys(errors)[0];
      if (first) { form.elements[first].focus(); return; }

      submit.disabled = true;
      var label = submit.textContent;
      submit.textContent = "Sending";
      fetch("/api/early-access", {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(data)
      }).then(function (r) {
        return r.json().catch(function () { return {}; }).then(function (body) { return { status: r.status, body: body }; });
      }).then(function (res) {
        if (res.status === 200 && res.body.ok) {
          form.hidden = true;
          success.hidden = false;
          success.focus();
          return;
        }
        if (res.status === 400 && res.body.errors) {
          Object.keys(res.body.errors).forEach(function (f) { setError(f, res.body.errors[f]); });
          showAlert("Please check the highlighted fields.");
        } else if (res.status === 429) {
          showAlert("Too many requests from this network. Please try again in an hour.");
        } else {
          showAlert("Something went wrong on our side. Please try again in a few minutes.");
        }
      }).catch(function () {
        showAlert("We could not reach the server. Check your connection and try again.");
      }).then(function () {
        submit.disabled = false;
        submit.textContent = label;
      });
    });
  }

  // Guide: table of contents highlight and print mode
  if (printMode) {
    doc.querySelectorAll("details").forEach(function (d) { d.open = true; });
    doc.querySelectorAll("img[loading=lazy]").forEach(function (i) { i.loading = "eager"; });
  }
  window.addEventListener("beforeprint", function () { doc.querySelectorAll(".faq details").forEach(function (d) { d.open = true; }); });

  var tocLinks = Array.prototype.slice.call(doc.querySelectorAll(".toc a"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    tocLinks.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var visible = {};
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { visible[en.target.id] = en.isIntersecting; });
      var current = null;
      tocLinks.some(function (a) {
        var id = a.getAttribute("href").slice(1);
        if (visible[id]) { current = id; return true; }
        return false;
      });
      if (current) {
        tocLinks.forEach(function (a) { a.classList.remove("active"); a.removeAttribute("aria-current"); });
        byId[current].classList.add("active");
        byId[current].setAttribute("aria-current", "true");
      }
    }, { rootMargin: "-90px 0px -65% 0px" });
    Object.keys(byId).forEach(function (id) { var s = doc.getElementById(id); if (s) spy.observe(s); });
  }
  var tocMobile = doc.querySelector(".toc-mobile");
  if (tocMobile) tocMobile.addEventListener("click", function (e) { if (e.target.closest("a")) tocMobile.open = false; });
})();

// Pricing: annual / monthly toggle
(function () {
  "use strict";
  var plans = document.querySelector(".plans");
  var btns = document.querySelectorAll(".billing-toggle button");
  if (!plans || !btns.length) return;
  btns.forEach(function (b) {
    b.addEventListener("click", function () {
      var monthly = b.getAttribute("data-period") === "monthly";
      plans.classList.toggle("monthly", monthly);
      btns.forEach(function (o) { o.setAttribute("aria-pressed", String(o === b)); });
    });
  });
})();
