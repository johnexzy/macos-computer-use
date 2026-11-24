/**
 * Reproducible end-to-end BUA (Browser-Use Agent) benchmark comparing:
 *   - Baseline Wave 1/2 AX (recorded from 7edbf2f9-7e95-409e-8042-1163a245a70b + raw JSON size)
 *   - Layer A: Optimized Native AX (short disjoint refs, compact MCP text formatter, AXShowMenu fix,
 *              compound act(..., observeAfter), open(..., observe))
 *   - Layer B: MV3 Native Messaging Chromium Extension Accelerator (browser tool: openTab, snapshot,
 *              compound act, navigate, parallel batchRead) + native TextEdit/clipboard
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { Session, root } from "./mcp-session.mjs";

const CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const BRAVE_BIN = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
const EXT_DIR = path.join(root, "extension", "chromium");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const unwrapNative = (resp) => {
  assert.ok(!resp.result?.isError, `Native MCP error: ${JSON.stringify(resp.result)}`);
  const env = resp.result.structuredContent;
  assert.notEqual(env.body.result, "error", `Runtime error: ${JSON.stringify(env.body.data)}`);
  return {
    data: env.body.data,
    compactText: resp.result.content?.[0]?.text ?? "",
    rawJsonBytes: Buffer.byteLength(JSON.stringify(env), "utf8"),
    compactBytes: Buffer.byteLength(resp.result.content?.[0]?.text ?? "", "utf8"),
  };
};

const unwrapBrowser = (resp) => {
  assert.ok(!resp.result?.isError, `Browser MCP error: ${JSON.stringify(resp.result)}`);
  return {
    data: resp.result.structuredContent.data,
    compactText: resp.result.content?.[0]?.text ?? "",
    rawJsonBytes: Buffer.byteLength(JSON.stringify(resp.result.structuredContent), "utf8"),
    compactBytes: Buffer.byteLength(resp.result.content?.[0]?.text ?? "", "utf8"),
  };
};

// Local deterministic dense-DOM server (320 rows + interactive form + 3 profile subpages)
function startLocalServer() {
  const profiles = {
    "/p/alpha": { name: "AlphaPay", city: "Lagos, Nigeria", sector: "Payments · FinTech", summary: "Instant cross-border merchant settlement across West Africa. Raised $120M across 4 rounds." },
    "/p/beta": { name: "BetaBank", city: "Ikeja, Nigeria", sector: "Digital Banking · Credit", summary: "Working capital and POS banking for 400k SMEs in Nigeria. Raised $85M across 3 rounds." },
    "/p/gamma": { name: "GammaRail", city: "Abuja, Nigeria", sector: "Infrastructure · APIs", summary: "Real-time bank-to-bank open banking rails for African fintechs. Raised $60M across 2 rounds." },
  };
  const noise = Array.from({ length: 320 }, (_, i) => `<p>Dense market feed update row #${i + 1} with summary metrics</p>`).join("\n");
  const indexHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>BUA Dense Directory</title>
<style>body{font-family:-apple-system,sans-serif;margin:16px}.panel{position:fixed;top:12px;right:12px;width:320px;background:#fff;border:1px solid #ccc;padding:12px}</style>
</head><body>
  <h1>African FinTech Directory</h1>
  <div class="panel">
    <h2 id="status">READY</h2>
    <input id="q" type="text" aria-label="Filter Query" placeholder="Filter..." />
    <label><input id="verified" type="checkbox" aria-label="Verified Only" /> Verified Only</label>
    <button id="apply" type="button" onclick="
      document.getElementById('status').textContent = 'APPLIED:' + document.getElementById('q').value + ':' + document.getElementById('verified').checked;
    ">Apply Filter</button>
    <ul>
      <li><a href="/p/alpha">AlphaPay</a></li>
      <li><a href="/p/beta">BetaBank</a></li>
      <li><a href="/p/gamma">GammaRail</a></li>
    </ul>
  </div>
  <div class="noise">${noise}</div>
</body></html>`;

  const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    const p = profiles[req.url];
    if (p) {
      res.end(`<!doctype html><html><head><meta charset="utf-8"><title>${p.name} — Profile</title></head>
        <body><main><h1>${p.name}</h1><p>Location: ${p.city}</p><p>Sector: ${p.sector}</p><p>${p.summary}</p><a href="/directory">Back to Directory</a></main></body></html>`);
    } else {
      res.end(indexHtml);
    }
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, baseUrl: `http://127.0.0.1:${server.address().port}` })));
}

const report = {
  timestamp: new Date().toISOString(),
  localDense: {},
  liveStartuplist: {},
};

const { server, baseUrl } = await startLocalServer();
const chromeProfile = fs.mkdtempSync(path.join(os.tmpdir(), "cua-bench-chrome-"));
const braveProfile = fs.mkdtempSync(path.join(os.tmpdir(), "cua-bench-brave-"));
let chromeProc = null;
let braveProc = null;
const session = new Session();

try {
  await session.initialize();

  // =========================================================================
  // PART 1: Layer A (Optimized Native AX) on Local Dense App (Chrome)
  // =========================================================================
  chromeProc = spawn(CHROME_BIN, [
    `--user-data-dir=${chromeProfile}`,
    "--no-first-run", "--no-default-browser-check", "--disable-default-apps",
    "--window-position=60,60", "--window-size=1020,760",
    `${baseUrl}/directory`,
  ], { stdio: "ignore" });

  let chromeTarget = null;
  for (let i = 0; i < 60; i++) {
    const t = unwrapNative(await session.tool("targets", { bundleId: "com.google.Chrome" })).data;
    chromeTarget = (t.targets ?? []).find((w) => w.key.pid === chromeProc.pid && w.title.includes("BUA Dense Directory"));
    if (chromeTarget) break;
    await sleep(200);
  }
  assert.ok(chromeTarget, "Chrome local benchmark window did not appear");
  await sleep(300);

  const aStart = Date.now();
  let aCalls = 0;

  // 1a. Observe full webArea vs interactiveOnly (measure payload compression!)
  const tObsFull = Date.now();
  const obsFull = unwrapNative(await session.tool("observe", {
    target: chromeTarget.key, scope: "webArea", includeValues: true,
  }));
  const fullObsMs = Date.now() - tObsFull;
  aCalls++;

  const tObsInt = Date.now();
  const obsInt = unwrapNative(await session.tool("observe", {
    target: chromeTarget.key, scope: "webArea", interactiveOnly: true,
  }));
  const intObsMs = Date.now() - tObsInt;
  aCalls++;

  // 1b. Compound act (fill + check + submit + observeAfter in ONE tool call!)
  const qEl = obsInt.data.elements.find((e) => e.label === "Filter Query");
  const cbEl = obsInt.data.elements.find((e) => e.label === "Verified Only");
  const applyEl = obsInt.data.elements.find((e) => e.label === "Apply Filter");
  assert.ok(qEl && cbEl && applyEl, "Expected form controls in interactiveOnly observation");

  const tForm = Date.now();
  const formAct = unwrapNative(await session.tool("act", {
    target: chromeTarget.key,
    observationId: obsInt.data.observationId,
    steps: [
      { actionId: "fill", operation: { kind: "setValue", params: { elementRef: qEl.reference, value: "Nigeria" } } },
      { actionId: "check", operation: { kind: "press", params: { elementRef: cbEl.reference } } },
      { actionId: "apply", operation: { kind: "press", params: { elementRef: applyEl.reference } } },
    ],
    observeAfter: { scope: "webArea", includeValues: true, query: "APPLIED" },
  }));
  const formCompoundMs = Date.now() - tForm;
  aCalls++;
  assert.ok(formAct.data.observation?.elements.some((e) => (e.value || e.label || "").includes("APPLIED:Nigeria:true")),
    "Compound observeAfter must confirm form mutation in the same call");

  // 1c. Visit 3 profiles sequentially using compound act(expect: urlContains, observeAfter: includeValues)!
  const tProfiles = Date.now();
  let curObs = obsInt.data;
  const axProfilesRead = [];
  for (const [label, slug] of [["AlphaPay", "/p/alpha"], ["BetaBank", "/p/beta"], ["GammaRail", "/p/gamma"]]) {
    const link = curObs.elements.find((e) => e.label === label);
    assert.ok(link, `Missing link ${label}`);
    const navRes = unwrapNative(await session.tool("act", {
      target: chromeTarget.key,
      observationId: curObs.observationId,
      steps: [{
        actionId: `open-${label}`,
        operation: { kind: "press", params: { elementRef: link.reference } },
        expect: { kind: "urlContains", params: { contains: slug } },
      }],
      observeAfter: { scope: "webArea", includeValues: true },
    }));
    aCalls++;
    const profileObs = navRes.data.observation;
    assert.ok(profileObs, `Missing observeAfter on ${label}`);
    axProfilesRead.push({ label, elements: profileObs.elements.length, compactBytes: navRes.compactBytes, rawBytes: navRes.rawJsonBytes });
    const backLink = profileObs.elements.find((e) => e.label === "Back to Directory");
    assert.ok(backLink, `Missing Back link on ${label}`);
    const backRes = unwrapNative(await session.tool("act", {
      target: chromeTarget.key,
      observationId: profileObs.observationId,
      steps: [{
        actionId: `back-${label}`,
        operation: { kind: "press", params: { elementRef: backLink.reference } },
        expect: { kind: "urlContains", params: { contains: "/directory" } },
      }],
      observeAfter: { scope: "webArea", interactiveOnly: true },
    }));
    aCalls++;
    curObs = backRes.data.observation;
  }
  const ax3ProfilesMs = Date.now() - tProfiles;

  report.localDense.layerA_AX = {
    totalToolCalls: aCalls,
    totalWallMs: Date.now() - aStart,
    fullWebAreaElements: obsFull.data.elements.length,
    fullWebAreaRawBytes: obsFull.rawJsonBytes,
    fullWebAreaCompactBytes: obsFull.compactBytes,
    fullWebAreaCompressionRatio: +(obsFull.rawJsonBytes / obsFull.compactBytes).toFixed(2),
    fullObsMs,
    interactiveElements: obsInt.data.elements.length,
    interactiveRawBytes: obsInt.rawJsonBytes,
    interactiveCompactBytes: obsInt.compactBytes,
    intObsMs,
    compoundFormMs: formCompoundMs,
    threeProfilesSequentialMs: ax3ProfilesMs,
    profiles: axProfilesRead,
  };

  // =========================================================================
  // PART 2: Layer B (MV3 Native Messaging Extension) on Brave Browser
  // =========================================================================
  assert.ok(fs.existsSync(BRAVE_BIN), "Brave Browser required for automated --load-extension benchmark");
  braveProc = spawn(BRAVE_BIN, [
    `--user-data-dir=${braveProfile}`,
    `--load-extension=${EXT_DIR}`,
    "--no-first-run", "--no-default-browser-check", "--disable-default-apps",
    "--window-position=120,100", "--window-size=1020,760",
    "about:blank",
  ], { stdio: "ignore" });

  // Wait for extension Native Messaging bridge to connect!
  let connected = false;
  let extStatus = null;
  for (let i = 0; i < 60; i++) {
    extStatus = unwrapBrowser(await session.tool("browser", { action: "status" })).data;
    if (extStatus.connected) {
      connected = true;
      break;
    }
    await sleep(250);
  }
  assert.ok(connected, `MV3 extension bridge did not connect within 15s (last status: ${JSON.stringify(extStatus)})`);

  // Verify capabilities reports browserExtension connected=true too!
  const capResp = await session.tool("capabilities", {});
  assert.equal(capResp.result.structuredContent.browserExtension?.connected, true,
    "capabilities must report browserExtension.connected === true");

  const bStart = Date.now();
  let bCalls = 0;

  // 2a. Open local dense page in background tab + get compact snapshot in ONE call
  const tBOpen = Date.now();
  const bOpen = unwrapBrowser(await session.tool("browser", {
    action: "openTab", url: `${baseUrl}/directory`, active: false, returnSnapshot: true, interactiveOnly: true,
  }));
  const bOpenMs = Date.now() - tBOpen;
  bCalls++;
  const tabId = bOpen.data.tabId;
  const snap1 = bOpen.data.snapshot;

  // 2b. Measure pure DOM snapshot latency + bytes
  const tBSnap = Date.now();
  const bSnap = unwrapBrowser(await session.tool("browser", {
    action: "snapshot", tabId, interactiveOnly: true,
  }));
  const bSnapMs = Date.now() - tBSnap;
  bCalls++;

  // 2c. Compound DOM form fill + check + submit + returnSnapshot + includeText in ONE call
  const bQ = bSnap.data.snapshot.elements.find((e) => e.label === "Filter Query");
  const bCb = bSnap.data.snapshot.elements.find((e) => e.label === "Verified Only");
  const bApply = bSnap.data.snapshot.elements.find((e) => e.label === "Apply Filter");
  assert.ok(bQ && bCb && bApply, "Expected DOM controls in browser snapshot");

  const tBForm = Date.now();
  const bForm = unwrapBrowser(await session.tool("browser", {
    action: "act",
    tabId,
    snapshotId: bSnap.data.snapshot.snapshotId,
    steps: [
      { kind: "type", ref: bQ.ref, value: "Nigeria" },
      { kind: "click", ref: bCb.ref },
      { kind: "click", ref: bApply.ref },
    ],
    returnSnapshot: true,
    includeText: true,
    settleMs: 50,
  }));
  const bFormMs = Date.now() - tBForm;
  bCalls++;
  assert.ok(bForm.data.snapshot?.text?.includes("APPLIED:Nigeria:true"),
    "Browser compound act must confirm form state in one round-trip");

  // 2d. Parallel batchRead of all 3 profiles in background tabs in ONE single tool call!
  const tBBatch = Date.now();
  const bBatch = unwrapBrowser(await session.tool("browser", {
    action: "batchRead",
    urls: [`${baseUrl}/p/alpha`, `${baseUrl}/p/beta`, `${baseUrl}/p/gamma`],
    closeAfter: true,
    settleMs: 100,
    concurrency: 3,
  }));
  const bBatchMs = Date.now() - tBBatch;
  bCalls++;
  assert.equal(bBatch.data.pages.length, 3);
  assert.ok(bBatch.data.pages.every((p) => p.ok && p.text.includes("Nigeria")));

  await session.tool("browser", { action: "closeTab", tabId });

  report.localDense.layerB_Extension = {
    totalToolCalls: bCalls,
    totalWallMs: Date.now() - bStart,
    openAndSnapshotMs: bOpenMs,
    pureSnapshotMs: bSnapMs,
    snapshotElements: snap1.elements.length,
    snapshotRawBytes: bSnap.rawJsonBytes,
    snapshotCompactBytes: bSnap.compactBytes,
    compoundFormMs: bFormMs,
    threeProfilesParallelBatchMs: bBatchMs,
    batchReadCompactBytes: bBatch.compactBytes,
  };

  // =========================================================================
  // PART 3: Real-World Live Benchmark — StartupList Africa (Nigeria)
  // =========================================================================
  // 3a. Layer B live StartupList Africa: open filtered directory + batchRead 3 Nigerian fintechs!
  const slBStart = Date.now();
  let slBCalls = 0;

  const tSlOpen = Date.now();
  const slOpenRaw = unwrapBrowser(await session.tool("browser", {
    action: "openTab",
    url: "https://www.startuplist.africa/startups?country=nigeria",
    active: false,
    returnSnapshot: true,
    interactiveOnly: true,
    settleMs: 1200,
    budgetMs: 25000,
  }));
  let slDir = slOpenRaw;
  let startupLinks = (slDir.data.snapshot.elements ?? [])
    .filter((e) => e.role === "link" && typeof e.href === "string" && /\/startups\/[a-z0-9-]+$/i.test(e.href))
    .filter((e, idx, arr) => arr.findIndex((x) => x.href === e.href) === idx)
    .slice(0, 3);
  if (startupLinks.length < 3) {
    // Wait for SPA cards to finish async fetch & re-snapshot cleanly!
    const waited = unwrapBrowser(await session.tool("browser", {
      action: "act",
      tabId: slOpenRaw.data.tabId,
      steps: [{ kind: "waitFor", textContains: "OPay", timeoutMs: 12000 }],
      returnSnapshot: true,
      interactiveOnly: true,
      settleMs: 300,
      budgetMs: 20000,
    }));
    slDir = waited;
    slBCalls++;
    startupLinks = (slDir.data.snapshot.elements ?? [])
      .filter((e) => e.role === "link" && typeof e.href === "string" && /\/startups\/[a-z0-9-]+$/i.test(e.href))
      .filter((e, idx, arr) => arr.findIndex((x) => x.href === e.href) === idx)
      .slice(0, 3);
  }
  const slDirMs = Date.now() - tSlOpen;
  slBCalls++;
  if (startupLinks.length < 3) {
    console.error("DEBUG slDir snapshot:", JSON.stringify({
      url: slDir.data.snapshot?.url,
      title: slDir.data.snapshot?.title,
      count: slDir.data.snapshot?.elements?.length,
      sample: (slDir.data.snapshot?.elements ?? []).slice(0, 25),
    }, null, 2));
  }
  assert.ok(startupLinks.length >= 3, `Expected >=3 Nigerian startup links, found ${startupLinks.length}`);

  const tSlBatch = Date.now();
  const slBatch = unwrapBrowser(await session.tool("browser", {
    action: "batchRead",
    urls: startupLinks.map((l) => l.href),
    closeAfter: true,
    maxCharsPerPage: 3500,
    settleMs: 600,
    concurrency: 3,
    budgetMs: 30000,
  }));
  const slBatchMs = Date.now() - tSlBatch;
  slBCalls++;
  assert.ok(slBatch.data.pages.every((p) => p.ok && p.text.length > 100),
    `Live StartupList batchRead failed: ${JSON.stringify(slBatch.data.pages.map((p) => ({ url: p.url, ok: p.ok, err: p.error, len: p.text?.length })))}`);

  // Also test Layer B in-tab click + waitFor + back navigation latency on StartupList Africa!
  const tSlNav = Date.now();
  const firstStartup = startupLinks[0];
  const slClick = unwrapBrowser(await session.tool("browser", {
    action: "act",
    tabId: slDir.data.tabId,
    snapshotId: slDir.data.snapshot.snapshotId,
    steps: [
      { kind: "click", ref: firstStartup.ref },
      { kind: "waitFor", urlContains: new URL(firstStartup.href).pathname },
    ],
    returnSnapshot: true,
    includeText: true,
    maxChars: 3500,
    settleMs: 400,
    budgetMs: 20000,
  }));
  const slClickMs = Date.now() - tSlNav;

  const tSlBack = Date.now();
  const slBack = unwrapBrowser(await session.tool("browser", {
    action: "navigate",
    tabId: slDir.data.tabId,
    history: "back",
    returnSnapshot: true,
    interactiveOnly: true,
    settleMs: 300,
    budgetMs: 15000,
  }));
  const slBackMs = Date.now() - tSlBack;
  await session.tool("browser", { action: "closeTab", tabId: slDir.data.tabId });

  // 3b. Layer A (Optimized Native AX) on the EXACT same live StartupList Africa page in isolated Chrome!
  const chromeSlProfile = fs.mkdtempSync(path.join(os.tmpdir(), "cua-bench-chrome-sl-"));
  const chromeSlProc = spawn(CHROME_BIN, [
    `--user-data-dir=${chromeSlProfile}`,
    "--no-first-run", "--no-default-browser-check", "--disable-default-apps",
    "--window-position=80,80", "--window-size=1200,820",
    "https://www.startuplist.africa/startups?country=nigeria",
  ], { stdio: "ignore" });
  let slChromeWin = null;
  try {
    for (let i = 0; i < 60; i++) {
      const wins = unwrapNative(await session.tool("targets", { bundleId: "com.google.Chrome" })).data.targets ?? [];
      slChromeWin = wins.find((w) => w.key.pid === chromeSlProc.pid && w.title.toLowerCase().includes("startuplist"));
      if (slChromeWin) break;
      await sleep(250);
    }
    assert.ok(slChromeWin, "Isolated Chrome window for StartupList Africa did not load");
    await sleep(1500);

    const tAxSlFull = Date.now();
    const axSlFull = unwrapNative(await session.tool("observe", {
      target: slChromeWin.key, scope: "webArea", includeValues: true, budgetMs: 10000,
    }));
    const axSlFullMs = Date.now() - tAxSlFull;

    const tAxSlInt = Date.now();
    const axSlInt = unwrapNative(await session.tool("observe", {
      target: slChromeWin.key, scope: "webArea", interactiveOnly: true, budgetMs: 10000,
    }));
    const axSlIntMs = Date.now() - tAxSlInt;

    // Also measure compound act(scrollToVisible + press + expect(urlContains), observeAfter) on live StartupList!
    const axFirstStartup = axSlInt.data.elements.find((e) => e.role === "AXLink" && typeof e.url === "string" && /\/startups\/[a-z0-9-]+$/i.test(e.url));
    let axCompoundNavMs = null;
    let axCompoundProfileBytes = null;
    let axCompoundProfileRawBytes = null;
    if (axFirstStartup) {
      const tComp = Date.now();
      const compRes = unwrapNative(await session.tool("act", {
        target: slChromeWin.key,
        observationId: axSlInt.data.observationId,
        steps: [
          { actionId: "scroll", operation: { kind: "scrollToVisible", params: { elementRef: axFirstStartup.reference } } },
          {
            actionId: "open-profile",
            operation: { kind: "press", params: { elementRef: axFirstStartup.reference } },
            expect: { kind: "urlContains", params: { contains: new URL(axFirstStartup.url).pathname } },
          },
        ],
        observeAfter: { scope: "webArea", includeValues: true },
        budgetMs: 20000,
      }));
      axCompoundNavMs = Date.now() - tComp;
      axCompoundProfileBytes = compRes.compactBytes;
      axCompoundProfileRawBytes = compRes.rawJsonBytes;
    }

    report.liveStartuplist = {
      baselineRecordedFrom7edbf2f9: {
        totalWallSec: 534.0,
        llmTurns: 47,
        wastedReadFileTurns: 10,
        profileObserveRawBytes: 72605,
        profileObserveInlineDeliveredBytes: "TRUNCATED (>46KB -> output.txt)",
        interactiveOnlyElementsBeforeAXShowMenuFix: 256,
      },
      layerA_OptimizedAX: {
        fullWebAreaMs: axSlFullMs,
        fullWebAreaElements: axSlFull.data.elements.length,
        fullWebAreaRawJsonBytes: axSlFull.rawJsonBytes,
        fullWebAreaCompactTextBytes: axSlFull.compactBytes,
        compressionVsBaseline72KB: +(72605 / axSlFull.compactBytes).toFixed(2),
        interactiveOnlyMs: axSlIntMs,
        interactiveOnlyElements: axSlInt.data.elements.length,
        interactiveOnlyCompactTextBytes: axSlInt.compactBytes,
        compoundClickWaitObserveMs: axCompoundNavMs,
        compoundProfileCompactBytes: axCompoundProfileBytes,
        compoundProfileRawJsonBytes: axCompoundProfileRawBytes,
      },
      layerB_Extension: {
        directoryOpenAndSnapshotMs: slDirMs,
        directoryElements: slDir.data.snapshot.elements.length,
        directoryCompactTextBytes: slDir.compactBytes,
        threeStartupsDiscovered: startupLinks.map((l) => ({ label: l.label, href: l.href })),
        batchRead3ProfilesMs: slBatchMs,
        batchReadCompactTextBytes: slBatch.compactBytes,
        batchReadPerPageMs: slBatch.data.pages.map((p) => ({ title: p.title, ms: p.elapsedMs, chars: p.text.length })),
        directoryPlus3ProfilesToolCalls: slBCalls,
        directoryPlus3ProfilesTotalMs: slDirMs + slBatchMs,
        inTabClickAndWaitMs: slClickMs,
        inTabBackNavigateMs: slBackMs,
        inTabBackUrl: slBack.data.snapshot?.url,
      },
    };
  } finally {
    if (chromeSlProc.exitCode === null) {
      try { chromeSlProc.kill("SIGTERM"); } catch {}
    }
    await sleep(300);
    fs.rmSync(chromeSlProfile, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
} finally {
  await session.close().catch(() => {});
  for (const proc of [chromeProc, braveProc]) {
    if (proc && proc.exitCode === null) {
      try { proc.kill("SIGTERM"); } catch {}
    }
  }
  await sleep(400);
  fs.rmSync(chromeProfile, { recursive: true, force: true });
  fs.rmSync(braveProfile, { recursive: true, force: true });
  server.close();
}
