// A tiny DOM boundary fixture: selectors, input propagation, and painted fields only.
export class Element {
  constructor(tag, attributes = {}, children = []) {
    this.tagName = tag.toUpperCase();
    this.attributes = new Map(Object.entries(attributes));
    this.children = [];
    this.parentElement = null;
    this.style = {};
    this._text = "";
    this.rect = { left: 0, width: 200 };
    for (const child of children) this.appendChild(child);
  }
  get id() { return this.getAttribute("id"); }
  set id(value) { this.setAttribute("id", value); }
  get hidden() { return this.attributes.has("hidden"); }
  get isConnected() {
    let node = this;
    while (node.parentElement) {
      if (!node.parentElement.children.includes(node)) return false;
      node = node.parentElement;
    }
    return node.tagName === "DOCUMENT";
  }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(""); }
  set textContent(value) { for (const child of this.children) child.parentElement = null; this._text = String(value); this.children = []; }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  removeAttribute(name) { this.attributes.delete(name); }
  get parentNode() { return this.parentElement; }
  attachShadow() {
    const root = element("shadow-root");
    root.host = this;
    root.parentElement = this;
    this.shadowRoot = root;
    return root;
  }
  appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
  replaceChild(child, previous) {
    const index = this.children.indexOf(previous);
    if (index < 0) throw new Error("The replaced node is not a child.");
    previous.parentElement = null; child.parentElement = this; this.children[index] = child;
    return previous;
  }
  getClientRects() {
    for (let node = this; node; node = node.parentElement) if (node.hidden) return [];
    return [this.rect];
  }
  checkVisibility({ visibilityProperty = false, opacityProperty = false } = {}) {
    for (let node = this; node; node = node.parentElement || node.parentNode?.host) {
      if (node.hidden || node.style.display === "none" || opacityProperty && String(node.style.opacity) === "0") return false;
    }
    if (visibilityProperty) for (let node = this; node; node = node.parentElement || node.parentNode?.host) {
      if (node.style.visibility) return node.style.visibility === "visible";
    }
    return true;
  }
  getBoundingClientRect() { return this.rect; }
  setPointerCapture(pointer) { this.capturedPointer = pointer; }
  hasPointerCapture(pointer) { return this.capturedPointer === pointer; }
  releasePointerCapture(pointer) { if (this.capturedPointer === pointer) this.capturedPointer = null; }
  matches(selector) {
    return selector.split(",").some(option => {
      const parts = option.trim().match(/(?:\[[^\]]*\]|[^\s[])+/g) || [];
      let node = this;
      if (!simpleMatch(node, parts.pop())) return false;
      while (parts.length) {
        const parentSelector = parts.pop();
        node = node.parentElement;
        while (node && !simpleMatch(node, parentSelector)) node = node.parentElement;
        if (!node) return false;
      }
      return true;
    });
  }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
  querySelectorAll(selector) {
    const descendants = this.children.flatMap(child => [child, ...child.querySelectorAll("*")]);
    return descendants.filter(child => child.matches(selector));
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  elementsFromPoint(x, y) {
    return this.querySelectorAll("*").filter(node => {
      const { left, top, width, height } = node.getBoundingClientRect();
      return node.style.display !== "none" && !node.hidden && width > 0 && height > 0 &&
        x >= left && x <= left + width && y >= top && y <= top + height;
    }).reverse();
  }
  getRootNode() {
    let node = this;
    while (node.parentElement && !node.host) node = node.parentElement;
    return node;
  }
}

