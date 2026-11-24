const dot = document.getElementById("dot");
const statusEl = document.getElementById("status");
const extIdEl = document.getElementById("ext-id");
const reconnectBtn = document.getElementById("reconnect");
const pauseBtn = document.getElementById("pause-btn");
const visualBtn = document.getElementById("visual-btn");
const closeTabsBtn = document.getElementById("close-tabs");
const tabsList = document.getElementById("tabs-list");
const activityList = document.getElementById("activity-list");

extIdEl.textContent = chrome.runtime.id.slice(0, 14) + "…";
extIdEl.title = chrome.runtime.id;

function timeAgo(ts) {
  const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (sec < 5) return "now";
  if (sec < 60) return `${sec}s`;
  return `${Math.floor(sec / 60)}m`;
}

function renderTabs(tabs) {
  tabsList.textContent = "";
  if (!tabs || tabs.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No active UseUI tabs";
    tabsList.appendChild(empty);
    closeTabsBtn.style.display = "none";
    return;
  }
  closeTabsBtn.style.display = "inline-block";
  for (const t of tabs) {
    const row = document.createElement("div");
    row.className = "item clickable";
    const main = document.createElement("span");
    main.className = "item-main";
    main.textContent = t.title || t.url || `Tab ${t.tabId}`;
    const meta = document.createElement("span");
    meta.className = "item-meta";
    meta.textContent = t.active ? "Active" : "Jump";
    row.appendChild(main);
    row.appendChild(meta);
    row.addEventListener("click", async () => {
      await chrome.runtime.sendMessage({ type: "useui_focus_tab", tabId: t.tabId });
      window.close();
    });
    tabsList.appendChild(row);
  }
}

function renderActivity(entries) {
  activityList.textContent = "";
  if (!entries || entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "Waiting for agent activity…";
    activityList.appendChild(empty);
    return;
  }
  for (const e of entries.slice(0, 8)) {
    const row = document.createElement("div");
    row.className = "item";
    const main = document.createElement("span");
    main.className = "item-main";
    const icon = e.ok === false ? "✕" : e.inFlight ? "●" : "✓";
    main.textContent = `${icon} ${e.label}`;
    const meta = document.createElement("span");
    meta.className = "item-meta";
    meta.textContent = timeAgo(e.ts);
    row.appendChild(main);
    row.appendChild(meta);
    activityList.appendChild(row);
  }
}

async function refresh() {
  try {
    const res = await chrome.runtime.sendMessage({ type: "cua_bridge_status" });
    dot.className = "dot";
    if (res?.paused) {
      dot.classList.add("paused");
      statusEl.textContent = "Paused";
    } else if (res?.connected) {
      dot.classList.add("ok");
      statusEl.textContent = res.inFlight > 0 ? `Working (${res.inFlight})` : "Connected";
    } else {
      dot.classList.add("err");
      statusEl.textContent = "Disconnected";
    }

    pauseBtn.textContent = res?.paused ? "Resume Agent" : "Pause Agent";
    pauseBtn.classList.toggle("primary", Boolean(res?.paused));

    const vis = res?.visualEnabled !== false;
    visualBtn.textContent = vis ? "Visuals: On" : "Visuals: Off";

    renderTabs(res?.agentTabs || []);
    renderActivity(res?.recentActivity || []);
  } catch (err) {
    dot.className = "dot err";
    statusEl.textContent = "Error";
  }
}

pauseBtn.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "useui_toggle_pause" });
  refresh();
});

visualBtn.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "useui_toggle_visual" });
  refresh();
});

closeTabsBtn.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "useui_close_agent_tabs" });
  refresh();
});

reconnectBtn.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "cua_bridge_reconnect" });
  setTimeout(refresh, 300);
});

refresh();
setInterval(refresh, 1500);
