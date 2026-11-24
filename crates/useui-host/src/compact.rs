//! Compact, LLM-native text projection for MCP `CallToolResult.content[0]`.
//!
//! Full lossless JSON always remains in `structuredContent` for programmatic callers;
//! this module removes structural JSON bloat (repeated keys, null fields, non-spatial
//! bounds, and redundant Chromium child `AXStaticText` duplicates) so observations stay
//! well under client inline truncation limits (~6-10 KB instead of ~72 KB).

use std::fmt::Write;
use useui_protocol::*;

pub fn format_response(response: &Response) -> String {
    let mut out = String::with_capacity(2048);
    match &response.body {
        ResponseBody::Capabilities(cap) => format_capabilities(cap, None, &mut out),
        ResponseBody::Targets(res) => format_targets(res, &mut out),
        ResponseBody::Observe(obs) => format_observation(obs, &mut out),
        ResponseBody::Act(act) => format_act(act, &mut out),
        ResponseBody::WaitFor(wait) => format_wait(wait, &mut out),
        ResponseBody::Open(open) => format_open(open, &mut out),
        ResponseBody::Clipboard(clip) => format_clipboard(clip, &mut out),
        ResponseBody::Hello(h) => {
            let _ = write!(
                out,
                "hello v{} helper={}",
                h.selected_version, h.helper_version
            );
        }
        ResponseBody::Cancel(c) => {
            let _ = write!(out, "cancel req={} status={:?}", c.request_id, c.status);
        }
        ResponseBody::Error(e) => {
            let _ = write!(out, "error {:?}: {}", e.code, e.message);
        }
    }
    out
}

pub fn format_capabilities(cap: &Capabilities, browser_status: Option<&str>, out: &mut String) {
    let acts: Vec<&str> = cap.actions.iter().map(action_kind_str).collect();
    let _ = writeln!(
        out,
        "mode={} perms(ax={},input={},screen={}) actions=[{}]",
        execution_mode_str(cap.mode),
        cap.permissions.accessibility,
        cap.permissions.input_posting,
        cap.permissions.screen_recording,
        acts.join(",")
    );
    if let Some(status) = browser_status {
        let _ = writeln!(out, "browserExtension: {status}");
    }
}

fn format_targets(res: &TargetsResult, out: &mut String) {
    let _ = writeln!(
        out,
        "targets={}{}",
        res.targets.len(),
        if res.truncated { " (truncated)" } else { "" }
    );
    for t in &res.targets {
        let owner = t
            .bundle_id
            .as_deref()
            .or(t.owner_name.as_deref())
            .unwrap_or("unbundled");
        let off = if t.on_screen == Some(false) {
            " offscreen"
        } else {
            ""
        };
        let title = t.title.as_str();
        let _ = writeln!(
            out,
            "- {}:{} [{}] {} @{:.0},{:.0},{:.0}x{:.0}{}",
            t.key.pid,
            t.key.window_id,
            owner,
            quote(title),
            t.bounds.x,
            t.bounds.y,
            t.bounds.width,
            t.bounds.height,
            off
        );
    }
    if let Some(displays) = &res.displays {
        let _ = writeln!(out, "displays={}", displays.len());
        for d in displays {
            let _ = writeln!(
                out,
                "- display={} @{:.0},{:.0},{:.0}x{:.0} scale={:.1}{}",
                d.display_id,
                d.bounds.x,
                d.bounds.y,
                d.bounds.width,
                d.bounds.height,
                d.scale_factor,
                if d.is_primary { " primary" } else { "" }
            );
        }
    }
    if let Some(apps) = &res.apps {
        let running: Vec<&AppInfo> = apps.iter().filter(|a| a.running).collect();
        let installed_only = apps.len() - running.len();
        let _ = writeln!(
            out,
            "apps={} (running={}, installedOnly={})",
            apps.len(),
            running.len(),
            installed_only
        );
        for a in running {
            let bid = a.bundle_id.as_deref().unwrap_or("-");
            let flags = match (a.active, a.hidden) {
                (true, _) => " active",
                (false, true) => " hidden",
                _ => "",
            };
            let _ = writeln!(
                out,
                "- {} [{}] pid={}{}",
                a.name,
                bid,
                a.pid.unwrap_or(0),
                flags
            );
        }
        if installed_only > 0 {
            let names: Vec<&str> = apps
                .iter()
                .filter(|a| !a.running)
                .take(40)
                .map(|a| a.name.as_str())
                .collect();
            let _ = writeln!(
                out,
                "installed(sample {} of {}): {}",
                names.len(),
                installed_only,
                names.join(", ")
            );
        }
    }
}

