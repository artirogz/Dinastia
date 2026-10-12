#!/usr/bin/env node
// Smoke check of a deployed instance. Exits non-zero if any check fails.
//
//   node scripts/smoke.mjs https://app.example.ru
//   node scripts/smoke.mjs --base https://app.example.ru
//   SMOKE_BASE=https://app.example.ru node scripts/smoke.mjs
//
// Checks: home page, auth wall, dev login absent, health, security headers, Telegram webhook
// secret, TLS certificate lifetime. Uses only Node built-ins (Node 22: global fetch).

import tls from "node:tls";

const TIMEOUT_MS = 10_000;
const MIN_CERT_DAYS = 14;

function resolveBase(argv) {
  const flagAt = argv.indexOf("--base");
  const raw = flagAt >= 0 ? argv[flagAt + 1] : argv.find((a) => !a.startsWith("--")) ?? process.env.SMOKE_BASE;
  if (!raw) {
    console.error("usage: node scripts/smoke.mjs https://app.<domain>");
    process.exit(2);
  }
  return raw.replace(/\/+$/, "");
}

const base = resolveBase(process.argv.slice(2));
const baseUrl = new URL(base);

async function request(pathname, init = {}) {
  return fetch(`${base}${pathname}`, {
    redirect: "manual",
    signal: AbortSignal.timeout(TIMEOUT_MS),
    ...init,
  });
}

function certDaysLeft(hostname, port) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: hostname, port, servername: hostname, timeout: TIMEOUT_MS }, () => {
      const cert = socket.getPeerCertificate();
      socket.end();
      if (!cert || !cert.valid_to) return reject(new Error("no certificate"));
      resolve(Math.floor((new Date(cert.valid_to).getTime() - Date.now()) / 86_400_000));
    });
    socket.on("timeout", () => {
      socket.destroy();
      reject(new Error("TLS connect timeout"));
    });
    socket.on("error", reject);
  });
}

const checks = [
  {
    name: "GET / is 200",
    run: async () => {
      const res = await request("/");
      return { ok: res.status === 200, detail: `status ${res.status}` };
    },
  },
  {
    name: "GET /api/health is 200",
    run: async () => {
      const res = await request("/api/health");
      return { ok: res.status === 200, detail: `status ${res.status}` };
    },
  },
  {
    name: "GET /api/me without cookie is 401",
    run: async () => {
      const res = await request("/api/me");
      return { ok: res.status === 401, detail: `status ${res.status}` };
    },
  },
  {
    name: "POST /api/dev/login is 404",
    run: async () => {
      const res = await request("/api/dev/login", { method: "POST" });
      return { ok: res.status === 404, detail: `status ${res.status}` };
    },
  },
  {
    name: "security headers on /",
    run: async () => {
      const res = await request("/");
      const h = res.headers;
      const missing = [];
      if (!(h.get("strict-transport-security") ?? "").includes("max-age")) missing.push("Strict-Transport-Security");
      if ((h.get("x-content-type-options") ?? "").toLowerCase() !== "nosniff") missing.push("X-Content-Type-Options");
      if (!h.get("referrer-policy")) missing.push("Referrer-Policy");
      if (!(h.get("content-security-policy") ?? "").includes("frame-ancestors")) missing.push("CSP frame-ancestors");
      // X-Frame-Options would block Telegram Web, which embeds the app in an iframe
      if (h.get("x-frame-options")) missing.push("X-Frame-Options must be absent");
      return { ok: missing.length === 0, detail: missing.length ? `problem: ${missing.join(", ")}` : "all present" };
    },
  },
  {
    name: "POST /api/tg/webhook without secret is 401",
    run: async () => {
      const res = await request("/api/tg/webhook", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      });
      return { ok: res.status === 401, detail: `status ${res.status}` };
    },
  },
  {
    name: `TLS certificate has >= ${MIN_CERT_DAYS} days left`,
    run: async () => {
      if (baseUrl.protocol !== "https:") return { ok: false, detail: "base URL is not https" };
      const days = await certDaysLeft(baseUrl.hostname, Number(baseUrl.port) || 443);
      return { ok: days >= MIN_CERT_DAYS, detail: `${days} days left` };
    },
  },
];

async function main() {
  const rows = [];
  for (const check of checks) {
    try {
      const { ok, detail } = await check.run();
      rows.push({ name: check.name, ok, detail });
    } catch (err) {
      rows.push({ name: check.name, ok: false, detail: err instanceof Error ? err.message : String(err) });
    }
  }

  const width = Math.max(...rows.map((r) => r.name.length));
  console.log(`smoke ${base}`);
  for (const r of rows) {
    console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.name.padEnd(width)}  ${r.detail}`);
  }
  const failed = rows.filter((r) => !r.ok).length;
  console.log(failed === 0 ? "\nall checks passed" : `\n${failed} check(s) failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main();
