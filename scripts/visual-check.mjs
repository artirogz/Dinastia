#!/usr/bin/env node
// Screenshots of the app screens at the reference phone viewport (390x844 @2x).
//
//   node scripts/visual-check.mjs                       all routes
//   node scripts/visual-check.mjs --only lesson,profile only the named routes
//   node scripts/visual-check.mjs --base http://localhost:3000
//   node scripts/visual-check.mjs --routes design/routes.json   replace the route map
//   node scripts/visual-check.mjs --label m1            put files in design/visual-check/m1 instead of a timestamp
//   node scripts/visual-check.mjs --no-auth             skip the dev login (M0/M1, before /api/dev/login exists)
//
// The script first waits for GET /api/health to answer (up to 60 s), so it can be started right after
// `npm run dev &`. Routes marked auth:true need the dev server running with DEV_LOGIN=1
// (NODE_ENV != production): the script logs in through POST /api/dev/login, keeps the cookie in the
// browser context and then opens every route. With --no-auth every route is opened anonymously.
// Output: design/visual-check/<stamp>/<name>.png, one path printed per line.
//
// Claude: verify the Playwright API against current docs if a call below fails
// (browser.newContext options, page.goto waitUntil values, document.fonts).

import { chromium } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { readFile } from "node:fs/promises";
import path from "node:path";

// Route map: name -> path, or { path, auth: false } for screens that must be captured without a session.
// Names match the file names in design/screens (see docs/07-screens-and-ux.md section 5).
const DEFAULT_ROUTES = {
  home: { path: "/", auth: false }, // public landing; the only route that exists at M0
  courses: "/courses",
  course: "/courses/example-course",
  lesson: "/lessons/1",
  lesson_notes: "/lessons/1?tab=notes",
  lesson_materials: "/lessons/1?tab=materials",
  lesson_assignment: "/lessons/1?tab=assignment",
  lesson_discussion: "/lessons/1?tab=discussion",
  profile: "/profile",
  // locked=1 forces the "no access" rendering; honoured only outside production builds
  paywall: "/courses/example-course?locked=1",
  login: { path: "/login", auth: false },
};

const VIEWPORT = { width: 390, height: 844 };
const DEVICE_SCALE_FACTOR = 2;
const NAV_TIMEOUT_MS = 30_000;
const HEALTH_TIMEOUT_MS = 60_000;

function parseArgs(argv) {
  const args = { base: "http://localhost:3000", only: null, routes: null, label: null, noAuth: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--base") args.base = argv[++i];
    else if (flag === "--only") args.only = argv[++i].split(",").map((s) => s.trim()).filter(Boolean);
    else if (flag === "--routes") args.routes = argv[++i];
    else if (flag === "--label") args.label = argv[++i];
    else if (flag === "--no-auth") args.noAuth = true;
    else if (flag === "--help" || flag === "-h") {
      console.log("usage: node scripts/visual-check.mjs [--only a,b] [--base URL] [--routes file.json] [--label name] [--no-auth]");
      process.exit(0);
    } else {
      console.error(`unknown argument: ${flag}`);
      process.exit(2);
    }
  }
  if (!args.base) {
    console.error("--base needs a value");
    process.exit(2);
  }
  args.base = args.base.replace(/\/+$/, "");
  return args;
}

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function normalize(entry, noAuth) {
  const e = typeof entry === "string" ? { path: entry, auth: true } : { auth: true, ...entry };
  return noAuth ? { ...e, auth: false } : e;
}

// Bundled Chromium first; if Playwright ships none for this OS (e.g. macOS 13 since 1.64), fall back to
// the installed Google Chrome. PW_CHANNEL=chrome forces the fallback.
async function launchBrowser() {
  if (process.env.PW_CHANNEL) return chromium.launch({ channel: process.env.PW_CHANNEL });
  try {
    return await chromium.launch();
  } catch (err) {
    console.error(`bundled chromium unavailable (${err.message.split("\n")[0]}), using installed Chrome`);
    return chromium.launch({ channel: "chrome" });
  }
}

async function newContext(browser) {
  return browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: DEVICE_SCALE_FACTOR,
    isMobile: true,
    hasTouch: true,
  });
}

async function waitForServer(base) {
  // Poll /api/health (created at M0) so the script can start right after `npm run dev &`.
  const deadline = Date.now() + HEALTH_TIMEOUT_MS;
  let lastError = "no attempt";
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/api/health`);
      if (res.ok) return;
      lastError = `HTTP ${res.status}`;
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`${base}/api/health did not answer 200 within ${HEALTH_TIMEOUT_MS / 1000}s (${lastError}); is the dev server running?`);
}

async function devLogin(context, base) {
  // The request context shares the cookie jar with pages of the same browser context.
  // Origin is required by the same-origin guard on mutating routes (docs/03 §2); send our own base.
  const res = await context.request.post(`${base}/api/dev/login`, { data: {}, headers: { Origin: base } });
  if (!res.ok()) {
    throw new Error(
      `POST /api/dev/login returned ${res.status()}; start the app with DEV_LOGIN=1 and NODE_ENV!=production`,
    );
  }
}

async function capture(context, base, name, entry, outDir) {
  const page = await context.newPage();
  try {
    const response = await page.goto(`${base}${entry.path}`, { waitUntil: "networkidle", timeout: NAV_TIMEOUT_MS });
    if (!response) throw new Error("no response");
    if (response.status() >= 400) throw new Error(`HTTP ${response.status()}`);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForLoadState("networkidle");

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (overflow > 0) console.warn(`warning: ${name} scrolls horizontally by ${overflow}px`);

    const file = path.join(outDir, `${name}.png`);
    await page.screenshot({ path: file, fullPage: true });
    return { name, file, ok: true };
  } catch (err) {
    return { name, file: null, ok: false, error: err instanceof Error ? err.message : String(err) };
  } finally {
    await page.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const routes = args.routes ? JSON.parse(await readFile(args.routes, "utf8")) : DEFAULT_ROUTES;

  const names = args.only ?? Object.keys(routes);
  const unknown = names.filter((n) => !(n in routes));
  if (unknown.length > 0) {
    console.error(`unknown route name(s): ${unknown.join(", ")}. Available: ${Object.keys(routes).join(", ")}`);
    process.exit(2);
  }

  const outDir = path.join("design", "visual-check", args.label ?? stamp());
  await mkdir(outDir, { recursive: true });

  await waitForServer(args.base);

  const browser = await launchBrowser();
  const results = [];
  try {
    const authed = await newContext(browser);
    const anonymous = await newContext(browser);
    if (names.some((n) => normalize(routes[n], args.noAuth).auth)) await devLogin(authed, args.base);

    for (const name of names) {
      const entry = normalize(routes[name], args.noAuth);
      results.push(await capture(entry.auth ? authed : anonymous, args.base, name, entry, outDir));
    }
  } finally {
    await browser.close();
  }

  for (const r of results) {
    if (r.ok) console.log(r.file);
    else console.error(`FAILED ${r.name}: ${r.error}`);
  }
  if (results.some((r) => !r.ok)) process.exit(1);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
