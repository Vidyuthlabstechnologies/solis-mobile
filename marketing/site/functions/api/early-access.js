// POST /api/early-access
// Validates an early-access request, rate-limits by IP, and stores it in KV (binding LEADS).
// Never logs submission contents. The client IP is only kept as a salted hash for rate limiting.

const LIMIT_PER_HOUR = 8;
const MAX_BODY_BYTES = 10_000;
const ROLES = new Set([
  "Physician",
  "Nurse practitioner or PA",
  "Practice owner or manager",
  "Front desk",
  "Billing and coding",
  "EMS or ambulance",
  "Other",
]);
const EMAIL_RE = /^[^\s@<>()[\],;:"]+@[^\s@<>()[\],;:"]+\.[A-Za-z]{2,}$/;
const PHONE_RE = /^[0-9+().\-\s]{7,40}$/;

const json = (status, body, extra = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra },
  });

const clean = (v, max) =>
  typeof v === "string" ? v.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim().slice(0, max + 1) : "";

async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function validate(input) {
  const d = {
    name: clean(input.name, 120),
    practice: clean(input.practice, 160),
    role: clean(input.role, 60),
    email: clean(input.email, 200).toLowerCase(),
    phone: clean(input.phone, 40),
    specialty: clean(input.specialty, 120),
    message: clean(input.message, 2000),
  };
  const errors = {};
  if (d.name.length < 2 || d.name.length > 120) errors.name = "Please enter your name.";
  if (d.practice.length < 2 || d.practice.length > 160) errors.practice = "Please enter your practice or organization.";
  if (!ROLES.has(d.role)) errors.role = "Please choose your role.";
  if (!EMAIL_RE.test(d.email) || d.email.length > 200) errors.email = "Please enter a valid email address.";
  if (d.phone && !PHONE_RE.test(d.phone)) errors.phone = "Please enter a valid phone number, or leave it empty.";
  if (d.specialty.length < 2 || d.specialty.length > 120) errors.specialty = "Please enter your specialty.";
  if (d.message.length > 2000) errors.message = "Please keep the message under 2000 characters.";
  return { data: d, errors };
}

export async function onRequestPost({ request, env }) {
  if (!env.LEADS) return json(503, { ok: false, error: "unavailable" });

  // Same-origin browsers only (curl and server-side tests send no Origin).
  const origin = request.headers.get("origin");
  if (origin && new URL(origin).host !== new URL(request.url).host) return json(403, { ok: false, error: "forbidden" });

  const len = Number(request.headers.get("content-length") || 0);
  if (len > MAX_BODY_BYTES) return json(413, { ok: false, error: "too_large" });

  let input;
  const type = request.headers.get("content-type") || "";
  try {
    const raw = await request.text();
    if (raw.length > MAX_BODY_BYTES) return json(413, { ok: false, error: "too_large" });
    if (type.includes("application/json")) input = JSON.parse(raw);
    else if (type.includes("application/x-www-form-urlencoded")) input = Object.fromEntries(new URLSearchParams(raw));
    else return json(415, { ok: false, error: "unsupported_media_type" });
  } catch {
    return json(400, { ok: false, error: "bad_json" });
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) return json(400, { ok: false, error: "bad_request" });

  // Rate limit per IP (salted hash, never the raw address).
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const hour = Math.floor(Date.now() / 3_600_000);
  const ipHash = (await sha256(`${env.RATE_SALT || "solis-leads"}:${ip}`)).slice(0, 32);
  const rlKey = `rl:${ipHash}:${hour}`;
  const count = Number((await env.LEADS.get(rlKey)) || 0);
  if (count >= LIMIT_PER_HOUR) return json(429, { ok: false, error: "rate_limited" }, { "retry-after": "3600" });
  await env.LEADS.put(rlKey, String(count + 1), { expirationTtl: 3900 });

  // Honeypot: bots fill the hidden field. Pretend success, store nothing.
  if (typeof input.website === "string" && input.website.trim() !== "") return json(200, { ok: true });

  const { data, errors } = validate(input);
  if (Object.keys(errors).length) return json(400, { ok: false, error: "invalid", errors });

  const now = new Date();
  const id = `lead:${now.toISOString()}:${crypto.randomUUID().slice(0, 8)}`;
  const record = {
    ...data,
    submittedAt: now.toISOString(),
    country: request.cf?.country || null,
    userAgent: (request.headers.get("user-agent") || "").slice(0, 200),
  };
  await env.LEADS.put(id, JSON.stringify(record), { metadata: { at: record.submittedAt } });
  return json(200, { ok: true });
}

export async function onRequest({ request }) {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: { allow: "POST" } });
  return json(405, { ok: false, error: "method_not_allowed" }, { allow: "POST" });
}
