const NATIVE_HOST_NAME = "com.johnoba.useui.browser";
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const KEEPALIVE_ALARM = "useui_bridge_keepalive";
const VALID_GROUP_COLORS = new Set([
  "grey",
  "blue",
  "red",
  "yellow",
  "green",
  "pink",
  "purple",
  "cyan",
  "orange",
]);

let port = null;
let connected = false;
let lastError = null;
let reconnectTimer = null;
let reconnectDelayMs = 1000;

// Visual UX, respectful Tab Group tracking, and graceful Pause Gate state.
let visualEnabled = true;
let paused = false;
let inFlightCount = 0;
const pauseWaiters = [];
const agentTabIds = new Set();
const recentActivity = []; // newest first, max 16

function recordActivity(label, opts = {}) {
  const entry = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
    ts: Date.now(),
    label: String(label || "Working…").slice(0, 96),
    inFlight: Boolean(opts.inFlight),
    ok: opts.ok ?? null,
    tabId: opts.tabId ?? null,
  };
  recentActivity.unshift(entry);
  if (recentActivity.length > 16) recentActivity.length = 16;
  return entry;
}

function finishActivity(entry, ok, finalLabel) {
  if (!entry) return;
  entry.inFlight = false;
  entry.ok = ok;
  if (finalLabel) entry.label = String(finalLabel).slice(0, 96);
}

function updateBadge() {
  try {
    if (!connected) {
      chrome.action.setBadgeText({ text: "OFF" });
      chrome.action.setBadgeBackgroundColor({ color: "#506173" });
      return;
    }
    if (paused) {
      chrome.action.setBadgeText({ text: "II" });
      chrome.action.setBadgeBackgroundColor({ color: "#D97706" });
      return;
    }
    if (inFlightCount > 0) {
      chrome.action.setBadgeText({ text: inFlightCount > 9 ? "9+" : String(inFlightCount) });
      chrome.action.setBadgeBackgroundColor({ color: "#059669" });
      return;
    }
    chrome.action.setBadgeText({ text: "ON" });
    chrome.action.setBadgeBackgroundColor({ color: "#10B981" });
  } catch {
    // Ignore badge errors in headless/unfocused environments.
  }
}

async function broadcastPauseStateToActiveTabs() {
  try {
    const activeTabs = await chrome.tabs.query({ active: true });
    await Promise.allSettled(
      activeTabs
        .filter((t) => t.id && isScriptableUrl(t.url))
        .map(async (t) => {
          await ensureStageInjected(t.id);
          await chrome.scripting.executeScript({
            target: { tabId: t.id },
            func: (p) => {
              if (window.__useuiStage) window.__useuiStage.setPaused(p);
            },
            args: [paused],
          });
        })
    );
  } catch {
    // Best effort only.
  }
}

function setPaused(nextPaused) {
  const normalized = Boolean(nextPaused);
  if (paused === normalized) return paused;
  paused = normalized;
  updateBadge();
  if (!paused) {
    while (pauseWaiters.length > 0) {
      const wake = pauseWaiters.shift();
      try {
        wake();
      } catch {
        // Ignore waiter errors.
      }
    }
  }
  broadcastPauseStateToActiveTabs();
  return paused;
}

async function waitIfPaused(deadlineMs) {
  while (paused) {
    const remaining = deadlineMs ? deadlineMs - Date.now() : 30000;
    if (remaining <= 0) {
      throw bridgeError("paused_timeout", "Paused by user until request budget expired");
    }
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        const idx = pauseWaiters.indexOf(onResume);
        if (idx >= 0) pauseWaiters.splice(idx, 1);
        resolve();
      }, Math.min(remaining, 1000));
      const onResume = () => {
        clearTimeout(timer);
        resolve();
      };
      pauseWaiters.push(onResume);
    });
  }
}

function scheduleReconnect() {
  if (reconnectTimer !== null) return;
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, 15000);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, delay);
}

function connectNative() {
  if (port) return;
  try {
    const nextPort = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    port = nextPort;
    lastError = null;
    connected = true;
    updateBadge();
    reconnectDelayMs = 1000;

    nextPort.onMessage.addListener((message) => {
      handleNativeRequest(nextPort, message);
    });

    nextPort.onDisconnect.addListener(() => {
      const err = chrome.runtime.lastError?.message || "Native host disconnected";
      lastError = err;
      if (port === nextPort) {
        port = null;
        connected = false;
        updateBadge();
        scheduleReconnect();
      }
    });
  } catch (err) {
    lastError = String(err);
    port = null;
    connected = false;
    updateBadge();
    scheduleReconnect();
  }
}

function safePost(targetPort, message) {
  try {
    targetPort.postMessage(message);
  } catch (err) {
    lastError = String(err);
  }
}

async function handleNativeRequest(targetPort, msg) {
  const id = msg?.id ?? "unknown";
  const action = msg?.action;
  const params = msg?.params ?? {};
  const t0 = Date.now();
  const isTracked = action && action !== "ping" && action !== "listTabs";
  if (isTracked) {
    inFlightCount += 1;
    updateBadge();
  }
  try {
    const data = await dispatchAction(action, params);
    safePost(targetPort, {
      id,
      ok: true,
      data: { ...data, elapsedMs: Date.now() - t0 },
    });
  } catch (err) {
    const code = err?.code || "browser_error";
    const message = err?.message || String(err);
    safePost(targetPort, {
      id,
      ok: false,
      error: { code, message },
    });
  } finally {
    if (isTracked) {
      inFlightCount = Math.max(0, inFlightCount - 1);
      updateBadge();
    }
  }
}

