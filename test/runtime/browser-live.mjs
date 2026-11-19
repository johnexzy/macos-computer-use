import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { Session } from "./mcp-session.mjs";

const CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const unwrap = (response) => {
  assert.ok(!response.result?.isError, `MCP tool error: ${JSON.stringify(response.result?.content)}`);
  const envelope = response.result.structuredContent ?? JSON.parse(response.result.content[0].text);
  assert.notEqual(envelope.body.result, "error", `Runtime error: ${JSON.stringify(envelope.body.data)}`);
  return envelope.body.data;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const mainHtml = () => {
  const noise = Array.from({ length: 320 }, (_, i) => `<p>Dense feed item row number ${i + 1}</p>`).join("\n");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>CUA Browser Benchmark</title>
<style>
  body { font-family: -apple-system, sans-serif; margin: 16px; }
  .noise p { margin: 2px 0; font-size: 11px; line-height: 13px; }
  .controls { position: fixed; top: 12px; right: 12px; width: 320px; background: #fff; border: 1px solid #ccc; padding: 12px; z-index: 10; }
  .spacer { height: 2400px; }
</style>
</head>
<body>
  <div class="noise">${noise}</div>
  <div class="controls">
    <h2 id="form-status">FORM_READY</h2>
    <input id="customer-name" type="text" aria-label="Customer Name" placeholder="Name" />
    <label><input id="accept-terms" type="checkbox" aria-label="Accept Terms" /> Accept Terms</label>
    <button id="save-btn" type="button" onclick="
      const name = document.getElementById('customer-name').value;
      const ok = document.getElementById('accept-terms').checked ? 'checked' : 'unchecked';
      document.getElementById('form-status').textContent = 'SAVED:' + name + ':' + ok;
    ">Save Profile</button>
    <div><a id="checkout-link" href="/checkout">Proceed to Checkout</a></div>
    <iframe title="Embedded Companion" src="/frame" width="280" height="60"></iframe>
  </div>
  <div class="spacer"></div>
  <button id="footer-btn" type="button" onclick="this.textContent='FOOTER_CLICKED'">Footer Action</button>
</body></html>`;
};

const frameHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Companion Frame</title></head>
<body><button id="frame-btn" type="button">Frame Ping</button></body></html>`;

const checkoutHtml = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>CUA Checkout</title></head>
<body style="background:#ffffff; margin:24px; font-family:-apple-system,sans-serif;">
  <h1>Checkout Ready</h1>
  <canvas id="canvas-pay" width="320" height="90" style="border:2px solid #111; display:block;"></canvas>
  <script>
    const c = document.getElementById('canvas-pay');
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#0b57d0';
    ctx.fillRect(0, 0, 320, 90);
    ctx.fillStyle = '#ffffff';
    ctx.font = 'bold 34px -apple-system, sans-serif';
    ctx.fillText('PAY NOW', 72, 57);
  </script>
</body></html>`;

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  if (req.url === "/frame") res.end(frameHtml);
  else if (req.url === "/checkout") res.end(checkoutHtml);
  else res.end(mainHtml());
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const { port } = server.address();
const baseUrl = `http://127.0.0.1:${port}`;
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), "cua-browser-live-"));

assert.ok(fs.existsSync(CHROME_BIN), `Google Chrome not found at ${CHROME_BIN}`);

const chrome = spawn(CHROME_BIN, [
  `--user-data-dir=${profileDir}`,
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-default-apps",
  "--window-position=80,80",
  "--window-size=960,720",
  `${baseUrl}/`,
], { stdio: "ignore" });

const session = new Session();
const metrics = {};

