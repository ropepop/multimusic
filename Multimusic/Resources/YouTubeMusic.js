(() => {
  "use strict";
  if (window.top !== window || location.protocol !== "https:" || location.hostname !== "music.youtube.com") return;
  const ROW = "ytmusic-responsive-list-item-renderer, ytmusic-two-row-item-renderer, ytmusic-card-shelf-renderer";
  const PLAYER_ROW = `${ROW},ytmusic-player-queue-item`;
  const PAGE = "ytmusic-browse-response, ytmusic-browse-page, ytmusic-two-column-browse-results-renderer";
  const MAX_TRACKS = 50;
  const PLAYER_ANY = "ytmusic-player-bar,ytmusic-player-page,ytmusic-player";
  const PLAYER = PLAYER_ANY;
  const ARTWORK = "ytmusic-miniplayer img.ytmusicTrackInfoThumbnail,ytmusic-player-bar img.image,ytmusic-player-page ytmusic-player-controls img.image,ytmusic-player #song-image img,ytmusic-player #song-video video.video-stream.html5-main-video";
  const PLAY = '.play-pause-button,#play-pause-button,.ytp-play-button,button[aria-label="Play"],button[aria-label="Pause"],[aria-label="Play" i],[aria-label="Pause" i]';
  const NEXT = '.next-button,#next-button,.ytp-next-button,button[aria-label="Next"],button[aria-label="Next song"],[aria-label^="Next" i]';
  const PREVIOUS = '.previous-button,#previous-button,.ytp-prev-button,button[aria-label="Previous"],button[aria-label="Previous song"],[aria-label^="Previous" i]';
  // The compact/mini bar renders its transport inside open shadow roots and uses
  // element hosts instead of the large-player class names.
  const CONTROL_TAGS = 'ytmusic-play-button-renderer,yt-icon-button,tp-yt-paper-icon-button,button,[role="button"]';
  const PROGRESS = '#progress-bar,.ytp-progress-bar,[role="slider"][aria-label="Seek slider"],#slider';
  const MINI_ROOT = "ytmusic-miniplayer", MINI_PROGRESS = "input.ytMusicMiniPlayerProgressBar", SEEK_INPUT = `${PROGRESS},${MINI_PROGRESS},input[type="range"]`;
  // Narrow layouts replace ytmusic-player-bar with ytmusic-miniplayer hosts (track info + Play/Next).
  const PAINT_ROOT = `${PLAYER},${MINI_ROOT}`;
  const MINI_TITLE = ".ytmusicTrackInfoTitle", MINI_BYLINE = ".ytmusicTrackInfoByline";
  const seekRoot = node => closestDeep(node, `ytmusic-player-bar,${MINI_ROOT}`) || (node.matches(MINI_PROGRESS) ? node : null);
  const TRANSPORT_NODES = `${CONTROL_TAGS},${PROGRESS}`;
  const CURRENT_TIME = ".ytp-time-current,ytmusic-player-controls .current-time";
  const TOTAL_TIME = ".ytp-time-duration,ytmusic-player-controls .total-time";
  const CONTROLS = `.title,.byline,.byline-wrapper,.time-info,${PLAY},${NEXT},${PREVIOUS},${PROGRESS},${CURRENT_TIME},${TOTAL_TIME},.ytp-title-text,${MINI_TITLE},${MINI_BYLINE}`;
  let lastHandledTouch = null, lastSeekAt = null, toggleParity = null;
  let collapseCandidate = null, collapseTimer = null;
  let token = null, sequence = 0, snapshot = null, renderPending = false, drag = null, lastStatus = null, touch = null;
  let roots = [], artwork = [], metadataLabels = [], rootsDirty = true, metadataDirty = true, controlsDirty = true, highlightedID = null, requestTimer = null, lastPaintedDelivery = null;
  const progressViews = new Map();
  const requests = new Map();
  const sourceLinks = new Map();
  const sourceAlbums = new Map(), bylineKinds = new WeakMap(), separatorText = new WeakMap();
  let diagnosticsEnabled = false, diagnosticsTimer = null, gestureStarted = null, renderQueuedAt = null;
  const commandTimings = new Map();
  let latestTiming = null, timingDropped = 0;
  let metrics = {};
  let measuringTask = false;
  const now = () => typeof performance === "object" ? performance.now() : Date.now();
  const count = (name, value = 1) => { if (diagnosticsEnabled) metrics[name] = (metrics[name] || 0) + value; };
  const maximum = (name, value) => { if (diagnosticsEnabled) metrics[name] = Math.max(metrics[name] || 0, value); };
  function measure(callback) {
    return (...args) => {
      if (!diagnosticsEnabled || measuringTask) return callback(...args);
      const started = now();
      measuringTask = true;
      try { return callback(...args); }
      finally {
        measuringTask = false;
        const elapsed = Math.max(0, now() - started);
        maximum("adapterTaskMaxMs", elapsed);
        if (elapsed > 50) count("adapterOver50Count");
      }
    };
  }
  const renderCallback = measure(render);

  const text = node => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const visible = node => !!node && node.checkVisibility({ visibilityProperty: true, opacityProperty: true });
  const setAttribute = (node, name, value) => {
    if (node && node.getAttribute(name) !== String(value)) node.setAttribute(name, String(value));
  };
  const setText = (node, value) => { if (node && node.textContent !== value) node.textContent = value; };
  const anchors = node => node ? [...(node.matches("a") ? [node] : []), ...node.querySelectorAll("a")] : [];

  // Selector helpers that cross open shadow roots. element.closest() and
  // root.querySelectorAll() stop at a shadow boundary, which is exactly where
  // the compact bar hides its play/next/previous hosts.
  function deepQuery(root, selector) {
    if (!root?.querySelectorAll) return [];
    const found = [], seen = new Set();
    const visit = scope => {
      if (!scope?.querySelectorAll) return;
      if (scope.shadowRoot) visit(scope.shadowRoot);
      for (const node of scope.querySelectorAll(selector)) if (!seen.has(node)) { seen.add(node); found.push(node); }
      for (const host of scope.querySelectorAll("*")) if (host.shadowRoot && !seen.has(host.shadowRoot)) {
        seen.add(host.shadowRoot); visit(host.shadowRoot);
      }
    };
    visit(root);
    return found;
  }
  function closestDeep(node, selector, boundary = null) {
    for (let current = node; current && current !== boundary; current = current.parentElement || current.parentNode?.host) {
      if (current instanceof Element && current.matches(selector)) return current;
    }
    return null;
  }
  function labelCommand(label) {
    const value = (label || "").trim().toLowerCase();
    if (/^(?:play|pause)$/.test(value)) return "toggle";
    if (/^next(?: song| track)?$/.test(value)) return "next";
    if (/^(?:previous|prev)(?: song| track)?$/.test(value)) return "previous";
    if (/^(?:seek|scrub)(?: slider)?$/.test(value)) return "seek";
    return null;
  }
  function controlCommand(node) {
    if (!node || volumeSlider(node)) return null;
    const label = labelCommand(node.getAttribute("aria-label") || node.getAttribute("title"));
    if (label) return label;
    if (node.matches(PROGRESS) || node.matches('[role="slider"]')) return "seek";
    if (node.matches(NEXT)) return "next";
    if (node.matches(PREVIOUS)) return "previous";
    if (node.matches(PLAY)) return "toggle";
    // A bare play renderer in the player bar is the transport toggle.
    return node.matches("ytmusic-play-button-renderer") ? "toggle" : null;
  }
  function insideRect(node, event) {
    const rect = node?.getBoundingClientRect?.();
    const point = event.changedTouches?.[0] || event;
    if (!rect || !Number.isFinite(point.clientX) || !Number.isFinite(point.clientY)) return false;
    const left = Number(rect.left) || 0, top = Number(rect.top) || 0;
    const width = Number(rect.width) || 0, height = Number(rect.height) || 0;
    return width > 0 && height > 0 && point.clientX >= left && point.clientX <= left + width &&
      point.clientY >= top && point.clientY <= top + height;
  }

  const playerNodes = (root, selector) => root ? deepQuery(root, selector)
    .filter(node => !closestDeep(node, PLAYER_ROW) && (!root.matches(PLAYER) || closestDeep(node, PLAYER) === root)) : [];
  const metadataNodes = (root, selector) => playerNodes(root, selector).filter(node =>
    root.matches(`ytmusic-player-bar,ytmusic-player,${MINI_ROOT}`) || node.closest("ytmusic-player-controls"));
  // The video surface doubles as the collapsed player's artwork; it carries no labels or visible controls.
  const artworkOnly = root => root.matches("ytmusic-player") && !deepQuery(root, CONTROL_TAGS).some(visible) &&
    !playerNodes(root, CONTROLS).some(visible);
  const rowNodes = (row, selector) => [...row.querySelectorAll(selector)].filter(node => node.closest(PLAYER_ROW) === row);
  const send = payload => {
    if (payload.type === "selection") window.MultimusicQueueProbe?.capture();
    if (diagnosticsEnabled && ["command", "selection"].includes(payload.type) && gestureStarted !== null) {
      count("intents"); maximum("gestureToSendMaxMs", now() - gestureStarted); gestureStarted = null;
    }
    if (token) window.webkit.messageHandlers.multimusic.postMessage({ ...payload, provider: "youtubeMusic", token, sequence: ++sequence });
  };
  const status = value => {
    if (lastStatus !== value) { lastStatus = value; send({ type: "status", status: value }); }
  };
  const stop = event => {
    event.preventDefault(); event.stopImmediatePropagation();
    if (event.type === "touchend") lastHandledTouch = {
      id: event.changedTouches[0]?.identifier, target: eventTarget(event), at: now()
    };
  };
  const eventTarget = event => event.composedPath().find(node => node instanceof Element);
  function playerRootFor(path, event) {
    for (const node of path) {
      const root = closestDeep(node, PLAYER_ANY);
      if (root && visible(root)) return root;
    }
    if (path.some(navigationTarget)) return null;
    // A retained player host can cover the viewport; require a compact transport cluster.
    for (const root of path) {
      const { width, height } = root.getBoundingClientRect();
      if (height > 0 && height <= 120 && width >= 200 && visible(root) && insideRect(root, event) &&
          deepQuery(root, '[aria-label="Play" i],[aria-label="Pause" i],[title="Play" i],[title="Pause" i]').some(visible) &&
          deepQuery(root, NEXT).some(visible)) return root;
    }
    return null;
  }

  const COLLAPSE = /^(back|close|collapse|minimi[sz]e|hide)( player( page)?)?$/i;
  function playerButtonLabel(target) {
    const button = closestDeep(target, "button[aria-label],[role=button][aria-label],yt-icon-button");
    return button?.getAttribute("aria-label") || deepQuery(button, "#button").find(visible)?.getAttribute("aria-label") || "";
  }

  const navigationTarget = node => !closestDeep(node, MINI_PROGRESS) && closestDeep(node, 'a[href],.title,.byline,.byline-wrapper,#song-image,input,textarea,[contenteditable="true"],[role="combobox"]');

  function volumeSlider(node) {
    for (let current = node; current && !current.matches?.(PLAYER_ANY); current = current.parentElement || current.parentNode?.host) {
      if (/volume/i.test(["id", "aria-label", "title"].map(key => current.getAttribute?.(key) || "").join(" "))) return true;
    }
    return false;
  }

  function deepHitStack(event) {
    const point = event.changedTouches?.[0] || event;
    if (!Number.isFinite(point.clientX) || !Number.isFinite(point.clientY)) return [];
    const stack = [], seen = new Set();
    const visit = scope => {
      for (const node of scope.elementsFromPoint?.(point.clientX, point.clientY) || []) {
        if (!(node instanceof Element) || seen.has(node)) continue;
        seen.add(node);
        if (node.shadowRoot) visit(node.shadowRoot);
        stack.push(node);
      }
    };
    visit(document);
    return stack;
  }

  function seekRect(slider) {
    // Preserve the expanded player's existing inner-track geometry.
    if (!seekRoot(slider)) {
      const track = deepQuery(slider, "#sliderBar")[0]?.getBoundingClientRect();
      return track?.width > 0 ? track : slider.getBoundingClientRect();
    }
    return [slider, ...deepQuery(slider, "#sliderBar,#progressContainer")].map(node => node.getBoundingClientRect())
      .filter(rect => rect.width > 0).sort((a, b) => b.width - a.width)[0] || slider.getBoundingClientRect();
  }

  function stackSeek(event, info) {
    if (["row", "volume", "transportOther", "navigation"].includes(info.reason)) return null;
    const point = event.changedTouches?.[0] || event;
    for (const node of deepHitStack(event)) {
      const command = controlCommand(node);
      if (command && command !== "seek") { info.reason = "transportOther"; return null; }
      if (closestDeep(node, PLAYER_ROW)) { info.reason = "row"; return null; }
      if (volumeSlider(node)) { info.reason = "volume"; return null; }
      // Range inputs are navigation targets too, so recognize the slider first.
      if (node.matches(SEEK_INPUT)) {
        info.slider = node;
        if (!seekRoot(node)) { info.reason = "noRoot"; return null; }
        const rect = node.getBoundingClientRect();
        if (!(rect.width >= 0.5 * window.innerWidth)) { info.reason = "narrow"; return null; }
        if (!(rect.height > 0 && rect.height <= 48) || point.clientX < rect.left || point.clientX > rect.left + rect.width ||
            Math.abs(point.clientY - rect.top - rect.height / 2) > 12) { info.reason = "outside"; return null; }
        info.reason = "none";
        return node;
      }
      if (navigationTarget(node)) { info.reason = "navigation"; return null; }
    }
    return null;
  }

  function seekHit(event, info) {
    const path = event.composedPath().filter(node => node instanceof Element);
    info.reason = "none";
    if (path.some(node => closestDeep(node, PLAYER_ROW))) { info.reason = "row"; return null; }
    if (path.some(volumeSlider)) { info.reason = "volume"; return null; }
    const transport = pathControl(event);
    if (transport.command && transport.command !== "seek") { info.reason = "transportOther"; return null; }
    for (const node of path) {
      const slider = closestDeep(node, SEEK_INPUT);
      if (!slider) continue;
      info.slider = slider;
      if (visible(slider) && (closestDeep(slider, PLAYER_ANY) || seekRoot(slider))) return slider;
      info.reason = visible(slider) ? "noRoot" : "notVisible";
    }
    if (transport.command === "seek") {
      info.slider = transport.control;
      if (visible(transport.control)) return transport.control;
      info.reason = "notVisible";
    }
    const root = path.map(node => closestDeep(node, PLAYER_ANY)).find(Boolean);
    if (!root) { info.reason = path.some(navigationTarget) ? "navigation" : info.reason === "none" ? "noRoot" : info.reason; return null; }
    const point = event.changedTouches?.[0] || event;
    const slider = deepQuery(root, PROGRESS).find(slider => {
      if (closestDeep(slider, PLAYER_ROW) || volumeSlider(slider)) return false;
      info.slider = slider;
      if (!visible(slider)) { info.reason = "notVisible"; return false; }
      const { left, top, width, height } = slider.getBoundingClientRect();
      if (width < 120) { info.reason = "narrow"; return false; }
      const inside = height > 0 && point.clientX >= left && point.clientX <= left + width &&
        Math.abs(point.clientY - top - height / 2) <= Math.max(12, height / 2);
      if (!inside) info.reason = "outside";
      return inside;
    }) || null;
    if (slider) info.reason = "none";
    else if (path.some(navigationTarget) && !info.slider) info.reason = "navigation";
    return slider;
  }

  function reportBottomHit(event) {
    const point = event.changedTouches?.[0] || event;
    if (!token || !Number.isFinite(point.clientX) || !(point.clientY >= window.innerHeight - 160)) return;
    const info = {};
    const slider = seekHit(event, info) || stackSeek(event, info);
    const rect = (slider || info.slider) && seekRect(slider || info.slider);
    const fields = { hitX: String(point.clientX), hitY: String(point.clientY), seekMissReason: slider ? "none" : info.reason,
      seekResolved: String(!!slider), sliderVis: String(visible(slider || info.slider)) };
    const stack = deepHitStack(event);
    for (let index = 0; index < 5; index++) {
      const node = stack[index];
      if (!node) { fields[`hitStack${index}`] = "none"; continue; }
      const tag = String(node.tagName).toLowerCase();
      const identifier = value => (value || "").replace(/[^a-zA-Z0-9_-]/g, "");
      const id = identifier(node.id), classes = (node.getAttribute("class") || "").split(/\s+/).map(identifier).filter(Boolean);
      const role = identifier(node.getAttribute("role"));
      const box = node.getBoundingClientRect();
      const host = String(node.getRootNode()?.host?.tagName || "none").toLowerCase().slice(0, 24);
      const suffix = `@${[box.left, box.top, box.width, box.height].map(value => Math.round(value || 0)).join(",")}^${host}`;
      const parts = [tag, ...(id ? ["#" + id] : []), ...classes.map(value => "." + value), ...(role ? ["[" + role + "]"] : [])];
      while (parts.length > 1 && parts.join("").length + suffix.length > 64) parts.pop();
      fields[`hitStack${index}`] = parts.join("").slice(0, Math.max(1, 64 - suffix.length)) + suffix;
    }
    for (const [key, value] of Object.entries({ X: rect?.left, Y: rect?.top, Width: rect?.width, Height: rect?.height }))
      fields["seekRect" + key] = String(Number.isFinite(value) ? value : 0);
    send({ type: "diagnostic", event: "web.aggregate", fields });
  }

  function clearCollapse() {
    if (collapseTimer !== null) clearInterval(collapseTimer);
    collapseCandidate = null; collapseTimer = null;
  }

  function watchCollapse(root, event) {
    const rect = root.getBoundingClientRect();
    if (!(rect.height > 120) || !visible(root)) return;
    const path = event.composedPath().filter(node => node instanceof Element);
    let labelled = false;
    for (const node of path) {
      for (let current = node; current; current = current.parentElement || current.parentNode?.host) {
        labelled ||= ["aria-label", "title"].some(key => COLLAPSE.test(current.getAttribute?.(key) || ""));
        if (current === root) break;
      }
      if (node === root) break;
    }
    const point = event.changedTouches?.[0] || event;
    const arrow = path.some(node => closestDeep(node, "yt-icon-button,tp-yt-paper-icon-button", root)) &&
      insideRect(root, event) && point.clientY <= rect.top + 96 && point.clientX <= rect.left + rect.width / 2;
    if (!labelled && !arrow || collapseCandidate?.root === root) return;
    clearCollapse();
    collapseCandidate = { root, at: now() };
    collapseTimer = setInterval(() => {
      if (now() - collapseCandidate.at > 1200) { clearCollapse(); return; }
      if (!root.isConnected || !visible(root) || root.getBoundingClientRect().height <= 120) {
        clearCollapse();
        send({ type: "diagnostic", event: "web.aggregate", fields: { collapsePath: "arrow" } });
      }
    }, 50);
  }

  function geometricControl(root, event) {
    if (!(root.getBoundingClientRect().height <= 120) || !visible(root) || !insideRect(root, event)) return null;
    const point = event.changedTouches?.[0] || event;
    let nearest = null;
    for (const node of playerNodes(root, `${TRANSPORT_NODES},${PLAY},${NEXT},${PREVIOUS}`)) {
      if (!visible(node)) continue;
      const command = controlCommand(node);
      if (!command) continue;
      const rect = node.getBoundingClientRect(), bar = root.getBoundingClientRect();
      const { left, top, width, height } = rect;
      if (!(width > 0 && height > 0) || left < bar.left || top < bar.top ||
          left + width > bar.left + bar.width || top + height > bar.top + bar.height) continue;
      const edge = Math.hypot(Math.max(0, left - point.clientX, point.clientX - left - width),
        Math.max(0, top - point.clientY, point.clientY - top - height));
      const distance = Math.hypot(point.clientX - left - width / 2, point.clientY - top - height / 2);
      if (edge > 6 || distance > 28) continue;
      const specific = node.matches(`${PROGRESS},.next-button,#next-button,.ytp-next-button,.previous-button,#previous-button,.ytp-prev-button,.play-pause-button,#play-pause-button,.ytp-play-button`);
      if (!nearest || specific > nearest.specific || specific === nearest.specific && distance < nearest.distance)
        nearest = { control: node, command, specific, distance };
    }
    return nearest;
  }

  function pathControl(event) {
    const path = event.composedPath().filter(node => node instanceof Element);
    const root = playerRootFor(path, event);
    if (!root || path.some(node => closestDeep(node, PLAYER_ROW)) || path.some(volumeSlider) || path.some(navigationTarget)) return { root };
    if (!path.includes(root) && !path.some(node => closestDeep(node, PLAYER_ANY) === root)) {
      const geometric = geometricControl(root, event);
      return { root, ...(geometric || {}) };
    }
    for (const node of path) {
      if (node === root) break;
      for (const [selector, command] of [[PROGRESS, "seek"], [NEXT, "next"], [PREVIOUS, "previous"], [PLAY, "toggle"]]) {
        const control = closestDeep(node, selector, root);
        if (control && !volumeSlider(control)) return { root, control, command };
      }
    }
    for (const node of path) {
      if (node === root) break;
      const control = closestDeep(node, CONTROL_TAGS, root);
      const command = controlCommand(control);
      if (command) return { root, control, command };
    }
    const geometric = geometricControl(root, event);
    return geometric ? { root, control: geometric.control, command: geometric.command } : { root };
  }

  function expandPlayer(root, path) {
    send({ type: "diagnostic", event: "web.aggregate", fields: { expandPath: path } });
    const control = playerNodes(root, '[aria-label="Expand player"]').find(visible);
    if (!control) return false;
    control.click();
    return true;
  }

  function reportUnmappedMiniTap(event, info = {}) {
    count("miniTapUnmapped");
    const tags = [...new Set(event.composedPath().filter(node => node instanceof Element)
      .map(node => String(node.tagName || "").toLowerCase()).filter(tag => /^[a-z][a-z0-9-]*$/.test(tag)))].slice(0, 8);
    while (tags.join(",").length > 64) tags.pop();
    send({ type: "diagnostic", event: "web.aggregate", fields: {
      miniTapUnmapped: "1", seekMissReason: info.reason || "none", ...(tags.length ? { composedPathTags: tags.join(",") } : {})
    } });
  }

  const requestID = () => typeof crypto === "object" && crypto.randomUUID ? crypto.randomUUID().replaceAll("-", "") :
    Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  const playIcon = (playing, large) => large ? playing ?
    "M12 10h4v16h-4zM20 10h4v16h-4z" : "M12 10v16l14-8z" : playing ?
    "M7 3a1 1 0 0 0-1 1v16a1 1 0 0 0 2 0V4a1 1 0 0 0-1-1Zm10 0a1 1 0 0 0-1 1v16a1 1 0 0 0 2 0V4a1 1 0 0 0-1-1Z" :
    "M5 4.623V19.38a1.5 1.5 0 002.26 1.29L22 12 7.26 3.33A1.5 1.5 0 005 4.623Z";

  const displayedState = () => toggleParity === null ? snapshot?.state : toggleParity ? "playing" : "paused";

  function timingControl(state) {
    if (document.visibilityState === "hidden") return null;
    for (const root of roots.filter(visible)) for (const play of playerNodes(root, PLAY).filter(visible)) {
      const button = play.querySelector("button") || play;
      const label = state === "playing" ? "Pause" : "Play";
      if (play.getAttribute("title") === label && button.getAttribute("aria-label") === label &&
          play.querySelector("path")?.getAttribute("d") === playIcon(state === "playing", play.matches(".ytp-play-button"))) return { root, button };
    }
    return null;
  }

  function settleTiming(timing, outcome) {
    timing.outcome = outcome; timing.ready = true;
  }

  function startTiming(commandId, payload) {
    if (!diagnosticsEnabled || gestureStarted === null) return;
    const previous = commandTimings.get(latestTiming);
    if (previous && !previous.ready) settleTiming(previous, 4);
    if (gestureStarted > 604800000) { timingDropped++; latestTiming = null; return; }
    if (commandTimings.size >= 128) { commandTimings.delete(commandTimings.keys().next().value); timingDropped++; }
    commandTimings.set(commandId, { started: gestureStarted, command: payload.command, position: payload.position,
      initialLabel: timingControl(displayedState())?.button.getAttribute("aria-label") });
    latestTiming = commandId;
  }

  function matchesTimingSnapshot(value, expected, timing) {
    return value && expected && ["sourceID", "title", "artist", "duration", "state", "synchronized"].every(key => value[key] === expected[key]) &&
      (timing?.command === "seek" ? [value, expected].every(item =>
        Math.abs(item.position - Math.min(timing.position, Math.max(0, item.duration - 0.25))) < 1.5) : Math.abs(value.position - expected.position) <= 2);
  }

  function matchesTimingControl(timing, value, control) {
    return control && value.synchronized && ["playing", "paused", "stopped"].includes(value.state) && (timing.command !== "play" || value.state === "playing") &&
      (timing.command !== "pause" || value.state === "paused") && displayedState() === value.state &&
      metadataNodes(control.root, ".ytp-title-text,.title").some(node => text(node) === (value.title || "Choose a song")) &&
      (timing.command !== "seek" || playerNodes(control.root, PROGRESS).some(node => visible(node) && Number(node.getAttribute("aria-valuenow")) === value.position));
  }

  function captureTimingFrame() {
    if (!diagnosticsEnabled) return;
    const timing = commandTimings.get(latestTiming);
    if (!timing || timing.ready || timing.framePending) return;
    const id = latestTiming, documentToken = token, painted = snapshot;
    const control = timingControl(displayedState());
    const label = timing.command === "play" ? "Pause" : timing.command === "pause" ? "Play" : null;
    const feedback = label && timing.initialLabel && timing.initialLabel !== label && control?.button.getAttribute("aria-label") === label && timing.feedback === undefined;
    const completed = timing.native && matchesTimingSnapshot(painted, timing.native, timing) && matchesTimingControl(timing, painted, control);
    if (document.visibilityState === "hidden" || (timing.native && !completed)) { settleTiming(timing, 5); return; }
    if (!feedback && !completed) return;
    timing.framePending = true;
    // A following animation frame is a paint opportunity, not proof of compositor or physical display latency.
    requestAnimationFrame(measure(() => {
      timing.framePending = false;
      if (!diagnosticsEnabled || token !== documentToken || latestTiming !== id || commandTimings.get(id) !== timing || timing.ready) return;
      const current = timingControl(displayedState());
      if (!current || !control.root.isConnected || current.button !== control.button) {
        settleTiming(timing, 5); return;
      }
      if (!matchesTimingSnapshot(snapshot, painted, timing)) {
        if (timing.native && !matchesTimingSnapshot(snapshot, timing.native, timing)) settleTiming(timing, 5);
        else captureTimingFrame();
        return;
      }
      const elapsed = Math.max(0, now() - timing.started);
      if (elapsed > 60000) { settleTiming(timing, 5); return; }
      if (feedback && current.button.getAttribute("aria-label") === label) timing.feedback = elapsed;
      if (completed && matchesTimingSnapshot(snapshot, timing.native, timing) && matchesTimingControl(timing, snapshot, current)) {
        timing.completed = elapsed; settleTiming(timing, 1);
      } else if (completed) settleTiming(timing, 5);
    }));
  }

  function submit(payload) {
    if (requests.size >= 32) { status("controlTimedOut"); return false; }
    const commandId = requestID();
    startTiming(commandId, payload);
    requests.set(commandId, { payload: { ...payload, commandId }, sent: now(), started: now(), attempts: 1 });
    if (["play", "pause"].includes(payload.command)) toggleParity = payload.command === "play";
    else if (payload.type === "selection") toggleParity = null;
    send(requests.get(commandId).payload);
    if (requestTimer === null) requestTimer = setInterval(measure(retryRequests), 500);
    metadataDirty ||= payload.type === "selection";
    controlsDirty = true;
    scheduleRender();
    return true;
  }

  function retryRequests() {
    for (const [id, request] of requests) {
      if (now() - request.started > (request.payload.type === "selection" ? 45000 : 8000)) {
        const timing = commandTimings.get(id);
        if (timing && !timing.ready) settleTiming(timing, 3);
        requests.delete(id); status("controlTimedOut"); send({ type: "resync" }); controlsDirty = true; scheduleRender();
      } else if (request.attempts < 3 && now() - request.sent >= (request.accepted ? 1500 : 700)) {
        request.sent = now(); request.attempts++; send(request.payload);
      }
    }
    if (!requests.size && requestTimer !== null) { clearInterval(requestTimer); requestTimer = null; }
  }

  function receiveAck(value) {
    if (!value || value.token !== token || !requests.has(value.commandId)) return false;
    const request = requests.get(value.commandId);
    if (["accepted", "pending"].includes(value.status)) request.accepted = true;
    else if (["completed", "rejected"].includes(value.status)) {
      const latest = [...requests.keys()].at(-1) === value.commandId;
      const timing = commandTimings.get(value.commandId);
      const older = validSnapshot(value.snapshot) && Number.isSafeInteger(value.snapshot.revision) && value.snapshot.revision >= 0 &&
        Number.isSafeInteger(snapshot?.revision) && value.snapshot.revision < snapshot.revision;
      const applied = value.snapshot && !older ? applySnapshot(value.snapshot).accepted : false;
      if (timing && !timing.ready) {
        if (value.status === "rejected") settleTiming(timing, 2);
        else if (applied || (older && latestTiming === value.commandId && matchesTimingSnapshot(snapshot, value.snapshot, timing) &&
          snapshot.synchronized && (timing.command !== "play" || snapshot.state === "playing") && (timing.command !== "pause" || snapshot.state === "paused"))) timing.native = value.snapshot;
        else settleTiming(timing, 6);
      }
      requests.delete(value.commandId);
      if (![...requests.values()].some(({ payload }) => ["play", "pause"].includes(payload.command))) toggleParity = snapshot?.state === "playing";
      if (value.status === "rejected" && latest) {
        const reasons = ["inactive", "unauthorized", "invalidSelection", "unmappedQueue", "awaitingNext", "cancelled", "nativeFailure", "nativeNoChange", "timedOut", "foreignPlayback", "noMatch", "cleared"];
        status(reasons.includes(value.reason) ? value.reason : "unsupported");
      }
      controlsDirty = true; scheduleRender(); retryRequests();
    } else return false;
    return true;
  }

  function flushDiagnostics() {
    if (!diagnosticsEnabled || !token) return;
    const fields = { renders: 0, renderTotalMs: 0, renderMaxMs: 0, rowsScanned: 0, observerCallbacks: 0,
      mutations: 0, framesQueued: 0, renderQueueMaxMs: 0, intents: 0, gestureToSendMaxMs: 0,
      renderAtLeast4Count: 0, adapterTaskMaxMs: 0, adapterOver50Count: 0, progressRenders: 0, progressRowsScanned: 0,
      ...metrics, viewportWidth: window.innerWidth || 0, viewportHeight: window.innerHeight || 0,
      devicePixelRatio: window.devicePixelRatio || 1, visualWidth: window.visualViewport?.width || 0,
      visualHeight: window.visualViewport?.height || 0, visualScale: window.visualViewport?.scale || 0 };
    const bars = deepQuery(document, `${PLAYER_ANY},${MINI_ROOT}`);
    const wide = root => visible(root) && root.getBoundingClientRect().width >= 200;
    const bar = bars.find(root => root.matches("ytmusic-player-bar") && visible(root)) ||
      bars.find(root => root.matches(MINI_ROOT) && visible(root)) ||
      bars.find(root => wide(root) && playerNodes(root, PLAY).some(visible)) || bars.find(wide) || null;
    for (const [name, selector] of [["bar", null], ["play", PLAY], ["next", NEXT],
      ["previous", PREVIOUS], ["slider", PROGRESS]]) {
      const candidates = selector ? playerNodes(bar, selector)
        .flatMap(node => [node, deepQuery(node, "button")[0]].filter(Boolean)) : [bar].filter(Boolean);
      const box = candidates.find(node => visible(node) && node.getBoundingClientRect().width > 0 && node.getBoundingClientRect().height > 0) || candidates.find(visible);
      const rect = box?.getBoundingClientRect();
      for (const [key, value] of Object.entries({ X: rect?.left, Y: rect?.top, Width: rect?.width, Height: rect?.height })) {
        fields[name + key] = Number.isFinite(value) ? value : 0;
      }
    }
    metrics = {};
    const output = Object.fromEntries(Object.entries(fields).filter(([, value]) => Number.isFinite(value))
      .map(([key, value]) => [key, String(Math.round(value * 100) / 100)]));
    output.aggregateRoot = String(bar?.tagName || "none").toLowerCase();
    output.commandTimingDroppedCount = String(timingDropped);
    const [sample] = [...commandTimings].filter(([, timing]) => timing.ready);
    if (sample) {
      const [id, timing] = sample;
      const millis = value => String(Math.round(value * 1000) / 1000);
      Object.assign(output, { commandId: id, commandStartedMs: millis(timing.started), commandFrameOutcome: String(timing.outcome) });
      if (timing.feedback !== undefined) output.feedbackFrameMs = millis(timing.feedback);
      if (timing.completed !== undefined) output.completedFrameMs = millis(timing.completed);
    }
    // Native adds documentId; keep its existing 1 KiB detail limit without discarding a timing sample.
    if (JSON.stringify({ ...output, documentId: "0".repeat(32) }).length > 1024)
      for (const name of ["bar", "play", "next", "previous", "slider"]) for (const key of ["X", "Y", "Width", "Height"]) delete output[name + key];
    send({ type: "diagnostic", event: "web.aggregate", fields: output });
    if (sample) commandTimings.delete(sample[0]);
    timingDropped = 0;
  }

  function setDiagnostics(enabled) {
    window.MultimusicQueueProbe?.configure(enabled, fields => send({ type: "diagnostic", event: "web.queueProbe", fields }));
    if (diagnosticsEnabled === enabled) return;
    diagnosticsEnabled = enabled;
    metrics = {};
    gestureStarted = null;
    commandTimings.clear(); latestTiming = null; timingDropped = 0;
    if (diagnosticsTimer !== null) clearInterval(diagnosticsTimer);
    diagnosticsTimer = enabled ? setInterval(measure(flushDiagnostics), 1000) : null;
  }

  function watchURL(anchor) {
    if (!anchor) return null;
    try {
      const url = new URL(typeof anchor === "string" ? anchor : anchor.getAttribute("href"), "https://music.youtube.com/");
      return url.origin === "https://music.youtube.com" &&
        url.pathname === "/watch" && /^[\w-]{11}$/.test(url.searchParams.get("v") || "") ? url : null;
    } catch { return null; }
  }

  function queueSourceURL(row, linkedURL) {
    const images = [...row.querySelectorAll("img")];
    const ids = new Set(linkedURL ? [linkedURL.searchParams.get("v")] : []);
    for (const image of images) {
      const sources = [image.currentSrc, image.getAttribute("src")].filter(Boolean);
      if (!sources.length && !linkedURL) return null;
      for (const source of sources) {
        try {
          const url = new URL(source, "https://music.youtube.com/");
          const match = url.pathname.match(/^\/vi\/([\w-]{11})\/hqdefault\.jpg$/);
          if (url.origin !== "https://i.ytimg.com" || url.username || url.password || !match) {
            if (linkedURL) continue;
            return null;
          }
          ids.add(match[1]);
        } catch { if (!linkedURL) return null; }
      }
    }
    if (ids.size !== 1) return null;
    for (const link of row.querySelectorAll('a[href*="watch"]')) {
      const url = watchURL(link);
      if (url ? !ids.has(url.searchParams.get("v")) : !linkedURL) return null;
    }
    // The observed queue thumbnail ID agrees with its public Start mix link; this DOM convention can change.
    return linkedURL || new URL(`https://music.youtube.com/watch?v=${[...ids][0]}`);
  }

  function trackFromRow(row) {
    const queueItem = row.matches("ytmusic-player-queue-item");
    const titleNode = rowNodes(row, queueItem ? ".song-title,.title" : ".title")[0];
    const anchor = titleNode?.querySelector('a[href*="watch"]') || rowNodes(row, 'a[href*="watch"]')[0];
    const linkedURL = watchURL(anchor);
    const url = queueItem ? queueSourceURL(row, linkedURL) : linkedURL;
    if (!url) return null;
    const title = text(titleNode) || anchor?.getAttribute("title")?.trim() || text(anchor);
    const cardSubtitles = row.matches("ytmusic-card-shelf-renderer") ? rowNodes(row, ".subtitle-container yt-formatted-string.subtitle")
      .filter(node => node.parentElement.matches(".subtitle-container")) : [];
    let artistNodes = rowNodes(row, 'a[href^="channel/"]');
    const subtitleArtists = artistNodes.filter(node => cardSubtitles.includes(node.closest("yt-formatted-string.subtitle")));
    if (subtitleArtists.length) artistNodes = subtitleArtists;
    let artists = artistNodes.map(text).filter(Boolean);
    if (!artists.length && queueItem) artists = [text(row.querySelector(".byline"))].filter(Boolean);
    if (!artists.length && row.matches('[is-album-detail-page]')) {
      const header = [...(row.closest(PAGE)?.querySelectorAll('ytmusic-responsive-header-renderer[is-album-detail-page]') || [])].find(visible);
      artistNodes = [...(header?.querySelectorAll('.strapline-text a[href^="channel/"]') || [])];
      artists = artistNodes.map(text).filter(Boolean);
    }
    const artist = [...new Set(artists)].join(" & ");
    if (!title || title.length > 500 || !artist || artist.length > 500) return null;
    let clockText = text(rowNodes(row, queueItem ? ".duration,.fixed-columns" : ".fixed-columns")[0]);
    if (row.matches("ytmusic-card-shelf-renderer")) {
      const clocks = cardSubtitles.filter(node => artistNodes.some(artist => artist.closest("yt-formatted-string") === node))
        .map(node => text(node).split(/[•·]/).at(-1).trim()).filter(value => /^(?:(\d{1,2}):)?\d{1,2}:[0-5]\d$/.test(value));
      if (new Set(clocks).size > 1) return null;
      if (clocks.length) clockText = clocks[0];
    }
    const clock = clockText.match(/^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})$/);
    const duration = clock ? Number(clock[1] || 0) * 3600 + Number(clock[2]) * 60 + Number(clock[3]) : null;
    if (queueItem && !linkedURL && (!clock || Number(clock[3]) >= 60 || (clock[1] && Number(clock[2]) >= 60) || !(duration > 0 && duration <= 86400))) return null;
    if (sourceLinks.size >= 200) {
      const oldest = sourceLinks.keys().next().value;
      sourceLinks.delete(oldest); sourceAlbums.delete(oldest);
    }
    sourceLinks.set(url.searchParams.get("v"), { artist: artistNodes.length === 1 ? artistNodes[0].getAttribute("href") : null, watch: url.pathname + url.search });
    const albumLink = rowNodes(row, 'a[href^="browse/MPRE"]')[0];
    if (text(albumLink) && text(albumLink).length <= 500) sourceAlbums.set(url.searchParams.get("v"), {
      title: text(albumLink), href: albumLink.getAttribute("href")
    });
    // Search shelf cards can carry unrelated badges; only scoped recording metadata counts.
    const searchCard = new URL(location.href).pathname === "/search" && row.matches("ytmusic-card-shelf-renderer");
    const explicitScope = [titleNode, ...rowNodes(row, ".byline,.byline-wrapper,.badges,ytmusic-badge-renderer")].filter(Boolean);
    const badge = '[aria-label="Explicit"],[title="Explicit"],[aria-label="E"],[title="E"]';
    const explicit = !searchCard && explicitScope.some(node => node.matches(badge) || deepQuery(node, badge).length > 0);
    return { id: url.searchParams.get("v"), title, artist,
      ...(duration > 0 && duration <= 86400 ? { duration } : {}), ...(explicit ? { isExplicit: true } : {}) };
  }

  function selectRow(row) {
    const selected = trackFromRow(row);
    if (!selected) { status("unreadable"); return; }
    const queueItem = row.matches("ytmusic-player-queue-item");
    const documentURL = queueItem ? watchURL(location.href) : null;
    const selectedURL = watchURL(rowNodes(row, 'a[href*="watch"]').find(link => watchURL(link)?.searchParams.get("v") === selected.id)) ||
      (documentURL?.searchParams.get("list")?.startsWith("RD") ? documentURL : null);
    const list = selectedURL?.searchParams.get("list");
    const page = row.closest(PAGE);
    const header = page?.querySelector('ytmusic-responsive-header-renderer[is-album-detail-page]');
    const path = new URL(location.href).pathname;
    const album = row.matches('[is-album-detail-page]') && visible(header);
    // shortcut: only an ordered rendered collection is handed over; radio and search start with one song.
    const collection = row.closest("ytmusic-shelf-renderer, ytmusic-playlist-shelf-renderer");
    const rows = collection && list && !list.startsWith("RD") && (path === "/playlist" || album)
      ? [...collection.querySelectorAll(ROW)].filter(visible) : [row];
    const start = Math.max(0, rows.indexOf(row));
    const tracks = [];
    let omitted = 0;
    for (const candidate of rows.slice(start, start + MAX_TRACKS)) {
      const candidateURL = watchURL(candidate.querySelector('.title a[href*="watch"]') || candidate.querySelector('a[href*="watch"]'));
      if (candidate !== row && candidateURL && candidateURL.searchParams.get("list") !== list) break;
      const track = trackFromRow(candidate);
      if (track) tracks.push(track); else omitted++;
    }
    lastStatus = null;
    const context = { provider: "youtubeMusic", kind: list?.startsWith("RD") ? "radio" : path === "/search" ? "search" :
      path === "/" ? "home" : path === "/watch" ? "watch" : "unknown", selectedSourceID: selected.id };
    if (start < 10000) context.selectedOrdinal = start;
    if (list && !list.startsWith("RD") && /^[A-Za-z0-9_-]{1,256}$/.test(list)) context.collectionID = list;
    if (album) {
      const title = text(header.querySelector(".title"));
      const artist = [...header.querySelectorAll('.strapline-text a[href^="channel/"]')].map(text).filter(Boolean).join(" & ");
      if (title && title.length <= 500 && artist && artist.length <= 500) Object.assign(context, { kind: "album", title, artist });
    } else if (path === "/playlist" && list && !list.startsWith("RD") && collection) context.kind = "playlist";
    else if (row.closest("ytmusic-search-page")) context.kind = "search";
    else if (row.closest("ytmusic-home-page")) context.kind = "home";
    if (context.kind === "album") {
      const pageURL = new URL(location.href);
      for (const track of tracks) sourceAlbums.set(track.id, { title: context.title, href: pageURL.pathname + pageURL.search });
    }
    const counts = [...(page?.querySelectorAll("ytmusic-responsive-header-renderer,ytmusic-detail-header-renderer") || [])]
      .filter(visible).flatMap(node => [...[...node.querySelectorAll("*")].filter(child => visible(child) && !child.children.length)
        .map(text).join(" ").matchAll(/\b([\d,]+)\s+(?:songs|tracks)\b/gi)])
      .map(match => Number(match[1].replace(/[, ]/g, ""))).filter(value => Number.isSafeInteger(value) && value > 0 && value <= 1000000);
    const declaredCount = context.kind === "playlist" || context.kind === "album" ? [...new Set(counts)].length === 1 ? counts[0] : null : null;
    const capped = rows.length - start > MAX_TRACKS || (tracks.length + omitted === MAX_TRACKS && declaredCount > rows.length);
    submit({ type: "selection", tracks: tracks.length ? tracks : [selected], omitted, context, capped,
      ...(declaredCount ? { declaredCount } : {}) });
  }

  function collectionRows(target) {
    const page = target.closest(PAGE);
    return page ? [...page.querySelectorAll(ROW)].filter(visible) : [];
  }

  function command(value, position) {
    if (!snapshot?.synchronized && !["play", "pause"].includes(value)) { status("choose"); return false; }
    if (value === "seek" && lastSeekAt !== null && now() - lastSeekAt < 800) return true;
    const sent = submit({ type: "command", command: value, ...(position === undefined ? {} : { position }) });
    if (sent && value === "seek") lastSeekAt = now();
    return sent;
  }

  function handleActivation(event) {
    if (!event.isTrusted || !token) return;
    if (event.type === "click") {
      const handled = lastHandledTouch;
      lastHandledTouch = null;
      if (handled?.target === eventTarget(event) && now() - handled.at < 800) { stop(event); return; }
    }
    if (diagnosticsEnabled) gestureStarted = now();
    try { activateControl(event); } finally { gestureStarted = null; }
  }

  function activateControl(event) {
    if (event.type === "keydown" && event.key?.toLowerCase() === "e" && !event.ctrlKey && !event.metaKey && !event.altKey &&
        !navigationTarget(eventTarget(event))) {
      const root = deepQuery(document, "ytmusic-player-bar").find(visible);
      if (root && expandPlayer(root, "keyboard")) stop(event);
      return;
    }
    if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
    const seekInfo = {};
    const slider = seekHit(event, seekInfo) || stackSeek(event, seekInfo);
    if (slider) {
      stop(event);
      seekAt(slider, event);
      return;
    }
    const target = eventTarget(event);
    const transport = pathControl(event);
    if (!target) return;
    if (target.closest('input,textarea,[contenteditable="true"],[role="combobox"]')) {
      return;
    }
    const menuItem = target.closest("ytmusic-menu-navigation-item-renderer,ytmusic-menu-service-item-renderer");
    if (menuItem && /^(Start mix|Start radio)(?:\s|$)/i.test(text(menuItem))) {
      stop(event);
      const link = target.closest("a[href]") || menuItem.querySelector("a[href]");
      if (link) {
        const url = watchURL(link);
        if (url && !url.username && !url.password && url.searchParams.getAll("v").length === 1 &&
            url.searchParams.getAll("list").length === 1 && /^RD[\w-]{1,254}$/.test(url.searchParams.get("list"))) {
          status("mixOpened"); location.assign(url.href);
        } else status("unsupported");
        return;
      }
      if (!snapshot?.synchronized || [...requests.values()].some(({ payload }) =>
          payload.type === "selection" || ["next", "previous"].includes(payload.command))) {
        status("unsupported"); return;
      }
      const url = watchURL(sourceLinks.get(snapshot?.sourceID)?.watch);
      if (!url?.searchParams.get("list")?.startsWith("RD") || url.searchParams.get("v") !== snapshot.sourceID) {
        status("unsupported"); return;
      }
      status("mixOpened"); location.assign(url.href);
      return;
    }
    const bar = transport.root;
    if (bar) {
      if (!transport.command) watchCollapse(bar, event);
      const navigation = !closestDeep(target, PLAYER_ROW) && navigationTarget(target);
      if (navigation) {
        if (bar.matches("ytmusic-player-bar") && closestDeep(target, ".title,#song-image,img.image") &&
            expandPlayer(bar, closestDeep(target, ".title") ? "title" : "cover")) stop(event);
        return;
      }
      if (bar.matches("ytmusic-player-bar") && closestDeep(target, "img.image")) {
        if (expandPlayer(bar, "cover")) stop(event);
        return;
      }
      if (transport.command) {
        if (transport.command === "seek") { stop(event); reportUnmappedMiniTap(event, seekInfo); return; }
        stop(event);
        if (!command(transport.command === "toggle" ? toggleParity ? "pause" : "play" : transport.command)) reportUnmappedMiniTap(event, seekInfo);
        return;
      }
      const label = playerButtonLabel(target);
      if (COLLAPSE.test(label) || volumeSlider(target)) return;
      if (/^Expand player$/i.test(label)) return;
      if (!target.closest(PLAYER_ROW)) {
        if (bar.getBoundingClientRect().height <= 120) {
          stop(event); status("unsupported"); reportUnmappedMiniTap(event, seekInfo);
        }
        return;
      }
    }
    const point = event.changedTouches?.[0] || event;
    if (!bar && !navigationTarget(target) && point.clientY >= window.innerHeight - 120 && point.clientY <= window.innerHeight)
      reportUnmappedMiniTap(event, seekInfo);
    if (menuItem && /^(Play|Start radio|Add to queue|Shuffle)/i.test(text(menuItem))) {
      stop(event); status("unsupported"); return;
    }
    if (target.closest("ytmusic-menu-renderer")) return;
    const row = target.closest(PLAYER_ROW);
    const anchor = target.closest("a[href]");
    let play = target.closest("ytmusic-play-button-renderer");
    if (!play && row?.matches("ytmusic-card-shelf-renderer")) {
      const button = target.closest('button[aria-label="Play"]');
      const renderer = button?.parentElement?.parentElement;
      if (button?.parentElement.matches("yt-button-shape") && renderer?.matches("yt-button-renderer") &&
          renderer.parentElement?.matches("#actions.actions-container") && renderer.parentElement.closest(PLAYER_ROW) === row) play = button;
    }
    const watch = watchURL(anchor);
    if (row && play && !row.matches("ytmusic-player-queue-item") && !row.querySelector('a[href*="watch"]')) {
      stop(event);
      const collectionLink = row.querySelector('a[href^="playlist?"],a[href^="browse/"]');
      if (collectionLink) { collectionLink.click(); status("openCollection"); } else status("empty");
      return;
    }
    if (row && (watch || play)) {
      stop(event); selectRow(row); return;
    }
    if (play?.closest("ytmusic-responsive-header-renderer,ytmusic-detail-header-renderer") ||
      target.closest("ytmusic-responsive-header-renderer button,ytmusic-detail-header-renderer button")?.getAttribute("aria-label")?.startsWith("Play")) {
      stop(event);
      const rows = collectionRows(target);
      if (rows.length) selectRow(rows[0]); else status("empty");
      return;
    }
    if (play || watch) { stop(event); status("unreadable"); }
  }

  function seek(event) {
    if (!event.isTrusted || !token) return;
    if (event.type === "pointerdown") reportBottomHit(event);
    if (diagnosticsEnabled) gestureStarted = now();
    try { seekControl(event); } finally { gestureStarted = null; }
  }

  function seekControl(event) {
    const seekInfo = {};
    const slider = seekHit(event, seekInfo) || stackSeek(event, seekInfo);
    const target = eventTarget(event);
    const transport = pathControl(event);
    if (event.type === "pointerdown" && transport.root && !transport.command) watchCollapse(transport.root, event);
    if (!transport.command && COLLAPSE.test(playerButtonLabel(target))) return;
    if (event.type === "pointerdown" && slider) {
      stop(event);
      clearDrag();
      drag = { slider, pointer: event.pointerId };
      slider.setPointerCapture(event.pointerId);
    } else if (event.type === "pointermove" && drag && drag.pointer === event.pointerId) {
      stop(event);
    } else if (event.type === "pointerup" && drag && drag.pointer === event.pointerId) {
      stop(event);
      const slider = drag.slider;
      clearDrag();
      seekAt(slider, event);
    } else if (event.type === "pointercancel" && drag) {
      stop(event); clearDrag();
    } else if (event.type === "keydown" && slider && ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) {
      stop(event);
      const position = event.key === "Home" ? 0 : event.key === "End" ? snapshot?.duration || 0 :
        (snapshot?.position || 0) + (event.key === "ArrowLeft" ? -5 : 5);
      if (!command("seek", Math.max(0, Math.min(snapshot?.duration || 0, position)))) reportUnmappedMiniTap(event, seekInfo);
    } else if (!slider && transport.command === "seek" && event.type === "pointerdown") {
      stop(event); reportUnmappedMiniTap(event, seekInfo);
    } else if (transport.root && transport.root.getBoundingClientRect().height <= 120 &&
      !navigationTarget(target) && !volumeSlider(target) && !target?.closest(PLAYER_ROW) && !transport.command &&
      (event.type === "pointerdown" || (event.type === "keydown" && ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)))) {
      stop(event); status("unsupported"); reportUnmappedMiniTap(event, seekInfo);
    }
  }

  function seekAt(slider, event) {
    const rect = seekRect(slider);
    const point = event.changedTouches?.[0] || event;
    if (rect.width > 0 && Number.isFinite(point.clientX) && snapshot?.duration > 0) {
      const position = Math.max(0, Math.min(1, (point.clientX - rect.left) / rect.width)) * snapshot.duration;
      if (command("seek", position)) return;
    }
    reportUnmappedMiniTap(event);
  }

  function clearDrag() {
    const previous = drag;
    drag = null;
    if (previous?.slider.hasPointerCapture(previous.pointer)) previous.slider.releasePointerCapture(previous.pointer);
  }

  // YouTube's touchend handler dispatches its own tap before the browser's click.
  function touchActivation(event) {
    if (!event.isTrusted) return;
    if (event.type === "touchend") reportBottomHit(event);
    if (event.type === "touchcancel") { touch = null; lastHandledTouch = null; return; }
    if (event.type === "touchstart") {
      lastHandledTouch = null;
      const point = event.touches.length === 1 ? event.touches[0] : null;
      touch = point ? { id: point.identifier, x: point.clientX, y: point.clientY, moved: false } : null;
      return;
    }
    const point = [...event.changedTouches].find(point => point.identifier === touch?.id);
    if (!touch || !point) return;
    touch.moved ||= Math.hypot(point.clientX - touch.x, point.clientY - touch.y) > 12;
    if (event.type === "touchend") {
      const activate = !touch.moved && event.touches.length === 0;
      touch = null;
      if (activate) handleActivation(event);
    }
  }

  const clock = seconds => {
    const value = Math.floor(Math.max(0, seconds));
    return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
  };

  function labelLeaf(node) {
    const links = anchors(node);
    let leaf = links.find(link => /^(?:\/?channel\/)/.test(link.getAttribute("href") || "")) || links[0] || node.querySelector("yt-attributed-string") || node;
    while (leaf.children.length === 1 && !leaf.children[0].matches("svg,img")) leaf = leaf.children[0];
    return leaf;
  }

  function setLabel(node, value) {
    if (!node) return;
    const leaf = labelLeaf(node);
    if (!leaf.children.length) setText(leaf, value);
    setAttribute(node, "title", value);
  }

  function cacheProgress(root) {
    const checks = new Map();
    const watch = (node, boundary) => {
      let inside = true;
      for (let current = node; current && current !== root; current = current.parentElement) {
        if (!checks.has(current)) checks.set(current, { node: current, parent: current.parentElement, children: null });
        if (inside) checks.get(current).children ??= [...current.children];
        if (current === boundary) inside = false;
      }
    };
    const labels = [[".time-info", "combined"], [CURRENT_TIME, "current"], [TOTAL_TIME, "total"]].flatMap(([selector, kind]) =>
      playerNodes(root, selector).map(node => {
        const leaf = kind === "combined" ? node : labelLeaf(node);
        watch(leaf, node);
        return { node, leaf, kind };
      }));
    const sliders = playerNodes(root, PROGRESS).map(slider => {
      const bar = slider.querySelector("#sliderBar"), progress = slider.querySelector("#primaryProgress,.ytp-play-progress"), knob = slider.querySelector("#sliderKnob");
      for (const node of [slider, bar, progress, knob]) if (node) watch(node, slider);
      return { slider, values: [slider, bar], progress, knob };
    });
    const entries = [...checks.values()];
    return { labels, sliders, valid: () => root.isConnected && entries.every(({ node, parent, children }) =>
      node.isConnected && node.parentElement === parent && (!children || (node.children.length === children.length &&
      children.every((child, index) => node.children[index] === child)))) };
  }

  function paintRoot(root) {
    const playing = displayedState() === "playing";
    if (metadataDirty) {
      if (root.matches('ytmusic-player-bar[slot="player-bar"]')) { root.removeAttribute("inert"); root.removeAttribute("hidden"); }
      setAttribute(root, "aria-label", "Player · Apple Music");
      for (const title of metadataNodes(root, `.ytp-title-text,.title,${MINI_TITLE}`)) {
        title.removeAttribute("is-empty");
        setLabel(title, snapshot.title || "Choose a song");
        for (const link of anchors(title)) {
          if (snapshot.sourceID) { setAttribute(link, "href", sourceLinks.get(snapshot.sourceID)?.watch || `watch?v=${snapshot.sourceID}`); link.removeAttribute("aria-disabled"); }
          else { link.removeAttribute("href"); setAttribute(link, "aria-disabled", "true"); }
        }
      }
      for (const byline of metadataNodes(root, ".byline,.byline-wrapper .subtitle")) {
        byline.removeAttribute("is-empty");
        setLabel(byline, snapshot.artist || "Apple Music");
        const links = anchors(byline);
        for (const link of links) if (!bylineKinds.has(link)) bylineKinds.set(link,
          /(?:browse\/|playlist\?)/.test(link.getAttribute("href") || "") ? "album" : "artist");
        const primary = links.find(link => bylineKinds.get(link) === "artist") || links[0];
        const album = sourceAlbums.get(snapshot.sourceID);
        const showAlbum = album && links.some(link => link !== primary && bylineKinds.get(link) === "album");
        for (const link of links) {
          if (link === primary) {
            setLabel(link, snapshot.artist || "Apple Music"); link.removeAttribute("hidden");
            const href = sourceLinks.get(snapshot.sourceID)?.artist;
            if (href) { setAttribute(link, "href", href); link.removeAttribute("aria-disabled"); }
            else { link.removeAttribute("href"); setAttribute(link, "aria-disabled", "true"); }
          } else if (bylineKinds.get(link) === "album" && album) {
            setLabel(link, album.title); setAttribute(link, "href", album.href); link.removeAttribute("hidden");
          } else setAttribute(link, "hidden", "");
        }
        for (const child of byline?.children || []) if (!child.matches("a") && /^[\s•·&,]+$/.test(child.textContent || "")) {
          if (showAlbum) child.removeAttribute("hidden"); else setAttribute(child, "hidden", "");
        }
        for (const child of byline?.childNodes || []) if (child.nodeType === 3 && /^[\s•·&,]*$/.test(child.nodeValue || "")) {
          if (!separatorText.has(child)) separatorText.set(child, child.nodeValue);
          child.nodeValue = showAlbum ? separatorText.get(child) : "";
        }
      }
    }
    if (metadataDirty) for (const byline of metadataNodes(root, MINI_BYLINE)) {
      const artist = snapshot.artist || "Apple Music";
      const item = byline.querySelector(".ytmusicTrackInfoBylineItem") || byline;
      setAttribute(item, "title", artist);
      const link = anchors(item)[0];
      const leaf = link || labelLeaf(item);
      if (link) {
        const href = sourceLinks.get(snapshot.sourceID)?.artist;
        if (href) { setAttribute(link, "href", href); link.removeAttribute("aria-disabled"); }
        else { link.removeAttribute("href"); setAttribute(link, "aria-disabled", "true"); }
      }
      if (!leaf.children.length) setText(leaf, artist);
      // YouTube's view/like counts describe its own track, not Apple Music's.
      const clearOther = node => {
        if (node === leaf) return;
        for (const child of node.childNodes || []) {
          if (child.nodeType === 3) { if (child.nodeValue) child.nodeValue = ""; } else clearOther(child);
        }
      };
      clearOther(item);
    }
    if (controlsDirty) {
      for (const play of playerNodes(root, PLAY)) {
        setAttribute(play, "title", playing ? "Pause" : "Play");
        setAttribute(play, "aria-busy", requests.size > 0);
        setAttribute(play.querySelector("button") || play, "aria-label", playing ? "Pause" : "Play");
        setAttribute(play.querySelector("path"), "d", playIcon(playing, play.matches(".ytp-play-button")));
      }
    }
    const position = Math.max(0, Math.min(snapshot.duration, snapshot.position));
    const view = progressViews.get(root);
    for (const { node, leaf, kind } of view.labels) {
      const value = kind === "combined" ? `${clock(position)} / ${clock(snapshot.duration)}` : clock(kind === "current" ? position : snapshot.duration);
      if (kind === "combined" || !leaf.children.length) setText(leaf, value);
      if (kind !== "combined") setAttribute(node, "title", value);
    }
    for (const { slider, values, progress, knob } of view.sliders) {
      setAttribute(slider, "role", "slider");
      for (const valueNode of values) {
        setAttribute(valueNode, "value", position);
        setAttribute(valueNode, "aria-valuenow", position);
        setAttribute(valueNode, "aria-valuemax", snapshot.duration);
        setAttribute(valueNode, "aria-disabled", !snapshot.synchronized);
      }
      setAttribute(slider, "aria-valuetext", `${clock(position)} of ${clock(snapshot.duration)}`);
      const ratio = snapshot.duration > 0 ? position / snapshot.duration : 0;
      if (progress && progress.style.transform !== `scaleX(${ratio})`) progress.style.transform = `scaleX(${ratio})`;
      if (knob && knob.style.left !== `${ratio * 100}%`) knob.style.left = `${ratio * 100}%`;
    }
  }

  function render() {
    renderPending = false;
    const started = diagnosticsEnabled ? now() : null;
    let progressOnly = false;
    const rowsBefore = metrics.rowsScanned || 0;
    try {
      if (!rootsDirty && roots.some(root => !progressViews.get(root)?.valid())) rootsDirty = true;
      progressOnly = !!snapshot && !rootsDirty && !metadataDirty && !controlsDirty && highlightedID === snapshot.sourceID;
      if (started !== null && renderQueuedAt !== null) maximum("renderQueueMaxMs", started - renderQueuedAt);
      renderQueuedAt = null;
      if (!snapshot) return;
      if (rootsDirty) {
        roots = [...document.querySelectorAll(PAINT_ROOT)];
        artwork = [...document.querySelectorAll(ARTWORK)].filter(image => !image.closest(PLAYER_ROW));
        metadataLabels = roots.flatMap(root => metadataNodes(root, `.ytp-title-text,.title,.byline,.byline-wrapper .subtitle,${MINI_TITLE},${MINI_BYLINE}`));
        progressViews.clear();
        for (const root of roots) progressViews.set(root, cacheProgress(root));
        rootsDirty = false; metadataDirty = true; controlsDirty = true;
      }
      if (!roots.length) { status("adapterChanged"); captureTimingFrame(); return; }
      observer.disconnect();
      try {
        if (!document.getElementById("multimusic-player-style")) {
          const style = document.createElement("style");
          style.id = "multimusic-player-style";
          style.textContent = `
          ytmusic-player-bar[slot="player-bar"] { display:flex!important; visibility:visible!important; transform:none!important; }
          ytmusic-player-bar #progress-bar, ytmusic-player-page #progress-bar, ytmusic-player-page .ytp-progress-bar { touch-action:none; }
        `;
          (document.head || document.documentElement).appendChild(style);
        }
        if (metadataDirty) for (const image of artwork) {
          const attribute = image.matches("video") ? "poster" : "src";
          if (snapshot.sourceID) {
            if (attribute === "src") { image.removeAttribute("hidden"); image.removeAttribute("srcset"); }
            setAttribute(image, attribute, `https://i.ytimg.com/vi/${snapshot.sourceID}/hqdefault.jpg`);
          } else if (attribute === "poster") image.removeAttribute("poster");
          else setAttribute(image, "hidden", "");
        }
        for (const root of roots) {
          paintRoot(root);
          if (metadataDirty && visible(root) && !artworkOnly(root) && (!metadataNodes(root, `.title,.ytp-title-text,${MINI_TITLE}`).some(node => visible(node) && text(node) === (snapshot.title || "Choose a song")) ||
            !playerNodes(root, PLAY).some(visible))) status("adapterChanged");
        }
        if (highlightedID !== snapshot.sourceID) {
          for (const row of document.querySelectorAll(ROW)) {
            count("rowsScanned");
            const id = watchURL(row.querySelector('.title a[href*="watch"]') || row.querySelector('a[href*="watch"]'))?.searchParams.get("v");
            if (id === snapshot.sourceID) setAttribute(row, "aria-current", "true");
            else if (row.getAttribute("aria-current") === "true") row.removeAttribute("aria-current");
          }
          highlightedID = snapshot.sourceID;
        }
        metadataDirty = false; controlsDirty = false;
      } finally { observePlayer(); }
      captureTimingFrame();
      if (snapshot.deliveryId !== undefined && snapshot.deliveryId !== lastPaintedDelivery) {
        lastPaintedDelivery = snapshot.deliveryId;
        send({ type: "snapshotAck", deliveryId: snapshot.deliveryId });
      }
    } finally {
      if (started !== null) {
        const elapsed = Math.max(0, now() - started);
        count("renders");
        count("renderTotalMs", elapsed); maximum("renderMaxMs", elapsed);
        if (elapsed >= 4) count("renderAtLeast4Count");
        if (progressOnly) {
          count("progressRenders");
          count("progressRowsScanned", Math.max(0, (metrics.rowsScanned || 0) - rowsBefore));
        }
      }
    }
  }

  function scheduleRender() {
    if (renderPending) return;
    renderPending = true;
    if (diagnosticsEnabled) { renderQueuedAt = now(); count("framesQueued"); }
    requestAnimationFrame(renderCallback);
  }

  function validSnapshot(value) {
    return !!value && typeof value.title === "string" && typeof value.artist === "string" &&
      Number.isFinite(value.position) && Number.isFinite(value.duration) && value.duration >= 0 && value.duration <= 86400 &&
      typeof value.synchronized === "boolean" && (value.sourceID == null || /^[\w-]{11}$/.test(value.sourceID));
  }

  function applySnapshot(value) {
    if (!validSnapshot(value)) return { accepted: false };
    if (value.revision !== undefined && (!Number.isSafeInteger(value.revision) || value.revision < (snapshot?.revision || 0))) return { accepted: false };
    metadataDirty ||= !snapshot || ["sourceID", "title", "artist"].some(key => snapshot[key] !== value[key]);
    controlsDirty ||= !snapshot || ["state", "synchronized"].some(key => snapshot[key] !== value[key]);
    if (toggleParity === null || value.sourceID !== snapshot?.sourceID ||
        ![...requests.values()].some(({ payload }) => ["play", "pause"].includes(payload.command))) toggleParity = value.state === "playing";
    snapshot = value;
    setDiagnostics(value.diagnosticsEnabled === true);
    scheduleRender();
    return { accepted: true, deliveryId: value.deliveryId ?? null };
  }

  window.Multimusic = Object.freeze({
    activate: measure((value, initialSnapshot) => {
      if (typeof value !== "string" || value.length > 100) return false;
      if (token !== value) { requests.clear(); commandTimings.clear(); latestTiming = null; timingDropped = 0; toggleParity = null; snapshot = null; highlightedID = null; lastPaintedDelivery = null; rootsDirty = true; metadataDirty = true; controlsDirty = true; }
      token = value; sequence = 0; lastStatus = null;
      applySnapshot(initialSnapshot);
      status("ready");
      return true;
    }),
    applySnapshot: measure(applySnapshot),
    receiveAck: measure(receiveAck)
  });
  window.addEventListener("click", measure(handleActivation), true);
  window.addEventListener("keydown", measure(handleActivation), true);
  for (const event of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
    window.addEventListener(event, measure(touchActivation), { capture: true, passive: event !== "touchend" });
  }
  for (const event of ["pointerdown", "pointermove", "pointerup", "pointercancel", "keydown"]) {
    window.addEventListener(event, measure(seek), true);
  }
  window.addEventListener("blur", measure(() => { clearDrag(); touch = null; lastHandledTouch = null; }));
  window.addEventListener("visibilitychange", measure(() => {
    if (diagnosticsEnabled && document.visibilityState === "hidden")
      for (const timing of commandTimings.values()) if (!timing.ready) settleTiming(timing, 5);
  }), true);
  window.addEventListener("pagehide", measure(() => {
    clearDrag(); clearCollapse(); touch = null; lastHandledTouch = null; lastSeekAt = null; setDiagnostics(false); token = null; requests.clear();
    if (requestTimer !== null) clearInterval(requestTimer); requestTimer = null;
  }));
  window.addEventListener("resize", measure(() => { rootsDirty = true; scheduleRender(); }));
  function observePlayer() {
    observer.observe(document, { childList: true, subtree: true });
    for (const root of roots) observer.observe(root, { attributes: true, attributeFilter: ["hidden", "inert"] });
    for (const label of metadataLabels) observer.observe(label, { attributes: true, attributeFilter: ["is-empty"] });
    for (const image of artwork) observer.observe(image, { attributes: true, attributeFilter: image.matches("video") ? ["poster"] : ["src", "srcset", "hidden"] });
  }
  const observer = new MutationObserver(measure(records => {
    count("observerCallbacks"); count("mutations", records.length);
    const changed = records.some(record => {
      const target = record.target instanceof Element ? record.target : record.target?.parentElement;
      if (target?.matches(ARTWORK) && !target.closest(PLAYER_ROW)) return true;
      if (target?.matches(PAINT_ROOT)) return true;
      if (target?.closest(PAINT_ROOT) && !target.closest(PLAYER_ROW) && target.closest(CONTROLS)) return true;
      return [...record.addedNodes || []].some(node => node instanceof Element &&
        ((node.matches(ARTWORK) && !node.closest(PLAYER_ROW)) || node.querySelector(ARTWORK) || node.matches(PAINT_ROOT) || node.querySelector(PAINT_ROOT) ||
          (node.closest(PAINT_ROOT) && !node.closest(PLAYER_ROW) && (node.matches(CONTROLS) || node.querySelector(CONTROLS)))));
    });
    if (changed) { rootsDirty = true; scheduleRender(); }
  }));
  observePlayer();
})();