function bridgeError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function isScriptableUrl(url) {
  return typeof url === "string" && (url.startsWith("http://") || url.startsWith("https://"));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function hostFromUrl(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

function normalizeGroupColor(color) {
  if (typeof color === "string" && VALID_GROUP_COLORS.has(color.toLowerCase())) {
    return color.toLowerCase();
  }
  return "cyan";
}

function formatGroupTitle(label) {
  const clean = typeof label === "string" ? label.trim().slice(0, 28) : "";
  return clean ? `UseUI · ${clean}` : "UseUI";
}

// Respectful Chrome Tab Grouping: discovers authoritative Chrome group state via
// chrome.tabGroups.query (resilient across MV3 service-worker restarts) and only
// groups UseUI-owned tabs — never hijacking the user's personal tabs.
async function addTabToSessionGroup(tab, opts = {}) {
  if (!chrome.tabGroups || !tab || typeof tab.id !== "number") return null;
  const title = formatGroupTitle(opts.groupLabel);
  const color = normalizeGroupColor(opts.groupColor);
  const collapsed = Boolean(opts.collapsed);
  const windowId = tab.windowId;
  try {
    const groups = await chrome.tabGroups.query({ windowId });
    // Reuse an existing exact-title group, or any non-reading "UseUI" session group in this window.
    const existing =
      groups.find((g) => g.title === title) ||
      (!opts.groupLabel
        ? groups.find((g) => g.title === "UseUI" || (g.title?.startsWith("UseUI · ") && !g.title.startsWith("UseUI · Reading")))
        : null);

    let groupId;
    if (existing) {
      groupId = await chrome.tabs.group({ groupId: existing.id, tabIds: [tab.id] });
      if (opts.groupLabel || opts.groupColor) {
        await chrome.tabGroups.update(groupId, { title, color });
      }
      return { groupId, title: opts.groupLabel ? title : existing.title || title, color: opts.groupColor ? color : existing.color || color };
    }

    groupId = await chrome.tabs.group({ createProperties: { windowId }, tabIds: [tab.id] });
    await chrome.tabGroups.update(groupId, { title, color, collapsed });
    return { groupId, title, color };
  } catch {
    return null;
  }
}

// Collapsed "Quiet Worker" group for parallel batchRead tabs in one explicit window
// so the user's tab strip never thrashes.
async function groupBatchTabs(windowId, tabIds, title, color = "cyan", collapsed = true) {
  if (!chrome.tabGroups || !Array.isArray(tabIds) || tabIds.length === 0) return null;
  try {
    const groupId = await chrome.tabs.group({
      createProperties: typeof windowId === "number" ? { windowId } : undefined,
      tabIds,
    });
    await chrome.tabGroups.update(groupId, { title, color: normalizeGroupColor(color), collapsed });
    return groupId;
  } catch {
    return null;
  }
}

async function updateBatchGroupTitle(groupId, title) {
  if (!chrome.tabGroups || typeof groupId !== "number") return;
  try {
    await chrome.tabGroups.update(groupId, { title });
  } catch {
    // Group already auto-dissolved when its last tab closed.
  }
}

// Inject the closed Shadow DOM stage lazily into visible tabs only.
async function ensureStageInjected(tabId) {
  try {
    const check = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => Boolean(window.__useuiStage && window.__useuiStage.version === "1.1.0"),
    });
    if (check?.[0]?.result === true) return true;
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["stage.js"],
    });
    return true;
  } catch {
    return false;
  }
}

async function showTabStageStatus(tab, labelText, state = "active", opts = {}) {
  if (!visualEnabled || opts.visual === false) return;
  if (!tab || !tab.active || !isScriptableUrl(tab.url)) return;
  const injected = await ensureStageInjected(tab.id);
  if (!injected) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: (lbl, st, options) => {
        if (window.__useuiStage) window.__useuiStage.setStatus(lbl, st, options);
      },
      args: [labelText, state, { tag: opts.tag || "UseUI", idleMs: opts.idleMs ?? 2600 }],
    });
  } catch {
    // Non-fatal visual error.
  }
}

async function resolveTab(tabId) {
  if (typeof tabId === "number") {
    try {
      return await chrome.tabs.get(tabId);
    } catch {
      throw bridgeError("tab_not_found", `Tab ${tabId} was not found`);
    }
  }
  const active = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (active.length > 0) return active[0];
  const anyActive = await chrome.tabs.query({ active: true });
  if (anyActive.length > 0) return anyActive[0];
  const all = await chrome.tabs.query({});
  if (all.length > 0) return all[0];
  throw bridgeError("tab_not_found", "No open browser tabs found");
}

async function waitForTabComplete(tabId, timeoutMs = 15000, settleMs = 300) {
  const deadline = Date.now() + timeoutMs;
  const current = await chrome.tabs.get(tabId);
  if (current.status !== "complete") {
    await new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        chrome.tabs.onUpdated.removeListener(onUpdated);
        chrome.tabs.onRemoved.removeListener(onRemoved);
        clearTimeout(timer);
        resolve();
      };
      const onUpdated = (updatedId, changeInfo) => {
        if (updatedId === tabId && changeInfo.status === "complete") {
          finish();
        }
      };
      const onRemoved = (removedId) => {
        if (removedId === tabId) finish();
      };
      const remaining = Math.max(100, deadline - Date.now());
      const timer = setTimeout(finish, remaining);
      chrome.tabs.onUpdated.addListener(onUpdated);
      chrome.tabs.onRemoved.addListener(onRemoved);
    });
  }
  if (settleMs > 0) {
    await sleep(Math.min(settleMs, Math.max(0, deadline - Date.now())));
  }
  return await chrome.tabs.get(tabId);
}