pub fn format_observation(obs: &Observation, out: &mut String) {
    let ms = obs
        .collected
        .finished_unix_ms
        .saturating_sub(obs.collected.started_unix_ms);
    let include_bounds = obs.screenshot.is_some() || obs.visual.is_some();
    let _ = writeln!(
        out,
        "obs={} target={}:{} cov={} win={:.0},{:.0},{:.0}x{:.0} els={} ms={}",
        obs.observation_id,
        obs.target.pid,
        obs.target.window_id,
        coverage_str(obs.accessibility),
        obs.window_bounds.x,
        obs.window_bounds.y,
        obs.window_bounds.width,
        obs.window_bounds.height,
        obs.elements.len(),
        ms
    );
    if let Some(sel) = &obs.ax_selection {
        let _ = writeln!(
            out,
            "axSelection cov={} ambiguous={} visited={}",
            coverage_str(sel.coverage),
            sel.ambiguous,
            sel.visited_nodes
        );
    }
    if let Some(vis) = &obs.visual {
        let _ = write!(out, "visual={:?}", vis.capture_status);
        if let Some(matches_ax) = vis.geometry_matches_ax {
            let _ = write!(out, " geometryMatchesAX={matches_ax}");
        }
        if let Some(frame) = &vis.frame {
            let _ = write!(out, " frame={}x{}", frame.width_px, frame.height_px);
        }
        out.push('\n');
        if let Some(ocr) = &vis.ocr {
            let _ = writeln!(out, "ocr={:?} matches={}", ocr.status, ocr.matches.len());
            for m in &ocr.matches {
                let _ = writeln!(
                    out,
                    "  ocr {} @{:.0},{:.0},{:.0}x{:.0}",
                    quote(&m.text),
                    m.image_bounds.x,
                    m.image_bounds.y,
                    m.image_bounds.width,
                    m.image_bounds.height
                );
            }
        }
    }

    // Track preceding interactive label so we skip redundant Chromium child AXStaticText duplicates.
    let mut prev_container_label: Option<&str> = None;
    for el in &obs.elements {
        let is_static = el.role == "AXStaticText";
        let has_interactive_action = el.actions.iter().any(|a| {
            matches!(
                a,
                ElementAction::Press
                    | ElementAction::SetValue
                    | ElementAction::TypeText
                    | ElementAction::Confirm
                    | ElementAction::Cancel
                    | ElementAction::Scroll
            )
        });
        if is_static && !has_interactive_action {
            let text = el
                .value
                .as_deref()
                .or(el.label.as_deref())
                .unwrap_or("")
                .trim();
            if !text.is_empty()
                && let Some(prev) = prev_container_label
                && prev.contains(text)
            {
                continue;
            }
        } else if matches!(
            el.role.as_str(),
            "AXLink" | "AXButton" | "AXHeading" | "AXMenuItem" | "AXTabButton" | "AXPopUpButton"
        ) {
            prev_container_label = el.label.as_deref();
        } else {
            prev_container_label = None;
        }

        let role = el.role.strip_prefix("AX").unwrap_or(&el.role);
        let _ = write!(out, "[{}] {}", el.reference, role);
        if let Some(sub) = &el.subrole {
            let s = sub.strip_prefix("AX").unwrap_or(sub);
            let _ = write!(out, ":{s}");
        }
        if let Some(lbl) = &el.label
            && !lbl.is_empty()
        {
            let _ = write!(out, " {}", quote(lbl));
        }
        if let Some(val) = &el.value
            && el.label.as_deref() != Some(val.as_str())
        {
            let _ = write!(out, " val={}", quote(val));
        }
        if let Some(id) = &el.identifier
            && !id.is_empty()
        {
            let _ = write!(out, " id={id}");
        }
        if let Some(url) = &el.url
            && !url.is_empty()
        {
            let _ = write!(out, " url={url}");
        }
        if el.enabled == Some(false) {
            out.push_str(" disabled");
        } else if el.enabled.is_none() {
            out.push_str(" enabled=?");
        }
        if include_bounds {
            let _ = write!(
                out,
                " @{:.0},{:.0},{:.0}x{:.0}",
                el.bounds.x, el.bounds.y, el.bounds.width, el.bounds.height
            );
        }
        let is_non_interactive_text = matches!(
            el.role.as_str(),
            "AXStaticText" | "AXHeading" | "AXImage" | "AXList" | "AXTable"
        );
        let acts: Vec<&str> = el
            .actions
            .iter()
            .filter(|a| {
                if is_non_interactive_text {
                    !matches!(a, ElementAction::ShowMenu | ElementAction::ScrollToVisible)
                } else {
                    !matches!(a, ElementAction::ShowMenu)
                        || matches!(
                            el.role.as_str(),
                            "AXMenuButton" | "AXPopUpButton" | "AXMenuItem"
                        )
                }
            })
            .map(element_action_str)
            .collect();
        if !acts.is_empty() {
            let _ = write!(out, " ({})", acts.join(","));
        }
        out.push('\n');
    }

    if let Some(ev) = &obs.events {
        let _ = writeln!(
            out,
            "events cursor={}:{} count={} stale={} overrun={}",
            ev.cursor.generation,
            ev.cursor.sequence,
            ev.events.len(),
            ev.stale,
            ev.overrun
        );
    }
}

