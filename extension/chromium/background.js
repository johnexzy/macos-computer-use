const NATIVE_HOST_NAME = "com.johnoba.cua.browser";
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const KEEPALIVE_ALARM = "cua_bridge_keepalive";

let port = null;
let connected = false;
let lastError = null;
let reconnectTimer = null;
let reconnectDelayMs = 1000;

function updateBadge(isConnected) {
  connected = isConnected;
  try {
    chrome.action.setBadgeText({ text: isConnected ? "ON" : "OFF" });
    chrome.action.setBadgeBackgroundColor({
      color: isConnected ? "#1f883d" : "#6e7781",
    });
  } catch {
    // Ignore badge errors in headless/unfocused environments.
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
    updateBadge(true);
    reconnectDelayMs = 1000;

    nextPort.onMessage.addListener((message) => {
      handleNativeRequest(nextPort, message);
    });

    nextPort.onDisconnect.addListener(() => {
      const err = chrome.runtime.lastError?.message || "Native host disconnected";
      lastError = err;
      if (port === nextPort) {
        port = null;
        updateBadge(false);
        scheduleReconnect();
      }
    });
  } catch (err) {
    lastError = String(err);
    port = null;
    updateBadge(false);
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

// Execute a single DOM action step inside the page.
function executeDomStepInPage(step, snapshotId) {
  const kind = step.kind;

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

  if (kind === "scroll") {
    if (step.ref || step.text || step.selector) {
      const { el, error } = resolveTarget();
      if (error) return { ok: false, error };
      el.scrollIntoView({ behavior: "instant", block: "center", inline: "nearest" });
      return { ok: true, scrollY: Math.round(window.scrollY || 0) };
    }
    if (step.direction === "top") {
      window.scrollTo({ top: 0, behavior: "instant" });
    } else if (step.direction === "bottom") {
      window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" });
    } else {
      const dy =
        typeof step.deltaY === "number"
          ? step.deltaY
          : step.direction === "up"
            ? -Math.round(window.innerHeight * 0.75)
            : Math.round(window.innerHeight * 0.75);
      window.scrollBy({ top: dy, behavior: "instant" });
    }
    return { ok: true, scrollY: Math.round(window.scrollY || 0) };
  }

  if (kind === "click") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el) return { ok: false, error: { code: "invalid_request", message: "click requires ref, text, or selector" } };
    el.scrollIntoView({ behavior: "instant", block: "center", inline: "nearest" });
    const rect = el.getBoundingClientRect();
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
      return { ok: false, error: { code: "click_failed", message: String(e) } };
    }
    return { ok: true, tag: el.tagName, href: el.href || undefined };
  }

  if (kind === "type") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el) return { ok: false, error: { code: "invalid_request", message: "type requires ref, text target, or selector" } };
    el.scrollIntoView({ behavior: "instant", block: "center", inline: "nearest" });
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
    return { ok: true };
  }

  if (kind === "select") {
    const { el, error } = resolveTarget();
    if (error) return { ok: false, error };
    if (!el || el.tagName !== "SELECT") {
      return { ok: false, error: { code: "invalid_request", message: "select requires a <select> element" } };
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
      return { ok: false, error: { code: "option_not_found", message: "No matching <option> found" } };
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { ok: true, value: el.value };
  }

  if (kind === "pressKey") {
    const target = step.ref || step.selector ? resolveTarget().el : (document.activeElement || document.body);
    if (!target) return { ok: false, error: { code: "stale_ref", message: "Target element unavailable" } };
    const key = String(step.key || "Enter");
    const init = { key, bubbles: true, cancelable: true };
    target.dispatchEvent(new KeyboardEvent("keydown", init));
    target.dispatchEvent(new KeyboardEvent("keypress", init));
    target.dispatchEvent(new KeyboardEvent("keyup", init));
    return { ok: true };
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
  switch (action) {
    case "ping": {
      const tabs = await chrome.tabs.query({});
      const ua = navigator.userAgent || "";
      const browser = ua.includes("Edg/") ? "Edge" : ua.includes("Chrome/") ? "Chromium" : "Browser";
      return {
        browser,
        extensionVersion: EXTENSION_VERSION,
        tabCount: tabs.length,
      };
    }

    case "listTabs": {
      const tabs = await chrome.tabs.query({});
      return {
        tabs: tabs.map((t) => ({
          tabId: t.id,
          windowId: t.windowId,
          active: Boolean(t.active),
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
      const active = Boolean(params.active);
      const tab = await chrome.tabs.create({ url, active });
      const settleMs = params.settleMs ?? 350;
      const loaded = await waitForTabComplete(tab.id, params.timeoutMs ?? 15000, settleMs);
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
        return { tabId: tab.id, windowId: loaded.windowId, active: Boolean(loaded.active), snapshot: snap };
      }
      return {
        tabId: tab.id,
        windowId: loaded.windowId,
        active: Boolean(loaded.active),
        url: loaded.url || url,
        title: loaded.title || "",
      };
    }

    case "navigate": {
      const tab = await resolveTab(params.tabId);
      const history = params.history;
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
            throw err;
          }
        }
      } else if (history === "reload") {
        await chrome.tabs.reload(tab.id);
      } else if (params.url) {
        if (!isScriptableUrl(params.url)) {
          throw bridgeError("invalid_request", "navigate url must be http:// or https://");
        }
        await chrome.tabs.update(tab.id, { url: params.url });
      } else {
        throw bridgeError("invalid_request", "navigate requires url or history ('back'|'forward'|'reload')");
      }
      await sleep(150);
      const loaded = await waitForTabComplete(tab.id, params.timeoutMs ?? 15000, params.settleMs ?? 350);
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
      const snap = await runSnapshot(tab.id, {
        interactiveOnly: params.interactiveOnly !== false,
        includeText: Boolean(params.includeText),
        includeLinks: Boolean(params.includeLinks),
        query: params.query,
        maxChars: params.maxChars,
        maxElements: params.maxElements,
      });
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
      const receipts = [];
      for (let i = 0; i < steps.length; i++) {
        const step = steps[i];
        const stepId = step.id || `step-${i + 1}`;
        if (step.kind === "waitFor") {
          const waitRes = await runWaitStep(tab.id, step);
          receipts.push({ id: stepId, kind: "waitFor", ok: true, ...(waitRes.url ? { url: waitRes.url } : {}) });
          continue;
        }
        const exec = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: executeDomStepInPage,
          args: [step, params.snapshotId || null],
        });
        const outcome = exec?.[0]?.result;
        if (!outcome || !outcome.ok) {
          const err = outcome?.error || { code: "step_failed", message: "DOM step failed" };
          throw bridgeError(err.code, `Step ${stepId} (${step.kind}) failed: ${err.message}`);
        }
        receipts.push({ id: stepId, kind: step.kind, ok: true });
        if (step.kind === "click" && i + 1 < steps.length && steps[i + 1].kind !== "waitFor") {
          await sleep(120);
        }
      }
      const settleMs = params.settleMs ?? 250;
      await sleep(100);
      const loaded = await waitForTabComplete(tab.id, 10000, settleMs);
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

      const results = new Array(urls.length);
      let cursor = 0;

      async function worker() {
        while (cursor < urls.length) {
          const idx = cursor++;
          const targetUrl = urls[idx];
          const started = Date.now();
          let createdTab = null;
          try {
            createdTab = await chrome.tabs.create({ url: targetUrl, active: false });
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
            if (closeAfter && createdTab?.id !== undefined) {
              try {
                await chrome.tabs.remove(createdTab.id);
              } catch {
                // Ignore if already closed.
              }
            }
          }
        }
      }

      await Promise.all(Array.from({ length: Math.min(concurrency, urls.length) }, () => worker()));
      return { pages: results };
    }

    case "closeTab": {
      if (typeof params.tabId !== "number") {
        throw bridgeError("invalid_request", "closeTab requires numeric tabId");
      }
      await chrome.tabs.remove(params.tabId);
      return { closed: true, tabId: params.tabId };
    }

    default:
      throw bridgeError("invalid_request", `Unknown browser action: ${action}`);
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "cua_bridge_status") {
    sendResponse({ connected, lastError, extensionId: chrome.runtime.id });
    return true;
  }
  if (message?.type === "cua_bridge_reconnect") {
    if (port) {
      try { port.disconnect(); } catch { /* ignore */ }
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