// Self-contained DOM snapshot & clean text extraction function injected into target tabs.
// Explicitly skips UseUI's own closed Shadow DOM stage host (`#__useui_stage_host`).
function collectSnapshotInPage(opts) {
  const interactiveOnly = opts.interactiveOnly !== false;
  const includeText = Boolean(opts.includeText);
  const includeLinks = Boolean(opts.includeLinks);
  const query = typeof opts.query === "string" && opts.query.trim() ? opts.query.trim().toLowerCase() : null;
  const maxElements = Math.min(Math.max(Number(opts.maxElements) || 180, 1), 400);
  const maxChars = Math.min(Math.max(Number(opts.maxChars) || 8000, 200), 30000);

  if (!window.__cuaBridge) {
    window.__cuaBridge = { gen: 0, snapshots: new Map(), order: [] };
  }
  const store = window.__cuaBridge;
  store.gen += 1;
  const gen = store.gen;
  const snapshotId = `snap-${gen}`;
  const refMap = new Map();
  store.snapshots.set(snapshotId, refMap);
  store.order.push(snapshotId);
  while (store.order.length > 8) {
    const oldest = store.order.shift();
    store.snapshots.delete(oldest);
  }

  const vw = window.innerWidth || 1280;
  const vh = window.innerHeight || 800;

  const INTERACTIVE_TAGS = new Set(["A", "BUTTON", "INPUT", "TEXTAREA", "SELECT", "SUMMARY", "OPTION"]);
  const INTERACTIVE_ROLES = new Set([
    "button", "link", "tab", "checkbox", "radio", "combobox",
    "menuitem", "menuitemcheckbox", "menuitemradio", "option",
    "switch", "textbox", "searchbox", "slider", "spinbutton",
  ]);
  const HEADING_TAGS = new Set(["H1", "H2", "H3", "H4", "H5", "H6"]);

  function cleanText(s, limit = 160) {
    if (!s) return "";
    const norm = String(s).replace(/\s+/g, " ").trim();
    return norm.length > limit ? norm.slice(0, limit - 1) + "…" : norm;
  }

  function isVisible(el) {
    if (!(el instanceof Element)) return false;
    if (el.id === "__useui_stage_host" || el.hasAttribute("data-useui-ignore")) return false;
    if (el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true") return false;
    const style = window.getComputedStyle(el);
    if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") {
      return false;
    }
    const rect = el.getBoundingClientRect();
    return rect.width > 0.5 && rect.height > 0.5;
  }

  function inferRole(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit.trim().toLowerCase();
    const tag = el.tagName;
    if (tag === "A") return "link";
    if (tag === "BUTTON" || tag === "SUMMARY") return "button";
    if (tag === "SELECT") return "combobox";
    if (tag === "TEXTAREA") return "textbox";
    if (tag === "INPUT") {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "checkbox") return "checkbox";
      if (t === "radio") return "radio";
      if (t === "submit" || t === "button" || t === "reset") return "button";
      if (t === "search") return "searchbox";
      return "textbox";
    }
    if (HEADING_TAGS.has(tag)) return "heading";
    if (el.isContentEditable) return "textbox";
    return tag.toLowerCase();
  }

  function inferLabel(el) {
    const aria = el.getAttribute("aria-label");
    if (aria && aria.trim()) return cleanText(aria);
    const labelledBy = el.getAttribute("aria-labelledby");
    if (labelledBy) {
      const parts = labelledBy
        .split(/\s+/)
        .map((id) => document.getElementById(id)?.innerText || "")
        .filter(Boolean);
      if (parts.length) return cleanText(parts.join(" "));
    }
    if (el.id) {
      const assoc = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (assoc && assoc.innerText) return cleanText(assoc.innerText);
    }
    const parentLabel = el.closest("label");
    if (parentLabel && (el.tagName === "INPUT" || el.tagName === "SELECT" || el.tagName === "TEXTAREA")) {
      const txt = cleanText(parentLabel.innerText);
      if (txt) return txt;
    }
    const inner = cleanText(el.innerText || el.textContent || "");
    if (inner) return inner;
    const ph = el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("name");
    if (ph) return cleanText(ph);
    return "";
  }

  const elements = [];
  let truncated = false;
  let totalVisited = 0;

  function visit(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let node = walker.currentNode;
    while (node) {
      if (node instanceof Element) {
        if (node.id === "__useui_stage_host" || node.hasAttribute("data-useui-ignore")) {
          node = walker.nextSibling() || walker.nextNode();
          continue;
        }
        totalVisited += 1;
        const tag = node.tagName;
        const roleAttr = (node.getAttribute("role") || "").trim().toLowerCase();
        const isInteractive =
          (tag === "A" && node.hasAttribute("href")) ||
          (INTERACTIVE_TAGS.has(tag) && tag !== "A" && tag !== "OPTION") ||
          INTERACTIVE_ROLES.has(roleAttr) ||
          node.isContentEditable ||
          (node.hasAttribute("tabindex") && node.getAttribute("tabindex") !== "-1" && typeof node.onclick === "function");
        const isHeading = !interactiveOnly && HEADING_TAGS.has(tag);

        if ((isInteractive || isHeading) && isVisible(node)) {
          if (tag === "INPUT" && (node.getAttribute("type") || "").toLowerCase() === "hidden") {
            // Skip hidden inputs.
          } else {
            const role = inferRole(node);
            const label = inferLabel(node);
            const href = tag === "A" ? node.href || node.getAttribute("href") || undefined : undefined;
            let value;
            if (tag === "INPUT") {
              const t = (node.getAttribute("type") || "text").toLowerCase();
              if (t === "password") {
                value = node.value ? "[redacted]" : "";
              } else if (t !== "checkbox" && t !== "radio" && t !== "button" && t !== "submit") {
                value = cleanText(node.value || "", 200);
              }
            } else if (tag === "TEXTAREA") {
              value = cleanText(node.value || "", 200);
            } else if (tag === "SELECT") {
              const opt = node.options?.[node.selectedIndex];
              value = cleanText(opt?.text || node.value || "", 120);
            }
            const placeholder = node.getAttribute("placeholder") || undefined;
            const hay = `${role} ${label} ${href || ""} ${value || ""} ${placeholder || ""}`.toLowerCase();
            if (!query || hay.includes(query)) {
              if (elements.length >= maxElements) {
                truncated = true;
              } else {
                const ref = `b${gen}.${elements.length + 1}`;
                refMap.set(ref, new WeakRef(node));
                const rect = node.getBoundingClientRect();
                const inViewport = rect.bottom > 0 && rect.top < vh && rect.right > 0 && rect.left < vw;
                const item = { ref, role, label };
                if (href) item.href = href;
                if (value) item.value = value;
                if (placeholder && placeholder !== label) item.placeholder = cleanText(placeholder, 80);
                if (node.disabled || node.getAttribute("aria-disabled") === "true") item.disabled = true;
                if (tag === "INPUT" && (node.type === "checkbox" || node.type === "radio")) {
                  item.checked = Boolean(node.checked);
                } else if (node.getAttribute("aria-checked") === "true") {
                  item.checked = true;
                }
                const expanded = node.getAttribute("aria-expanded");
                if (expanded === "true" || expanded === "false") {
                  item.expanded = expanded === "true";
                }
                if (!inViewport) item.inViewport = false;
                elements.push(item);
              }
            }
          }
        }
        if (node.shadowRoot) {
          visit(node.shadowRoot);
        }
      }
      node = walker.nextNode();
    }
  }

  if (document.body) {
    visit(document.body);
  }

  let text;
  if (includeText) {
    const main =
      document.querySelector("main") ||
      document.querySelector("[role='main']") ||
      document.querySelector("article") ||
      document.body;
    const raw = (main?.innerText || document.body?.innerText || "").trim();
    const normalized = raw
      .split(/\r?\n/)
      .map((l) => l.replace(/[ \t]+/g, " ").trim())
      .filter(Boolean)
      .join("\n");
    text = normalized.length > maxChars ? normalized.slice(0, maxChars) + "\n…[truncated]" : normalized;
  }

  let links;
  if (includeLinks) {
    const seen = new Set();
    links = [];
    for (const a of document.querySelectorAll("a[href]")) {
      if (links.length >= 40) break;
      const href = a.href;
      if (!href || (!href.startsWith("http://") && !href.startsWith("https://")) || seen.has(href)) continue;
      const label = cleanText(a.innerText || a.getAttribute("aria-label") || "", 100);
      if (!label) continue;
      seen.add(href);
      links.push({ label, href });
    }
  }

  return {
    snapshotId,
    url: location.href,
    title: document.title || "",
    readyState: document.readyState,
    viewport: { width: vw, height: vh, scrollY: Math.round(window.scrollY || 0) },
    elementCount: elements.length,
    visitedNodes: totalVisited,
    truncated,
    elements,
    ...(text !== undefined ? { text } : {}),
    ...(links !== undefined ? { links } : {}),
  };
}