fn format_act(act: &ActResult, out: &mut String) {
    let _ = writeln!(
        out,
        "act obs={} stop={:?} rem={}",
        act.observation_id, act.stop_reason, act.remaining_steps
    );
    for s in &act.steps {
        let _ = write!(
            out,
            "- {}: {:?}/{:?}",
            s.action_id, s.delivery, s.verification
        );
        if let Some(route) = s.route {
            let _ = write!(out, " route={route:?}");
        }
        if let Some(reason) = s.reason {
            let _ = write!(out, " reason={reason:?}");
        }
        out.push('\n');
    }
    if let Some(fb) = &act.feedback {
        let _ = writeln!(
            out,
            "feedback invalidated={} controls={}",
            fb.invalidated,
            fb.controls.len()
        );
        for c in &fb.controls {
            let _ = write!(out, "  {} {:?}", c.element_ref, c.state);
            if let Some(el) = &c.element
                && let Some(val) = &el.value
            {
                let _ = write!(out, " val={}", quote(val));
            }
            out.push('\n');
        }
    }
    if let Some(obs) = &act.observation {
        out.push_str("--- observeAfter ---\n");
        format_observation(obs, out);
    }
}

fn format_wait(wait: &WaitResult, out: &mut String) {
    let _ = write!(
        out,
        "wait={:?} already={}",
        wait.outcome, wait.already_satisfied
    );
    if let Some(ev) = &wait.evidence {
        let _ = write!(out, " matched={}", ev.matched);
        if let Some(c) = &ev.collected {
            let _ = write!(
                out,
                " waitMs={}",
                c.finished_unix_ms.saturating_sub(c.started_unix_ms)
            );
        }
    }
    out.push('\n');
    if let Some(obs) = &wait.observation {
        format_observation(obs, out);
    }
}

fn format_open(open: &OpenResult, out: &mut String) {
    let _ = writeln!(
        out,
        "open pid={} bundle={} activated={} targets={}",
        open.pid
            .map(|p| p.to_string())
            .unwrap_or_else(|| "-".into()),
        open.bundle_id.as_deref().unwrap_or("-"),
        open.activated,
        open.targets.len()
    );
    for t in &open.targets {
        let _ = writeln!(
            out,
            "- {}:{} {} @{:.0},{:.0},{:.0}x{:.0}",
            t.key.pid,
            t.key.window_id,
            quote(&t.title),
            t.bounds.x,
            t.bounds.y,
            t.bounds.width,
            t.bounds.height
        );
    }
    if let Some(obs) = &open.observation {
        out.push_str("--- initialObservation ---\n");
        format_observation(obs, out);
    }
}

fn format_clipboard(clip: &ClipboardResult, out: &mut String) {
    let _ = writeln!(
        out,
        "clipboard changeCount={} types=[{}] textBytes={}{}",
        clip.change_count,
        clip.types.join(","),
        clip.text_bytes
            .map(|n| n.to_string())
            .unwrap_or_else(|| "-".into()),
        if clip.truncated { " truncated" } else { "" }
    );
    if let Some(text) = &clip.text {
        let _ = writeln!(out, "text: {}", quote(text));
    }
}

fn quote(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| format!("\"{s}\""))
}

fn coverage_str(c: Coverage) -> &'static str {
    match c {
        Coverage::Complete => "complete",
        Coverage::Partial => "partial",
        Coverage::Unavailable => "unavailable",
    }
}

fn execution_mode_str(m: ExecutionMode) -> &'static str {
    match m {
        ExecutionMode::BackgroundRequired => "backgroundRequired",
        ExecutionMode::ForegroundAllowed => "foregroundAllowed",
    }
}

