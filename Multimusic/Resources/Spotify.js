(() => {
  "use strict";
  if (window.top !== window || location.protocol !== "https:" || location.hostname !== "open.spotify.com") return;
  const ROW = '[data-testid="track-row"][role="group"]';
  const PLAY = 'button[data-testid="play-button"][aria-label="Play"]';
  let token = null, sequence = 0, revision = -1, lastDelivery = null, requestTimer = null, touch = null;
  let diagnosticsEnabled = false, diagnosticsTimer = null, diagnosticsRevision = 0, measuringTask = false, metrics = {};
  const requests = new Map();
  const now = () => typeof performance === "object" ? performance.now() : Date.now();
  const text = node => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const visible = node => !!node && !node.hidden && node.getClientRects().length > 0;
  const requestID = () => typeof crypto === "object" && crypto.randomUUID ? crypto.randomUUID().replaceAll("-", "") :
    Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  const send = payload => {
    if (payload.type === "selection") window.MultimusicQueueProbe?.capture();
    if (!token) return false;
    try {
      window.webkit.messageHandlers.multimusic.postMessage({ ...payload, provider: "spotify", token, sequence: ++sequence });
      return true;
    } catch { return false; }
  };
  const status = value => send({ type: "status", status: value });
  const stop = event => { event.preventDefault(); event.stopImmediatePropagation(); };
  const count = name => { if (diagnosticsEnabled) metrics[name] = (metrics[name] || 0) + 1; };
  const measure = callback => (...args) => {
    if (!diagnosticsEnabled || measuringTask) return callback(...args);
    const started = now(), generation = diagnosticsRevision;
    measuringTask = true;
    try { return callback(...args); }
    finally {
      measuringTask = false;
      if (diagnosticsEnabled && generation === diagnosticsRevision) {
        const elapsed = Math.max(0, now() - started);
        if (Number.isFinite(elapsed)) {
          metrics.adapterTaskMaxMs = Math.max(metrics.adapterTaskMaxMs || 0, elapsed);
          if (elapsed > 50) count("adapterOver50Count");
        }
      }
    }
  };
  function flushDiagnostics() {
    if (!diagnosticsEnabled || !token) return;
    // This adapter validates snapshots but never paints, so it emits no render samples.
    const fields = { adapterTaskMaxMs: 0, adapterOver50Count: 0, rowsScanned: 0, progressRowsScanned: 0, ...metrics };
    const output = Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, String(Math.round(value * 1000) / 1000)]));
    if (send({ type: "diagnostic", event: "web.aggregate", fields: output })) metrics = {};
  }
  function setDiagnostics(enabled) {
    window.MultimusicQueueProbe?.configure(enabled, fields => send({ type: "diagnostic", event: "web.queueProbe", fields }));
    if (diagnosticsEnabled === enabled) return;
    diagnosticsEnabled = enabled; diagnosticsRevision++; metrics = {};
    if (diagnosticsTimer !== null) clearInterval(diagnosticsTimer);
    diagnosticsTimer = enabled ? setInterval(measure(flushDiagnostics), 1000) : null;
  }
  function publicID(value, kind) {
    try {
      const url = new URL(typeof value === "string" ? value : value?.getAttribute("href"), "https://open.spotify.com/");
      return url.origin === "https://open.spotify.com" && !url.username && !url.password
        ? url.pathname.match(new RegExp(`^/(?:intl-[a-z]{2}/)?${kind}/([A-Za-z0-9]{22})/?$`, "i"))?.[1] || null : null;
    } catch { return null; }
  }

  function artistFrom(scope) {
    const artists = [...scope.querySelectorAll('a[href*="/artist/"]')].filter(node => visible(node) && publicID(node, "artist"));
    const artist = [...new Set(artists.map(text).filter(Boolean))].join(" & ");
    return artist && artist.length <= 500 ? artist : null;
  }

  function metadata(scope) {
    const artist = artistFrom(scope);
    if (!artist) return null;
    const nodes = [...scope.querySelectorAll("*")].filter(visible);
    const durationCells = [...scope.querySelectorAll('[data-testid="tracklist-row-duration"],[data-testid="duration"],[aria-colindex="5"]')]
      .filter(node => !node.closest("[hidden]"));
    const clocks = [...new Set([...nodes.filter(node => !node.children.length), ...durationCells].map(text)
      .filter(value => /^(?:\d{1,2}:[0-5]\d|\d{1,3}):[0-5]\d$/.test(value)))];
    const labels = [...new Set(nodes.flatMap(node => [node.getAttribute("aria-label"), node.getAttribute("title")])
      .flatMap(value => /^(Explicit|Explicit content|Contains explicit content)$/i.test(value || "") ? [true] :
        /^(Clean|Clean version)$/i.test(value || "") ? [false] : []))];
    if (clocks.length > 1 || labels.length > 1) return null;
    const duration = clocks[0]?.split(":").reduce((total, value) => total * 60 + Number(value), 0);
    if (duration !== undefined && !(duration > 0 && duration <= 86400)) return null;
    return { artist, ...(duration === undefined ? {} : { duration }), ...(labels.length ? { isExplicit: labels[0] } : {}) };
  }

  function trackFromRow(row) {
    count("rowsScanned");
    const links = [...row.querySelectorAll('a[href*="/track/"]')].filter(node => visible(node) && publicID(node, "track"));
    const ids = new Set(links.map(node => publicID(node, "track")));
    const titles = [...new Set(links.map(text).filter(Boolean))];
    const details = metadata(row);
    if (ids.size !== 1 || titles.length !== 1 || titles[0].length > 500 || !details) return null;
    return { id: [...ids][0], title: titles[0], ...details };
  }

  function renderedEntity(play) {
    const entityPlay = play.closest('[data-testid="entity-play-button"]');
    if (!entityPlay) return null;
    for (let header = entityPlay.parentElement, depth = 0; header && header !== document.body && depth < 10; header = header.parentElement, depth++) {
      const headings = [...header.querySelectorAll("h1")].filter(visible);
      if (headings.length > 1) return null;
      if (!headings.length) continue;
      // The proved mobile entity has one header and its row list as siblings; never widen past that parent.
      const scope = header.parentElement;
      if (!scope || scope === document.body || [...header.querySelectorAll(ROW)].some(visible) ||
          [...scope.querySelectorAll("h1")].filter(visible).length !== 1) return null;
      const rows = [...scope.querySelectorAll(ROW)].filter(visible);
      if (!rows.length) return null;
      const plays = [...scope.querySelectorAll(PLAY)].filter(node => visible(node) && !node.closest(ROW));
      const entities = [...scope.querySelectorAll('[data-testid="entity-play-button"]')].filter(node => visible(node) && !node.closest(ROW));
      if (plays.length !== 1 || plays[0] !== play || entities.length !== 1 || entities[0] !== entityPlay) return null;
      const headerText = [...header.querySelectorAll("*")].filter(node => visible(node) && !node.children.length).map(text).join(" ");
      const counts = [...headerText.matchAll(/\b([\d,]+)\s+(?:songs|tracks)\b/gi)]
        .map(match => Number(match[1].replace(/[, ]/g, ""))).filter(value => Number.isSafeInteger(value) && value > 0 && value <= 1000000);
      return { heading: headings[0], rows: rows.slice(0, 50), capped: rows.length > 50,
        declaredCount: [...new Set(counts)].length === 1 ? counts[0] : null };
    }
    return null;
  }

  function capture(play) {
    if (play.closest(ROW)) return null;
    const detail = play.closest('[data-testid="track-view"]');
    const id = publicID(location.href, "track");
    if (detail && id) {
      const headings = [...detail.querySelectorAll("h1")].filter(visible);
      if (headings.length !== 1) return null;
      const header = headings[0].parentElement;
      const plays = [...header.querySelectorAll(PLAY)].filter(visible);
      if (plays.length !== 1 || plays[0] !== play) return null;
      const title = text(headings[0]);
      const details = metadata(header);
      if (!title || title.length > 500 || !details) return null;
      return { tracks: [{ id, title, ...details }], omitted: 0,
        context: { provider: "spotify", kind: "watch", selectedSourceID: id } };
    }
    const albumID = publicID(location.href, "album");
    const collectionID = albumID || publicID(location.href, "playlist");
    const entity = renderedEntity(play);
    if (!collectionID || !entity) return null;
    const { rows, heading } = entity;
    const first = trackFromRow(rows[0]);
    if (!first) return null;
    const context = { provider: "spotify", kind: albumID ? "album" : "playlist", collectionID,
      selectedSourceID: first.id, selectedOrdinal: 0 };
    if (albumID) {
      const title = text(heading), artist = artistFrom(heading.parentElement);
      if (!title || title.length > 500 || !artist) return null;
      Object.assign(context, { title, artist });
    }
    const tracks = [first];
    let omitted = 0;
    for (const row of rows.slice(1)) {
      const track = trackFromRow(row);
      if (track) tracks.push(track); else omitted++;
    }
    return { tracks, omitted, context, capped: entity.capped || (rows.length === 50 && entity.declaredCount > 50),
      ...(entity.declaredCount ? { declaredCount: entity.declaredCount } : {}) };
  }

  function retryRequests() {
    for (const [id, request] of requests) {
      if (now() - request.started > 45000) {
        requests.delete(id); status("controlTimedOut"); send({ type: "resync" });
      } else if (request.attempts < 3 && now() - request.sent >= (request.accepted ? 1500 : 700)) {
        request.sent = now(); request.attempts++; send(request.payload);
      }
    }
    if (!requests.size && requestTimer !== null) { clearInterval(requestTimer); requestTimer = null; }
  }

  function navigateSong(event, target) {
    if (!target || target.closest('a,button,input,textarea,[contenteditable="true"],[role="button"],[role="menuitem"]')) return;
    const trackRow = target.closest('[data-encore-id="listRow"][role="group"]');
    const links = trackRow && visible(trackRow) ? [...trackRow.querySelectorAll('a[href*="/track/"]')].filter(visible) : [];
    if (links.length) {
      stop(event);
      const ids = links.map(link => publicID(link, "track"));
      if (ids.some(id => !id) || new Set(ids).size !== 1) { status("unreadable"); return; }
      // The mobile row body otherwise promotes the app even when its title has a working public link.
      location.assign(`https://open.spotify.com/track/${ids[0]}`);
      return;
    }
    if (!target.closest('[data-testid="search-page"]')) return;
    const row = target.closest('[role="group"][aria-labelledby]');
    if (!visible(row) || ![...row.querySelectorAll('[data-encore-id="text"]')].some(node =>
      visible(node) && !node.children.length && /^Song [•·] \S/.test(text(node)))) return;
    stop(event);
    const association = row.getAttribute("aria-labelledby");
    const id = association?.match(/^listrow-title-([A-Za-z0-9]{22})$/)?.[1];
    const label = id && document.getElementById(association);
    if (!visible(label) || label.closest('[role="group"]') !== row ||
        !text(label) || text(label).length > 500 || text(label) !== row.getAttribute("aria-label")) {
      status("unreadable"); return;
    }
    // Mobile Search otherwise sends this song gesture to an app-promotion reload.
    location.assign(`https://open.spotify.com/track/${id}`);
  }

  function activateSelection(event) {
    if (!event.isTrusted || !token || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
        (event.type === "keydown" && !["Enter", " "].includes(event.key))) return;
    const target = event.composedPath().find(node => node instanceof Element);
    const play = target?.closest(PLAY);
    if (!play || !visible(play)) { navigateSong(event, target); return; }
    stop(event);
    const selection = capture(play);
    if (!selection) { status("unreadable"); return; }
    if (requests.size >= 32) { status("controlTimedOut"); return; }
    const commandId = requestID();
    const request = { payload: { type: "selection", commandId, ...selection }, started: now(), sent: now(), attempts: 1 };
    requests.set(commandId, request);
    send(request.payload);
    if (requestTimer === null) requestTimer = setInterval(measure(retryRequests), 500);
  }

  function touchActivation(event) {
    if (!event.isTrusted) return;
    if (event.type === "touchcancel") { touch = null; return; }
    if (event.type === "touchstart") {
      const point = event.touches.length === 1 ? event.touches[0] : null;
      touch = point ? { id: point.identifier, x: point.clientX, y: point.clientY, moved: false, url: location.href } : null;
      return;
    }
    const point = [...event.changedTouches].find(point => point.identifier === touch?.id);
    if (!touch || !point) return;
    touch.moved ||= Math.hypot(point.clientX - touch.x, point.clientY - touch.y) > 12;
    if (event.type === "touchend") {
      const activate = !touch.moved && event.touches.length === 0 && touch.url === location.href;
      touch = null;
      if (activate) activateSelection(event);
    }
  }

  function applySnapshot(snapshot) {
    const rowsBefore = metrics.rowsScanned || 0;
    try {
      if (!token || !snapshot || (snapshot.sourceProvider !== undefined && snapshot.sourceProvider !== "spotify") ||
          typeof snapshot.title !== "string" || typeof snapshot.artist !== "string" ||
          typeof snapshot.synchronized !== "boolean" || !Number.isFinite(snapshot.position) ||
          !Number.isFinite(snapshot.duration) || snapshot.duration < 0 || snapshot.duration > 86400 ||
          (snapshot.sourceID != null && (typeof snapshot.sourceID !== "string" || snapshot.sourceID.length !== 22 || !/^[A-Za-z0-9]{22}$/.test(snapshot.sourceID))) ||
          (snapshot.revision !== undefined && (!Number.isSafeInteger(snapshot.revision) || snapshot.revision < revision)) ||
          (snapshot.deliveryId !== undefined && (!Number.isSafeInteger(snapshot.deliveryId) || snapshot.deliveryId < 0 || snapshot.deliveryId < (lastDelivery ?? 0)))) {
        return { accepted: false };
      }
      revision = snapshot.revision ?? revision;
      setDiagnostics(snapshot.diagnosticsEnabled === true);
      if (snapshot.deliveryId !== undefined && snapshot.deliveryId !== lastDelivery) {
        if (!send({ type: "snapshotAck", deliveryId: snapshot.deliveryId })) return { accepted: false };
        lastDelivery = snapshot.deliveryId;
      }
      return { accepted: true, deliveryId: snapshot.deliveryId ?? null };
    } finally {
      if (diagnosticsEnabled) metrics.progressRowsScanned = (metrics.progressRowsScanned || 0) +
        Math.max(0, (metrics.rowsScanned || 0) - rowsBefore);
    }
  }
  function retire() {
    setDiagnostics(false);
    token = null; revision = -1; lastDelivery = null; touch = null; requests.clear();
    if (requestTimer !== null) clearInterval(requestTimer);
    requestTimer = null;
  }

  window.Multimusic = Object.freeze({
    activate: measure((value, snapshot) => {
      if (typeof value !== "string" || !value.length || value.length > 100) return false;
      if (token !== value) { retire(); sequence = 0; }
      token = value;
      if (!applySnapshot(snapshot).accepted) { token = null; return false; }
      status("ready");
      return true;
    }),
    applySnapshot: measure(applySnapshot),
    receiveAck: measure(ack => {
      if (!token || ack?.token !== token || !requests.has(ack.commandId)) return false;
      const request = requests.get(ack.commandId);
      if (["accepted", "pending"].includes(ack.status)) request.accepted = true;
      else if (["completed", "rejected"].includes(ack.status)) {
        if (ack.snapshot) applySnapshot(ack.snapshot);
        const latest = [...requests.keys()].at(-1) === ack.commandId;
        requests.delete(ack.commandId);
        if (latest && ack.status === "rejected" && ack.reason !== "inactive") status(ack.reason === "noMatch" ? "noMatch" : "choose");
        retryRequests();
      } else return false;
      return true;
    })
  });
  window.addEventListener("click", measure(activateSelection), true);
  window.addEventListener("keydown", measure(activateSelection), true);
  for (const event of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
    window.addEventListener(event, measure(touchActivation), { capture: true, passive: event !== "touchend" });
  }
  window.addEventListener("blur", () => { touch = null; });
  window.addEventListener("pagehide", retire);
})();