// Execute a single DOM action step inside the page, driving UseUI's Shadow DOM stage
// smoothly when the tab is visibly watched, and running with 0ms overhead when hidden.
async function executeDomStepInPage(step, snapshotId, visualOpts) {
  const kind = step.kind;
  const showVisual = Boolean(visualOpts?.enabled) && document.visibilityState === "visible" && Boolean(window.__useuiStage);
  const stepSuffix = visualOpts?.totalSteps > 1 ? ` · ${visualOpts.stepIndex + 1}/${visualOpts.totalSteps}` : "";
  const reducedMotion = Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);

  function shortLabel(el, fallback = "") {
    if (!el) return fallback;
    const raw =
      el.getAttribute?.("aria-label") ||
      el.getAttribute?.("placeholder") ||
      el.innerText ||
      el.textContent ||
      el.getAttribute?.("title") ||
      el.getAttribute?.("name") ||
      fallback;
    const clean = String(raw || "").replace(/\s+/g, " ").trim();
    return clean.length > 34 ? clean.slice(0, 33) + "…" : clean;
  }

  function plainRect(el) {
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  }

  function findByRef(ref) {
    const store = window.__cuaBridge;
    if (!store) return null;
    if (snapshotId && store.snapshots.has(snapshotId)) {
      const wr = store.snapshots.get(snapshotId).get(ref);
      const el = wr?.deref();
      if (el && el.isConnected) return el;
    }
    for (let i = store.order.length - 1; i >= 0; i--) {
      const map = store.snapshots.get(store.order[i]);
      const wr = map?.get(ref);
      const el = wr?.deref();
      if (el && el.isConnected) return el;
    }
    return null;
  }

  function isVisible(el) {
    if (!(el instanceof Element)) return false;
    if (el.id === "__useui_stage_host" || el.hasAttribute("data-useui-ignore")) return false;
    if (el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true") return false;
    const style = window.getComputedStyle(el);
    if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0.5 && rect.height > 0.5;
  }

  function findByTextOrSelector(step) {
    if (step.selector) {
      const el = document.querySelector(step.selector);
      if (el && isVisible(el)) return el;
      return null;
    }
    if (!step.text) return null;
    const needle = step.text.trim().toLowerCase();
    const roleFilter = step.role ? step.role.trim().toLowerCase() : null;
    const candidates = Array.from(
      document.querySelectorAll(
        "a[href], button, input, textarea, select, [role='button'], [role='link'], [role='menuitem'], [role='option'], [role='tab'], [role='checkbox'], [role='radio'], [role='combobox'], li, label"
      )
    ).filter(isVisible);

    const roleOf = (el) => {
      const r = el.getAttribute("role");
      if (r) return r.toLowerCase();
      if (el.tagName === "A") return "link";
      if (el.tagName === "BUTTON") return "button";
      if (el.tagName === "INPUT") return (el.type === "checkbox" ? "checkbox" : "textbox");
      if (el.tagName === "SELECT") return "combobox";
      return el.tagName.toLowerCase();
    };
    const labelOf = (el) =>
      (el.getAttribute("aria-label") || el.innerText || el.textContent || el.getAttribute("placeholder") || "")
        .replace(/\s+/g, " ")
        .trim()
        .toLowerCase();

    let partial = null;
    for (const el of candidates) {
      if (roleFilter && roleOf(el) !== roleFilter) continue;
      const lbl = labelOf(el);
      if (!lbl) continue;
      if (lbl === needle) return el;
      if (!partial && lbl.includes(needle)) partial = el;
    }
    return partial;
  }

  function resolveTarget() {
    if (step.ref) {
      const el = findByRef(step.ref);
      if (!el) return { error: { code: "stale_ref", message: `Element ref ${step.ref} is stale or detached` } };
      return { el };
    }
    if (step.text || step.selector) {
      const el = findByTextOrSelector(step);
      if (!el) {
        return {
          error: {
            code: "element_not_found",
            message: `No visible element matched ${step.selector || JSON.stringify(step.text)}`,
          },
        };
      }
      return { el };
    }
    return { el: null };
  }

  async function scrollControlIntoView(el) {
    const r = el.getBoundingClientRect();
    const inView = r.top >= 16 && r.bottom <= window.innerHeight - 16 && r.left >= 0 && r.right <= window.innerWidth;
    if (inView) return;
    if (showVisual && !reducedMotion) {
      el.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
      await new Promise((res) => setTimeout(res, 170));
    } else {
      el.scrollIntoView({ behavior: "instant", block: "center", inline: "nearest" });
    }
  }

  if (kind === "scroll") {
    const scrollBehavior = showVisual && !reducedMotion ? "smooth" : "instant";
    if (step.ref || step.text || step.selector) {
      const { el, error } = resolveTarget();
      if (error) return { ok: false, error };
      if (showVisual) {
        const lbl = shortLabel(el);
        await window.__useuiStage.animateScroll("down", lbl ? `Scrolling to "${lbl}"${stepSuffix}` : `Scrolling${stepSuffix}`);
      }
      el.scrollIntoView({ behavior: scrollBehavior, block: "center", inline: "nearest" });
      if (scrollBehavior === "smooth") await new Promise((res) => setTimeout(res, 170));
      return { ok: true, scrollY: Math.round(window.scrollY || 0), narration: "Scrolled to target" };
    }
    const dir = step.direction || (typeof step.deltaY === "number" && step.deltaY < 0 ? "up" : "down");
    if (showVisual) {
      await window.__useuiStage.animateScroll(dir, `Scrolling ${dir}${stepSuffix}`);
    }
    if (step.direction === "top") {
      window.scrollTo({ top: 0, behavior: scrollBehavior });
    } else if (step.direction === "bottom") {
      window.scrollTo({ top: document.documentElement.scrollHeight, behavior: scrollBehavior });
    } else {
      const dy =
        typeof step.deltaY === "number"
          ? step.deltaY
          : step.direction === "up"
            ? -Math.round(window.innerHeight * 0.75)
            : Math.round(window.innerHeight * 0.75);
      window.scrollBy({ top: dy, behavior: scrollBehavior });
    }
    if (scrollBehavior === "smooth") await new Promise((res) => setTimeout(res, 170));
    return { ok: true, scrollY: Math.round(window.scrollY || 0), narration: `Scrolled ${dir}` };
  }

  if (kind === "click") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el) return { ok: false, error: { code: "invalid_request", message: "click requires ref, text, or selector" } };
    await scrollControlIntoView(el);
    const rect = plainRect(el);
    const lbl = shortLabel(el, step.text || "");
    const narration = lbl ? `Clicking "${lbl}"` : "Clicking element";
    if (showVisual) {
      await window.__useuiStage.animateClick(rect, `${narration}${stepSuffix}`, {
        tag: visualOpts?.tag || "UseUI",
      });
    }
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const init = { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 0 };
    try {
      el.dispatchEvent(new PointerEvent("pointerdown", init));
      el.dispatchEvent(new MouseEvent("mousedown", init));
      if (typeof el.focus === "function") el.focus({ preventScroll: true });
      el.dispatchEvent(new PointerEvent("pointerup", init));
      el.dispatchEvent(new MouseEvent("mouseup", init));
      el.click();
    } catch (e) {
      if (showVisual) window.__useuiStage.setStatus("Click failed", "error");
      return { ok: false, error: { code: "click_failed", message: String(e) } };
    }
    return { ok: true, tag: el.tagName, href: el.href || undefined, narration };
  }

  if (kind === "type") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el) return { ok: false, error: { code: "invalid_request", message: "type requires ref, text target, or selector" } };
    await scrollControlIntoView(el);
    const rect = plainRect(el);
    const isPassword = el.tagName === "INPUT" && (el.getAttribute("type") || "").toLowerCase() === "password";
    const lbl = isPassword ? "password field" : shortLabel(el);
    const narration = lbl ? `Typing in "${lbl}"` : "Typing text";
    if (showVisual) {
      await window.__useuiStage.animateType(rect, `${narration}${stepSuffix}`, {
        tag: visualOpts?.tag || "UseUI",
      });
    }
    if (typeof el.focus === "function") el.focus({ preventScroll: true });
    const valueText = String(step.value ?? step.input ?? "");
    const shouldClear = step.clear !== false;
    if (el.isContentEditable) {
      el.textContent = shouldClear ? valueText : (el.textContent || "") + valueText;
      el.dispatchEvent(new InputEvent("input", { bubbles: true, data: valueText }));
    } else {
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
      const nextValue = shouldClear ? valueText : (el.value || "") + valueText;
      if (setter) setter.call(el, nextValue);
      else el.value = nextValue;
      el.dispatchEvent(new InputEvent("input", { bubbles: true, data: valueText, inputType: "insertText" }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }
    if (step.submit) {
      el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true }));
      el.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
      if (el.form && typeof el.form.requestSubmit === "function") {
        try { el.form.requestSubmit(); } catch { /* ignore */ }
      }
    }
    return { ok: true, narration };
  }

  if (kind === "select") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el || el.tagName !== "SELECT") {
      return { ok: false, error: { code: "invalid_request", message: "select requires a <select> element" } };
    }
    await scrollControlIntoView(el);
    const lbl = shortLabel(el);
    const narration = lbl ? `Selecting in "${lbl}"` : "Selecting option";
    if (showVisual) {
      await window.__useuiStage.animateClick(plainRect(el), `${narration}${stepSuffix}`, {
        tag: visualOpts?.tag || "UseUI",
      });
    }
    const wantVal = step.value !== undefined ? String(step.value) : null;
    const wantLabel = step.label !== undefined ? String(step.label).trim().toLowerCase() : null;
    let matched = false;
    for (const opt of el.options) {
      if ((wantVal !== null && opt.value === wantVal) || (wantLabel !== null && opt.text.trim().toLowerCase() === wantLabel)) {
        el.value = opt.value;
        matched = true;
        break;
      }
    }
    if (!matched) {
      if (showVisual) window.__useuiStage.setStatus("Option not found", "error");
      return { ok: false, error: { code: "option_not_found", message: "No matching <option> found" } };
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { ok: true, value: el.value, narration };
  }

  if (kind === "pressKey") {
    const target = step.ref || step.selector ? resolveTarget().el : (document.activeElement || document.body);
    if (!target) return { ok: false, error: { code: "stale_ref", message: "Target element unavailable" } };
    const key = String(step.key || "Enter");
    const narration = `Pressing ${key}`;
    if (showVisual) {
      window.__useuiStage.setStatus(`${narration}${stepSuffix}`, "active", { tag: visualOpts?.tag || "UseUI" });
    }
    const init = { key, bubbles: true, cancelable: true };
    target.dispatchEvent(new KeyboardEvent("keydown", init));
    target.dispatchEvent(new KeyboardEvent("keypress", init));
    target.dispatchEvent(new KeyboardEvent("keyup", init));
    return { ok: true, narration };
  }

  return { ok: false, error: { code: "invalid_request", message: `Unsupported step kind: ${kind}` } };
}