try {
  await session.initialize();

  // Wait for isolated Chrome window to finish loading the benchmark page.
  let target = null;
  for (let i = 0; i < 50; i++) {
    const tData = unwrap(await session.tool("targets", { bundleId: "com.google.Chrome" }));
    target = (tData.targets ?? []).find((w) => w.key.pid === chrome.pid && w.title?.includes("CUA Browser Benchmark"));
    if (target) break;
    await sleep(200);
  }
  assert.ok(target, "Isolated Chrome benchmark window did not appear");
  await sleep(300);

  // Scenario 1: First observe on fresh Chrome (lazy AXEnhancedUserInterface + interactive-first budget).
  const t0 = Date.now();
  const obs1 = unwrap(await session.tool("observe", { target: target.key }));
  metrics.firstObserveMs = Date.now() - t0;

  const webArea = obs1.elements.find((e) => e.role === "AXWebArea" && e.url?.startsWith(baseUrl));
  const nameField = obs1.elements.find((e) => e.role === "AXTextField" && e.label === "Customer Name");
  const termsBox = obs1.elements.find((e) => e.role === "AXCheckBox" && e.label === "Accept Terms");
  const saveBtn = obs1.elements.find((e) => e.role === "AXButton" && e.label === "Save Profile");
  const checkoutLink = obs1.elements.find((e) => e.role === "AXLink" && e.label === "Proceed to Checkout");
  const footerBtn = obs1.elements.find((e) => e.role === "AXButton" && e.label === "Footer Action");

  assert.ok(webArea, `Expected AXWebArea with url starting with ${baseUrl}`);
  assert.ok(nameField, "Interactive-first budget must retain Customer Name field past 320 static text rows");
  assert.ok(termsBox?.actions.includes("press"), "Checkbox should advertise background press");
  assert.ok(saveBtn?.actions.includes("press"), "Button should advertise background press");
  assert.ok(checkoutLink?.actions.includes("press"), "Link should advertise background press");
  assert.equal(checkoutLink.url, `${baseUrl}/checkout`);
  assert.ok(footerBtn?.actions.includes("scrollToVisible"), "Off-screen footer button should advertise scrollToVisible");
  metrics.scenario1 = { elements: obs1.elements.length, url: webArea.url, interactiveRetained: true };

  // Scenario 2: 100% Background web form fill + checkbox toggle + button submit.
  const t1 = Date.now();
  const formAct = unwrap(await session.tool("act", {
    target: target.key,
    observationId: obs1.observationId,
    steps: [
      { actionId: "fill-name", operation: { kind: "setValue", params: { elementRef: nameField.reference, value: "Ada" } } },
      { actionId: "toggle-terms", operation: { kind: "press", params: { elementRef: termsBox.reference } } },
      { actionId: "submit-form", operation: { kind: "press", params: { elementRef: saveBtn.reference } } },
    ],
  }));
  assert.equal(formAct.stopReason, "completed", `Background form act failed: ${JSON.stringify(formAct)}`);
  const formVerify = unwrap(await session.tool("observe", {
    target: target.key,
    includeValues: true,
    axSelectors: [{ role: "AXStaticText" }],
  }));
  assert.ok(formVerify.elements.some((e) => e.value === "SAVED:Ada:checked" || e.label === "SAVED:Ada:checked"),
    "Background form submit should mutate DOM to SAVED:Ada:checked");
  metrics.scenario2BackgroundFormMs = Date.now() - t1;

  // Scenario 3: 100% Background scrollToVisible on off-screen footer button + background press.
  const t2 = Date.now();
  const scrollAct = unwrap(await session.tool("act", {
    target: target.key,
    observationId: obs1.observationId,
    steps: [
      { actionId: "scroll-footer", operation: { kind: "scrollToVisible", params: { elementRef: footerBtn.reference } } },
      { actionId: "press-footer", operation: { kind: "press", params: { elementRef: footerBtn.reference } } },
    ],
  }));
  assert.equal(scrollAct.stopReason, "completed", `scrollToVisible + press failed: ${JSON.stringify(scrollAct)}`);
  assert.equal(scrollAct.steps[0].route, "axScrollToVisible");
  assert.equal(scrollAct.steps[1].route, "axPress");
  const footerVerify = unwrap(await session.tool("observe", {
    target: target.key,
    axSelectors: [{ role: "AXButton", label: "FOOTER_CLICKED" }],
  }));
  assert.equal(footerVerify.elements.length, 1, "Footer button label should update to FOOTER_CLICKED in background");
  metrics.scenario3BackgroundScrollPressMs = Date.now() - t2;

  // Scenario 4: Nested AXWebArea iframe discovery.
  const iframeObs = unwrap(await session.tool("observe", {
    target: target.key,
    axSelectors: [{ role: "AXWebArea" }],
  }));
  const webUrls = iframeObs.elements.map((e) => e.url).filter(Boolean);
  assert.ok(webUrls.some((u) => u === `${baseUrl}/`), `Missing main webArea URL in ${JSON.stringify(webUrls)}`);
  assert.ok(webUrls.some((u) => u === `${baseUrl}/frame`), `Missing iframe webArea URL in ${JSON.stringify(webUrls)}`);
  metrics.scenario4WebAreas = webUrls;

  // Scenario 5: 100% Background link click + waitFor(urlContains).
  const t4 = Date.now();
  const navObs = unwrap(await session.tool("observe", {
    target: target.key,
    axSelectors: [{ role: "AXLink", label: "Proceed to Checkout" }],
  }));
  const liveLink = navObs.elements[0];
  assert.ok(liveLink, "Checkout link should be observable");
  const navAct = unwrap(await session.tool("act", {
    target: target.key,
    observationId: navObs.observationId,
    steps: [
      { actionId: "click-checkout", operation: { kind: "press", params: { elementRef: liveLink.reference } } },
    ],
  }));
  assert.equal(navAct.stopReason, "completed");
  const waited = unwrap(await session.tool("waitFor", {
    target: target.key,
    observationId: navObs.observationId,
    condition: { kind: "urlContains", params: { contains: "/checkout" } },
  }));
  assert.equal(waited.outcome, "satisfied", `waitFor(urlContains) failed: ${JSON.stringify(waited)}`);
  metrics.scenario5BackgroundNavWaitMs = Date.now() - t4;

  // Scenario 6: Hybrid visual grounding fallback on non-AX <canvas> ("PAY NOW").
  const t5 = Date.now();
  const canvasObs = unwrap(await session.tool("observe", {
    target: target.key,
    includeScreenshot: true,
    includeOcr: true,
    ocrQuery: "PAY NOW",
  }));
  const ocrMatches = canvasObs.visual?.ocr?.matches ?? [];
  assert.ok(ocrMatches.some((m) => m.text.includes("PAY NOW")),
    `Expected Vision OCR match for canvas PAY NOW, got: ${JSON.stringify(ocrMatches)}`);
  metrics.scenario6VisualCanvasMs = Date.now() - t5;
  metrics.scenario6OcrMatches = ocrMatches.map((m) => ({ text: m.text, imageBounds: m.imageBounds }));

  console.log("BROWSER_LIVE_BENCHMARK_PASS:", JSON.stringify(metrics, null, 2));
} finally {
  await session.close().catch(() => {});
  chrome.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(() => { chrome.kill("SIGKILL"); resolve(); }, 1500);
    chrome.once("exit", () => { clearTimeout(timer); resolve(); });
  });
  server.close();
  fs.rmSync(profileDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
