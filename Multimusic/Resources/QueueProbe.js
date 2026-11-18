(() => {
  "use strict";
  if (window.top !== window) return;
  let enabled = false, send = null, timer = null, capture = 0, signature = "";
  const delayed = new Set();
  // Diagnostic fingerprints only; raw source IDs and text never cross the bridge.
  const hash = value => {
    if (!value) return "none";
    let result = 2166136261;
    for (const c of String(value)) result = Math.imul(result ^ c.charCodeAt(0), 16777619);
    return (result >>> 0).toString(16).padStart(8, "0");
  };
  function query(selector, root = document) {
    const result = [...root.querySelectorAll(selector)];
    for (const node of root.querySelectorAll("*")) if (node.shadowRoot) result.push(...query(selector, node.shadowRoot));
    return result;
  }
  const visible = node => node.getClientRects().length > 0;
  function identity(row) {
    const href = row.querySelector('a[href*="watch?"],a[href*="/track/"]')?.getAttribute("href");
    if (href) {
      try { const url = new URL(href, location.href); return url.searchParams.get("v") || url.pathname; } catch {}
    }
    for (const image of row.querySelectorAll("img")) {
      try {
        const url = new URL(image.currentSrc || image.getAttribute("src"), location.href);
        const id = url.origin === "https://i.ytimg.com" && url.pathname.match(/^\/vi\/([\w-]{11})\/hqdefault\.jpg$/)?.[1];
        if (id) return id;
      } catch {}
    }
    return row.getAttribute("video-id") || row.getAttribute("data-video-id") || "";
  }
  function sample(kind) {
    if (!enabled || !send) return;
    try {
      const rows = query("ytmusic-player-queue-item").filter(visible);
      const ids = rows.map(row => hash(identity(row)));
      const selected = rows.findIndex(row => row.hasAttribute("selected") || row.hasAttribute("playing") || row.getAttribute("aria-selected") === "true");
      const video = query("video")[0];
      const url = new URL(location.href);
      const fields = { qpKind: kind, qpCapture: String(capture), qpRows: String(rows.length), qpHash: hash(ids.join(",")),
        qpSelected: String(selected), qpSelectedID: ids[selected] || "none", qpV: hash(url.searchParams.get("v")),
        qpList: hash(url.searchParams.get("list")), qpPaused: video ? String(video.paused) : "none",
        qpTime: video && Number.isFinite(video.currentTime) ? String(Math.round(video.currentTime * 1000)) : "-1",
        qpRendered: String(query('ytmusic-responsive-list-item-renderer,ytmusic-two-row-item-renderer,[data-testid="track-row"]').filter(visible).length) };
      send(fields);
      const next = ids.join(",") + ":" + selected;
      if (next !== signature || kind === "capture" || kind === "plus1" || kind === "plus10") {
        signature = next;
        ids.forEach((id, index) => send({ qpKind: "row", qpCapture: String(capture), qpRow: String(index), qpRowID: id, qpHash: fields.qpHash }));
      }
    } catch { send({ qpKind: "readError", qpCapture: String(capture) }); }
  }
  function onClick(event) {
    if (!enabled) return;
    const path = event.composedPath();
    const button = path.find(node => node?.matches?.('button,[role="button"],ytmusic-play-button-renderer'));
    const header = path.some(node => node?.matches?.('ytmusic-detail-header-renderer,ytmusic-responsive-header-renderer,ytmusic-immersive-header-renderer,[data-testid="playlist-page"]'));
    const queue = path.some(node => node?.matches?.("ytmusic-player-queue-item"));
    const label = button?.getAttribute("aria-label") || button?.textContent || "";
    const action = header && /shuffle/i.test(label) ? "headerShuffle" : header && /play/i.test(label) ? "headerPlay" : queue ? "queueTap" : null;
    if (action) sample(action);
  }
  window.addEventListener("click", onClick, { capture: true, passive: true });
  window.addEventListener("touchend", onClick, { capture: true, passive: true });
  window.MultimusicQueueProbe = {
    configure(value, callback) {
      send = callback;
      if (enabled === value) return;
      enabled = value;
      if (timer !== null) clearInterval(timer);
      for (const id of delayed) clearTimeout(id);
      delayed.clear(); signature = "";
      timer = enabled ? setInterval(() => sample("poll"), 1000) : null;
      if (enabled) sample("enabled");
    },
    capture() {
      if (!enabled) return;
      capture++; sample("capture");
      const generation = capture;
      for (const [delay, kind] of [[1000, "plus1"], [10000, "plus10"]]) {
        const id = setTimeout(() => { delayed.delete(id); if (enabled && capture === generation) sample(kind); }, delay);
        delayed.add(id);
      }
    }
  };
})();
