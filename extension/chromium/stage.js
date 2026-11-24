// UseUI In-Page Closed Shadow DOM Stage
// Renders UseUI's Mint (#66E9BC) / Ink (#101C2C) / Paper (#F2F7F5) choreography
// inside watched browser tabs with zero CSS leakage and zero DOM snapshot pollution.
(() => {
  if (window.__useuiStage && window.__useuiStage.version === "1.1.0") {
    return;
  }

  const HOST_ID = "__useui_stage_host";
  const BRAND = {
    ink: "#101C2C",
    mint: "#66E9BC",
    paper: "#F2F7F5",
    slate: "#506173",
    amber: "#F5A623",
    coral: "#F25F5C",
  };

  function prefersReducedMotion() {
    return Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function isVisible() {
    return document.visibilityState === "visible";
  }

  function clamp(v, min, max) {
    return Math.max(min, Math.min(max, v));
  }

  // Cubic Bezier evaluation for organic curved cursor paths.
  function bezierPoint(p0, p1, p2, p3, t) {
    const u = 1 - t;
    const tt = t * t;
    const uu = u * u;
    const uuu = uu * u;
    const ttt = tt * t;
    return {
      x: uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
      y: uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y,
    };
  }

  function bezierTangent(p0, p1, p2, p3, t) {
    const u = 1 - t;
    return {
      x: 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x),
      y: 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y),
    };
  }

  function easeInOutCubic(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  // Fitts's Law inspired adaptive duration: fast on short hops, trackable on long sweeps.
  function fittsDuration(from, to) {
    const dist = Math.hypot(to.x - from.x, to.y - from.y);
    if (dist < 14) return 75;
    return Math.round(clamp(95 + 34 * Math.log2(1 + dist / 40), 110, 240));
  }

  function createStageDom() {
    const existing = document.getElementById(HOST_ID);
    if (existing) existing.remove();

    const host = document.createElement("div");
    host.id = HOST_ID;
    host.setAttribute("data-useui-ignore", "true");
    host.setAttribute("aria-hidden", "true");
    host.style.cssText =
      "position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;" +
      "pointer-events:none!important;z-index:2147483647!important;contain:layout style!important;" +
      "margin:0!important;padding:0!important;border:0!important;background:transparent!important;";

    const shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `
      <style>
        :host { all: initial; }
        * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif; }

        .stage {
          position: fixed;
          inset: 0;
          pointer-events: none;
          opacity: 0;
          transition: opacity 180ms cubic-bezier(0.22, 1, 0.36, 1);
        }
        .stage.visible { opacity: 1; }

        /* Open Frame viewport border & subtle breathing edge aura */
        .frame {
          position: fixed;
          inset: 0;
          border: 1.5px solid rgba(102, 233, 188, 0.72);
          box-shadow: inset 0 0 18px rgba(102, 233, 188, 0.16), inset 0 0 0 1px rgba(16, 28, 44, 0.38);
          border-radius: 2px;
          transition: border-color 180ms ease, box-shadow 180ms ease;
        }
        .stage[data-state="paused"] .frame {
          border-color: rgba(80, 97, 115, 0.7);
          box-shadow: inset 0 0 14px rgba(80, 97, 115, 0.14);
        }
        .stage[data-state="error"] .frame {
          border-color: rgba(242, 95, 92, 0.85);
          box-shadow: inset 0 0 22px rgba(242, 95, 92, 0.22);
        }
        .stage[data-state="warning"] .frame {
          border-color: rgba(245, 166, 35, 0.85);
          box-shadow: inset 0 0 20px rgba(245, 166, 35, 0.20);
        }

        /* Signature corner brackets mirroring UseUI app-icon.svg */
        .corner {
          position: fixed;
          width: 18px;
          height: 18px;
          border-color: ${BRAND.mint};
          border-style: solid;
          border-width: 0;
          filter: drop-shadow(0 0 4px rgba(16, 28, 44, 0.55));
          transition: border-color 180ms ease, opacity 180ms ease;
        }
        .stage[data-state="paused"] .corner { border-color: ${BRAND.slate}; }
        .stage[data-state="error"] .corner { border-color: ${BRAND.coral}; }
        .stage[data-state="warning"] .corner { border-color: ${BRAND.amber}; }
        .c-tl { top: 8px; left: 8px; border-top-width: 2.5px; border-left-width: 2.5px; border-top-left-radius: 5px; }
        .c-tr { top: 8px; right: 8px; border-top-width: 2.5px; border-right-width: 2.5px; border-top-right-radius: 5px; }
        .c-bl { bottom: 8px; left: 8px; border-bottom-width: 2.5px; border-left-width: 2.5px; border-bottom-left-radius: 5px; }
        .c-br { bottom: 8px; right: 8px; border-bottom-width: 2.5px; border-right-width: 2.5px; border-bottom-right-radius: 5px; }

        /* Target element lock-on spotlight brackets */
        .lock {
          position: fixed;
          left: 0;
          top: 0;
          width: 0;
          height: 0;
          opacity: 0;
          border-radius: 6px;
          background: rgba(102, 233, 188, 0.08);
          box-shadow: 0 0 0 1.5px rgba(102, 233, 188, 0.88), 0 0 0 3px rgba(16, 28, 44, 0.32), 0 0 16px rgba(102, 233, 188, 0.25);
          transition: opacity 150ms ease, transform 140ms cubic-bezier(0.22, 1, 0.36, 1);
          overflow: hidden;
        }
        .lock.show { opacity: 1; }
        .lock.shimmer::after {
          content: "";
          position: absolute;
          inset: 0;
          background: linear-gradient(105deg, transparent 20%, rgba(102, 233, 188, 0.36) 50%, transparent 80%);
          transform: translateX(-100%);
          animation: useuiShimmer 420ms ease-out forwards;
        }
        @keyframes useuiShimmer {
          to { transform: translateX(120%); }
        }

        /* Animated UseUI Mint/Ink cursor */
        .cursor {
          position: fixed;
          left: 0;
          top: 0;
          width: 34px;
          height: 34px;
          margin: 0;
          opacity: 0;
          transform-origin: 3px 3px;
          will-change: transform, opacity;
          transition: opacity 160ms ease;
          filter: drop-shadow(0 3px 7px rgba(16, 28, 44, 0.42));
        }
        .cursor.show { opacity: 1; }
        .cursor svg { display: block; width: 28px; height: 28px; overflow: visible; }
        .cursor-tag {
          position: absolute;
          left: 19px;
          top: 20px;
          padding: 2px 7px;
          border-radius: 999px;
          background: rgba(16, 28, 44, 0.92);
          color: ${BRAND.paper};
          border: 1px solid rgba(102, 233, 188, 0.55);
          font-size: 10px;
          font-weight: 600;
          letter-spacing: 0.01em;
          white-space: nowrap;
          box-shadow: 0 4px 12px rgba(16, 28, 44, 0.28);
        }
        .cursor-scroll {
          position: absolute;
          left: 24px;
          top: 2px;
          color: ${BRAND.mint};
          font-size: 12px;
          font-weight: 800;
          text-shadow: 0 1px 3px rgba(16, 28, 44, 0.9);
          opacity: 0;
          transition: opacity 120ms ease;
        }
        .cursor-scroll.show { opacity: 1; }

        /* Dual concentric Mint click ripples */
        .ripple {
          position: fixed;
          left: 0;
          top: 0;
          width: 14px;
          height: 14px;
          margin-left: -7px;
          margin-top: -7px;
          border-radius: 999px;
          border: 2px solid ${BRAND.mint};
          box-shadow: 0 0 0 1px rgba(16, 28, 44, 0.35);
          opacity: 0;
          pointer-events: none;
        }
        .ripple.animate {
          animation: useuiRipple 420ms cubic-bezier(0.16, 1, 0.3, 1) forwards;
        }
        .ripple.ring2.animate {
          animation: useuiRippleOuter 500ms cubic-bezier(0.16, 1, 0.3, 1) 55ms forwards;
        }
        @keyframes useuiRipple {
          0% { transform: scale(0.5); opacity: 0.95; }
          100% { transform: scale(3.1); opacity: 0; }
        }
        @keyframes useuiRippleOuter {
          0% { transform: scale(0.45); opacity: 0.65; }
          100% { transform: scale(4.2); opacity: 0; }
        }

        /* Floating Intent Pill (Bottom-Center Action Island) */
        .pill-wrap {
          position: fixed;
          left: 50%;
          bottom: 18px;
          transform: translateX(-50%) translateY(10px);
          opacity: 0;
          transition: opacity 180ms ease, transform 220ms cubic-bezier(0.22, 1, 0.36, 1);
          pointer-events: none;
        }
        .stage.visible .pill-wrap {
          opacity: 1;
          transform: translateX(-50%) translateY(0);
        }
        .pill {
          display: inline-flex;
          align-items: center;
          gap: 10px;
          max-width: min(520px, calc(100vw - 32px));
          padding: 7px 10px 7px 12px;
          border-radius: 999px;
          background: rgba(16, 28, 44, 0.90);
          -webkit-backdrop-filter: blur(14px) saturate(140%);
          backdrop-filter: blur(14px) saturate(140%);
          color: ${BRAND.paper};
          border: 1px solid rgba(102, 233, 188, 0.32);
          box-shadow: 0 10px 28px rgba(16, 28, 44, 0.36), 0 1px 0 rgba(242, 247, 245, 0.08) inset;
          pointer-events: auto;
        }
        .stage[data-state="paused"] .pill { border-color: rgba(245, 166, 35, 0.55); }
        .stage[data-state="error"] .pill { border-color: rgba(242, 95, 92, 0.65); }

        .dot {
          width: 8px;
          height: 8px;
          border-radius: 999px;
          background: ${BRAND.mint};
          box-shadow: 0 0 10px rgba(102, 233, 188, 0.85);
          flex-shrink: 0;
          animation: useuiPulse 1.6s ease-in-out infinite;
        }
        .stage[data-state="paused"] .dot { background: ${BRAND.amber}; box-shadow: 0 0 8px rgba(245, 166, 35, 0.7); animation: none; }
        .stage[data-state="error"] .dot { background: ${BRAND.coral}; box-shadow: 0 0 8px rgba(242, 95, 92, 0.75); animation: none; }
        @keyframes useuiPulse {
          0%, 100% { transform: scale(1); opacity: 1; }
          50% { transform: scale(0.75); opacity: 0.65; }
        }

        .brand {
          font-size: 11px;
          font-weight: 700;
          color: ${BRAND.mint};
          letter-spacing: 0.02em;
          flex-shrink: 0;
        }
        .sep {
          width: 1px;
          height: 12px;
          background: rgba(242, 247, 245, 0.18);
          flex-shrink: 0;
        }
        .label {
          font-size: 12px;
          font-weight: 500;
          color: ${BRAND.paper};
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          max-width: 280px;
        }
        .btn {
          appearance: none;
          border: 1px solid rgba(242, 247, 245, 0.16);
          background: rgba(242, 247, 245, 0.08);
          color: ${BRAND.paper};
          font-size: 11px;
          font-weight: 600;
          padding: 4px 10px;
          border-radius: 999px;
          cursor: pointer;
          transition: background 120ms ease, border-color 120ms ease, transform 80ms ease;
          flex-shrink: 0;
        }
        .btn:hover { background: rgba(102, 233, 188, 0.18); border-color: rgba(102, 233, 188, 0.55); }
        .btn:active { transform: scale(0.95); }
        .btn.resume {
          background: ${BRAND.mint};
          color: ${BRAND.ink};
          border-color: ${BRAND.mint};
        }
        .btn.resume:hover { background: #85f0cb; }

        @media (prefers-reduced-motion: reduce) {
          .dot, .ripple.animate, .lock.shimmer::after { animation: none !important; }
          .stage, .pill-wrap, .lock, .cursor { transition: none !important; }
        }
        @media (prefers-contrast: more) {
          .frame { border-width: 3px; }
          .pill { border-width: 2px; background: ${BRAND.ink}; }
        }
      </style>

      <div class="stage" data-state="active">
        <div class="frame"></div>
        <div class="corner c-tl"></div>
        <div class="corner c-tr"></div>
        <div class="corner c-bl"></div>
        <div class="corner c-br"></div>
        <div class="lock"></div>
        <div class="ripple ring1"></div>
        <div class="ripple ring2"></div>
        <div class="cursor">
          <svg viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path class="arrow-path" d="M3.2 2.8a1.4 1.4 0 0 1 2-.1.1 0 0 1 .1.1l18.2 9.1a1.4 1.4 0 0 1-.3 2.6l-7.7 1.8-4.1 7.2a1.4 1.4 0 0 1-2.6-.3L3.2 2.8Z"
                  fill="${BRAND.mint}" stroke="${BRAND.ink}" stroke-width="2.1" stroke-linejoin="round"/>
            <path class="arrow-rim" d="M4.9 4.7l15.4 7.7-6.4 1.5-3.4 6L4.9 4.7Z"
                  fill="none" stroke="${BRAND.paper}" stroke-opacity="0.45" stroke-width="0.9" stroke-linejoin="round"/>
            <g class="caret-shape" opacity="0">
              <rect x="1" y="1" width="3.2" height="20" rx="1.6" fill="${BRAND.mint}" stroke="${BRAND.ink}" stroke-width="1.2"/>
              <rect x="-2.5" y="0" width="10" height="2.4" rx="1.2" fill="${BRAND.mint}" stroke="${BRAND.ink}" stroke-width="0.9"/>
              <rect x="-2.5" y="19.5" width="10" height="2.4" rx="1.2" fill="${BRAND.mint}" stroke="${BRAND.ink}" stroke-width="0.9"/>
            </g>
          </svg>
          <span class="cursor-scroll"></span>
          <span class="cursor-tag">UseUI</span>
        </div>
        <div class="pill-wrap">
          <div class="pill">
            <span class="dot"></span>
            <span class="brand">UseUI</span>
            <span class="sep"></span>
            <span class="label">Working…</span>
            <button class="btn pause-btn" type="button">Pause</button>
          </div>
        </div>
      </div>
    `;

    (document.documentElement || document.body).appendChild(host);
    return { host, shadow };
  }

  let refs = null;
  let idleTimer = null;
  let lockTimer = null;
  let animRaf = null;
  let cursorPos = { x: Math.round(window.innerWidth * 0.55), y: Math.round(window.innerHeight * 0.45) };
  let isPaused = false;
  let stageActive = false;
  let userNudgeTimer = null;

  function ensureStage() {
    if (refs && refs.host.isConnected) return refs;
    const { host, shadow } = createStageDom();
    const stage = shadow.querySelector(".stage");
    const lock = shadow.querySelector(".lock");
    const cursor = shadow.querySelector(".cursor");
    const arrowPath = shadow.querySelector(".arrow-path");
    const arrowRim = shadow.querySelector(".arrow-rim");
    const caretShape = shadow.querySelector(".caret-shape");
    const scrollBadge = shadow.querySelector(".cursor-scroll");
    const cursorTag = shadow.querySelector(".cursor-tag");
    const ring1 = shadow.querySelector(".ring1");
    const ring2 = shadow.querySelector(".ring2");
    const label = shadow.querySelector(".label");
    const pauseBtn = shadow.querySelector(".pause-btn");

    pauseBtn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      ev.preventDefault();
      try {
        chrome.runtime.sendMessage({ type: "useui_toggle_pause" }, (res) => {
          if (chrome.runtime.lastError) return;
          applyPauseVisual(Boolean(res?.paused));
        });
      } catch {
        // Ignore if extension context reloaded.
      }
    });

    refs = {
      host, shadow, stage, lock, cursor, arrowPath, arrowRim, caretShape,
      scrollBadge, cursorTag, ring1, ring2, label, pauseBtn,
    };
    return refs;
  }

  function applyPauseVisual(paused) {
    isPaused = paused;
    const r = ensureStage();
    if (paused) {
      clearTimeout(idleTimer);
      r.stage.dataset.state = "paused";
      r.stage.classList.add("visible");
      r.label.textContent = "Paused · You're in control";
      r.pauseBtn.textContent = "Resume";
      r.pauseBtn.classList.add("resume");
    } else {
      r.stage.dataset.state = "active";
      r.pauseBtn.textContent = "Pause";
      r.pauseBtn.classList.remove("resume");
      r.label.textContent = "Resuming…";
      scheduleIdleHide(2200);
    }
  }

  // Graceful auto-yield: detect real human clicks while UseUI is actively driving this tab.
  window.addEventListener(
    "pointerdown",
    (ev) => {
      if (!ev.isTrusted || !stageActive || isPaused) return;
      if (refs && ev.target === refs.host) return;
      const r = ensureStage();
      r.label.textContent = "You're interacting · Pause UseUI?";
      r.stage.dataset.state = "warning";
      clearTimeout(userNudgeTimer);
      userNudgeTimer = setTimeout(() => {
        if (!isPaused && refs) refs.stage.dataset.state = "active";
      }, 2400);
    },
    { capture: true, passive: true }
  );

  function scheduleIdleHide(ms = 2400) {
    clearTimeout(idleTimer);
    if (isPaused) return;
    idleTimer = setTimeout(() => {
      if (isPaused || !refs) return;
      stageActive = false;
      refs.stage.classList.remove("visible");
      refs.cursor.classList.remove("show");
      refs.lock.classList.remove("show");
    }, ms);
  }

  function setCursorMode(mode) {
    const r = ensureStage();
    const isCaret = mode === "type";
    r.arrowPath.setAttribute("opacity", isCaret ? "0" : "1");
    r.arrowRim.setAttribute("opacity", isCaret ? "0" : "1");
    r.caretShape.setAttribute("opacity", isCaret ? "1" : "0");
    if (mode === "scroll-up") {
      r.scrollBadge.textContent = "▲";
      r.scrollBadge.classList.add("show");
    } else if (mode === "scroll-down") {
      r.scrollBadge.textContent = "▼";
      r.scrollBadge.classList.add("show");
    } else {
      r.scrollBadge.classList.remove("show");
    }
  }

  function placeCursor(x, y, angleDeg = 0, scale = 1) {
    const r = ensureStage();
    cursorPos = { x, y };
    r.cursor.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) rotate(${angleDeg.toFixed(2)}deg) scale(${scale.toFixed(3)})`;
  }

  function showLockOn(rect, shimmer = false) {
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    const r = ensureStage();
    const pad = 4;
    r.lock.style.left = `${Math.max(2, rect.left - pad)}px`;
    r.lock.style.top = `${Math.max(2, rect.top - pad)}px`;
    r.lock.style.width = `${Math.min(window.innerWidth - 4, rect.width + pad * 2)}px`;
    r.lock.style.height = `${Math.min(window.innerHeight - 4, rect.height + pad * 2)}px`;
    r.lock.classList.remove("shimmer");
    if (shimmer) {
      void r.lock.offsetWidth;
      r.lock.classList.add("shimmer");
    }
    r.lock.classList.add("show");
    clearTimeout(lockTimer);
    lockTimer = setTimeout(() => {
      if (refs) refs.lock.classList.remove("show", "shimmer");
    }, 850);
  }

  function fireRipple(x, y) {
    if (prefersReducedMotion()) return;
    const r = ensureStage();
    for (const ring of [r.ring1, r.ring2]) {
      ring.classList.remove("animate");
      ring.style.left = `${x}px`;
      ring.style.top = `${y}px`;
      void ring.offsetWidth;
      ring.classList.add("animate");
    }
  }

  function glideTo(targetX, targetY, opts = {}) {
    if (!isVisible()) return Promise.resolve();
    const r = ensureStage();
    if (animRaf) cancelAnimationFrame(animRaf);
    const tx = clamp(targetX, 4, window.innerWidth - 6);
    const ty = clamp(targetY, 4, window.innerHeight - 6);
    r.cursor.classList.add("show");

    if (prefersReducedMotion() || opts.instant) {
      placeCursor(tx, ty, 0, 1);
      return Promise.resolve();
    }

    const p0 = { ...cursorPos };
    const p3 = { x: tx, y: ty };
    const dx = p3.x - p0.x;
    const dy = p3.y - p0.y;
    const dist = Math.hypot(dx, dy);
    const duration = opts.durationMs || fittsDuration(p0, p3);

    // Subtle perpendicular Bezier arc for organic, human-trackable movement.
    const nx = dist > 1 ? -dy / dist : 0;
    const ny = dist > 1 ? dx / dist : 0;
    const arc = clamp(dist * 0.14, 8, 52) * (dx >= 0 ? -1 : 1);
    const p1 = { x: p0.x + dx * 0.28 + nx * arc, y: p0.y + dy * 0.28 + ny * arc };
    const p2 = { x: p0.x + dx * 0.72 + nx * arc * 0.65, y: p0.y + dy * 0.72 + ny * arc * 0.65 };

    return new Promise((resolve) => {
      const t0 = performance.now();
      function frame(now) {
        const raw = clamp((now - t0) / duration, 0, 1);
        const eased = easeInOutCubic(raw);
        const pos = bezierPoint(p0, p1, p2, p3, eased);
        const tan = bezierTangent(p0, p1, p2, p3, eased);
        // Gentle velocity banking that settles smoothly to 0 deg before contact.
        const settle = Math.sin(raw * Math.PI);
        const bank = clamp((tan.x / (Math.hypot(tan.x, tan.y) || 1)) * 9 * settle, -8, 8);
        placeCursor(pos.x, pos.y, bank, 1);
        if (raw < 1) {
          animRaf = requestAnimationFrame(frame);
        } else {
          animRaf = null;
          placeCursor(tx, ty, 0, 1);
          resolve();
        }
      }
      animRaf = requestAnimationFrame(frame);
    });
  }

  function squishClick(x, y) {
    if (!isVisible() || prefersReducedMotion()) return Promise.resolve();
    fireRipple(x, y);
    return new Promise((resolve) => {
      placeCursor(x, y, 0, 0.85);
      setTimeout(() => {
        placeCursor(x, y, 0, 1.04);
        setTimeout(() => {
          placeCursor(x, y, 0, 1.0);
          resolve();
        }, 55);
      }, 65);
    });
  }

  window.__useuiStage = {
    version: "1.1.0",

    setStatus(labelText, state = "active", opts = {}) {
      if (!isVisible() && state !== "paused") return;
      const r = ensureStage();
      stageActive = true;
      if (opts.tag) r.cursorTag.textContent = opts.tag;
      r.stage.dataset.state = isPaused ? "paused" : state;
      r.stage.classList.add("visible");
      if (!isPaused && labelText) r.label.textContent = labelText;
      scheduleIdleHide(opts.idleMs ?? 2600);
    },

    setPaused(paused) {
      applyPauseVisual(Boolean(paused));
    },

    async animateClick(rect, labelText, opts = {}) {
      if (!isVisible()) return;
      this.setStatus(labelText || "Clicking element", "active", opts);
      setCursorMode("pointer");
      const cx = rect ? rect.left + rect.width / 2 : cursorPos.x;
      const cy = rect ? rect.top + rect.height / 2 : cursorPos.y;
      if (rect) showLockOn(rect, false);
      await glideTo(cx, cy, opts);
      await squishClick(cx, cy);
      scheduleIdleHide(2600);
    },

    async animateType(rect, labelText, opts = {}) {
      if (!isVisible()) return;
      this.setStatus(labelText || "Typing text", "active", opts);
      const tx = rect ? rect.left + Math.min(18, rect.width * 0.25) : cursorPos.x;
      const ty = rect ? rect.top + rect.height / 2 : cursorPos.y;
      setCursorMode("pointer");
      if (rect) showLockOn(rect, false);
      await glideTo(tx, ty, opts);
      setCursorMode("type");
      if (rect) showLockOn(rect, true);
      scheduleIdleHide(2600);
    },

    async animateScroll(direction, labelText, opts = {}) {
      if (!isVisible()) return;
      this.setStatus(labelText || "Scrolling page", "active", opts);
      setCursorMode(direction === "up" || direction === "top" ? "scroll-up" : "scroll-down");
      const cx = clamp(cursorPos.x, 80, window.innerWidth - 80);
      const cy = clamp(cursorPos.y, 80, window.innerHeight - 80);
      placeCursor(cx, cy, 0, 1);
      ensureStage().cursor.classList.add("show");
      scheduleIdleHide(2400);
    },

    hide() {
      if (!refs) return;
      stageActive = false;
      clearTimeout(idleTimer);
      refs.stage.classList.remove("visible");
      refs.cursor.classList.remove("show");
      refs.lock.classList.remove("show");
    },
  };
})();
