const dot = document.getElementById("dot");
const statusEl = document.getElementById("status");
const extIdEl = document.getElementById("ext-id");
const btn = document.getElementById("reconnect");

extIdEl.textContent = chrome.runtime.id;

async function refresh() {
  try {
    const res = await chrome.runtime.sendMessage({ type: "cua_bridge_status" });
    if (res?.connected) {
      dot.classList.add("ok");
      statusEl.textContent = "Native bridge connected";
    } else {
      dot.classList.remove("ok");
      statusEl.textContent = res?.lastError ? `Disconnected: ${res.lastError}` : "Disconnected";
    }
  } catch (err) {
    dot.classList.remove("ok");
    statusEl.textContent = String(err);
  }
}

btn.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "cua_bridge_reconnect" });
  setTimeout(refresh, 300);
});

refresh();