function simpleMatch(node, selector) {
  if (!selector || !node) return false;
  const attributes = [...selector.matchAll(/\[([^\]^*=]+)(\^=|\*=|=)?["']?([^\]"']*)["']?(\s+i)?\]/g)];
  let rest = selector.replace(/\[[^\]]*\]/g, "");
  const tag = rest.match(/^[\w*-]+/)?.[0];
  if (tag && tag !== "*" && tag.toUpperCase() !== node.tagName) return false;
  for (const match of rest.matchAll(/#([\w-]+)/g)) if (node.id !== match[1]) return false;
  for (const match of rest.matchAll(/\.([\w-]+)/g)) {
    if (!(node.getAttribute("class") || "").split(" ").includes(match[1])) return false;
  }
  return attributes.every(([, name, operator, value, insensitive]) => {
    const actual = node.getAttribute(name);
    if (actual === null) return false;
    const left = insensitive ? String(actual).toLowerCase() : String(actual);
    const right = insensitive ? String(value).toLowerCase() : String(value);
    return !operator || (operator === "=" ? left === right :
      operator === "^=" ? left.startsWith(right) : left.includes(right));
  });
}

export function element(tag, attributes = {}, children = [], text = "") {
  const node = new Element(tag, attributes, children);
  node._text = text;
  return node;
}

export function song(id, title, { list = "OLAK5album", artist = "Daft Punk", duration = "4:36", explicit = false } = {}) {
  return element("ytmusic-responsive-list-item-renderer", {}, [
    element("yt-formatted-string", { class: "title" }, [
      element("a", { href: `watch?v=${id}${list ? `&list=${list}` : ""}` }, [], title),
      ...(explicit ? [element("span", { "aria-label": "Explicit" })] : [])
    ]),
    element("div", { class: "flex-columns" }, [element("a", { href: "channel/artist" }, [], artist)]),
    element("div", { class: "fixed-columns" }, [], duration)
  ]);
}

export function fixture(rows = [], { host = "music.youtube.com", synchronized = true, artistContainer = "subtitle", albumArtist, albumTitle = "Homework (25th Anniversary Edition)", manualFrames = false } = {}) {
  const head = element("head");
  const shelf = element("ytmusic-shelf-renderer", {}, rows);
  const headerPlay = element("ytmusic-play-button-renderer", { "aria-label": "Play album", role: "button" }, [element("yt-icon")]);
  const header = element("ytmusic-responsive-header-renderer", {}, [headerPlay]);
  if (albumArtist !== undefined) {
    header.setAttribute("is-album-detail-page", "");
    header.appendChild(element("yt-formatted-string", { class: "title" }, [], albumTitle));
    header.appendChild(element("yt-formatted-string", { class: "strapline-text" }, [element("a", { href: "channel/artist" }, [], albumArtist)]));
    for (const row of rows) row.setAttribute("is-album-detail-page", "");
  }
  const browse = element("ytmusic-browse-response", {}, [element("ytmusic-two-column-browse-results-renderer", {}, [header, shelf])]);
  const play = element("yt-icon-button", { id: "play-pause-button", class: "play-pause-button" }, [element("button"), element("path")]);
  const previous = element("yt-icon-button", { class: "previous-button" }, [element("button")]);
  const next = element("yt-icon-button", { class: "next-button" }, [element("button")]);
  const slider = element("tp-yt-paper-slider", { id: "progress-bar" }, [
    element("tp-yt-paper-progress", { id: "sliderBar" }, [element("div", { id: "primaryProgress" })]),
    element("div", { id: "sliderKnob" })
  ]);
  const artist = element("yt-formatted-string", { class: artistContainer });
  const bar = element("ytmusic-player-bar", { inert: "", slot: "player-bar" }, [play, next, previous, slider,
    element("yt-formatted-string", { class: "title", "is-empty": "" }), element("span", { class: "byline-wrapper" }, [artist]),
    element("span", { class: "time-info" }), element("img", { class: "image" })]);
  const body = element("body", {}, [browse, bar]);
  const root = element("html", {}, [head, body]);
  const document = element("document", {}, [root]);
  Object.assign(document, { head, body, documentElement: root,
    createElement: tag => element(tag), getElementById(id) {
      const pending = [document];
      while (pending.length) {
        const node = pending.pop();
        if (node.id === id) return node;
        pending.push(...node.children);
      }
      return null;
    } });
  const listeners = new Map();
  const timers = new Map();
  const frames = [];
  let time = 0, nextTimer = 0, mutationCallback = null, observations = [];
  const messages = [];
  const window = { innerWidth: 402, innerHeight: 649, addEventListener(type, listener) { listeners.set(type, [...(listeners.get(type) || []), listener]); },
    webkit: { messageHandlers: { multimusic: { postMessage(value) { messages.push(structuredClone(value)); } } } } };
  window.top = window;
  const snapshot = { sourceID: "AAAAAAAAAAA", title: "Apple matched recording", artist: "Apple artist", duration: 200,
    position: 25, state: "paused", synchronized };
  function dispatch(type, target, options = {}) {
    const event = { type, isTrusted: true, key: undefined, pointerId: 1, clientX: 0,
      stopped: false, prevented: false, composedPath: () => [target], ...options,
      preventDefault() { this.prevented = true; }, stopImmediatePropagation() { this.stopped = true; } };
    for (const callback of listeners.get(type) || []) { callback(event); if (event.stopped) break; }
    return event;
  }
  function advance(milliseconds) {
    time += milliseconds;
    for (const timer of timers.values()) if (time >= timer.next) {
      timer.next = time + timer.interval;
      timer.callback();
    }
  }
  return { window, document, Element, location: { protocol: "https:", hostname: host, href: `https://${host}/playlist?list=OLAK5album`,
      assign(url) { this.href = url; } },
    MutationObserver: class {
      constructor(callback) { mutationCallback = callback; }
      observe(target, options) { this.observing = true; observations.push({ target, options }); }
      disconnect() { this.observing = false; observations = []; }
    }, requestAnimationFrame: callback => manualFrames ? frames.push(callback) : callback(), URL,
    setInterval(callback, interval) { const id = ++nextTimer; timers.set(id, { callback, interval, next: time + interval }); return id; },
    clearInterval(id) { timers.delete(id); }, performance: { now: () => time },
    mutate(records) {
      const delivered = records.filter(record => observations.some(({ target, options }) => {
        let inside = record.target === target;
        if (options.subtree) for (let node = record.target?.parentElement; node; node = node.parentElement) inside ||= node === target;
        return inside && ((record.type || "childList") === "attributes"
          ? options.attributes && (!options.attributeFilter || options.attributeFilter.includes(record.attributeName))
          : options.childList);
      }));
      if (delivered.length) mutationCallback?.(delivered);
    },
    frame(milliseconds = 16) { time += milliseconds; for (const callback of frames.splice(0)) callback(time); },
    messages, snapshot, dispatch, advance, bar, play, previous, next, slider, headerPlay, artist };
}
