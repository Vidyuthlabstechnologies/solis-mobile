// Builds the SOLIS site into marketing/site/dist.
//   node tools/build.mjs            (from marketing/site)
// Expands <x-header>, <x-footer>, <x-phone> and {{SITE}} in src/*.html,
// copies src/ and media/ into dist/. No dependencies.
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "src");
const MEDIA = join(ROOT, "media");
const DIST = join(ROOT, "dist");
export const SITE = process.env.SOLIS_SITE_URL || "https://solis-health.pages.dev";

const icon = (id, cls = "icon") => `<svg class="${cls}" aria-hidden="true"><use href="assets/icons.svg#${id}"/></svg>`;

const wordmark = `<svg class="brand-word" viewBox="312 72 373 96" role="img" aria-label="SOLIS"><path fill="currentColor" fill-rule="evenodd" d="M340.32 128.64A28.32 28.32 0 0 1 340.32 72L340.32 89.28A11.04 11.04 0 0 0 340.32 111.36ZM354.01 111.36A28.32 28.32 0 0 1 354.01 168L354.01 150.72A11.04 11.04 0 0 0 354.01 128.64ZM340.32 72H382.33V89.28H340.32ZM340.32 111.36H354.01V128.64H340.32ZM312 150.72H354.01V168H312ZM397.69 120A48 48 0 1 1 493.69 120A48 48 0 1 1 397.69 120ZM414.97 120A30.72 30.72 0 1 0 476.41 120A30.72 30.72 0 1 0 414.97 120ZM509.05 72H526.33V168H509.05ZM509.05 150.72H566.65V168H509.05ZM582.01 72H599.29V168H582.01ZM642.97 128.64A28.32 28.32 0 0 1 642.97 72L642.97 89.28A11.04 11.04 0 0 0 642.97 111.36ZM656.661 111.36A28.32 28.32 0 0 1 656.661 168L656.661 150.72A11.04 11.04 0 0 0 656.661 128.64ZM642.97 72H684.981V89.28H642.97ZM642.97 111.36H656.661V128.64H642.97ZM614.65 150.72H656.661V168H614.65Z"/></svg>`;

const markImg = `<img class="brand-mark" src="assets/img/solis-mark.svg" width="32" height="32" alt="">`;

function header(active) {
  const link = (href, label, key) => `<li><a href="${href}"${active === key ? ' aria-current="page"' : ""}>${label}</a></li>`;
  const home = active === "home" ? "" : "index.html";
  return `<a class="skip-link" href="#main">Skip to content</a>
<header class="site-header" id="top">
  <nav class="container nav" aria-label="Main">
    <a class="brand" href="index.html" aria-label="SOLIS home">${markImg}${wordmark}</a>
    <button class="menu-btn" type="button" aria-expanded="false" aria-controls="nav-links" aria-label="Open menu">${icon("menu")}</button>
    <ul class="nav-links" id="nav-links">
      ${link(home + "#how", "How it works", "")}
      ${link("pricing.html", "Pricing", "pricing")}
      ${link("security.html", "Security", "security")}
      ${link("get-started.html", "Get started", "get-started")}
      ${link("guide.html", "User guide", "guide")}
      <li class="nav-cta"><a class="btn btn-primary btn-sm" href="${home}#access">Request early access</a></li>
    </ul>
  </nav>
</header>`;
}

function footer() {
  return `<footer class="site-footer">
  <div class="container">
    <div class="footer-grid">
      <div>
        <a class="brand" href="index.html" aria-label="SOLIS home">${markImg}${wordmark}</a>
        <p>SOLIS listens to the visit, writes the note, and builds a clean claim, on the doctor's phone.</p>
      </div>
      <div>
        <h4>Product</h4>
        <ul>
          <li><a href="index.html#how">How a visit works</a></li>
          <li><a href="index.html#coding">Coding and claims</a></li>
          <li><a href="index.html#scan">Scan the cards</a></li>
          <li><a href="index.html#privacy">Privacy and control</a></li>
          <li><a href="pricing.html">Pricing</a></li>
        </ul>
      </div>
      <div>
        <h4>Resources</h4>
        <ul>
          <li><a href="get-started.html">Get started</a></li>
          <li><a href="guide.html">User guide</a></li>
          <li><a href="media/SOLIS-User-Guide.pdf">User guide (PDF)</a></li>
          <li><a href="security.html">Security and compliance</a></li>
          <li><a href="privacy.html">How data is handled</a></li>
          <li><a href="index.html#access">Request early access</a></li>
        </ul>
      </div>
    </div>
    <div class="footer-base">
      <span>&copy; 2026 SOLIS. Android app v1.0.0, pilot stage. iOS not yet released.</span>
      <span>CPT is a registered trademark of the American Medical Association.</span>
    </div>
  </div>
</footer>`;
}