function checkConditionInPage(cond) {
  if (cond.selector) {
    const el = document.querySelector(cond.selector);
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0.5 && rect.height > 0.5;
  }
  if (cond.textContains) {
    const bodyText = document.body?.innerText || "";
    return bodyText.toLowerCase().includes(cond.textContains.toLowerCase());
  }
  return true;
}

async function runSnapshot(tabId, opts = {}) {
  const tab = await chrome.tabs.get(tabId);
  if (!isScriptableUrl(tab.url)) {
    throw bridgeError("restricted_url", `Cannot inspect restricted URL: ${tab.url || "(empty)"}`);
  }
  const results = await chrome.scripting.executeScript({
    target: { tabId },
    func: collectSnapshotInPage,
    args: [opts],
  });
  if (!results || !results[0] || !results[0].result) {
    throw bridgeError("snapshot_failed", "Failed to capture DOM snapshot");
  }
  return { tabId, windowId: tab.windowId, ...results[0].result };
}

async function waitForPageHydration(tabId, maxWaitMs = 2500) {
  const deadline = Date.now() + maxWaitMs;
  while (Date.now() < deadline) {
    try {
      const res = await chrome.scripting.executeScript({
        target: { tabId },
        func: () => {
          const main = document.querySelector("main, [role='main'], article");
          return ((main?.innerText || document.body?.innerText) || "").trim().length;
        },
      });
      const len = res?.[0]?.result ?? 0;
      if (len >= 180) return;
    } catch {
      // Tab may still be transitioning.
    }
    await sleep(150);
  }
}