fn element_action_str(a: &ElementAction) -> &'static str {
    match a {
        ElementAction::SetValue => "setValue",
        ElementAction::Press => "press",
        ElementAction::TypeText => "typeText",
        ElementAction::Key => "key",
        ElementAction::Scroll => "scroll",
        ElementAction::ScrollToVisible => "scrollToVisible",
        ElementAction::Confirm => "confirm",
        ElementAction::ShowMenu => "showMenu",
        ElementAction::Cancel => "cancel",
    }
}

fn action_kind_str(a: &ActionKind) -> &'static str {
    match a {
        ActionKind::SetValue => "setValue",
        ActionKind::Press => "press",
        ActionKind::TypeText => "typeText",
        ActionKind::Scroll => "scroll",
        ActionKind::ScrollToVisible => "scrollToVisible",
        ActionKind::Confirm => "confirm",
        ActionKind::ShowMenu => "showMenu",
        ActionKind::Cancel => "cancel",
        ActionKind::InvokeMenu => "invokeMenu",
        ActionKind::SetWindowFrame => "setWindowFrame",
        ActionKind::WindowAction => "windowAction",
        ActionKind::Key => "key",
        ActionKind::Hotkey => "hotkey",
        ActionKind::TypeKeys => "typeKeys",
        ActionKind::FocusWindow => "focusWindow",
        ActionKind::Click => "click",
        ActionKind::DoubleClick => "doubleClick",
        ActionKind::RightClick => "rightClick",
        ActionKind::Hover => "hover",
        ActionKind::Drag => "drag",
        ActionKind::ScrollWheel => "scrollWheel",
    }
}

pub fn format_browser_result(action: &str, data: &serde_json::Value) -> String {
    let mut out = String::with_capacity(2048);
    let ms = data
        .get("elapsedMs")
        .and_then(|v| v.as_u64())
        .map(|v| format!(" ms={v}"))
        .unwrap_or_default();

    match action {
        "status" => {
            let conn = data
                .get("connected")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let ext = data
                .get("extensionId")
                .and_then(|v| v.as_str())
                .unwrap_or("-");
            if conn {
                let br = data
                    .get("browser")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Chromium");
                let ver = data
                    .get("extensionVersion")
                    .and_then(|v| v.as_str())
                    .unwrap_or("-");
                let tabs = data.get("tabCount").and_then(|v| v.as_u64()).unwrap_or(0);
                let _ = writeln!(
                    out,
                    "browserExtension connected=true browser={br} version={ver} tabs={tabs} id={ext}"
                );
            } else {
                let _ = writeln!(out, "browserExtension connected=false id={ext}");
            }
        }
        "listTabs" => {
            let tabs = data.get("tabs").and_then(|v| v.as_array());
            let count = tabs.map(|a| a.len()).unwrap_or(0);
            let _ = writeln!(out, "tabs={count}{ms}");
            if let Some(tabs) = tabs {
                for t in tabs {
                    let tid = t.get("tabId").and_then(|v| v.as_i64()).unwrap_or(-1);
                    let wid = t.get("windowId").and_then(|v| v.as_i64()).unwrap_or(-1);
                    let active = if t.get("active").and_then(|v| v.as_bool()) == Some(true) {
                        "*"
                    } else {
                        " "
                    };
                    let title = t.get("title").and_then(|v| v.as_str()).unwrap_or("");
                    let url = t.get("url").and_then(|v| v.as_str()).unwrap_or("");
                    let _ = writeln!(
                        out,
                        "{active} tab={tid} win={wid} {} url={url}",
                        quote(title)
                    );
                }
            }
        }
        "batchRead" => {
            let pages = data.get("pages").and_then(|v| v.as_array());
            let count = pages.map(|a| a.len()).unwrap_or(0);
            let _ = writeln!(out, "batchRead pages={count}{ms}");
            if let Some(pages) = pages {
                for (i, p) in pages.iter().enumerate() {
                    let ok = p.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
                    let pms = p.get("elapsedMs").and_then(|v| v.as_u64()).unwrap_or(0);
                    if ok {
                        let title = p.get("title").and_then(|v| v.as_str()).unwrap_or("");
                        let final_url = p.get("finalUrl").and_then(|v| v.as_str()).unwrap_or("");
                        let _ = writeln!(
                            out,
                            "\n=== Page {} ({pms}ms): {} ===\nurl={final_url}",
                            i + 1,
                            title
                        );
                        if let Some(text) = p.get("text").and_then(|v| v.as_str()) {
                            out.push_str(text);
                            out.push('\n');
                        }
                        if let Some(links) = p.get("links").and_then(|v| v.as_array())
                            && !links.is_empty()
                        {
                            let _ = writeln!(out, "links({}):", links.len());
                            for l in links.iter().take(15) {
                                let lbl = l.get("label").and_then(|v| v.as_str()).unwrap_or("");
                                let href = l.get("href").and_then(|v| v.as_str()).unwrap_or("");
                                let _ = writeln!(out, "  - {} -> {href}", quote(lbl));
                            }
                        }
                    } else {
                        let url = p.get("url").and_then(|v| v.as_str()).unwrap_or("");
                        let err = p.get("error").and_then(|v| v.as_str()).unwrap_or("failed");
                        let _ = writeln!(
                            out,
                            "\n=== Page {} FAILED ({pms}ms): {url} ===\nerror={err}",
                            i + 1
                        );
                    }
                }
            }
        }
        "closeTab" => {
            let tid = data.get("tabId").and_then(|v| v.as_i64()).unwrap_or(-1);
            let _ = writeln!(out, "closed tab={tid}{ms}");
        }
        _ => {
            // openTab, navigate, snapshot, act
            if let Some(tid) = data.get("tabId").and_then(|v| v.as_i64()) {
                let _ = write!(out, "browser:{action} tab={tid}");
                if let Some(title) = data.get("groupTitle").and_then(|v| v.as_str()) {
                    let _ = write!(out, " group={}", quote(title));
                }
                if let Some(steps) = data.get("steps").and_then(|v| v.as_array()) {
                    let _ = write!(out, " steps={}", steps.len());
                }
                let _ = writeln!(out, "{ms}");
            }
            if let Some(snap) = data.get("snapshot") {
                format_browser_snapshot(snap, &mut out);
            } else {
                let url = data.get("url").and_then(|v| v.as_str()).unwrap_or("");
                let title = data.get("title").and_then(|v| v.as_str()).unwrap_or("");
                if !url.is_empty() || !title.is_empty() {
                    let _ = writeln!(out, "{} url={url}", quote(title));
                }
            }
        }
    }
    out
}