const statusBar = `<div class="sb" aria-hidden="true"><span>9:41</span><svg viewBox="0 0 40 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="4.5" y="5.5" width="3" height="6.5" rx="1"/><rect x="9" y="3" width="3" height="9" rx="1"/><rect x="13.5" y="0.5" width="3" height="11.5" rx="1"/><rect x="21" y="1" width="16" height="10" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.2"/><rect x="22.8" y="2.8" width="10.5" height="6.4" rx="1.4"/><rect x="38" y="4" width="1.6" height="4" rx="0.8"/></svg></div>`;

function phone(attrs) {
  const src = attrs.src;
  const alt = attrs.alt ?? "";
  const cls = attrs.class ? " " + attrs.class : "";
  const sizes = attrs.sizes || "(max-width: 560px) 250px, 300px";
  const eager = "eager" in attrs;
  const dark = "dark" in attrs ? " dark" : "";
  const load = eager ? 'loading="eager" fetchpriority="high"' : 'loading="lazy"';
  return `<div class="phone${cls}"><div class="screen${dark}">${statusBar}<img src="assets/img/${src}-720.webp" srcset="assets/img/${src}-360.webp 360w, assets/img/${src}-720.webp 720w" sizes="${sizes}" width="412" height="915" alt="${alt}" ${load} decoding="async"></div></div>`;
}

function parseAttrs(s) {
  const out = {};
  for (const m of s.matchAll(/([a-z-]+)(?:="([^"]*)")?/g)) out[m[1]] = m[2] ?? "";
  return out;
}

// APK download (hosted on R2; Pages caps files at 25 MB). Edit tools/apk.json for a new build.
const APK_FILE = join(ROOT, "tools", "apk.json");
const APK = existsSync(APK_FILE) ? JSON.parse(readFileSync(APK_FILE, "utf8")) : { url: "#", version: "", size: "", sha256: "" };

export function render(html) {
  return html
    .replace(/\{\{APK_URL\}\}/g, APK.url)
    .replace(/\{\{APK_VERSION\}\}/g, APK.version)
    .replace(/\{\{APK_SIZE\}\}/g, APK.size)
    .replace(/\{\{APK_SHA256\}\}/g, APK.sha256)
    .replace(/<x-header(?:\s+active="([^"]*)")?\s*><\/x-header>/g, (_, a) => header(a || ""))
    .replace(/<x-footer\s*><\/x-footer>/g, () => footer())
    .replace(/<x-phone\s+([^>]*)><\/x-phone>/g, (_, a) => phone(parseAttrs(a)))
    .replace(/<x-icon\s+id="([^"]+)"(?:\s+class="([^"]*)")?\s*><\/x-icon>/g, (_, id, c) => icon(id, c ? "icon " + c : "icon"))
    .replace(/\{\{SITE\}\}/g, SITE);
}

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  rmSync(DIST, { recursive: true, force: true });
  mkdirSync(DIST, { recursive: true });
  cpSync(SRC, DIST, { recursive: true });
  if (existsSync(MEDIA)) cpSync(MEDIA, join(DIST, "media"), { recursive: true });
  for (const f of walk(DIST)) {
    if (/\.(html|xml|txt|webmanifest)$/.test(f) || f.endsWith("_headers")) {
      writeFileSync(f, render(readFileSync(f, "utf8")));
    }
  }
  // Pretty URLs on Pages, and a CSP hash for the one inline script.
  const { createHash } = await import("node:crypto");
  const hashes = new Set();
  const ver = Object.fromEntries(["site.css", "site.js", "icons.svg"].map((n) => [n, createHash("sha256").update(readFileSync(join(DIST, "assets", n))).digest("hex").slice(0, 10)]));
  for (const f of walk(DIST).filter((f) => f.endsWith(".html"))) {
    let h = readFileSync(f, "utf8")
      .replace(/assets\/(site\.css|site\.js|icons\.svg)/g, (m, n) => `${m}?v=${ver[n]}`)
      .replace(/href="index\.html#/g, 'href="/#')
      .replace(/href="index\.html"/g, 'href="/"')
      .replace(/href="(guide|privacy|pricing|security|get-started)\.html(#[^"]*)?"/g, (_, p, hash) => `href="/${p}${hash || ""}"`);
    for (const m of h.matchAll(/<script>([\s\S]*?)<\/script>/g)) hashes.add("'sha256-" + createHash("sha256").update(m[1]).digest("base64") + "'");
    writeFileSync(f, h);
  }
  const hp = join(DIST, "_headers");
  writeFileSync(hp, readFileSync(hp, "utf8").replace("'sha256-HASHJS'", [...hashes].join(" ")));
  const media = existsSync(join(DIST, "media")) ? readdirSync(join(DIST, "media")) : [];
  console.log(`built dist (${SITE}); media: ${media.join(", ") || "none"}`);
}