async function runWaitStep(tabId, step, defaultTimeoutMs = 10000) {
  const timeoutMs = Math.min(Math.max(Number(step.timeoutMs) || defaultTimeoutMs, 100), 30000);
  if (typeof step.ms === "number" && step.ms > 0) {
    await sleep(Math.min(step.ms, 10000));
    return { ok: true };
  }
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    await waitIfPaused(deadline);
    const tab = await chrome.tabs.get(tabId);
    let urlOk = true;
    if (step.urlContains) {
      urlOk = typeof tab.url === "string" && tab.url.toLowerCase().includes(step.urlContains.toLowerCase());
    }
    if (urlOk && (step.textContains || step.selector)) {
      if (isScriptableUrl(tab.url)) {
        try {
          const res = await chrome.scripting.executeScript({
            target: { tabId },
            func: checkConditionInPage,
            args: [{ textContains: step.textContains, selector: step.selector }],
          });
          if (res?.[0]?.result === true) {
            return { ok: true, url: tab.url };
          }
        } catch {
          // Page still navigating; retry.
        }
      }
    } else if (urlOk && step.urlContains) {
      if (tab.status === "complete") {
        return { ok: true, url: tab.url };
      }
    }
    await sleep(120);
  }
  throw bridgeError("timeout", `waitFor timed out (${step.urlContains || step.textContains || step.selector || "condition"})`);
}