fn format_browser_snapshot(snap: &serde_json::Value, out: &mut String) {
    let tid = snap.get("tabId").and_then(|v| v.as_i64()).unwrap_or(-1);
    let sid = snap
        .get("snapshotId")
        .and_then(|v| v.as_str())
        .unwrap_or("-");
    let url = snap.get("url").and_then(|v| v.as_str()).unwrap_or("");
    let title = snap.get("title").and_then(|v| v.as_str()).unwrap_or("");
    let els = snap.get("elements").and_then(|v| v.as_array());
    let count = els.map(|a| a.len()).unwrap_or(0);
    let trunc = if snap.get("truncated").and_then(|v| v.as_bool()) == Some(true) {
        " truncated"
    } else {
        ""
    };
    let _ = writeln!(
        out,
        "tab={tid} snap={sid} els={count}{trunc} {} url={url}",
        quote(title)
    );
    if let Some(els) = els {
        for el in els {
            let r = el.get("ref").and_then(|v| v.as_str()).unwrap_or("-");
            let role = el.get("role").and_then(|v| v.as_str()).unwrap_or("el");
            let lbl = el.get("label").and_then(|v| v.as_str()).unwrap_or("");
            let _ = write!(out, "[{r}] {role}");
            if !lbl.is_empty() {
                let _ = write!(out, " {}", quote(lbl));
            }
            if let Some(val) = el.get("value").and_then(|v| v.as_str())
                && !val.is_empty()
                && val != lbl
            {
                let _ = write!(out, " val={}", quote(val));
            }
            if let Some(href) = el.get("href").and_then(|v| v.as_str()) {
                let _ = write!(out, " href={href}");
            }
            if el.get("disabled").and_then(|v| v.as_bool()) == Some(true) {
                out.push_str(" disabled");
            }
            if let Some(checked) = el.get("checked").and_then(|v| v.as_bool()) {
                let _ = write!(out, " checked={checked}");
            }
            if let Some(exp) = el.get("expanded").and_then(|v| v.as_bool()) {
                let _ = write!(out, " expanded={exp}");
            }
            if el.get("inViewport").and_then(|v| v.as_bool()) == Some(false) {
                out.push_str(" offscreen");
            }
            out.push('\n');
        }
    }
    if let Some(text) = snap.get("text").and_then(|v| v.as_str())
        && !text.is_empty()
    {
        out.push_str("--- pageText ---\n");
        out.push_str(text);
        out.push('\n');
    }
}