async function dispatchAction(action, params) {
  const allowVisual = params.visual !== false && visualEnabled;
  const tag = params.groupLabel ? `UseUI · ${String(params.groupLabel).trim().slice(0, 18)}` : "UseUI";

  switch (action) {
    case "ping": {
      const tabs = await chrome.tabs.query({});
      const ua = navigator.userAgent || "";
      const browser = ua.includes("Edg/") ? "Edge" : ua.includes("Chrome/") ? "Chromium" : "Browser";
      return {
        browser,
        extensionVersion: EXTENSION_VERSION,
        tabCount: tabs.length,
        agentTabCount: agentTabIds.size,
        paused,
        visualEnabled,
      };
    }

    case "listTabs": {
      const tabs = await chrome.tabs.query({});
      return {
        tabs: tabs.map((t) => ({
          tabId: t.id,
          windowId: t.windowId,
          active: Boolean(t.active),
          groupId: typeof t.groupId === "number" && t.groupId >= 0 ? t.groupId : null,
          managedByUseUI: agentTabIds.has(t.id),
          title: t.title || "",
          url: t.url || "",
          status: t.status || "complete",
          scriptable: isScriptableUrl(t.url),
        })),
      };
    }

    case "openTab": {
      const url = params.url;
      if (!isScriptableUrl(url)) {
        throw bridgeError("invalid_request", "openTab requires an http:// or https:// url");
      }
      await waitIfPaused(Date.now() + (params.timeoutMs ?? 15000));
      const actEntry = recordActivity(`Opening ${hostFromUrl(url) || url}`, { inFlight: true });
      const active = Boolean(params.active);
      const tab = await chrome.tabs.create({ url, active });
      agentTabIds.add(tab.id);
      const group = await addTabToSessionGroup(tab, {
        groupLabel: params.groupLabel,
        groupColor: params.groupColor,
        collapsed: false,
      });
      const settleMs = params.settleMs ?? 350;
      const loaded = await waitForTabComplete(tab.id, params.timeoutMs ?? 15000, settleMs);
      if (allowVisual && loaded.active) {
        await showTabStageStatus(loaded, `Opened ${hostFromUrl(loaded.url || url) || "page"}`, "active", { tag });
      }
      finishActivity(actEntry, true, `Opened ${loaded.title || hostFromUrl(url) || "tab"}`);
      if (params.returnSnapshot || params.includeText) {
        await waitForPageHydration(tab.id, 2000);
        const snap = await runSnapshot(tab.id, {
          interactiveOnly: params.interactiveOnly !== false,
          includeText: Boolean(params.includeText),
          includeLinks: Boolean(params.includeLinks),
          query: params.query,
          maxChars: params.maxChars,
          maxElements: params.maxElements,
        });
        return {
          tabId: tab.id,
          windowId: loaded.windowId,
          active: Boolean(loaded.active),
          ...(group ? { groupId: group.groupId, groupTitle: group.title } : {}),
          snapshot: snap,
        };
      }
      return {
        tabId: tab.id,
        windowId: loaded.windowId,
        active: Boolean(loaded.active),
        ...(group ? { groupId: group.groupId, groupTitle: group.title } : {}),
        url: loaded.url || url,
        title: loaded.title || "",
      };
    }

    case "navigate": {
      await waitIfPaused(Date.now() + (params.timeoutMs ?? 15000));
      const tab = await resolveTab(params.tabId);
      const history = params.history;
      const navLabel = history
        ? `Navigating ${history}`
        : `Navigating to ${hostFromUrl(params.url) || params.url}`;
      const actEntry = recordActivity(navLabel, { inFlight: true, tabId: tab.id });
      if (allowVisual) {
        await showTabStageStatus(tab, navLabel, "active", { tag });
      }
      if (history === "back") {
        try {
          await chrome.tabs.goBack(tab.id);
        } catch (err) {
          if (isScriptableUrl(tab.url)) {
            await chrome.scripting.executeScript({
              target: { tabId: tab.id },
              func: () => window.history.back(),
            });
          } else {
            finishActivity(actEntry, false);
            throw err;
          }
        }
      } else if (history === "forward") {
        try {
          await chrome.tabs.goForward(tab.id);
        } catch (err) {
          if (isScriptableUrl(tab.url)) {
            await chrome.scripting.executeScript({
              target: { tabId: tab.id },
              func: () => window.history.forward(),
            });
          } else {
            finishActivity(actEntry, false);
            throw err;
          }
        }
      } else if (history === "reload") {
        await chrome.tabs.reload(tab.id);
      } else if (params.url) {
        if (!isScriptableUrl(params.url)) {
          finishActivity(actEntry, false);
          throw bridgeError("invalid_request", "navigate url must be http:// or https://");
        }
        await chrome.tabs.update(tab.id, { url: params.url });
      } else {
        finishActivity(actEntry, false);
        throw bridgeError("invalid_request", "navigate requires url or history ('back'|'forward'|'reload')");
      }
      await sleep(150);
      const loaded = await waitForTabComplete(tab.id, params.timeoutMs ?? 15000, params.settleMs ?? 350);
      if (allowVisual && loaded.active) {
        await showTabStageStatus(loaded, `Loaded ${loaded.title || hostFromUrl(loaded.url) || "page"}`, "active", { tag });
      }
      finishActivity(actEntry, true, `Loaded ${loaded.title || hostFromUrl(loaded.url) || "page"}`);
      if (params.returnSnapshot !== false || params.includeText) {
        await waitForPageHydration(tab.id, 1800);
        const snap = await runSnapshot(tab.id, {
          interactiveOnly: params.interactiveOnly !== false,
          includeText: Boolean(params.includeText),
          includeLinks: Boolean(params.includeLinks),
          query: params.query,
          maxChars: params.maxChars,
          maxElements: params.maxElements,
        });
        return { tabId: tab.id, windowId: loaded.windowId, snapshot: snap };
      }
      return { tabId: tab.id, windowId: loaded.windowId, url: loaded.url || "", title: loaded.title || "" };
    }

    case "snapshot": {
      const tab = await resolveTab(params.tabId);
      const actEntry = recordActivity(`Inspecting ${tab.title || hostFromUrl(tab.url) || "tab"}`, {
        inFlight: true,
        tabId: tab.id,
      });
      if (allowVisual && tab.active) {
        await showTabStageStatus(tab, "Inspecting page…", "active", { tag, idleMs: 1800 });
      }
      const snap = await runSnapshot(tab.id, {
        interactiveOnly: params.interactiveOnly !== false,
        includeText: Boolean(params.includeText),
        includeLinks: Boolean(params.includeLinks),
        query: params.query,
        maxChars: params.maxChars,
        maxElements: params.maxElements,
      });
      finishActivity(actEntry, true, `Inspected ${snap.title || hostFromUrl(snap.url) || "page"}`);
      return { snapshot: snap };
    }

    case "act": {
      const tab = await resolveTab(params.tabId);
      if (!isScriptableUrl(tab.url)) {
        throw bridgeError("restricted_url", `Cannot act on restricted URL: ${tab.url || "(empty)"}`);
      }
      const steps = Array.isArray(params.steps) ? params.steps : [];
      if (steps.length === 0 || steps.length > 16) {
        throw bridgeError("invalid_request", "act requires 1 to 16 steps");
      }
      const deadline = Date.now() + (params.timeoutMs ?? 20000);
      const actEntry = recordActivity(`Running ${steps.length} step${steps.length > 1 ? "s" : ""}…`, {
        inFlight: true,
        tabId: tab.id,
      });

      // Lazily inject Shadow DOM stage if tab is currently active and visual feedback is enabled.
      const stageReady = allowVisual && tab.active ? await ensureStageInjected(tab.id) : false;

      const receipts = [];
      let lastNarration = null;
      for (let i = 0; i < steps.length; i++) {
        await waitIfPaused(deadline);
        const step = steps[i];
        const stepId = step.id || `step-${i + 1}`;
        if (step.kind === "waitFor") {
          if (stageReady) {
            const waitDesc = step.urlContains
              ? `Waiting for ${step.urlContains}…`
              : step.textContains
                ? `Waiting for "${step.textContains.slice(0, 24)}"…`
                : "Waiting…";
            await showTabStageStatus(tab, waitDesc, "active", { tag });
          }
          const waitRes = await runWaitStep(tab.id, step);
          receipts.push({ id: stepId, kind: "waitFor", ok: true, ...(waitRes.url ? { url: waitRes.url } : {}) });
          continue;
        }
        // Re-ensure stage if a prior step navigated the page while active.
        let useStage = stageReady;
        if (allowVisual && i > 0) {
          const liveTab = await chrome.tabs.get(tab.id).catch(() => tab);
          useStage = Boolean(liveTab.active) && (await ensureStageInjected(tab.id));
        }
        const exec = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: executeDomStepInPage,
          args: [
            step,
            params.snapshotId || null,
            {
              enabled: useStage,
              stepIndex: i,
              totalSteps: steps.length,
              tag,
            },
          ],
        });
        const outcome = exec?.[0]?.result;
        if (!outcome || !outcome.ok) {
          const err = outcome?.error || { code: "step_failed", message: "DOM step failed" };
          finishActivity(actEntry, false, `Failed: ${err.message}`);
          throw bridgeError(err.code, `Step ${stepId} (${step.kind}) failed: ${err.message}`);
        }
        if (outcome.narration) lastNarration = outcome.narration;
        receipts.push({ id: stepId, kind: step.kind, ok: true });
        if (step.kind === "click" && i + 1 < steps.length && steps[i + 1].kind !== "waitFor") {
          await sleep(120);
        }
      }
      const settleMs = params.settleMs ?? 250;
      await sleep(100);
      const loaded = await waitForTabComplete(tab.id, 10000, settleMs);
      finishActivity(actEntry, true, lastNarration || `Completed ${steps.length} step${steps.length > 1 ? "s" : ""}`);
      let snapshot;
      if (params.returnSnapshot !== false || params.includeText) {
        await waitForPageHydration(tab.id, 1500);
        snapshot = await runSnapshot(tab.id, {
          interactiveOnly: params.interactiveOnly !== false,
          includeText: Boolean(params.includeText),
          includeLinks: Boolean(params.includeLinks),
          query: params.query,
          maxChars: params.maxChars,
          maxElements: params.maxElements,
        });
      }
      return {
        tabId: tab.id,
        windowId: loaded.windowId,
        url: loaded.url || "",
        title: loaded.title || "",
        steps: receipts,
        ...(snapshot ? { snapshot } : {}),
      };
    }

    case "batchRead": {
      const urls = Array.isArray(params.urls) ? params.urls : [];
      if (urls.length === 0 || urls.length > 6) {
        throw bridgeError("invalid_request", "batchRead requires 1 to 6 http(s) URLs");
      }
      for (const u of urls) {
        if (!isScriptableUrl(u)) {
          throw bridgeError("invalid_request", `Invalid URL in batchRead: ${u}`);
        }
      }
      const closeAfter = params.closeAfter !== false;
      const maxCharsPerPage = Math.min(Math.max(Number(params.maxCharsPerPage) || 5000, 300), 16000);
      const includeLinks = Boolean(params.includeLinks);
      const settleMs = params.settleMs ?? 400;
      const concurrency = Math.min(Math.max(Number(params.concurrency) || 3, 1), 6);
      const batchColor = normalizeGroupColor(params.groupColor);
      const baseTitle = params.groupLabel ? `UseUI · ${String(params.groupLabel).trim().slice(0, 16)}` : "UseUI · Reading";

      // Pin all worker tabs for this batch into one target window so chrome.tabs.group
      // always groups them into a single collapsed chip cleanly.
      let targetWindowId;
      try {
        const win = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
        targetWindowId = win?.id;
      } catch {
        targetWindowId = undefined;
      }

      const actEntry = recordActivity(`Reading ${urls.length} page${urls.length > 1 ? "s" : ""}…`, { inFlight: true });
      const results = new Array(urls.length);
      let cursor = 0;
      let remaining = urls.length;
      let batchGroupId = null;
      let groupInitPromise = null;

      async function attachToCollapsedBatchGroup(tabId, winId) {
        if (!chrome.tabGroups) return;
        try {
          if (batchGroupId !== null) {
            await chrome.tabs.group({ groupId: batchGroupId, tabIds: [tabId] });
            return;
          }
          if (!groupInitPromise) {
            groupInitPromise = groupBatchTabs(winId, [tabId], `${baseTitle} (${remaining})`, batchColor, true).then((gid) => {
              batchGroupId = gid;
              return gid;
            });
            await groupInitPromise;
          } else {
            const gid = await groupInitPromise;
            if (typeof gid === "number") {
              await chrome.tabs.group({ groupId: gid, tabIds: [tabId] });
            }
          }
        } catch {
          // Best-effort grouping; never blocks batchRead.
        }
      }

      async function worker() {
        while (cursor < urls.length) {
          await waitIfPaused(Date.now() + (params.timeoutMs ?? 25000));
          const idx = cursor++;
          const targetUrl = urls[idx];
          const started = Date.now();
          let createdTab = null;
          try {
            const createOpts = { url: targetUrl, active: false };
            if (typeof targetWindowId === "number") createOpts.windowId = targetWindowId;
            createdTab = await chrome.tabs.create(createOpts);
            agentTabIds.add(createdTab.id);
            await attachToCollapsedBatchGroup(createdTab.id, createdTab.windowId);
            await waitForTabComplete(createdTab.id, params.timeoutMs ?? 15000, settleMs);
            await waitForPageHydration(createdTab.id, 2500);
            const snap = await runSnapshot(createdTab.id, {
              interactiveOnly: true,
              includeText: true,
              includeLinks,
              maxChars: maxCharsPerPage,
              maxElements: 1,
            });
            results[idx] = {
              ok: true,
              url: targetUrl,
              finalUrl: snap.url,
              title: snap.title,
              text: snap.text || "",
              ...(includeLinks ? { links: snap.links || [] } : {}),
              ...(!closeAfter ? { tabId: createdTab.id } : {}),
              elapsedMs: Date.now() - started,
            };
          } catch (err) {
            results[idx] = {
              ok: false,
              url: targetUrl,
              error: err?.message || String(err),
              elapsedMs: Date.now() - started,
            };
          } finally {
            remaining = Math.max(0, remaining - 1);
            if (closeAfter && createdTab?.id !== undefined) {
              agentTabIds.delete(createdTab.id);
              try {
                await chrome.tabs.remove(createdTab.id);
              } catch {
                // Ignore if already closed.
              }
            }
            if (batchGroupId !== null && remaining > 0) {
              updateBatchGroupTitle(batchGroupId, `${baseTitle} (${remaining})`);
            }
          }
        }
      }

      await Promise.all(Array.from({ length: Math.min(concurrency, urls.length) }, () => worker()));
      const okCount = results.filter((r) => r?.ok).length;
      finishActivity(actEntry, okCount > 0, `Read ${okCount}/${urls.length} pages`);
      return {
        pages: results,
        ...(batchGroupId !== null && !closeAfter ? { groupId: batchGroupId } : {}),
      };
    }

    case "closeTab": {
      if (typeof params.tabId !== "number") {
        throw bridgeError("invalid_request", "closeTab requires numeric tabId");
      }
      agentTabIds.delete(params.tabId);
      await chrome.tabs.remove(params.tabId);
      recordActivity(`Closed tab ${params.tabId}`, { ok: true });
      return { closed: true, tabId: params.tabId };
    }

    default:
      throw bridgeError("invalid_request", `Unknown browser action: ${action}`);
  }
}

chrome.tabs.onRemoved.addListener((tabId) => {
  agentTabIds.delete(tabId);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "cua_bridge_status") {
    (async () => {
      const liveTabs = [];
      for (const tid of Array.from(agentTabIds)) {
        try {
          const t = await chrome.tabs.get(tid);
          liveTabs.push({
            tabId: t.id,
            title: t.title || "",
            url: t.url || "",
            active: Boolean(t.active),
          });
        } catch {
          agentTabIds.delete(tid);
        }
      }
      sendResponse({
        connected,
        lastError,
        extensionId: chrome.runtime.id,
        paused,
        visualEnabled,
        inFlight: inFlightCount,
        agentTabs: liveTabs,
        recentActivity: recentActivity.slice(0, 10),
      });
    })();
    return true;
  }

  if (message?.type === "useui_toggle_pause") {
    const next = setPaused(!paused);
    sendResponse({ ok: true, paused: next });
    return true;
  }

  if (message?.type === "useui_toggle_visual") {
    visualEnabled = !visualEnabled;
    if (!visualEnabled) {
      chrome.tabs.query({ active: true }).then((tabs) => {
        for (const t of tabs) {
          if (t.id && isScriptableUrl(t.url)) {
            chrome.scripting
              .executeScript({
                target: { tabId: t.id },
                func: () => {
                  if (window.__useuiStage) window.__useuiStage.hide();
                },
              })
              .catch(() => {});
          }
        }
      });
    }
    sendResponse({ ok: true, visualEnabled });
    return true;
  }

  if (message?.type === "useui_focus_tab" && typeof message.tabId === "number") {
    chrome.tabs
      .get(message.tabId)
      .then(async (t) => {
        await chrome.windows.update(t.windowId, { focused: true });
        await chrome.tabs.update(t.id, { active: true });
        sendResponse({ ok: true });
      })
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  if (message?.type === "useui_close_agent_tabs") {
    const ids = Array.from(agentTabIds);
    agentTabIds.clear();
    Promise.allSettled(ids.map((id) => chrome.tabs.remove(id))).then(() => {
      sendResponse({ ok: true, closed: ids.length });
    });
    return true;
  }

  if (message?.type === "cua_bridge_reconnect") {
    if (port) {
      try {
        port.disconnect();
      } catch {
        /* ignore */
      }
      port = null;
    }
    reconnectDelayMs = 1000;
    connectNative();
    sendResponse({ ok: true });
    return true;
  }
  return false;
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === KEEPALIVE_ALARM && !port) {
    connectNative();
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.45 });
  connectNative();
});

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.45 });
  connectNative();
});

// Connect immediately when the service worker loads.
chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.45 });
connectNative();
