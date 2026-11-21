import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import { fixture, song, element } from "./dom-fixture.mjs";

const script = readFileSync(process.env.MULTIMUSIC_ADAPTER_PATH || new URL("../../Multimusic/Resources/YouTubeMusic.js", import.meta.url), "utf8");
function start(rows = [], options) {
  const env = fixture(rows, options);
  vm.runInNewContext(script, env);
  env.window.Multimusic?.activate("current-document", env.snapshot);
  env.messages.length = 0;
  return env;
}

function radioQueueRow(id, title, artist, duration, { play = false, src = `https://i.ytimg.com/vi/${id}/hqdefault.jpg` } = {}) {
  const image = element("img", { src });
  image.currentSrc = src;
  return element("ytmusic-player-queue-item", {}, [image,
    element("yt-formatted-string", { class: "song-title", title }, [], title),
    element("yt-formatted-string", { class: "byline", title: artist }, [], artist),
    element("yt-formatted-string", { class: "duration", title: duration }, [], duration),
    ...(play ? [element("ytmusic-play-button-renderer", { id: "play-button", "aria-label": `Play ${title}` })] : [])
  ]);
}

function startRadioQueue(rows) {
  const env = start();
  env.location.href = "https://music.youtube.com/watch?v=eNWfAvwxiCE&list=RDAMVMeNWfAvwxiCE";
  env.document.body.appendChild(element("ytmusic-player-page", {}, [element("ytmusic-player-queue", {}, rows)]));
  return env;
}

// The owning boundary is original DOM input -> native bridge, and native snapshot -> original DOM.
// These cases protect wrong queues, unintended playback, and stale feedback, without test-only exports.
test("a selected album row emits only its ordered available batch, including repeats and duration", () => {
  const rows = [song("AAAAAAAAAAA", "Before"), song("BBBBBBBBBBB", "Selected", { explicit: true }),
    song("BBBBBBBBBBB", "Selected again"), song("CCCCCCCCCCC", "After", { duration: "1:02:03" })];
  const env = start(rows);
  const event = env.dispatch("click", rows[1].querySelector(".title a"));
  assert.equal(event.prevented, true);
  assert.deepEqual(env.messages[0].tracks, [
    { id: "BBBBBBBBBBB", title: "Selected", artist: "Daft Punk", duration: 276, isExplicit: true },
    { id: "BBBBBBBBBBB", title: "Selected again", artist: "Daft Punk", duration: 276 },
    { id: "CCCCCCCCCCC", title: "After", artist: "Daft Punk", duration: 3723 }
  ]);
  assert.equal(env.messages[0].token, "current-document");
  assert.equal(env.messages[0].provider, "youtubeMusic");
  assert.equal(env.messages[0].context.provider, "youtubeMusic");
});

test("home, search and radio send the deliberately selected song only and never invent a duration", () => {
  for (const [list, path] of [[null, "/search?q=song"], ["RDAMVMAAAAAAAAAAA", "/watch?v=AAAAAAAAAAA"], ["OLAK5album", "/"]]) {
    const rows = [song("AAAAAAAAAAA", "One", { list, duration: "" }), song("BBBBBBBBBBB", "Unrelated", { list })];
    const env = start(rows);
    env.location.href = `https://music.youtube.com${path}`;
    env.dispatch("click", rows[0].querySelector("a"));
    assert.equal(env.messages[0].tracks.length, 1);
    assert.equal(env.messages[0].tracks[0].id, "AAAAAAAAAAA");
    assert.equal("duration" in env.messages[0].tracks[0], false);
  }
});

test("collection Play captures the rendered collection and limits a handoff to 50 tracks", () => {
  const rows = Array.from({ length: 55 }, (_, i) => song(String(i).padStart(11, "0"), `Song ${i}`));
  const env = start(rows);
  env.dispatch("click", env.headerPlay);
  assert.equal(env.messages[0].tracks.length, 50);
  assert.equal(env.messages[0].tracks[49].title, "Song 49");
  // Actual Liked Songs DOM: an unavailable second row separates Bongos from Work.
  const list = "PLk_-oBrxNL5Ht1xkrqFVYdYJ2ys9KPtBI";
  const unavailable = element("ytmusic-responsive-list-item-renderer", {}, [
    element("div", { class: "title" }, [], "4 morant x motel6")
  ]);
  const available = [song("2oK7bNovAwc", "Bongos (feat. Megan Thee Stallion)", { list, artist: "Cardi B", duration: "2:56", explicit: true }),
    unavailable, song("1PifcWdhRpY", "Work", { list, artist: "Charlotte Day Wilson", duration: "3:45" }),
    song("1PifcWdhRpY", "Work", { list, artist: "Charlotte Day Wilson", duration: "3:45" }),
    song("CCCCCCCCCCC", "Another playlist", { list: "PLanother" }), song("DDDDDDDDDDD", "Beyond the boundary", { list })];
  const playlist = start(available);
  playlist.location.href = `https://music.youtube.com/playlist?list=${list}`;
  const originalChildren = unavailable.children.slice();
  playlist.dispatch("click", playlist.headerPlay);
  assert.deepEqual(playlist.messages[0].tracks.map(track => track.id), ["2oK7bNovAwc", "1PifcWdhRpY", "1PifcWdhRpY"]);
  assert.equal(playlist.messages[0].omitted, 1);
  assert.equal(playlist.messages[0].context.kind, "playlist");
  assert.equal(playlist.messages[0].context.collectionID, list);
  assert.deepEqual(unavailable.children, originalChildren);
});

test("album touch Play captures header artists before the site's tap without treating a swipe as selection", () => {
  const rows = [song("AAAAAAAAAAA", "Daftendirekt", { artist: "", duration: "2:45" }),
    song("BBBBBBBBBBB", "Guest song", { artist: "Guest", duration: "0:29" })];
  const env = start(rows, { albumArtist: "Daft Punk" });
  const target = env.headerPlay.querySelector("yt-icon");
  const point = (x, y) => ({ identifier: 1, clientX: x, clientY: y });
  const begin = () => env.dispatch("touchstart", target, { touches: [point(50, 50)] });
  const end = (x = 50, y = 50) => env.dispatch("touchend", target, { touches: [], changedTouches: [point(x, y)] });
  begin();
  assert.equal(end().prevented, true);
  assert.deepEqual(env.messages[0].tracks, [
    { id: "AAAAAAAAAAA", title: "Daftendirekt", artist: "Daft Punk", duration: 165 },
    { id: "BBBBBBBBBBB", title: "Guest song", artist: "Guest", duration: 29 }
  ]);
  env.messages.length = 0;
  begin();
  env.dispatch("touchmove", target, { changedTouches: [point(50, 100)] });
  assert.equal(end().prevented, false);
  begin();
  env.dispatch("touchcancel", target);
  end();
  begin();
  env.dispatch("touchstart", target, { touches: [point(50, 50), { ...point(50, 50), identifier: 2 }] });
  end();
  assert.equal(env.messages.length, 0);
  rows[0].removeAttribute("is-album-detail-page");
  env.advance(800);
  env.dispatch("click", rows[0].querySelector("a"));
  assert.equal(env.messages.at(-1).status, "unreadable");
  env.messages.length = 0;
  env.dispatch("touchstart", env.slider, { touches: [point(50, 50)] });
  env.dispatch("pointerdown", env.slider, { clientX: 50 });
  env.dispatch("pointerup", env.slider, { clientX: 100 });
  env.dispatch("touchend", env.slider, { touches: [], changedTouches: [point(50, 50)] });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.command), ["seek"]);
});

test("artist navigation stays browsing; invalid identity or missing artist never sends playback", () => {
  const valid = song("AAAAAAAAAAA", "One");
  const invalid = song("evil", "Two");
  const noArtist = song("BBBBBBBBBBB", "Three", { artist: "" });
  const env = start([valid, invalid, noArtist]);
  assert.equal(env.dispatch("click", valid.querySelector('a[href^="channel/"]')).prevented, false);
  env.dispatch("click", invalid.querySelector("a"));
  env.dispatch("click", noArtist.querySelector("a"));
  assert.equal(env.messages.some(message => message.type === "selection"), false);
  assert.equal(env.messages.at(-1).status, "unreadable");
});

test("collection-card titles and browse links retain the website's original navigation", () => {
  for (const tag of ["ytmusic-card-shelf-renderer", "ytmusic-two-row-item-renderer", "ytmusic-responsive-list-item-renderer"]) {
    const env = start();
    const title = element("yt-formatted-string", { class: "title" }, [], "Homework (25th Anniversary Edition)");
    const browse = element("a", { href: "browse/MPRE_album" }, [], "Open album");
    const artist = element("a", { href: "channel/artist" }, [], "Daft Punk");
    const card = element(tag, {}, [title, browse, artist]);
    env.document.body.appendChild(card);
    for (const target of [title, browse, artist]) assert.equal(env.dispatch("click", target).prevented, false);
    assert.equal(env.messages.length, 0);
    const play = element("ytmusic-play-button-renderer");
    card.appendChild(play);
    let opened = false;
    browse.click = () => { opened = true; };
    assert.equal(env.dispatch("click", play).prevented, true);
    assert.equal(opened, true);
    assert.equal(env.messages.at(-1).status, "openCollection");
  }
});

test("mix menu follows its explicit public radio link without borrowing the playing song", () => {
  // Actual build26: Fresh is playing, but the explicitly chosen Veridis Quo menu has this public link.
  const href = "watch?v=qe8Q7mjxjig&list=RDAMVMqe8Q7mjxjig";
  const capture = (env, row) => {
    env.dispatch("click", row.querySelector("a"));
    const selection = env.messages.find(message => message.type === "selection");
    if (selection) env.window.Multimusic.receiveAck({ token: "current-document", commandId: selection.commandId,
      status: "completed", snapshot: env.snapshot });
    env.messages.length = 0;
  };
  for (const label of ["Start mix", "Start radio"]) for (const state of ["current", "disconnected", "selection", "next", "previous"]) {
    const row = song("hZmhMMmyGxg", "Fresh", { list: "RDAMVMhZmhMMmyGxg" });
    const env = start([row]);
    env.snapshot = { ...env.snapshot, sourceID: "hZmhMMmyGxg", title: "Fresh" };
    env.window.Multimusic.applySnapshot(env.snapshot);
    capture(env, row);
    if (state === "disconnected") env.window.Multimusic.applySnapshot({ ...env.snapshot, synchronized: false });
    else if (state === "selection") env.dispatch("click", row.querySelector("a"));
    else if (["next", "previous"].includes(state)) env.dispatch("click", env[state].querySelector("button"));
    env.messages.length = 0;
    const link = element("a", { href }, [element("span", {}, [], label)]);
    const item = element("ytmusic-menu-navigation-item-renderer", {}, [link]);
    (state === "current" ? env.bar : env.document.body).appendChild(item);
    assert.equal(env.dispatch("click", link.children[0]).prevented, true);
    assert.equal(env.location.href, `https://music.youtube.com/${href}`);
    assert.deepEqual(env.messages.map(message => [message.type, message.status]), [["status", "mixOpened"]]);
    assert.equal(item.children[0], link);
    assert.equal(link.getAttribute("href"), href);
    assert.equal(env.bar.querySelector(".time-info").textContent, "0:25 / 3:20");
  }
  for (const menuHref of [
    "https://other.example/watch?v=qe8Q7mjxjig&list=RDAMVMqe8Q7mjxjig",
    "https://music.youtube.com:8443/watch?v=qe8Q7mjxjig&list=RDAMVMqe8Q7mjxjig",
    "https://name:password@music.youtube.com/watch?v=qe8Q7mjxjig&list=RDAMVMqe8Q7mjxjig",
    "watch?v=bad&list=RDAMVMqe8Q7mjxjig", "watch?v=qe8Q7mjxjig",
    "watch?v=qe8Q7mjxjig&list=PLother", "watch?v=qe8Q7mjxjig&list=RD%20other",
    "watch?v=qe8Q7mjxjig&v=hZmhMMmyGxg&list=RDAMVMqe8Q7mjxjig",
    "watch?v=qe8Q7mjxjig&list=RDAMVMqe8Q7mjxjig&list=RDAMVMhZmhMMmyGxg",
    "watch?v=qe8Q7mjxjig&list=RD", `watch?v=qe8Q7mjxjig&list=RD${"a".repeat(255)}`
  ]) {
    const row = song("AAAAAAAAAAA", "Captured source", { list: "RDAMVMAAAAAAAAAAA" });
    const env = start([row]);
    env.location.href = "https://music.youtube.com/";
    capture(env, row);
    const before = env.location.href;
    const link = element("a", { href: menuHref }, [], "Start mix");
    env.document.body.appendChild(element("ytmusic-menu-navigation-item-renderer", {}, [link]));
    assert.equal(env.dispatch("click", link).prevented, true);
    assert.equal(env.location.href, before, "an invalid explicit link cannot fall back to the native song");
    assert.equal(env.messages.some(message => message.type === "selection"), false);
    assert.equal(env.messages.at(-1).status, "unsupported");
  }
  for (const block of ["none", "disconnected", "selection", "next", "previous", "different origin", "different song"]) {
    const row = song("AAAAAAAAAAA", "Current captured source", { list: "RDAMVMAAAAAAAAAAA" });
    if (block === "different origin") row.querySelector("a").setAttribute("href",
      "https://music.youtube.com:8443/watch?v=AAAAAAAAAAA&list=RDunsafe");
    const env = start([row]);
    capture(env, row);
    if (block === "disconnected") env.window.Multimusic.applySnapshot({ ...env.snapshot, synchronized: false });
    else if (block === "different song") env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: "BBBBBBBBBBB" });
    else if (block === "selection") env.dispatch("click", row.querySelector("a"));
    else if (["next", "previous"].includes(block)) env.dispatch("click", env[block].querySelector("button"));
    const before = env.location.href;
    const item = element("ytmusic-menu-service-item-renderer", {}, [element("span", {}, [], "Start mix")]);
    env.document.body.appendChild(item);
    env.messages.length = 0;
    assert.equal(env.dispatch("click", item.children[0]).prevented, true);
    assert.equal(env.location.href, block === "none" ? "https://music.youtube.com/watch?v=AAAAAAAAAAA&list=RDAMVMAAAAAAAAAAA" : before, block);
    assert.deepEqual(env.messages.map(message => [message.type, message.status]), block === "none" ? [["status", "mixOpened"]] : [["status", "unsupported"]], block);
  }
});

test("public mobile queue links select only the clicked readable occurrence and retain original queue content", () => {
  const queueRow = (id, title, artist = "Queue artist") => element("ytmusic-player-queue-item", {}, [
    element("yt-formatted-string", { class: "title" }, [element("a", { href: `watch?v=${id}&list=RDAMVM${id}` }, [], title)]),
    element("a", { href: "channel/queue-artist" }, [], artist),
    element("yt-formatted-string", { class: "duration" }, [], "3:25")
  ]);
  const rows = [queueRow("BBBBBBBBBBB", "Earlier occurrence"), queueRow("BBBBBBBBBBB", "Clicked occurrence"),
    queueRow("CCCCCCCCCCC", "Later song"), queueRow("DDDDDDDDDDD", "Missing artist", ""), queueRow("bad", "Invalid ID")];
  const unfamiliarImage = element("img", { src: "https://i.ytimg.com/vi/BBBBBBBBBBB/hq720.jpg" });
  unfamiliarImage.currentSrc = unfamiliarImage.getAttribute("src");
  rows[1].appendChild(unfamiliarImage);
  const env = start();
  env.location.href = "https://music.youtube.com/watch?v=AAAAAAAAAAA&list=RDAMVMAAAAAAAAAAA";
  const expanded = element("ytmusic-player-page", {}, [element("ytmusic-player-queue", {}, rows)]);
  env.document.body.appendChild(expanded);
  const target = rows[1].querySelector("a");
  assert.equal(env.dispatch("click", target).prevented, true);
  assert.deepEqual(env.messages[0].tracks, [{ id: "BBBBBBBBBBB", title: "Clicked occurrence", artist: "Queue artist", duration: 205 }]);
  assert.equal(env.messages[0].context.kind, "radio");
  assert.equal(env.messages[0].context.selectedSourceID, "BBBBBBBBBBB");
  env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: "BBBBBBBBBBB", title: "Native title", artist: "Native artist", position: 40 });
  assert.equal(target.textContent, "Clicked occurrence");
  assert.equal(target.getAttribute("href"), "watch?v=BBBBBBBBBBB&list=RDAMVMBBBBBBBBBBB");
  assert.equal(rows[1].querySelector(".duration").textContent, "3:25");
  env.messages.length = 0;
  for (const row of rows.slice(3)) env.dispatch("click", row.querySelector("a"));
  assert.equal(env.messages.some(message => message.type === "selection"), false);
  assert.equal(env.messages.at(-1).status, "unreadable");
});

test("actual radio Up Next metadata and public thumbnails identify only the deliberately clicked row", () => {
  const observed = [
    ["eNWfAvwxiCE", "Попытка №5", "ВИА ГРА", "3:25", 205],
    ["Tn-z95ev64s", "КатяЛель-Моймармеладный", "MAXIMFADEEV", "3:21", 201],
    ["MjLmxN7XdSA", "Ева", "Vintazh", "4:10", 250]
  ];
  for (const selected of [0, 1, 2]) {
    const rows = observed.map(([id, title, artist, duration], index) => radioQueueRow(id, title, artist, duration, { play: index === selected }));
    const env = startRadioQueue(rows);
    const target = rows[selected].querySelector("ytmusic-play-button-renderer");
    const children = rows[selected].children.slice();
    assert.equal(env.dispatch("click", target).prevented, true);
    const selections = env.messages.filter(message => message.type === "selection");
    assert.equal(selections.length, 1);
    const [id, title, artist, , duration] = observed[selected];
    assert.deepEqual(selections[0].tracks, [{ id, title, artist, duration }]);
    assert.equal(selections[0].context.kind, "radio");
    assert.equal(selections[0].context.selectedSourceID, id);
    env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: id, title: "Native matched title", artist: "Native artist", position: 35 });
    assert.deepEqual(rows[selected].children, children);
    assert.equal(rows[selected].querySelector(".song-title").textContent, title);
    assert.equal(rows[selected].querySelector(".byline").textContent, artist);
    assert.equal(rows[selected].querySelector(".duration").textContent, observed[selected][3]);
    assert.equal(rows[selected].querySelector("img").getAttribute("src"), `https://i.ytimg.com/vi/${id}/hqdefault.jpg`);
  }
});

test("radio thumbnail inference rejects uncertain identity or missing recording metadata and leaves menus alone", () => {
  for (const bad of ["host", "unknown path", "bad ID", "conflicting images", "stale currentSrc", "conflicting watch link", "missing title", "missing artist", "missing duration", "invalid duration"]) {
    const row = radioQueueRow("eNWfAvwxiCE", "Попытка №5", "ВИА ГРА", "3:25", { play: true });
    const image = row.querySelector("img");
    if (bad === "host") { image.currentSrc = "https://other.example/vi/eNWfAvwxiCE/hqdefault.jpg"; image.setAttribute("src", image.currentSrc); }
    if (bad === "unknown path") { image.currentSrc = "https://i.ytimg.com/vi_webp/eNWfAvwxiCE/hqdefault.webp"; image.setAttribute("src", image.currentSrc); }
    if (bad === "bad ID") { image.currentSrc = "https://i.ytimg.com/vi/bad/hqdefault.jpg"; image.setAttribute("src", image.currentSrc); }
    if (bad === "conflicting images") row.appendChild(element("img", { src: "https://i.ytimg.com/vi/MjLmxN7XdSA/hqdefault.jpg" }));
    if (bad === "stale currentSrc") image.currentSrc = "https://i.ytimg.com/vi/MjLmxN7XdSA/hqdefault.jpg";
    if (bad === "conflicting watch link") row.appendChild(element("a", { href: "/watch?v=MjLmxN7XdSA" }, [], "Other recording"));
    if (bad === "missing title") row.querySelector(".song-title").textContent = "";
    if (bad === "missing artist") row.querySelector(".byline").textContent = "";
    if (bad === "missing duration") row.querySelector(".duration").textContent = "";
    if (bad === "invalid duration") row.querySelector(".duration").textContent = "3:99";
    const env = startRadioQueue([row]);
    assert.equal(env.dispatch("click", row.querySelector("ytmusic-play-button-renderer")).prevented, true, bad);
    assert.equal(env.messages.some(message => message.type === "selection"), false, bad);
    assert.equal(env.messages.at(-1).status, "unreadable", bad);
  }
  const row = radioQueueRow("eNWfAvwxiCE", "Попытка №5", "ВИА ГРА", "3:25");
  const action = element("button", { "aria-label": "Action menu" });
  row.appendChild(element("ytmusic-menu-renderer", {}, [action]));
  const env = startRadioQueue([row]);
  assert.equal(env.dispatch("click", action).prevented, false);
  assert.equal(env.dispatch("click", row.querySelector(".song-title")).prevented, false);
  assert.equal(env.dispatch("click", row.querySelector(".byline")).prevented, false);
  assert.equal(env.dispatch("click", row.querySelector("img")).prevented, false);
  assert.equal(env.messages.length, 0);
  for (const src of ["https://i.ytimg.com/vi/eNWfAvwxiCE/hqdefault.jpg", "https://i.ytimg.com/vi/eNWfAvwxiCE/hq720.jpg", "https://other.example/unknown.jpg"]) {
    const linked = radioQueueRow("eNWfAvwxiCE", "Попытка №5", "ВИА ГРА", "", { play: true, src });
    linked.appendChild(element("a", { href: "/watch?v=eNWfAvwxiCE" }, [], "Public song link"));
    const existingLinked = startRadioQueue([linked]);
    existingLinked.dispatch("click", linked.querySelector("ytmusic-play-button-renderer"));
    assert.deepEqual(existingLinked.messages[0].tracks, [{ id: "eNWfAvwxiCE", title: "Попытка №5", artist: "ВИА ГРА" }]);
  }
});

test("original play/pause, previous, next and seek send distinct intentional native commands", () => {
  const env = start();
  env.dispatch("click", env.play.querySelector("button"));
  env.window.Multimusic.applySnapshot({ ...env.snapshot, state: "playing" });
  env.dispatch("click", env.play.querySelector("button"));
  env.dispatch("click", env.previous.querySelector("button"));
  env.dispatch("click", env.next.querySelector("button"));
  env.dispatch("pointerdown", env.slider, { clientX: 50 });
  env.dispatch("pointerup", env.slider, { clientX: 100 });
  assert.deepEqual(env.messages.map(message => [message.command, message.position]), [
    ["play", undefined], ["pause", undefined], ["previous", undefined], ["next", undefined], ["seek", 100]
  ]);
  assert.deepEqual(env.messages.map(message => message.sequence), [2, 3, 4, 5, 6]);
});

test("synthetic events and unsynchronized skips cannot play, while explicit Play reaches native ownership checks", () => {
  const row = song("AAAAAAAAAAA", "One");
  const env = start([row], { synchronized: false });
  env.dispatch("click", row.querySelector("a"), { isTrusted: false });
  env.dispatch("click", env.next.querySelector("button"));
  env.dispatch("click", env.play.querySelector("button"));
  env.window.Multimusic.applySnapshot({ ...env.snapshot, title: "External Music change", position: 50 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.command), ["play"]);
  assert.equal(env.messages.some(message => message.type === "selection"), false);
  assert.equal(env.messages[0].status, "choose");
  assert.equal(env.bar.querySelector(".title").textContent, "External Music change");
});

test("snapshots paint original title, artist, pause icon, progress and accessible seek position without feedback", () => {
  const env = start([song("AAAAAAAAAAA", "One")]);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, position: 60, state: "playing" });
  assert.equal(env.bar.querySelector(".title").textContent, "Apple matched recording");
  assert.equal(env.artist.textContent, "Apple artist");
  assert.equal(env.bar.querySelector(".title").getAttribute("is-empty"), null);
  assert.equal(env.bar.querySelector(".time-info").textContent, "1:00 / 3:20");
  assert.equal(env.play.querySelector("button").getAttribute("aria-label"), "Pause");
  assert.equal(env.slider.getAttribute("aria-valuenow"), "60");
  assert.equal(env.slider.querySelector("#primaryProgress").style.transform, "scaleX(0.3)");
  assert.equal(env.messages.length, 0);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, duration: Infinity, title: "Bad snapshot" });
  assert.equal(env.bar.querySelector(".title").textContent, "Apple matched recording");
});

test("prepared Play and Pause repaint controls without rereading unchanged song metadata", () => {
  const env = start();
  const title = env.bar.querySelector(".title");
  const image = env.bar.querySelector("img");
  const descriptor = Object.getOwnPropertyDescriptor(env.Element.prototype, "textContent");
  let reads = 0;
  for (const node of [title, env.artist]) Object.defineProperty(node, "textContent", {
    get() { reads++; return descriptor.get.call(this); },
    set(value) { descriptor.set.call(this, value); }
  });
  let revision = 0;
  for (const state of ["playing", "paused"]) {
    env.dispatch("click", env.play);
    assert.equal(env.play.querySelector("button").getAttribute("aria-label"), state === "playing" ? "Pause" : "Play");
    assert.equal(env.play.getAttribute("aria-busy"), "true");
    const request = env.messages.findLast(message => message.type === "command");
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: request.commandId, status: "completed",
      snapshot: { ...env.snapshot, state, revision: ++revision } });
    assert.equal(env.play.getAttribute("aria-busy"), "false");
  }
  assert.equal(reads, 0, "a control-only change must not revisit title or artist text");
  env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: "BBBBBBBBBBB", title: "Next recording", artist: "Next artist", revision: ++revision });
  assert.equal(title.textContent, "Next recording");
  assert.equal(env.artist.textContent, "Next artist");
  assert.equal(image.getAttribute("src"), "https://i.ytimg.com/vi/BBBBBBBBBBB/hqdefault.jpg");
});

test("a website metadata empty flag is repaired before subsequent control-only changes", () => {
  const env = start();
  const title = env.bar.querySelector(".title");
  for (const node of [title, env.artist]) {
    node.setAttribute("is-empty", "");
    env.mutate([{ type: "attributes", target: node, attributeName: "is-empty" }]);
  }
  env.dispatch("click", env.play);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, state: "playing", revision: 1 });
  assert.equal(title.getAttribute("is-empty"), null);
  assert.equal(env.artist.getAttribute("is-empty"), null);
  assert.equal(title.textContent, env.snapshot.title);
  assert.equal(env.artist.textContent, env.snapshot.artist);
  assert.equal(env.play.querySelector("button").getAttribute("aria-label"), "Pause");
});

test("the actual visible player artwork stays associated with native playback after website changes or a rejected selection", () => {
  const row = song("BBBBBBBBBBB", "Rejected replacement", { list: null });
  const env = fixture([row]);
  const image = element("img", { id: "img", class: "style-scope yt-img-shadow", src: "https://yt3.googleusercontent.com/website-art" });
  const thumbnail = element("yt-img-shadow", { id: "thumbnail", class: "thumbnail style-scope ytmusic-player no-transition" }, [image]);
  const songImage = element("div", { id: "song-image" }, [thumbnail]);
  const player = element("ytmusic-player", { id: "player" }, [songImage]);
  const wrapper = element("div", { id: "main-panel" }, [element("div", { id: "music-player-wrapper" }, [player])]);
  const unrelated = element("img", { class: "image", src: "unrelated-row-art.jpg" });
  row.appendChild(unrelated);
  env.document.body.appendChild(wrapper);
  vm.runInNewContext(script, env);
  const native = { ...env.snapshot, sourceID: "w8lFQ1_E7Gc", diagnosticsEnabled: true };
  const expected = "https://i.ytimg.com/vi/w8lFQ1_E7Gc/hqdefault.jpg";
  env.window.Multimusic.activate("current-document", native);
  assert.equal(image.getAttribute("src"), expected);
  env.dispatch("click", row.querySelector("a"));
  const selection = env.messages.find(message => message.type === "selection");
  image.setAttribute("src", "https://yt3.googleusercontent.com/rejected-art");
  image.setAttribute("srcset", "https://yt3.googleusercontent.com/rejected-art 2x");
  env.mutate([{ type: "attributes", target: image, attributeName: "srcset" }]);
  assert.equal(image.getAttribute("src"), expected);
  assert.equal(image.getAttribute("srcset"), null);
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: selection.commandId, status: "rejected", reason: "noMatch",
    snapshot: { ...native, revision: 1 } });
  assert.equal(env.bar.querySelector(".title").textContent, native.title);
  assert.equal(image.getAttribute("src"), expected);
  assert.equal(image.parentElement, thumbnail);
  assert.equal(thumbnail.parentElement, songImage);
  assert.equal(unrelated.getAttribute("src"), "unrelated-row-art.jpg");
  const replacement = element("img", { id: "img", src: "https://yt3.googleusercontent.com/changed-node" });
  thumbnail.replaceChild(replacement, image);
  env.mutate([{ type: "childList", target: thumbnail, addedNodes: [replacement], removedNodes: [image] }]);
  assert.equal(replacement.getAttribute("src"), expected);
  env.advance(1000);
  assert.equal(env.messages.find(message => message.event === "web.aggregate").fields.progressRowsScanned, "0");
  env.window.Multimusic.applySnapshot({ ...native, sourceID: null, revision: 2 });
  assert.equal(replacement.hidden, true, "unidentified website art must not stand for a native recording");
  env.window.Multimusic.applySnapshot({ ...native, revision: 3 });
  assert.equal(replacement.hidden, false);
  assert.equal(replacement.getAttribute("src"), expected);
});

test("a cold original video-mode player paints its poster and nonempty artist without initializing website playback", () => {
  const env = fixture();
  env.artist.setAttribute("is-empty", "");
  const video = element("video", { class: "video-stream html5-main-video", src: "website-video-stream" });
  let plays = 0;
  video.play = () => { plays++; };
  video.currentTime = 0;
  const movie = element("div", { id: "movie_player", class: "unstarted-mode paused-mode" }, [video]);
  const songVideo = element("div", { id: "song-video" }, [movie]); songVideo.style.display = "block";
  const image = element("img", { id: "img" });
  const songImage = element("div", { id: "song-image" }, [element("yt-img-shadow", { id: "thumbnail" }, [image])]); songImage.style.display = "none";
  const player = element("ytmusic-player", { id: "player", "video-mode": "" }, [songVideo, songImage]);
  const unrelated = element("video", { class: "video-stream html5-main-video", poster: "unrelated-poster.jpg" });
  env.document.body.appendChild(player); env.document.body.appendChild(unrelated);
  vm.runInNewContext(script, env);
  const native = { ...env.snapshot, sourceID: "CCCCCCCCCCC", title: "Around the World", artist: "Daft Punk" };
  const expected = "https://i.ytimg.com/vi/CCCCCCCCCCC/hqdefault.jpg";
  env.window.Multimusic.activate("current-document", native);
  assert.equal(env.artist.getAttribute("is-empty"), null);
  assert.equal(env.artist.textContent, native.artist);
  assert.equal(video.getAttribute("poster"), expected);
  assert.equal(image.getAttribute("src"), expected);
  assert.equal(video.getAttribute("src"), "website-video-stream");
  assert.equal(video.currentTime, 0);
  assert.equal(plays, 0);
  assert.equal(player.getAttribute("video-mode"), "");
  assert.equal(movie.getAttribute("class"), "unstarted-mode paused-mode");
  assert.equal(songImage.style.display, "none");
  assert.equal(songVideo.style.display, "block");
  assert.equal(video.parentElement, movie);
  assert.equal(unrelated.getAttribute("poster"), "unrelated-poster.jpg");
  video.setAttribute("poster", "wrong-website-poster.jpg");
  env.mutate([{ type: "attributes", target: video, attributeName: "poster" }]);
  assert.equal(video.getAttribute("poster"), expected);
  let queries = 0;
  const query = env.document.querySelectorAll.bind(env.document);
  env.document.querySelectorAll = selector => { queries++; return query(selector); };
  env.window.Multimusic.applySnapshot({ ...native, position: 26, revision: 1 });
  assert.equal(queries, 0, "progress does not rediscover player artwork or scan rows");
  const replacement = element("video", { class: "video-stream html5-main-video", src: "new-website-video-stream" });
  movie.replaceChild(replacement, video);
  env.mutate([{ type: "childList", target: movie, addedNodes: [replacement], removedNodes: [video] }]);
  assert.equal(replacement.getAttribute("poster"), expected);
  assert.equal(replacement.getAttribute("src"), "new-website-video-stream");
  env.window.Multimusic.applySnapshot({ ...native, sourceID: null, revision: 2 });
  assert.equal(replacement.getAttribute("poster"), null);
});

test("a real search top card uses its own subtitle duration and artist, excluding More From YouTube rows", () => {
  for (const duration of ["7:10", ""]) {
    const title = element("yt-formatted-string", { class: "title" }, [element("a", { href: "watch?v=CCCCCCCCCCC" }, [], "Around the World")]);
    const artist = element("a", { href: "channel/daft-punk" }, [], "Daft Punk");
    const subtitle = element("yt-formatted-string", { class: "subtitle" }, [element("span", {}, [], "Song • "), artist,
      element("span", { class: "style-scope yt-formatted-string" }, [], duration ? " • " + duration : "")]);
    const nested = song("DDDDDDDDDDD", "More From YouTube", { artist: "Unrelated nested artist", duration: "0:41", list: null });
    const card = element("ytmusic-card-shelf-renderer", {}, [title, element("div", { class: "subtitle-container" }, [subtitle]), nested,
      element("a", { href: "channel/unrelated-recommendation" }, [], "Other recommendation artist"),
      element("ytmusic-play-button-renderer", { "aria-label": "Play Around the World" })]);
    const env = start([card]);
    env.location.href = "https://music.youtube.com/search?q=public-test";
    env.dispatch("click", card.querySelector("ytmusic-play-button-renderer"));
    const selection = env.messages.find(message => message.type === "selection");
    assert.deepEqual(selection.tracks, [{ id: "CCCCCCCCCCC", title: "Around the World", artist: "Daft Punk", ...(duration ? { duration: 430 } : {}) }]);
    assert.equal(selection.context.kind, "search");
    assert.equal(nested.querySelector(".title").textContent, "More From YouTube");
    assert.equal(subtitle.children[1], artist);
  }
});

test("the actual direct search-card Play button selects its own song while Save, menus and nested controls retain their actions", () => {
  for (const activation of ["click", "icon-click", "touch", "keyboard", "save", "menu", "nested", "wrong-parent", "artist"]) {
    const button = element("button", { class: "ytSpecButtonShapeNextHost", "aria-label": activation === "save" ? "Save" : "Play" }, [element("span", {}, [], "Play")]);
    const shape = element("yt-button-shape", {}, [button]);
    const renderer = element("yt-button-renderer", { class: "style-scope ytmusic-card-shelf-renderer" }, [shape]);
    const actions = element("div", { id: "actions", class: "actions-container style-scope ytmusic-card-shelf-renderer" }, [renderer]);
    const artist = element("a", { href: "channel/daft-punk" }, [], "Daft Punk");
    const title = element("yt-formatted-string", { class: "title" }, [element("a", { href: "watch?v=CCCCCCCCCCC" }, [], "Around the World")]);
    const subtitle = element("yt-formatted-string", { class: "subtitle" }, [element("span", {}, [], "Song • "), artist, element("span", {}, [], " • 7:10")]);
    const card = element("ytmusic-card-shelf-renderer", {}, [element("div", { class: "main-card-container style-scope ytmusic-card-shelf-renderer" },
      [title, element("div", { class: "subtitle-container" }, [subtitle]), actions])]);
    if (activation === "menu") {
      const menu = element("ytmusic-menu-renderer"); actions.replaceChild(menu, renderer); menu.appendChild(renderer);
    }
    if (activation === "nested") {
      const nested = song("DDDDDDDDDDD", "Nested recommendation"); card.appendChild(nested);
      actions.children = []; nested.appendChild(renderer);
    }
    if (activation === "wrong-parent") actions.setAttribute("id", "unrelated-actions");
    const env = start([card]);
    let event;
    if (activation === "touch") {
      const point = { identifier: 1, clientX: 50, clientY: 50 };
      env.dispatch("touchstart", button.children[0], { touches: [point], changedTouches: [point] });
      event = env.dispatch("touchend", button.children[0], { touches: [], changedTouches: [point] });
    } else if (activation === "keyboard") event = env.dispatch("keydown", button, { key: "Enter" });
    else event = env.dispatch("click", activation === "artist" ? artist : activation === "icon-click" ? button.children[0] : button);
    const selections = env.messages.filter(message => message.type === "selection");
    const supported = ["click", "icon-click", "touch", "keyboard"].includes(activation);
    assert.equal(selections.length, supported ? 1 : 0, activation);
    assert.equal(event.prevented, supported, activation);
    if (supported) assert.deepEqual(selections[0].tracks, [{ id: "CCCCCCCCCCC", title: "Around the World", artist: "Daft Punk", duration: 430 }]);
    assert.equal(button.parentElement, shape);
    assert.equal(shape.parentElement, renderer);
    assert.equal(subtitle.children[1], artist);
  }
});

test("keyboard seeking clamps at the native duration and typing space does not play", () => {
  const env = start();
  env.window.Multimusic.applySnapshot({ ...env.snapshot, position: 198 });
  env.dispatch("keydown", env.slider, { key: "ArrowRight" });
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: env.messages.at(-1).commandId, status: "completed" });
  env.advance(800);
  env.dispatch("keydown", env.slider, { key: "Home" });
  env.dispatch("keydown", element("input"), { key: " " });
  assert.deepEqual(env.messages.map(message => message.position), [200, 0]);
});

test("a foreign document cannot install the bridge", () => {
  const env = start([], { host: "accounts.google.com" });
  assert.equal(env.window.Multimusic, undefined);
  assert.equal(env.messages.length, 0);
});

test("interrupted or cancelled seek gestures cannot turn a later pointerup into a command", () => {
  for (const interruption of ["blur", "pointercancel", "pagehide"]) {
    const env = start();
    env.dispatch("pointerdown", env.slider);
    assert.equal(env.slider.hasPointerCapture(1), true);
    env.dispatch(interruption, env.slider);
    env.dispatch("pointerup", env.slider, { clientX: 100 });
    assert.equal(env.slider.hasPointerCapture(1), false);
    assert.equal(env.messages.length, 0);
  }
});

test("opt-in diagnostics send numeric aggregates once a second and stop immediately when disabled", () => {
  const env = start([song("AAAAAAAAAAA", "Private-looking song text")]);
  env.advance(1000);
  assert.equal(env.messages.length, 0);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: true });
  env.dispatch("click", env.play.querySelector("button"));
  env.advance(999);
  assert.equal(env.messages.filter(message => message.type === "diagnostic").length, 0);
  env.advance(1);
  const aggregate = env.messages.find(message => message.type === "diagnostic");
  assert.equal(aggregate.event, "web.aggregate");
  assert.equal(Number(aggregate.fields.renders) > 0, true);
  assert.equal(aggregate.fields.rowsScanned, "0");
  assert.equal(aggregate.fields.intents, "1");
  assert.equal(aggregate.fields.aggregateRoot, "ytmusic-player-bar");
  assert.equal(Object.entries(aggregate.fields).filter(([key]) => key !== "aggregateRoot")
    .every(([, value]) => Number.isFinite(Number(value))), true);
  assert.equal(JSON.stringify(aggregate).includes("Private-looking"), false);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: false });
  env.advance(2000);
  assert.equal(env.messages.filter(message => message.type === "diagnostic").length, 1);
});

function frameTimingEnvironment() {
  const env = fixture([], { manualFrames: true });
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", { ...env.snapshot, diagnosticsEnabled: true });
  env.frame();
  env.messages.length = 0;
  return env;
}
const timingAggregates = env => env.messages.filter(message => message.event === "web.aggregate" && message.fields.commandId);

test("command timing retains the trusted handler origin across retries and waits for native-confirmed rendered frames", () => {
  const env = frameTimingEnvironment();
  for (const node of [env.bar, env.play, env.play.querySelector("button"), env.next, env.previous, env.slider])
    node.rect = { left: 123456789.12, top: 234567891.23, width: 345678912.34, height: 456789123.45 };
  env.dispatch("click", env.play.querySelector("button"));
  const command = env.messages.find(message => message.type === "command");
  env.frame();
  assert.equal(env.play.querySelector("button").getAttribute("aria-label"), "Pause");
  env.frame();
  env.advance(1000);
  assert.equal(timingAggregates(env).length, 0, "an optimistic icon is not a completed command");
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.commandId), [command.commandId, command.commandId]);
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed",
    snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 1, state: "playing" } });
  env.frame();
  assert.equal(timingAggregates(env).length, 0, "DOM writes alone do not establish a later frame opportunity");
  env.frame();
  env.advance(1000);
  const [sample] = timingAggregates(env);
  assert.equal(sample.fields.commandId, command.commandId);
  assert.equal(sample.fields.commandStartedMs, "16");
  assert.equal(sample.fields.feedbackFrameMs, "32");
  assert.equal(sample.fields.completedFrameMs, "1064");
  assert.equal(sample.fields.commandFrameOutcome, "1");
  assert.equal(Object.keys(sample.fields).length + 1 <= 48, true, "native documentId also consumes one field");
  assert.equal(Buffer.byteLength(JSON.stringify({ ...sample.fields, documentId: "d".repeat(32) })) <= 1024, true);
});

test("a fast native acknowledgement between frame callbacks is measured after its own matching render", () => {
  const env = frameTimingEnvironment();
  env.dispatch("click", env.play.querySelector("button"));
  const command = env.messages.find(message => message.type === "command");
  env.frame();
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed",
    snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 1, state: "playing" } });
  env.frame(); env.frame(); env.advance(1000);
  const [sample] = timingAggregates(env);
  assert.equal(sample.fields.commandFrameOutcome, "1");
  assert.equal(Number(sample.fields.completedFrameMs) >= 48, true);
});

test("a completed command can use an already newer matching snapshot without accepting stale conflicts or seek drift", () => {
  for (const scenario of ["play", "pause", "seek", "wrong-state", "wrong-source", "invalid-ack", "seek-drift"]) {
    const env = frameTimingEnvironment();
    const seeking = scenario.startsWith("seek");
    if (scenario === "pause") {
      env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: true, state: "playing", revision: 1 });
      env.frame();
    }
    if (seeking) env.dispatch("keydown", env.slider, { key: "ArrowRight" });
    else env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.find(message => message.type === "command");
    const wanted = command.command === "play" ? "playing" : "paused";
    const ack = { ...env.snapshot, diagnosticsEnabled: true, state: wanted, revision: 2,
      position: seeking ? command.position + 0.1 : 25.1 };
    const current = { ...ack, revision: 3, position: seeking ? command.position + (scenario === "seek-drift" ? 2 : 0.25) : 25.2 };
    if (scenario === "wrong-state") current.state = "paused";
    if (scenario === "wrong-source") current.sourceID = "BBBBBBBBBBB";
    if (scenario === "invalid-ack") ack.duration = NaN;
    env.window.Multimusic.applySnapshot(current);
    env.frame();
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed", snapshot: ack });
    env.frame(); env.frame(); env.advance(1000);
    const [sample] = timingAggregates(env);
    const valid = ["play", "pause", "seek"].includes(scenario);
    assert.equal(sample.fields.commandFrameOutcome, valid ? "1" : "6", scenario);
    assert.equal("completedFrameMs" in sample.fields, valid, scenario);
    assert.equal(env.slider.getAttribute("aria-valuenow"), String(current.position), "an old acknowledgement must not rewind the current snapshot");
    assert.equal(env.window.Multimusic.applySnapshot({ ...current, revision: 2 }).accepted, false);
  }
});

test("newer intent and stale completion cannot turn superseded optimistic controls into successful timing samples", () => {
  const env = frameTimingEnvironment();
  env.dispatch("click", env.play.querySelector("button"));
  const first = env.messages.find(message => message.type === "command");
  env.frame();
  env.dispatch("click", env.play.querySelector("button"));
  const second = env.messages.filter(message => message.type === "command").at(-1);
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: first.commandId, status: "completed",
    snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 2, state: "playing" } });
  env.frame(); env.frame();
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: second.commandId, status: "completed",
    snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 1, state: "paused" } });
  env.frame(); env.frame();
  env.advance(1000); env.advance(1000);
  const samples = timingAggregates(env);
  assert.deepEqual(samples.map(sample => [sample.fields.commandId, sample.fields.commandFrameOutcome]),
    [[first.commandId, "4"], [second.commandId, "6"]]);
  assert.equal(samples.some(sample => "completedFrameMs" in sample.fields), false);
});

test("hidden controls, disabled diagnostics and document replacement invalidate delayed frame opportunities", () => {
  for (const interruption of ["hidden", "hidden-return", "detached", "off", "navigation"]) {
    const env = frameTimingEnvironment();
    env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.find(message => message.type === "command");
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed",
      snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 1, state: "playing" } });
    env.frame();
    if (interruption === "hidden") env.document.visibilityState = "hidden";
    if (interruption === "hidden-return") {
      env.document.visibilityState = "hidden"; env.dispatch("visibilitychange", env.document);
      env.document.visibilityState = "visible"; env.dispatch("visibilitychange", env.document);
    }
    if (interruption === "detached") env.document.body.children = env.document.body.children.filter(child => child !== env.bar);
    if (interruption === "off") env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: false, revision: 2 });
    if (interruption === "navigation") {
      env.dispatch("pagehide", env.bar);
      env.window.Multimusic.activate("new-document", { ...env.snapshot, diagnosticsEnabled: true });
    }
    env.frame(); env.frame(); env.advance(1000);
    const samples = timingAggregates(env);
    if (["hidden", "hidden-return", "detached"].includes(interruption)) {
      assert.equal(samples.length, 1);
      assert.equal(samples[0].fields.commandFrameOutcome, "5");
      assert.equal("completedFrameMs" in samples[0].fields, false);
      assert.equal("feedbackFrameMs" in samples[0].fields, false);
    } else assert.equal(samples.length, 0, interruption);
    if (interruption === "off") assert.equal(env.messages.some(message => message.type === "diagnostic"), false);
  }
});

test("seek completion measures its matching native snapshot without calling an accessible busy flag visible feedback", () => {
  const env = frameTimingEnvironment();
  env.dispatch("keydown", env.slider, { key: "ArrowRight" });
  const command = env.messages.find(message => message.type === "command");
  assert.equal(command.command, "seek");
  env.frame(); env.frame();
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed",
    snapshot: { ...env.snapshot, diagnosticsEnabled: true, position: command.position, revision: 1 } });
  env.frame(); env.frame(); env.advance(1000);
  const [sample] = timingAggregates(env);
  assert.equal(sample.fields.commandFrameOutcome, "1");
  assert.equal(Number(sample.fields.completedFrameMs) > 0, true);
  assert.equal("feedbackFrameMs" in sample.fields, false);
});

test("native completion with the wrong requested state or changed visible content is not successful frame proof", () => {
  for (const invalidation of ["wrong-state", "title", "icon", "seek"]) {
    const env = frameTimingEnvironment();
    if (invalidation === "seek") env.dispatch("keydown", env.slider, { key: "ArrowRight" });
    else env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.find(message => message.type === "command");
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "completed",
      snapshot: { ...env.snapshot, diagnosticsEnabled: true, revision: 1,
        state: ["wrong-state", "seek"].includes(invalidation) ? "paused" : "playing",
        position: invalidation === "seek" ? command.position : env.snapshot.position } });
    env.frame();
    if (invalidation === "title") env.bar.querySelector(".title").textContent = "Website changed the visible song";
    if (invalidation === "icon") env.play.querySelector("path").setAttribute("d", "M0 0h1v1z");
    if (invalidation === "seek") env.slider.setAttribute("aria-valuenow", 0);
    env.frame(); env.advance(1000);
    const [sample] = timingAggregates(env);
    assert.equal(sample.fields.commandFrameOutcome, "5", invalidation);
    assert.equal("completedFrameMs" in sample.fields, false, invalidation);
  }
});

test("timing backlog is bounded, drains one sample per aggregate and reports discarded samples once", () => {
  const env = frameTimingEnvironment();
  const ids = [];
  for (let index = 0; index < 129; index++) {
    env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.filter(message => message.type === "command").at(-1);
    ids.push(command.commandId);
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "rejected" });
  }
  env.advance(1000);
  let samples = timingAggregates(env);
  assert.equal(samples.length, 1);
  assert.equal(samples[0].fields.commandId, ids[1]);
  assert.equal(samples[0].fields.commandTimingDroppedCount, "1");
  assert.equal(samples[0].fields.commandFrameOutcome, "2");
  env.advance(1000);
  samples = timingAggregates(env);
  assert.equal(samples.length, 2);
  assert.equal(samples[1].fields.commandId, ids[2]);
  assert.equal(samples[1].fields.commandTimingDroppedCount, "0");
  assert.equal(samples.every(sample => Object.keys(sample.fields).length + 1 <= 48), true);
});

test("rejected and unanswered commands retain feedback timing without a completed-frame sample", () => {
  for (const rejected of [true, false]) {
    const env = frameTimingEnvironment();
    env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.find(message => message.type === "command");
    env.frame(); env.frame();
    if (rejected) env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "rejected" });
    else env.advance(8001);
    env.advance(1000);
    const [sample] = timingAggregates(env);
    assert.equal(sample.fields.commandId, command.commandId);
    assert.equal(sample.fields.commandFrameOutcome, rejected ? "2" : "3");
    assert.equal(sample.fields.feedbackFrameMs, "32");
    assert.equal("completedFrameMs" in sample.fields, false);
  }
});

test("raw timing budget counts survive aggregate rounding without per-render events", () => {
  const env = fixture();
  let time = 0, renderCost = 3.999;
  env.performance.now = () => time;
  const clock = env.bar.querySelector(".time-info");
  Object.defineProperty(clock, "textContent", {
    get() { time += renderCost; renderCost = 0; return this._text; },
    set(value) { this._text = String(value); }
  });
  vm.runInNewContext(script, env);
  const native = { ...env.snapshot, diagnosticsEnabled: true };
  env.window.Multimusic.activate("current-document", native);
  renderCost = 4.125;
  env.window.Multimusic.applySnapshot({ ...native, position: 26, revision: 1 });
  renderCost = 50.001;
  env.window.Multimusic.applySnapshot({ ...native, position: 27, revision: 2 });
  assert.equal(env.messages.filter(message => message.type === "diagnostic").length, 0);
  env.advance(1000);
  const aggregate = env.messages.find(message => message.type === "diagnostic");
  assert.equal(aggregate.fields.renders, "3");
  assert.equal(aggregate.fields.renderAtLeast4Count, "2");
  assert.equal(aggregate.fields.adapterTaskMaxMs, "50");
  assert.equal(aggregate.fields.adapterOver50Count, "1");
  assert.equal(aggregate.fields.progressRenders, "2");
  assert.equal(aggregate.fields.progressRowsScanned, "0");
  assert.equal(env.messages.filter(message => message.type === "diagnostic").length, 1);
});

test("render diagnostics include the cost of an early missing-player return", () => {
  const env = fixture();
  env.document.body.children = env.document.body.children.filter(child => child !== env.bar);
  let time = 0, queryCost = 6;
  env.performance.now = () => time;
  const query = env.document.querySelectorAll.bind(env.document);
  env.document.querySelectorAll = selector => { time += queryCost; queryCost = 0; return query(selector); };
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", { ...env.snapshot, diagnosticsEnabled: true });
  env.advance(1000);
  const fields = env.messages.find(message => message.type === "diagnostic").fields;
  assert.equal(fields.renders, "1");
  assert.equal(fields.renderTotalMs, "6");
  assert.equal(fields.renderMaxMs, "6");
  assert.equal(fields.renderAtLeast4Count, "1");
});

test("adapter task timing covers slow song capture without charging its cost to render", () => {
  const row = song("AAAAAAAAAAA", "Selected");
  const env = fixture([row]);
  let time = 0, captureCost = 0;
  env.performance.now = () => time;
  const target = row.querySelector("a"), query = row.querySelector.bind(row);
  row.querySelector = selector => { time += captureCost; captureCost = 0; return query(selector); };
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", { ...env.snapshot, diagnosticsEnabled: true });
  captureCost = 70;
  env.dispatch("click", target);
  env.advance(1000);
  const fields = env.messages.find(message => message.type === "diagnostic").fields;
  assert.equal(fields.adapterTaskMaxMs, "70");
  assert.equal(fields.adapterOver50Count, "1");
  assert.equal(fields.renderMaxMs, "0");
});

test("rapid toggles retain the latest intent across retries, delayed acknowledgements and older snapshots", () => {
  for (const order of [[0, 1], [1, 0]]) {
    const env = start();
    env.window.Multimusic.applySnapshot({ ...env.snapshot, state: "playing", revision: 1 });
    env.dispatch("click", env.play.querySelector("button"));
    env.dispatch("click", env.play.querySelector("button"));
    assert.deepEqual(env.messages.map(message => message.command), ["pause", "play"]);
    const [pause, play] = env.messages;
    assert.match(pause.commandId, /^[a-f0-9]{32}$/);
    assert.notEqual(pause.commandId, play.commandId);
    env.advance(1000);
    assert.deepEqual(env.messages.slice(2).map(message => message.commandId), [pause.commandId, play.commandId]);
    const acknowledgements = [
      { token: "current-document", commandId: pause.commandId, status: "completed", snapshot: { ...env.snapshot, revision: 2, state: "paused" } },
      { token: "current-document", commandId: play.commandId, status: "completed", snapshot: { ...env.snapshot, revision: 3, state: "playing" } }
    ];
    for (const index of order) {
      env.window.Multimusic.receiveAck(acknowledgements[index]);
      assert.equal(env.play.querySelector("button").getAttribute("aria-label"), "Pause");
    }
    assert.equal(env.window.Multimusic.applySnapshot({ ...env.snapshot, revision: 2 }).accepted, false);
    assert.equal(env.play.querySelector("button").getAttribute("aria-label"), "Pause");
    const count = env.messages.length;
    env.advance(2000);
    assert.equal(env.messages.length, count);
  }
});

test("a rejected unmatched selection reports failure while retaining native authority over the previous queue", () => {
  for (const synchronized of [true, false]) {
    const row = song("BBBBBBBBBBB", "Unmatched", { list: null, duration: "" });
    const env = start([row], { synchronized });
    env.dispatch("click", row.querySelector("a"));
    const selected = env.messages.find(message => message.type === "selection");
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: selected.commandId,
      status: "rejected", reason: "noMatch", snapshot: { ...env.snapshot, revision: 1 } });
    assert.equal(env.messages.filter(message => message.type === "status").at(-1).status, "noMatch");
    assert.equal(env.bar.querySelector(".title").textContent, env.snapshot.title);
    env.messages.length = 0;
    env.dispatch("click", env.play.querySelector("button"));
    env.dispatch("click", env.next.querySelector("button"));
    assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.command),
      synchronized ? ["play", "next"] : ["play"]);
  }
});

test("time-only snapshots and unrelated page mutations do not rescan songs or repaint metadata", () => {
  const rows = Array.from({ length: 1000 }, (_, i) => song(String(i).padStart(11, "0"), `Song ${i}`));
  const env = start(rows);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, revision: 1, diagnosticsEnabled: true, position: 26 });
  env.mutate([{ target: rows[500], addedNodes: [] }]);
  env.advance(1000);
  const fields = env.messages.find(message => message.type === "diagnostic").fields;
  assert.equal(fields.rowsScanned, "0");
  assert.equal(fields.renders, "1");
  assert.equal(fields.observerCallbacks, "1");
});

test("original linked metadata, expanded transport and Back survive without unrelated collection fallback", () => {
  const env = fixture([song("AAAAAAAAAAA", "Album song")]);
  const titleLink = element("a", { href: "watch?v=ZZZZZZZZZZZ" }, [], "Old title");
  env.bar.querySelector(".title").appendChild(titleLink);
  const artistLink = element("a", { href: "channel/artist" }, [], "Old artist");
  const albumLink = element("a", { href: "browse/album" }, [], "Original source album");
  env.artist.appendChild(artistLink); env.artist.appendChild(element("span", {}, [], " • ")); env.artist.appendChild(albumLink);
  const expandedPlay = element("button", { class: "ytp-play-button" }, [element("svg", {}, [element("path")])]);
  const expandedTitle = element("a", { class: "ytp-title-text", href: "watch?v=ZZZZZZZZZZZ" }, [element("span", {}, [], "Old video")]);
  const expandedArtistLink = element("a", { href: "channel/old" }, [], "Old video artist");
  const expandedByline = element("div", { class: "byline" }, [expandedArtistLink]);
  const expandedTime = element("span", { class: "time-info" }, [], "0:00 / 3:25");
  const expandedSlider = element("tp-yt-paper-slider", { id: "progress-bar" }, [element("div", { id: "primaryProgress" })]);
  const back = element("button", { "aria-label": "Back" });
  const controls = element("ytmusic-player-controls", {}, [expandedTitle, expandedByline, expandedTime, expandedSlider]);
  const topTitleLink = element("a", { href: "watch?v=ZZZZZZZZZZZ" }, [], "Old top title");
  const topTitle = element("yt-formatted-string", { class: "title" }, [topTitleLink]);
  const topBar = element("ytmusic-player-bar", { id: "top-player-bar" }, [topTitle]);
  const queueHeadingLink = element("a", { href: "watch?v=CCCCCCCCCCC&list=RDoriginal" }, [], "Original mix heading");
  const queueHeading = element("div", { class: "title" }, [queueHeadingLink]);
  const autoplayTitle = element("div", { class: "title" }, [], "Autoplay");
  const queueBylineLink = element("a", { href: "channel/original-mix" }, [], "Original mix artist");
  const queueByline = element("div", { class: "byline" }, [queueBylineLink]);
  const queueImage = element("img", { class: "image", src: "original-mix.jpg" });
  const queue = element("ytmusic-player-queue", {}, [queueHeading, autoplayTitle, queueByline, queueImage]);
  const expanded = element("ytmusic-player-page", { hidden: "", inert: "" }, [topBar, controls, expandedPlay, back, queue]);
  const queuedRow = song("BBBBBBBBBBB", "Another song");
  expanded.appendChild(queuedRow);
  env.document.body.appendChild(expanded);
  const secondPlay = element("button", { id: "play-pause-button" }, [element("path")]);
  const secondTitle = element("div", { class: "title" }, [], "Old mobile title");
  const secondBar = element("ytmusic-player-bar", { slot: "mini-player" }, [secondTitle, secondPlay]);
  env.document.body.appendChild(secondBar);
  const unrelatedPlay = element("ytmusic-play-button-renderer");
  env.document.body.appendChild(unrelatedPlay);
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", env.snapshot);
  env.messages.length = 0;
  assert.equal(env.bar.querySelector(".title a"), titleLink);
  assert.equal(titleLink.textContent, env.snapshot.title);
  assert.equal(titleLink.getAttribute("href"), "watch?v=AAAAAAAAAAA");
  assert.equal(expandedTitle.textContent, env.snapshot.title);
  assert.equal(expandedTitle.getAttribute("href"), "watch?v=AAAAAAAAAAA");
  assert.equal(expandedTitle.querySelector("span") !== null, true);
  assert.equal(topTitle.children[0], topTitleLink);
  assert.equal(topTitleLink.textContent, env.snapshot.title);
  assert.equal(topTitleLink.getAttribute("href"), "watch?v=AAAAAAAAAAA");
  assert.equal(queueHeading.textContent, "Original mix heading");
  assert.equal(queueHeadingLink.getAttribute("href"), "watch?v=CCCCCCCCCCC&list=RDoriginal");
  assert.equal(autoplayTitle.textContent, "Autoplay");
  assert.equal(queueByline.textContent, "Original mix artist");
  assert.equal(queueBylineLink.getAttribute("href"), "channel/original-mix");
  assert.equal(queueImage.getAttribute("src"), "original-mix.jpg");
  assert.equal(expandedArtistLink.textContent, env.snapshot.artist);
  assert.equal(queuedRow.querySelector(".title").textContent, "Another song");
  assert.equal(expandedTime.textContent, "0:25 / 3:20");
  assert.equal(expandedSlider.getAttribute("aria-valuenow"), "25");
  assert.equal(secondTitle.textContent, env.snapshot.title);
  assert.equal(secondPlay.getAttribute("aria-label"), "Play");
  assert.equal(artistLink.textContent, env.snapshot.artist);
  assert.equal(env.artist.querySelectorAll("a").length, 2);
  assert.equal(albumLink.textContent, "Original source album");
  assert.equal(albumLink.hidden, true);
  assert.equal(albumLink.getAttribute("href"), "browse/album");
  assert.equal(env.dispatch("click", titleLink).prevented, false);
  assert.equal(titleLink.getAttribute("href"), "watch?v=AAAAAAAAAAA");
  assert.equal(expanded.hidden, true);
  assert.equal(expanded.getAttribute("inert"), "");
  expanded.removeAttribute("hidden"); expanded.removeAttribute("inert");
  assert.equal(env.dispatch("click", back).prevented, false);
  assert.equal(env.dispatch("click", expandedPlay).prevented, true);
  assert.equal(env.messages.find(message => message.type === "command").command, "play");
  env.dispatch("click", secondPlay);
  assert.equal(env.messages.at(-1).command, "pause");
  env.dispatch("keydown", expandedSlider, { key: "End" });
  assert.equal(env.messages.at(-1).position, 200);
  env.dispatch("click", unrelatedPlay);
  assert.equal(env.messages.some(message => message.type === "selection"), false);
  env.dispatch("click", queuedRow.querySelector("a"));
  assert.equal(env.messages.filter(message => message.type === "selection").at(-1).tracks[0].id, "BBBBBBBBBBB");
  env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: null, revision: 1 });
  assert.equal(env.dispatch("click", titleLink).prevented, false);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, revision: 2 });
  assert.equal(titleLink.getAttribute("href"), "watch?v=AAAAAAAAAAA");
});

test("album selections carry genuine edition context and the selected rendered ordinal", () => {
  const rows = [song("AAAAAAAAAAA", "Before", { artist: "" }), song("BBBBBBBBBBB", "Chosen", { artist: "" })];
  const env = start(rows, { albumArtist: "Daft Punk" });
  env.artist.textContent = "";
  env.bar.querySelector(".title").textContent = "";
  const currentLink = element("a", { href: "watch?v=AAAAAAAAAAA" }, [], "Before");
  env.bar.querySelector(".title").appendChild(currentLink);
  const artistLink = element("a", { href: "channel/old" }, [], "Old artist");
  const albumLink = element("a", { href: "browse/old" }, [], "Old album");
  env.artist.appendChild(artistLink); env.artist.appendChild(element("span", {}, [], " • ")); env.artist.appendChild(albumLink);
  env.dispatch("click", rows[1].querySelector("a"));
  assert.deepEqual(env.messages[0].context, { provider: "youtubeMusic", kind: "album", selectedSourceID: "BBBBBBBBBBB", selectedOrdinal: 1,
    collectionID: "OLAK5album", title: "Homework (25th Anniversary Edition)", artist: "Daft Punk" });
  assert.deepEqual(env.messages[0].tracks.map(track => track.id), ["BBBBBBBBBBB"]);
  env.window.Multimusic.applySnapshot({ ...env.snapshot, sourceID: "BBBBBBBBBBB", title: "Chosen", artist: "Daft Punk", revision: 1 });
  assert.equal(artistLink.textContent, "Daft Punk");
  assert.equal(artistLink.getAttribute("href"), "channel/artist");
  assert.equal(albumLink.textContent, "Homework (25th Anniversary Edition)");
  assert.equal(albumLink.hidden, false);
  assert.equal(albumLink.getAttribute("href"), "/playlist?list=OLAK5album");
  assert.equal(currentLink.getAttribute("href"), "/watch?v=BBBBBBBBBBB&list=OLAK5album");
});

test("mobile progress uses existing controls without repeated descendant searches and reconnects replaced handles", () => {
  const env = fixture();
  const current = element("span", { class: "current-time" }, [], "0:00");
  const duration = element("span", { class: "total-time" }, [], "3:25");
  const progress = element("div", { id: "primaryProgress" });
  const slider = element("tp-yt-paper-slider", { id: "progress-bar" }, [
    element("div", { id: "sliderContainer" }, [element("div", { class: "bar-container" }, [
      element("tp-yt-paper-progress", { id: "sliderBar" }, [element("div", { id: "progressContainer" }, [progress])])
    ])])
  ]);
  const group = element("div", { class: "progress-bar-container" }, [slider, current, duration]);
  slider.rect = { left: 0, width: 240 };
  slider.querySelector("#sliderBar").rect = { left: 30, width: 200 };
  const controls = element("ytmusic-player-controls", { id: "player-controls" }, [element("div", { class: "metadata-and-progress" }, [group])]);
  const queueRows = Array.from({ length: 1000 }, () => element("ytmusic-player-queue-item", {}, [
    element("yt-formatted-string", { class: "duration" }, [], "3:25")
  ]));
  const queueTitle = element("span", { class: "title" }, [], "Original queue title");
  queueRows[0].appendChild(queueTitle);
  const expanded = element("ytmusic-player-page", { id: "player-page" }, [element("div", { class: "content" }, [
    element("div", { id: "main-panel" }, [controls]), element("ytmusic-player-queue", {}, queueRows)
  ])]);
  env.document.body.appendChild(expanded);
  vm.runInNewContext(script, env);
  const native = { ...env.snapshot, position: 249, duration: 454, diagnosticsEnabled: true };
  env.window.Multimusic.activate("current-document", native);
  assert.equal(current.textContent, "4:09");
  assert.equal(duration.textContent, "7:34");
  assert.equal(slider.getAttribute("aria-valuenow"), "249");
  assert.equal(progress.style.transform, `scaleX(${249 / 454})`);
  assert.equal(queueTitle.textContent, "Original queue title");
  let searches = 0;
  for (const node of [env.bar, expanded, current, duration, slider]) {
    const query = node.querySelectorAll.bind(node);
    node.querySelectorAll = selector => { searches++; return query(selector); };
  }
  env.window.Multimusic.applySnapshot({ ...native, position: 250, revision: 1 });
  assert.equal(searches, 0);
  assert.equal(current.textContent, "4:10");
  assert.equal(duration.textContent, "7:34");
  assert.equal(queueRows[0].querySelector(".duration").textContent, "3:25");
  current.textContent = "";
  const changedLeaf = element("span", {}, [], "Old clock");
  current.appendChild(changedLeaf);
  env.window.Multimusic.applySnapshot({ ...native, position: 251, revision: 2 });
  assert.equal(changedLeaf.textContent, "4:11");
  assert.equal(current.children[0], changedLeaf);
  searches = 0;
  env.window.Multimusic.applySnapshot({ ...native, position: 252, revision: 3 });
  assert.equal(searches, 0);
  assert.equal(changedLeaf.textContent, "4:12");
  const nextCurrent = element("span", { class: "current-time" }, [], "Wrong clock");
  const nextProgress = element("div", { id: "primaryProgress" });
  const nextSlider = element("tp-yt-paper-slider", { id: "progress-bar" }, [
    element("tp-yt-paper-progress", { id: "sliderBar" }, [nextProgress]), element("div", { id: "sliderKnob" })
  ]);
  nextSlider.rect = { left: 0, width: 240 };
  nextSlider.querySelector("#sliderBar").rect = { left: 30, width: 200 };
  group.replaceChild(nextCurrent, current); group.replaceChild(nextSlider, slider);
  env.window.Multimusic.applySnapshot({ ...native, position: 253, revision: 4 });
  assert.equal(nextCurrent.textContent, "4:13");
  assert.equal(nextSlider.getAttribute("aria-valuenow"), "253");
  assert.equal(nextProgress.style.transform, `scaleX(${253 / 454})`);
  assert.equal(slider.getAttribute("aria-valuenow"), "252");
  env.dispatch("pointerdown", nextSlider);
  env.dispatch("pointerup", nextSlider, { clientX: 130 });
  assert.equal(env.messages.find(message => message.command === "seek").position, 227);
  env.advance(1000);
  assert.equal(env.messages.find(message => message.type === "diagnostic").fields.rowsScanned, "0");
  assert.equal(group.children[1], nextCurrent);
});

test("shadow mini-player composed paths route labelled transport and seek to native commands", () => {
  const env = start();
  const root = element("ytmusic-player", {}, [element("div", { class: "title" }, [], "Old title")]);
  env.document.body.appendChild(root);
  const button = element("button", { "aria-label": "Next track" }, [element("svg")]);
  const icon = button.children[0];
  const path = () => [icon, button, root, env.document];
  env.messages.length = 0;
  assert.equal(env.dispatch("click", root, { composedPath: path }).prevented, true);
  assert.equal(env.messages.find(value => value.type === "command").command, "next");
  button.setAttribute("aria-label", "Previous track");
  env.dispatch("click", root, { composedPath: path });
  button.setAttribute("aria-label", "Play");
  env.dispatch("keydown", root, { key: "Enter", composedPath: path });
  assert.deepEqual(env.messages.filter(value => value.type === "command").map(value => value.command), ["next", "previous", "play"]);
  const slider = element("div", { role: "slider", "aria-label": "Seek slider" });
  const seekPath = () => [slider, root, env.document];
  env.dispatch("pointerdown", root, { clientX: 20, composedPath: seekPath });
  env.dispatch("pointerup", root, { clientX: 100, composedPath: seekPath });
  assert.equal(env.messages.filter(value => value.type === "command").at(-1).command, "seek");
  assert.equal(env.messages.filter(value => value.type === "command").at(-1).position, 100);
});

test("unknown input inside a player is blocked and missing painted controls report adapterChanged", () => {
  const env = start();
  env.bar.rect = { left: 0, top: 542, width: 402, height: 100 };
  const unknown = element("button", { "aria-label": "Unknown website control" });
  env.bar.appendChild(unknown);
  assert.equal(env.dispatch("click", unknown).prevented, true);
  assert.equal(env.messages.some(value => value.status === "unsupported"), true);
  assert.equal(env.messages.some(value => value.type === "command"), false);
  const unmapped = env.messages.find(value => value.event === "web.aggregate" && value.fields.miniTapUnmapped === "1");
  assert.equal(unmapped !== undefined, true);
  assert.equal(unmapped.fields.composedPathTags.includes("button"), true);
  const broken = element("ytmusic-player", {}, [element("button", { "aria-label": "Unmapped" })]);
  broken.rect = { left: 0, top: 542, width: 402, height: 100 };
  env.document.body.appendChild(broken);
  env.mutate([{ type: "childList", target: env.document.body, addedNodes: [broken], removedNodes: [] }]);
  assert.equal(env.messages.some(value => value.status === "adapterChanged"), true);
  assert.equal(env.dispatch("click", broken.children[0]).prevented, true);
});

test("a handled touch suppresses only its own duplicate click", () => {
  const env = start();
  const target = env.play.querySelector("button"), point = { identifier: 1, clientX: 20, clientY: 20 };
  env.dispatch("touchstart", target, { touches: [point] });
  env.dispatch("touchend", target, { touches: [], changedTouches: [point] });
  assert.equal(env.dispatch("click", target).prevented, true);
  assert.equal(new Set(env.messages.filter(value => value.type === "command").map(value => value.commandId)).size, 1);
  env.dispatch("click", target);
  assert.equal(new Set(env.messages.filter(value => value.type === "command").map(value => value.commandId)).size, 2);
  assert.equal(env.messages.some(value => value.fields?.miniTapUnmapped), false);
});

test("every native rejection preserves its specific status", () => {
  for (const reason of ["inactive", "unauthorized", "invalidSelection", "unmappedQueue", "awaitingNext", "cancelled", "nativeFailure", "nativeNoChange", "timedOut", "foreignPlayback", "noMatch", "cleared"]) {
    const env = start();
    env.dispatch("click", env.play.querySelector("button"));
    const command = env.messages.find(value => value.type === "command");
    env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId, status: "rejected", reason });
    assert.equal(env.messages.filter(value => value.type === "status").at(-1).status, reason);
  }
});

test("playlist capture reports the declared total, row limit and unreadable count", () => {
  const rows = Array.from({ length: 50 }, (_, index) => song("AAAAAAAAAAA", `Song ${index}`, { artist: index >= 46 ? "" : "Artist" }));
  const env = start(rows);
  env.document.querySelector("ytmusic-responsive-header-renderer").appendChild(element("span", { class: "second-subtitle" }, [], "153 songs"));
  env.dispatch("click", rows[0].querySelector("a"));
  const capture = env.messages.find(value => value.type === "selection");
  assert.equal(capture.tracks.length, 46);
  assert.equal(capture.omitted, 4);
  assert.equal(capture.declaredCount, 153);
  assert.equal(capture.capped, true);
});

// Round 2 — compact/mini player controls rendered inside open shadow roots.
function miniBarEnvironment() {
  const env = fixture();
  env.document.body.children = env.document.body.children.filter(child => child !== env.bar);
  const bar = element("ytmusic-player-bar", { slot: "player-bar" }, []);
  bar.rect = { left: 0, top: 0, width: 300, height: 60 };
  env.document.body.appendChild(bar);
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", env.snapshot);
  env.messages.length = 0;
  const shadowButton = (hostTag, label, rect) => {
    const host = element(hostTag, { "aria-label": label });
    const shadow = host.attachShadow();
    const button = element("button", { "aria-label": label });
    shadow.appendChild(button);
    host.rect = rect; button.rect = rect;
    bar.appendChild(host);
    return { host, shadow, button };
  };
  return { env, bar, shadowButton };
}

test("mini-bar controls inside shadow roots map play, next and previous to distinct native commands", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  const rects = {
    play: { left: 10, top: 10, width: 40, height: 40 },
    next: { left: 130, top: 10, width: 40, height: 40 },
    previous: { left: 250, top: 10, width: 40, height: 40 }
  };
  const play = shadowButton("ytmusic-play-button-renderer", "Play song", rects.play);
  const next = shadowButton("yt-icon-button", "Next track", rects.next);
  const previous = shadowButton("tp-yt-paper-icon-button", "PREVIOUS song", rects.previous);
  for (const [control, expected] of [[play, "play"], [next, "next"], [previous, "previous"]]) {
    const path = [control.button, control.shadow, control.host, bar, env.document.body, env.document.documentElement, env.document];
    const event = env.dispatch("click", control.button, { composedPath: () => path });
    assert.equal(event.prevented, true);
    assert.equal(env.messages.filter(value => value.type === "command").at(-1).command, expected);
  }
  assert.deepEqual(env.messages.filter(value => value.type === "command").map(value => value.command),
    ["play", "next", "previous"]);
});

test("a tap inside the real mini-bar rect uses the nearest control rect when no selector matches", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  shadowButton("yt-icon-button", "Play", { left: 10, top: 10, width: 40, height: 40 });
  const next = shadowButton("yt-icon-button", "Next", { left: 130, top: 10, width: 40, height: 40 });
  shadowButton("yt-icon-button", "Previous", { left: 250, top: 10, width: 40, height: 40 });
  const blank = element("div", {}, []);
  bar.appendChild(blank);
  // 145 is inside the bar and closest to the Next rect centred at 150.
  const event = env.dispatch("click", blank, { clientX: 145, clientY: 30, composedPath: () => [blank, bar] });
  assert.equal(event.prevented, true);
  const commands = env.messages.filter(value => value.type === "command");
  assert.equal(commands.length, 1);
  assert.equal(commands[0].command, "next");
  assert.equal(next.host.getAttribute("aria-label"), "Next");
});

test("an unmapped tap inside a resolved mini-bar fails closed with a visible diagnostic", () => {
  const { env, bar } = miniBarEnvironment();
  const blank = element("div", {}, []);
  bar.appendChild(blank);
  const event = env.dispatch("click", blank, { clientX: 150, clientY: 30, composedPath: () => [blank, bar] });
  assert.equal(event.prevented, true, "the website must not receive an unmapped transport tap");
  assert.equal(env.messages.some(value => value.status === "unsupported"), true);
  assert.equal(env.messages.some(value => value.type === "command"), false);
  const diagnostic = env.messages.find(value => value.event === "web.aggregate" && value.fields.miniTapUnmapped === "1");
  assert.notEqual(diagnostic, undefined);
  assert.equal(diagnostic.fields.composedPathTags.includes("div"), true);
  assert.equal(diagnostic.fields.composedPathTags.includes("ytmusic-player-bar"), true);
  assert.equal(String(diagnostic.fields.miniTapUnmapped), "1");
});

// Round 2 — an "E" badge only identifies explicitness on selected list/watch metadata.
test("an explicit badge on a search card is ignored but a badge on a selected list title is kept", () => {
  const cardTitle = element("yt-formatted-string", { class: "title" }, [
    element("a", { href: "watch?v=CCCCCCCCCCC" }, [], "Around the World"),
    element("span", { "aria-label": "E" })
  ]);
  const card = element("ytmusic-card-shelf-renderer", {}, [
    cardTitle, element("a", { href: "channel/daft-punk" }, [], "Daft Punk"),
    element("ytmusic-play-button-renderer", { "aria-label": "Play Around the World" })
  ]);
  const search = fixture([card]);
  search.location.href = "https://music.youtube.com/search?q=espresso";
  vm.runInNewContext(script, search);
  search.window.Multimusic.activate("current-document", search.snapshot);
  search.messages.length = 0;
  search.dispatch("click", card.querySelector("ytmusic-play-button-renderer"));
  const fromCard = search.messages.find(value => value.type === "selection");
  assert.notEqual(fromCard, undefined);
  assert.equal("isExplicit" in fromCard.tracks[0], false, "a search-card E badge is not source explicitness");

  const list = start([song("BBBBBBBBBBB", "Song", { explicit: true })]);
  list.dispatch("click", list.document.querySelector("ytmusic-shelf-renderer yt-formatted-string.title a"));
  const fromList = list.messages.find(value => value.type === "selection");
  assert.equal(fromList.tracks[0].isExplicit, true);

  const loose = fixture();
  const row = song("BBBBBBBBBBB", "Loose", { explicit: false });
  row.appendChild(element("span", { "aria-label": "Explicit" }));
  loose.document.querySelector("ytmusic-shelf-renderer").appendChild(row);
  vm.runInNewContext(script, loose);
  loose.window.Multimusic.activate("current-document", loose.snapshot);
  loose.messages.length = 0;
  loose.location.href = "https://music.youtube.com/";
  loose.dispatch("click", row.querySelector(".title a"));
  const fromLoose = loose.messages.find(value => value.type === "selection");
  assert.equal("isExplicit" in fromLoose.tracks[0], false, "a badge outside .title/.byline is not accepted");

  const watch = fixture();
  const watchRow = song("BBBBBBBBBBB", "Watch song", { explicit: false });
  const byline = watchRow.querySelector(".flex-columns");
  byline.setAttribute("class", "byline");
  byline.appendChild(element("span", { "aria-label": "E" }));
  watch.document.querySelector("ytmusic-shelf-renderer").appendChild(watchRow);
  vm.runInNewContext(script, watch);
  watch.window.Multimusic.activate("current-document", watch.snapshot);
  watch.messages.length = 0;
  watch.location.href = "https://music.youtube.com/watch?v=BBBBBBBBBBB";
  watch.dispatch("click", watchRow.querySelector(".title a"));
  const fromWatch = watch.messages.find(value => value.type === "selection");
  assert.equal(fromWatch.tracks[0].isExplicit, true, "a badge inside a selected watch-page byline is accepted");
});

// Round 3 — bounded mini controls and a complete expanded-player command trip.
test("mini selector precedence crosses a real shadow boundary and never lets Play swallow Next", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  const control = shadowButton("ytmusic-play-button-renderer", "Play next song", { left: 20, top: 10, width: 40, height: 40 });
  control.host.setAttribute("class", "next-button");
  control.button.parentElement = null;
  Object.defineProperty(control.button, "parentNode", { value: { host: control.host } });
  const event = env.dispatch("click", control.button, { composedPath: () => [control.button, control.host, bar] });
  assert.equal(event.prevented, true);
  assert.equal(env.messages.find(message => message.type === "command").command, "next");
  control.host.setAttribute("class", "previous-button play-pause-button");
  env.dispatch("click", control.button, { composedPath: () => [control.button, control.host, bar] });
  assert.equal(env.messages.filter(message => message.type === "command").at(-1).command, "previous");
  control.host.setAttribute("id", "progress-bar");
  control.host.appendChild(element("div", { id: "sliderBar" })).rect = { left: 20, width: 100 };
  env.dispatch("click", control.button, { clientX: 70, composedPath: () => [control.button, control.host, bar] });
  assert.equal(env.messages.filter(message => message.type === "command").at(-1).command, "seek");
  assert.equal(env.messages.filter(message => message.type === "command").at(-1).position, 100);
});

test("mini generic control hosts require exact labels or a recognised class or slider role", () => {
  for (const [attributes, expected] of [[{ "aria-label": "Play next collection" }, null],
    [{ "aria-label": "Playlist" }, null], [{ "aria-label": "Next track" }, "next"],
    [{ class: "previous-button", "aria-label": "Play next collection" }, "previous"],
    [{ role: "slider", "aria-label": "Timeline" }, "seek"]]) {
    const { env, bar } = miniBarEnvironment();
    const button = element("button", attributes);
    bar.appendChild(button);
    env.dispatch("click", button, { clientX: 100, clientY: 30 });
    const commands = env.messages.filter(message => message.type === "command");
    assert.equal(commands[0]?.command || null, expected);
    if (!expected) assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped === "1"), true);
  }
});

test("mini geometry requires a nearby visible control inside the bar and prefers its specific class", () => {
  for (const [x, y, rect, hidden, expected] of [
    [76, 30, { left: 30, top: 10, width: 40, height: 40 }, false, "next"], // +6 at edge, 26 at centre
    [77, 30, { left: 30, top: 10, width: 40, height: 40 }, false, null],
    [50, 30, { left: 0, top: 10, width: 200, height: 40 }, false, null], // inside, but >28 from centre
    [58, 30, { left: 0, top: 10, width: 60, height: 40 }, false, "next"], // centre exactly 28
    [59, 30, { left: 0, top: 10, width: 60, height: 40 }, false, null],
    [50, 30, { left: 30, top: 10, width: 40, height: 40 }, true, null],
    [5, 30, { left: -10, top: 10, width: 40, height: 40 }, false, null]
  ]) {
    const { env, bar, shadowButton } = miniBarEnvironment();
    const next = shadowButton("yt-icon-button", "Next", rect);
    if (hidden) next.host.setAttribute("hidden", "");
    const blank = bar.appendChild(element("div"));
    env.dispatch("click", blank, { clientX: x, clientY: y });
    assert.equal(env.messages.find(message => message.type === "command")?.command || null, expected, `${x},${y}`);
  }
  const { env, bar, shadowButton } = miniBarEnvironment();
  shadowButton("ytmusic-play-button-renderer", "Play", { left: 30, top: 10, width: 40, height: 40 });
  const next = shadowButton("yt-icon-button", "Next", { left: 40, top: 10, width: 40, height: 40 });
  next.host.setAttribute("class", "next-button");
  env.dispatch("click", bar, { clientX: 50, clientY: 30 });
  assert.equal(env.messages.find(message => message.type === "command").command, "next");
});

test("seven rapid mini toggles create seven distinct command pairs despite delayed snapshots and retries", () => {
  const { env, shadowButton } = miniBarEnvironment();
  const play = shadowButton("yt-icon-button", "Play", { left: 10, top: 10, width: 40, height: 40 });
  const pairs = new Map();
  const initial = { ...env.snapshot, revision: 1, state: "playing" };
  env.window.Multimusic.applySnapshot(initial);
  for (let index = 0; index < 7; index++) {
    env.dispatch("click", play.button);
    const command = env.messages.filter(message => message.type === "command").at(-1);
    pairs.set(command.commandId, [command.command]);
    env.window.Multimusic.applySnapshot({ ...initial, revision: index + 2 });
  }
  assert.equal(pairs.size, 7);
  assert.deepEqual([...pairs.values()].flat(), ["pause", "play", "pause", "play", "pause", "play", "pause"]);
  env.advance(1000);
  for (const command of env.messages.filter(message => message.type === "command")) assert.equal(pairs.has(command.commandId), true);
  for (const [id, pair] of [...pairs].reverse()) {
    const state = pair[0] === "play" ? "playing" : "paused";
    assert.equal(env.window.Multimusic.receiveAck({ token: "current-document", commandId: id, status: "completed",
      snapshot: { ...initial, revision: 20, state: "paused" } }), true);
    pair.push(state);
  }
  assert.equal([...pairs.values()].every(pair => pair.length === 2), true);
  assert.equal(play.button.getAttribute("aria-label"), "Play");
});

test("seven rapid touch taps keep their toggles while suppressing only the generated clicks", () => {
  const { env, shadowButton } = miniBarEnvironment();
  const play = shadowButton("yt-icon-button", "Play", { left: 10, top: 10, width: 40, height: 40 });
  env.window.Multimusic.applySnapshot({ ...env.snapshot, state: "playing" });
  for (let index = 0; index < 7; index++) {
    const point = { identifier: index + 1, clientX: 30, clientY: 30 };
    env.dispatch("touchstart", play.button, { touches: [point] });
    const end = index === 3 ? { ...point, clientX: 43 } : point;
    env.dispatch("touchend", play.button, { touches: [], changedTouches: [end] });
    env.dispatch("click", play.button, { clientX: end.clientX, clientY: end.clientY });
  }
  const commands = env.messages.filter(message => message.type === "command");
  assert.equal(new Set(commands.map(command => command.commandId)).size, 7);
  assert.deepEqual(commands.map(command => command.command), ["pause", "play", "pause", "play", "pause", "play", "pause"]);
  const pairs = commands.map(command => {
    const state = command.command === "play" ? "playing" : "paused";
    assert.equal(env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId,
      status: "completed", snapshot: { ...env.snapshot, revision: 1, state } }), true);
    return [command.command, state];
  });
  assert.equal(pairs.length, 7);
  assert.deepEqual(pairs.at(-1), ["pause", "paused"]);
  assert.equal(play.button.getAttribute("aria-label"), "Play");
  assert.equal(env.messages.filter(message => message.fields?.miniTapUnmapped === "1").length, 0);
});

test("mini geometry uses touch coordinates when the tap has no mouse coordinates", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  shadowButton("yt-icon-button", "Next", { left: 30, top: 10, width: 40, height: 40 });
  const point = { identifier: 1, clientX: 76, clientY: 30 };
  env.dispatch("touchstart", bar, { touches: [point] });
  env.dispatch("touchend", bar, { touches: [], changedTouches: [point], clientX: undefined, clientY: undefined });
  assert.equal(env.messages.find(message => message.type === "command").command, "next");
});

test("dropped mini input always carries bounded unmapped path diagnostics", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  const next = shadowButton("yt-icon-button", "Next", { left: 10, top: 10, width: 40, height: 40 });
  env.window.Multimusic.applySnapshot({ ...env.snapshot, synchronized: false });
  env.dispatch("click", next.button, { composedPath: () => [next.button, next.host, bar, env.document.body, env.document] });
  assert.equal(env.messages.some(message => message.type === "command"), false);
  const diagnostics = env.messages.filter(message => message.fields?.miniTapUnmapped === "1");
  assert.equal(diagnostics.length, 1);
  assert.ok(diagnostics[0].fields.composedPathTags.length <= 64);
  assert.match(diagnostics[0].fields.composedPathTags, /button/);
});

test("mini navigation and search inputs never become transport or have their default action stopped", () => {
  const { env, bar, shadowButton } = miniBarEnvironment();
  shadowButton("yt-icon-button", "Play", { left: 10, top: 10, width: 40, height: 40 });
  for (const node of [element("a", { href: "channel/artist" }), element("div", { class: "byline" }),
    element("div", { class: "title" }), element("div", { id: "song-image" }), element("input", { role: "combobox" })]) {
    bar.appendChild(node);
    assert.equal(env.dispatch("click", node, { clientX: 30, clientY: 30 }).prevented, false);
    assert.equal(env.dispatch("pointerdown", node, { clientX: 30, clientY: 30 }).prevented, false);
  }
  assert.equal(env.messages.some(message => message.type === "command"), false);
});

test("slider click uses the widest track and a pointer/touch/click cycle emits one seek", () => {
  const env = start();
  env.slider.rect = { left: 0, width: 400 };
  env.slider.querySelector("#sliderBar").rect = { left: 50, width: 100 };
  env.dispatch("click", env.slider, { clientX: 75 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 37.5]]);
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: env.messages.find(message => message.type === "command").commandId, status: "completed" });
  env.advance(800);
  env.messages.length = 0;
  const point = { identifier: 1, clientX: 125, clientY: 10 };
  env.dispatch("touchstart", env.slider, { touches: [point] });
  env.dispatch("pointerdown", env.slider, { clientX: 125 });
  env.dispatch("pointerup", env.slider, { clientX: 125 });
  env.dispatch("touchend", env.slider, { touches: [], changedTouches: [point] });
  env.dispatch("click", env.slider, { clientX: 125 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 62.5]]);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: env.messages.find(message => message.type === "command").commandId, status: "completed" });
  env.advance(800);
  env.dispatch("click", env.slider, { clientX: 75 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 62.5], ["seek", 37.5]]);
});

test("title, cover and E shortcut expand through the original button; expanded controls round-trip four commands then collapse", () => {
  const env = fixture();
  const title = env.bar.querySelector(".title"), cover = env.bar.querySelector("img");
  const expand = element("button", { "aria-label": "Expand player" });
  env.bar.appendChild(expand);
  const pause = element("button", { class: "play-pause-button" });
  const next = element("button", { class: "next-button" });
  const previous = element("button", { class: "previous-button" });
  const slider = element("div", { id: "progress-bar" }, [element("div", { id: "sliderBar" })]);
  slider.children[0].rect = { left: 50, width: 100 };
  const collapse = element("button", { "aria-label": "Minimize player" });
  const page = element("ytmusic-player-page", { hidden: "" }, [pause, next, previous, slider, collapse]);
  env.document.body.appendChild(page);
  let expansions = 0;
  expand.click = () => { expansions++; page.removeAttribute("hidden"); env.bar.setAttribute("hidden", ""); };
  collapse.click = () => { page.setAttribute("hidden", ""); env.bar.removeAttribute("hidden"); };
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", { ...env.snapshot, state: "playing" });
  env.messages.length = 0;
  for (const [node, options, path] of [[title, {}, "title"], [cover, {}, "cover"], [env.document.body, { key: "e" }, "keyboard"]]) {
    env.dispatch(options.key ? "keydown" : "click", node, options);
    assert.equal(page.hidden, false);
    assert.equal(env.messages.filter(message => message.fields?.expandPath).at(-1).fields.expandPath, path);
    collapse.click();
  }
  assert.equal(expansions, 3);
  env.dispatch("click", title);
  const states = [], commands = [];
  for (const [node, name] of [[pause, "pause"], [next, "next"], [previous, "previous"], [slider, "seek"]]) {
    env.dispatch("click", node, { clientX: 75 });
    const command = env.messages.filter(message => message.type === "command").at(-1);
    assert.equal(command.command, name);
    commands.push(command);
    const state = { ...env.snapshot, state: "paused", revision: commands.length,
      sourceID: name === "next" ? "BBBBBBBBBBB" : "AAAAAAAAAAA", position: name === "seek" ? 50 : 0 };
    assert.equal(env.window.Multimusic.receiveAck({ token: "current-document", commandId: command.commandId,
      status: "completed", snapshot: state }), true);
    states.push([state.state, state.sourceID, state.position]);
  }
  assert.equal(new Set(commands.map(command => command.commandId)).size, 4);
  assert.deepEqual(states, [["paused", "AAAAAAAAAAA", 0], ["paused", "BBBBBBBBBBB", 0],
    ["paused", "AAAAAAAAAAA", 0], ["paused", "AAAAAAAAAAA", 50]]);
  assert.equal(env.dispatch("click", collapse).prevented, false);
  collapse.click();
  assert.equal(page.hidden, true);
  assert.equal(env.bar.hidden, false);
});

test("explicit badges cover each list renderer and watch queue", () => {
  for (const tag of ["ytmusic-responsive-list-item-renderer", "ytmusic-two-row-item-renderer", "ytmusic-card-shelf-renderer"]) {
    for (const scope of ["title", "byline", "badges"]) {
      const row = song("BBBBBBBBBBB", "Explicit song");
      row.tagName = tag.toUpperCase();
      row.appendChild(element("ytmusic-play-button-renderer"));
      const badge = element("span", { "aria-label": "E" });
      if (scope === "title") row.querySelector(".title").appendChild(badge);
      else row.appendChild(element("div", { class: scope }, [badge]));
      const env = start([row]);
      env.dispatch("click", row.querySelector("ytmusic-play-button-renderer"));
      assert.equal(env.messages.find(message => message.type === "selection").tracks[0].isExplicit, true, `${tag}/${scope}`);
    }
  }
  const row = radioQueueRow("BBBBBBBBBBB", "Explicit queue song", "Artist", "3:20", { play: true });
  row.querySelector(".byline").appendChild(element("span", { title: "Explicit" }));
  const env = startRadioQueue([row]);
  env.dispatch("click", row.querySelector("ytmusic-play-button-renderer"));
  assert.equal(env.messages.find(message => message.type === "selection").tracks[0].isExplicit, true);
});


// Round 3b — viewport-sized player roots must not claim the surrounding page.
test("a full-viewport player rectangle leaves Home Search and header navigation alone", () => {
  const env = start();
  env.bar.rect = { left: 0, top: 0, width: 402, height: 662 };
  const search = element("button", { "aria-label": "Search" });
  const header = env.document.body.appendChild(element("ytmusic-nav-bar", {}, [search]));
  env.location.href = "https://music.youtube.com/";
  for (const target of [search, element("a", { href: "/explore" }), element("input", { role: "combobox" })]) {
    header.appendChild(target);
    for (const type of ["pointerdown", "click"]) {
      const event = env.dispatch(type, target, { clientX: 360, clientY: 28 });
      assert.equal(event.prevented, false);
      assert.equal(event.stopped, false);
    }
  }
  assert.deepEqual(env.messages, []);
});

test("a header button labelled exactly Play selects the collection under a full-viewport player rect", () => {
  const row = song("BBBBBBBBBBB", "Selected");
  const env = start([row]);
  env.bar.rect = { left: 0, top: 0, width: 402, height: 662 };
  const header = env.document.querySelector("ytmusic-responsive-header-renderer");
  const play = header.appendChild(element("button", { "aria-label": "Play" }));
  assert.equal(env.dispatch("click", play, { clientX: 200, clientY: 150 }).prevented, true);
  assert.deepEqual(env.messages.filter(message => message.type === "selection").map(message => message.tracks[0].id), ["BBBBBBBBBBB"]);
  assert.equal(env.messages.some(message => message.type === "command" || message.fields?.miniTapUnmapped), false);
});

test("rectangle fallback never steals a navigation target even next to a transport button", () => {
  const { env, shadowButton } = miniBarEnvironment();
  shadowButton("yt-icon-button", "Next", { left: 10, top: 10, width: 40, height: 40 });
  for (const node of [element("a", { href: "/explore" }), element("div", { class: "title" }),
    element("div", { class: "byline" }), element("div", { id: "song-image" }), element("input", { role: "combobox" })]) {
    env.document.body.appendChild(node);
    assert.equal(env.dispatch("pointerdown", node, { clientX: 30, clientY: 30 }).prevented, false);
    assert.equal(env.dispatch("click", node, { clientX: 30, clientY: 30 }).prevented, false);
  }
  assert.deepEqual(env.messages, []);
});

test("seek considers sliderBar in the slider's own shadow root alongside its wider host", () => {
  const env = start();
  env.slider.rect = { left: 0, width: 400 };
  env.slider.querySelector("#sliderBar").setAttribute("id", "obsolete");
  const track = env.slider.attachShadow().appendChild(element("div", { id: "sliderBar" }));
  track.rect = { left: 50, width: 100 };
  env.dispatch("pointerdown", env.slider, { clientX: 125 });
  env.dispatch("pointerup", env.slider, { clientX: 125 });
  env.dispatch("click", env.slider, { clientX: 125 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 62.5]]);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
});

test("a title anchor touch expands once and cancels its website navigation", () => {
  const env = start();
  const title = env.bar.querySelector(".title");
  const link = title.appendChild(element("a", { href: "watch?v=AAAAAAAAAAA" }, [], "Song"));
  const expand = env.bar.appendChild(element("button", { "aria-label": "Expand player" }));
  let expansions = 0, navigations = 0;
  expand.click = () => { expansions++; };
  const point = { identifier: 7, clientX: 80, clientY: 630 };
  env.dispatch("touchstart", link, { touches: [point] });
  env.dispatch("touchend", link, { touches: [], changedTouches: [point] });
  const click = env.dispatch("click", link, { clientX: 80, clientY: 630 });
  if (!click.prevented) navigations++;
  assert.equal(expansions, 1);
  assert.equal(navigations, 0);
  assert.equal(env.messages.filter(message => message.fields?.expandPath === "title").length, 1);
  assert.equal(env.messages.some(message => message.type === "command" || message.fields?.miniTapUnmapped), false);
});

test("missing expand controls still report title, cover and keyboard attempts", () => {
  const env = start();
  const title = env.bar.querySelector(".title");
  for (const [type, target, options] of [["click", title, {}], ["click", env.bar.querySelector("img"), {}],
    ["keydown", env.document.body, { key: "e" }], ["keydown", title, { key: "Enter" }]]) {
    env.dispatch(type, target, options);
  }
  assert.deepEqual(env.messages.filter(message => message.fields?.expandPath).map(message => message.fields.expandPath),
    ["title", "cover", "keyboard", "title"]);
  assert.equal(env.messages.some(message => message.type === "command" || message.fields?.miniTapUnmapped), false);
});

// Round 4 — retained hidden pages and the visible mobile transport have different geometry.
function transportClusterEnvironment() {
  const env = fixture([song("BBBBBBBBBBB", "Header selection")]);
  env.bar.style.display = "none";
  const hiddenPlay = element("button", { "aria-label": "Play" });
  const hiddenNext = element("button", { "aria-label": "Next" });
  hiddenPlay.rect = { left: 282, top: 12, width: 48, height: 48 };
  hiddenNext.rect = { left: 338, top: 12, width: 48, height: 48 };
  const page = element("ytmusic-player-page", {}, [hiddenPlay, hiddenNext]);
  page.rect = { left: 0, top: 0, width: 402, height: 649 };
  page.style.visibility = "hidden";
  env.document.body.appendChild(page);
  const outer = env.document.body.appendChild(element("div", { role: "button", class: "play-pause-button", "aria-label": "Player controls" }));
  outer.rect = page.rect;
  const cluster = outer.appendChild(element("div", { id: "transport" }));
  cluster.rect = { left: 0, top: 583, width: 402, height: 66 };
  const control = (label, left) => {
    const host = cluster.appendChild(element("yt-icon-button"));
    const shadow = host.attachShadow();
    const button = shadow.appendChild(element("button", { "aria-label": label }));
    const icon = button.appendChild(element("yt-icon"));
    host.rect = button.rect = icon.rect = { left, top: 595, width: 48, height: 48 };
    return { host, shadow, button, icon };
  };
  const play = control("Play", 282), next = control("Next", 338);
  vm.runInNewContext(script, env);
  env.window.Multimusic.activate("current-document", env.snapshot);
  env.messages.length = 0;
  const path = control => [control.icon, control.button, control.shadow, control.host, cluster, outer, env.document.body];
  return { env, page, cluster, outer, play, next, hiddenNext, path };
}

test("visible transport clusters route thirty mini taps despite a hidden full-page player with top-edge controls", () => {
  const { env, page, cluster, play, next, hiddenNext, path } = transportClusterEnvironment();
  assert.equal(page.getClientRects().length, 1, "hidden visibility still has layout rectangles");
  const commands = [];
  for (let index = 0; index < 30; index++) {
    const control = index % 2 ? next : play;
    const event = env.dispatch("click", control.icon, {
      clientX: index % 2 ? 362 : 306, clientY: 619, composedPath: () => path(control)
    });
    assert.equal(event.prevented, true, `tap ${index}: ${JSON.stringify(env.messages)}`);
    const message = env.messages.filter(message => message.type === "command").at(-1);
    const expected = index % 2 ? "next" : index % 4 ? "pause" : "play";
    assert.equal(message.command, expected);
    commands.push(message.commandId);
  }
  assert.equal(new Set(commands).size, 30);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
  env.messages.length = 0;
  assert.equal(env.dispatch("click", hiddenNext, { clientX: 362, clientY: 36,
    composedPath: () => [hiddenNext, page, env.document.body] }).prevented, false);
  assert.deepEqual(env.messages, []);
  // A retargeted blank hit can still use geometry inside a generic compact root.
  const blank = cluster.appendChild(element("div"));
  env.dispatch("click", blank, { clientX: 362, clientY: 619, composedPath: () => [blank, cluster] });
  assert.equal(env.messages.find(message => message.type === "command")?.command, "next");
});

test("transport-cluster detection requires a compact visible cluster with both exact Play/Pause and Next", () => {
  for (const invalid of ["wide page", "narrow", "no next", "prefix play", "hidden play", "transparent next", "outside"]) {
    const { env, cluster, play, next, path } = transportClusterEnvironment();
    if (invalid === "wide page") cluster.rect.height = 649;
    if (invalid === "narrow") cluster.rect.width = 199;
    if (invalid === "no next") next.button.setAttribute("aria-label", "More");
    if (invalid === "prefix play") play.button.setAttribute("aria-label", "Play collection");
    if (invalid === "hidden play") play.host.style.visibility = "hidden";
    if (invalid === "transparent next") next.host.style.opacity = "0";
    const event = env.dispatch("click", next.icon, { clientX: 362, clientY: invalid === "outside" ? 582 : 619,
      composedPath: () => path(next) });
    assert.equal(event.prevented, false, invalid);
    assert.equal(env.messages.some(message => message.type === "command"), false, invalid);
  }
});

test("transport clusters never borrow an outer Player control or claim Search and header Play", () => {
  const { env, cluster, outer } = transportClusterEnvironment();
  const blank = cluster.appendChild(element("div"));
  env.dispatch("click", blank, { clientX: 150, clientY: 619, composedPath: () => [blank, cluster, outer] });
  assert.equal(env.messages.some(message => message.type === "command"), false);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped === "1"), true);
  env.messages.length = 0;
  const search = element("button", { "aria-label": "Search" });
  const header = env.document.body.appendChild(element("ytmusic-nav-bar", {}, [search]));
  header.rect = { left: 0, top: 0, width: 402, height: 64 };
  assert.equal(env.dispatch("click", search, { clientX: 362, clientY: 36, composedPath: () => [search, header] }).prevented, false);
  assert.deepEqual(env.messages, []);
  const collection = env.headerPlay.parentElement;
  collection.rect = { left: 0, top: 90, width: 402, height: 100 };
  const play = collection.appendChild(element("button", { "aria-label": "Play" }));
  env.dispatch("click", play, { clientX: 306, clientY: 150, composedPath: () => [play, collection, env.document.body] });
  assert.equal(env.messages.some(message => message.type === "command" || message.fields?.miniTapUnmapped), false);
  assert.deepEqual(env.messages.filter(message => message.type === "selection").map(message => message.tracks[0].id), ["BBBBBBBBBBB"]);
});

test("unresolved bottom-120px mouse and touch taps report path tags while navigation and higher taps stay quiet", () => {
  for (const touch of [false, true]) {
    const env = start();
    env.bar.style.display = "none";
    const blank = env.document.body.appendChild(element("yt-icon"));
    const point = { identifier: 1, clientX: 362, clientY: 619 };
    if (touch) env.dispatch("touchstart", blank, { touches: [point] });
    const options = touch ? { touches: [], changedTouches: [point] } : point;
    const event = env.dispatch(touch ? "touchend" : "click", blank, options);
    assert.equal(event.prevented, false);
    assert.deepEqual(env.messages.filter(message => message.fields?.miniTapUnmapped).map(message => message.fields),
      [{ miniTapUnmapped: "1", seekMissReason: "noRoot", composedPathTags: "yt-icon" }]);
    env.messages.length = 0;
    env.dispatch("click", blank, { clientX: 362, clientY: 528 });
    env.dispatch("click", blank, { clientX: 362, clientY: 650 });
    const link = env.document.body.appendChild(element("a", { href: "/explore" }));
    env.dispatch("click", link, point);
    assert.deepEqual(env.messages, []);
  }
});

test("collapse arrows cross icon shadow boundaries and report only after the page hides without blocking the website", () => {
  for (const label of ["Back", "Close player", "Collapse", "Minimise player", "Minimize", "Hide player", "Close player page"]) {
    for (const innerButton of [false, true]) {
      const env = start();
      const host = element("yt-icon-button", innerButton ? {} : { "aria-label": label });
      const shadow = host.attachShadow();
      const button = shadow.appendChild(element("button", { id: "button", ...(innerButton ? { "aria-label": label } : {}) }));
      const icon = button.appendChild(element("yt-icon"));
      // Native closest() cannot escape this boundary; closestDeep() must reach the host.
      button.parentElement = null;
      Object.defineProperty(button, "parentNode", { value: { host } });
      const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [host]));
      page.rect = { left: 0, top: 0, width: 402, height: 662 };
      const path = () => [icon, button, shadow, host, page];
      assert.equal(env.dispatch("pointerdown", icon, { composedPath: path }).prevented, false, label);
      const event = env.dispatch("click", icon, { composedPath: path });
      assert.equal(event.prevented, false, label);
      assert.equal(event.stopped, false, label);
      assert.deepEqual(env.messages, []);
      page.setAttribute("hidden", "");
      env.advance(50);
      assert.deepEqual(env.messages.map(message => message.fields), [{ collapsePath: "arrow" }]);
      assert.equal(env.messages.some(message => message.type === "command"), false);
    }
  }
});

// Round 5 — the visible seek line can belong to an otherwise hidden retained page.
test("visible sliders under a hidden player page seek through title links and range inputs", () => {
  for (const input of [false, true]) {
    const env = start();
    env.bar.style.display = "none";
    const slider = element(input ? "input" : "tp-yt-paper-slider", input ? { type: "range" } : { id: "progress-bar" });
    slider.style.visibility = "visible";
    slider.rect = { left: 50, top: 590, width: 300, height: 2 };
    const link = element("a", { href: "watch?v=AAAAAAAAAAA" }, [slider]);
    const title = element("div", { class: "title" }, [link]);
    const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [title]));
    page.rect = { left: 0, top: 0, width: 402, height: 662 };
    page.style.visibility = "hidden";
    assert.equal(page.checkVisibility({ visibilityProperty: true }), false);
    assert.equal(slider.checkVisibility({ visibilityProperty: true }), true);
    const point = { identifier: 7, clientX: 125, clientY: 591 };
    const path = () => [slider, link, title, page];
    for (const [type, options] of [
      ["pointerdown", point], ["touchstart", { touches: [point] }], ["pointerup", point],
      ["touchend", { touches: [], changedTouches: [point] }], ["click", point]
    ]) {
      const event = env.dispatch(type, slider, { ...options, composedPath: path });
      if (type !== "touchstart") assert.equal(event.prevented, true, type);
    }
    assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 50]]);
    assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
    if (!input) {
      env.window.Multimusic.receiveAck({ token: "current-document", commandId: env.messages.find(message => message.type === "command").commandId, status: "completed" });
      env.advance(800);
      env.messages.length = 0;
      env.dispatch("click", link, { clientX: 125, clientY: 584 });
      assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 50]]);
    }
  }
});

test("a two-pixel progress line accepts a tap six pixels above it without claiming Play or list rows", () => {
  const env = start();
  env.bar.rect = { left: 0, top: 542, width: 402, height: 100 };
  env.slider.rect = { left: 50, top: 590, width: 300, height: 2 };
  env.slider.querySelector("#sliderBar").rect = env.slider.rect;
  const title = env.bar.querySelector(".title");
  const link = title.appendChild(element("a", { href: "watch?v=AAAAAAAAAAA" }));
  assert.equal(env.dispatch("click", link, { clientX: 125, clientY: 584 }).prevented, true);
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]), [["seek", 50]]);
  env.messages.length = 0;
  env.dispatch("click", env.play.querySelector("button"), { clientX: 125, clientY: 584 });
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.command), ["play"]);
  env.messages.length = 0;
  const row = song("BBBBBBBBBBB", "A row");
  env.bar.appendChild(row);
  const rowSlider = row.appendChild(element("div", { id: "progress-bar" }));
  rowSlider.rect = env.slider.rect;
  env.dispatch("click", rowSlider, { clientX: 125, clientY: 584 });
  assert.equal(env.messages.some(message => message.command === "seek"), false);
});

test("progress geometry requires a wide visible line and a tap inside its horizontal and vertical bounds", () => {
  for (const [width, x, y, hidden] of [[119, 125, 584, false], [300, 49, 591, false],
    [300, 351, 591, false], [300, 125, 578, false], [300, 125, 584, true]]) {
    const env = start();
    env.bar.rect = { left: 0, top: 0, width: 402, height: 662 };
    env.slider.rect = { left: 50, top: 590, width, height: 2 };
    if (hidden) env.slider.style.display = "none";
    env.dispatch("click", env.bar, { clientX: x, clientY: y });
    assert.equal(env.messages.some(message => message.command === "seek"), false);
  }
});

test("volume sliders never seek even when a generic slider id or range input resembles progress", () => {
  for (const attributes of [{ id: "slider", role: "slider", "aria-label": "Volume" },
    { type: "range", "aria-label": "Volume slider" }, { id: "progress-bar", title: "Volume" }, { id: "slider" }]) {
    const env = start();
    env.bar.rect = { left: 0, top: 542, width: 402, height: 100 };
    env.slider.rect = { left: 50, top: 590, width: 300, height: 2 };
    const volume = element("input", attributes);
    volume.rect = env.slider.rect;
    env.bar.appendChild(element("div", { id: "volume-slider" }, [volume]));
    for (const type of ["pointerdown", "pointerup", "click"]) {
      assert.equal(env.dispatch(type, volume, { clientX: 125, clientY: 591 }).prevented, false);
    }
    assert.equal(env.messages.some(message => message.type === "command" || message.fields?.miniTapUnmapped), false);
    assert.equal(env.messages.find(message => message.fields?.hitX).fields.seekMissReason, "volume");
  }
});

test("an unlabelled expanded-page arrow passes through and reports once after collapse", () => {
  const env = start();
  const arrow = element("yt-icon-button", {}, [element("yt-icon")]);
  const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [arrow]));
  page.rect = { left: 0, top: 0, width: 402, height: 662 };
  const point = { identifier: 1, clientX: 24, clientY: 40 };
  for (const [type, options] of [["pointerdown", point], ["touchstart", { touches: [point] }],
    ["pointerup", point], ["touchend", { touches: [], changedTouches: [point] }], ["click", point]]) {
    const event = env.dispatch(type, arrow.children[0], options);
    assert.equal(event.prevented, false, type);
    assert.equal(event.stopped, false, type);
  }
  assert.deepEqual(env.messages, []);
  page.setAttribute("hidden", "");
  env.advance(50);
  env.advance(1200);
  assert.deepEqual(env.messages.map(message => message.fields), [{ collapsePath: "arrow" }]);
});

test("collapse diagnostics require an actual transition within 1200ms and ignore the top-right kebab", () => {
  for (const scenario of ["no collapse", "late collapse", "kebab", "ordinary expanded tap"]) {
    const env = start();
    const button = element(scenario === "ordinary expanded tap" ? "button" : "yt-icon-button");
    const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [button]));
    page.rect = { left: 0, top: 0, width: 402, height: 662 };
    const point = { clientX: scenario === "kebab" ? 370 : 24, clientY: 40 };
    for (const type of ["pointerdown", "click"]) {
      const event = env.dispatch(type, button, point);
      assert.equal(event.prevented, false, scenario);
      assert.equal(event.stopped, false, scenario);
    }
    if (scenario === "late collapse") env.advance(1201);
    if (scenario !== "no collapse") page.style.display = "none";
    env.advance(50);
    env.advance(1500);
    assert.deepEqual(env.messages, [], scenario);
  }
});

test("an arrow that hides the expanded page on pointer press still reports exactly one collapse", () => {
  const env = start();
  const arrow = element("yt-icon-button");
  const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [arrow]));
  page.rect = { left: 0, top: 0, width: 402, height: 662 };
  const point = { clientX: 24, clientY: 40 };
  const press = env.dispatch("pointerdown", arrow, point);
  assert.equal(press.prevented, false);
  assert.equal(press.stopped, false);
  page.setAttribute("hidden", "");
  assert.equal(env.dispatch("pointerup", arrow, point).prevented, false);
  assert.equal(env.dispatch("click", arrow, point).prevented, false);
  env.advance(50);
  env.advance(1200);
  assert.deepEqual(env.messages.map(message => message.fields), [{ collapsePath: "arrow" }]);
});

test("collapse labels on any path ancestor use aria-label or title and compact-root unmapped behavior stays unchanged", () => {
  for (const attribute of ["aria-label", "title"]) {
    const env = start();
    const icon = element("yt-icon");
    const wrapper = element("div", { [attribute]: "Hide player page" }, [element("span", {}, [icon])]);
    const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [wrapper]));
    page.rect = { left: 0, top: 0, width: 402, height: 662 };
    assert.equal(env.dispatch("click", icon, { clientX: 300, clientY: 200 }).prevented, false);
    page.rect.height = 100;
    env.advance(1200);
    assert.deepEqual(env.messages.map(message => message.fields), [{ collapsePath: "arrow" }]);
  }
  const env = start();
  env.bar.rect = { left: 0, top: 542, width: 402, height: 100 };
  const blank = env.bar.appendChild(element("yt-icon"));
  assert.equal(env.dispatch("pointerdown", blank, { clientX: 390, clientY: 630 }).prevented, true);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped === "1"), true);
});


// Round 6 — the thumbnail is not the progress bar; hit testing must enter shadow roots.
function round6Environment() {
  const env = start();
  env.bar.rect = { left: 0, top: 582, width: 402, height: 80 };
  const thumbnail = element("ytmusic-player");
  thumbnail.rect = { left: 16, top: 593, width: 48, height: 48 };
  env.document.body.children.unshift(thumbnail);
  thumbnail.parentElement = env.document.body;
  env.slider.setAttribute("id", "old-progress");
  env.slider.rect = { left: 0, top: 0, width: 0, height: 0 };
  const host = env.bar.appendChild(element("div"));
  host.rect = { left: 0, top: 578, width: 402, height: 8 };
  const shadow = host.attachShadow();
  const slider = shadow.appendChild(element("tp-yt-paper-slider", { id: "progress-bar", role: "slider" }));
  slider.rect = host.rect;
  slider.checkVisibility = () => false;
  const track = slider.attachShadow().appendChild(element("div", { id: "progressContainer", class: "track" }));
  track.rect = slider.rect;
  // The document exposes only the host; each shadow root exposes its own inner hit.
  env.document.elementsFromPoint = () => [host, env.bar, env.document.body];
  shadow.elementsFromPoint = () => [slider];
  slider.shadowRoot.elementsFromPoint = () => [track];
  env.play.rect = { left: 282, top: 595, width: 48, height: 48 };
  env.next.rect = { left: 338, top: 595, width: 48, height: 48 };
  return { env, host, shadow, slider, track, thumbnail };
}

function pointerTap(env, target, clientX = 156, clientY = 582) {
  env.dispatch("pointerdown", target, { clientX, clientY });
  env.dispatch("pointerup", target, { clientX, clientY });
}

test("Round 6: deep stack seeks the invisible full-width mini slider and records the actual hit geometry", () => {
  const { env, host, track } = round6Environment();
  pointerTap(env, env.document.body);
  const commands = env.messages.filter(message => message.type === "command");
  assert.equal(commands.length, 1);
  assert.equal(commands[0].command, "seek");
  assert.equal(commands[0].position, 156 / 402 * env.snapshot.duration);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
  const hits = env.messages.filter(message => message.fields?.hitX);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].fields.hitX, "156");
  assert.equal(hits[0].fields.hitY, "582");
  assert.equal(hits[0].fields.seekResolved, "true");
  assert.equal(hits[0].fields.seekMissReason, "none");
  assert.equal(hits[0].fields.sliderVis, "false");
  assert.equal(hits[0].fields.seekRectWidth, "402");
  assert.equal(hits[0].fields.seekRectY, "578");
  assert.match(hits[0].fields.hitStack0, /^div#progressContainer\.track@0,578,402,8\^tp-yt-paper-slider$/);
  assert.match(hits[0].fields.hitStack1, /^tp-yt-paper-slider#progress-bar\[slider\]@0,578,402,8\^div$/);
  assert.equal(Object.keys(hits[0].fields).filter(key => key.startsWith("hitStack")).length, 5);
  assert.ok(Object.values(hits[0].fields).every(value => value.length <= 64));
  assert.equal(track.getRootNode().host.tagName, "TP-YT-PAPER-SLIDER");
  assert.equal(host.hasPointerCapture(1), false);
});

test("Round 6: deep stack stops at Play, Next, navigation, rows and volume before an underlying slider", () => {
  for (const kind of ["play", "next", "title", "row", "volume"]) {
    const { env, host, slider } = round6Environment();
    const target = kind === "play" ? env.play : kind === "next" ? env.next :
      env.bar.appendChild(element(kind === "row" ? "ytmusic-player-queue-item" : "div",
        kind === "title" ? { class: "title" } : kind === "volume" ? { role: "slider", "aria-label": "Volume" } : {}));
    env.document.elementsFromPoint = () => [target, host, env.bar];
    const x = kind === "next" ? 362 : 306;
    pointerTap(env, target, x, 619);
    env.dispatch("click", target, { clientX: x, clientY: 619 });
    assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => message.command),
      kind === "play" ? ["play"] : kind === "next" ? ["next"] : [], kind);
    const fields = env.messages.find(message => message.fields?.hitX).fields;
    assert.equal(fields.seekMissReason, { play: "transportOther", next: "transportOther", title: "navigation", row: "row", volume: "volume" }[kind]);
    assert.equal(slider.checkVisibility(), false);
  }
});

test("Round 6: pointer, touch and click send one seek with time-only deduplication across replacement sliders", () => {
  const { env, slider, shadow } = round6Environment();
  const point = { identifier: 9, clientX: 156, clientY: 582 };
  env.dispatch("touchstart", env.document.body, { touches: [point] });
  pointerTap(env, env.document.body);
  const first = env.messages.find(message => message.type === "command");
  env.window.Multimusic.receiveAck({ token: "current-document", commandId: first.commandId, status: "completed",
    snapshot: { ...env.snapshot, position: first.position } });
  const replacement = element("input", { type: "range" });
  replacement.rect = slider.rect;
  replacement.checkVisibility = () => false;
  shadow.replaceChild(replacement, slider);
  shadow.elementsFromPoint = () => [replacement];
  env.dispatch("touchend", env.document.body, { touches: [], changedTouches: [point] });
  env.dispatch("click", env.document.body, point);
  env.advance(799);
  pointerTap(env, env.document.body);
  assert.equal(env.messages.filter(message => message.type === "command").length, 1);
  env.advance(1);
  pointerTap(env, env.document.body);
  assert.equal(env.messages.filter(message => message.type === "command").length, 2);
  assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
  assert.equal(env.messages.filter(message => message.fields?.hitX && message.fields.hitY === "582").length, 4);
});

test("Round 6: stack fallback rejects missing roots, narrow, tall and distant sliders with a reason", () => {
  for (const kind of ["noRoot", "narrow", "tall", "outside"]) {
    const { env, host, slider, track } = round6Environment();
    if (kind === "noRoot") {
      env.bar.children.splice(env.bar.children.indexOf(host), 1);
      env.document.body.appendChild(host);
    }
    if (kind === "narrow") slider.rect = track.rect = { left: 0, top: 578, width: 200, height: 8 };
    if (kind === "tall") slider.rect = track.rect = { left: 0, top: 578, width: 402, height: 49 };
    pointerTap(env, env.document.body, 156, kind === "outside" ? 595 : 582);
    assert.equal(env.messages.some(message => message.type === "command"), false, kind);
    const hit = env.messages.find(message => message.fields?.hitX).fields;
    assert.equal(hit.seekResolved, "false", kind);
    assert.equal(hit.seekMissReason, kind === "tall" ? "outside" : kind, kind);
  }
});

test("Round 6: recognized seek without a slider reports unmapped instead of returning silently", () => {
  const env = start();
  env.slider.setAttribute("hidden", "");
  const control = env.bar.appendChild(element("button", { "aria-label": "Seek" }));
  control.checkVisibility = () => false;
  env.document.elementsFromPoint = () => [control, env.bar];
  env.dispatch("click", control, { clientX: 156, clientY: 582 });
  const fields = env.messages.find(message => message.fields?.miniTapUnmapped)?.fields;
  assert.ok(fields);
  assert.equal(fields.seekMissReason, "notVisible");
  assert.equal(env.messages.some(message => message.type === "command"), false);
});

test("Round 6: periodic diagnostics prefer the visible player bar over the earlier thumbnail", () => {
  const { env } = round6Environment();
  env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: true });
  env.advance(1000);
  const fields = env.messages.find(message => message.fields?.aggregateRoot)?.fields;
  assert.ok(fields);
  assert.equal(fields.aggregateRoot, "ytmusic-player-bar");
  assert.deepEqual([fields.barX, fields.barY, fields.barWidth, fields.barHeight], ["0", "582", "402", "80"]);
});

test("Round 6: expanded sliders retain their existing inner-track geometry", () => {
  const env = start();
  const slider = element("div", { id: "progress-bar" }, [element("div", { id: "sliderBar" }), element("div", { id: "progressContainer" })]);
  slider.rect = { left: 10, top: 350, width: 300, height: 8 };
  slider.children[0].rect = { left: 20, top: 350, width: 100, height: 8 };
  slider.children[1].rect = { left: 0, top: 350, width: 402, height: 8 };
  const page = env.document.body.appendChild(element("ytmusic-player-page", {}, [slider]));
  page.rect = { left: 0, top: 0, width: 402, height: 662 };
  pointerTap(env, slider, 70, 354);
  assert.deepEqual(env.messages.filter(message => message.type === "command").map(message => [message.command, message.position]),
    [["seek", 100]]);
});


test("Round 6: fallback checks the slider host before its track and honors exact size and centre bounds", () => {
  for (const [width, height, y, accepted] of [[200, 8, 582, false], [201, 8, 582, true],
    [402, 48, 602, true], [402, 49, 602, false], [402, 8, 594, true], [402, 8, 595, false]]) {
    const { env, slider, track } = round6Environment();
    slider.rect = { left: 0, top: 578, width, height };
    track.rect = { left: 0, top: 578, width: 402, height: 8 };
    pointerTap(env, env.document.body, 156, y);
    assert.equal(env.messages.some(message => message.command === "seek"), accepted, `${width}/${height}/${y}`);
  }
});

test("Round 6: bottom hit diagnostics require trusted bottom input and remain bounded with long DOM identifiers", () => {
  const { env, track } = round6Environment();
  track.setAttribute("id", "x".repeat(200));
  track.setAttribute("class", "a".repeat(200));
  track.setAttribute("role", "slider");
  env.dispatch("pointerdown", env.document.body, { clientX: 156, clientY: 488 });
  env.dispatch("pointerdown", env.document.body, { clientX: 156, clientY: 582, isTrusted: false });
  env.dispatch("touchend", env.document.body, { touches: [], changedTouches: [{ clientX: 156, clientY: 582 }], isTrusted: false });
  assert.equal(env.messages.some(message => message.fields?.hitX), false);
  env.dispatch("pointerdown", env.document.body, { clientX: 156, clientY: 489 });
  env.dispatch("pointercancel", env.document.body);
  // Even a touchend without a preceding touchstart is useful diagnostic evidence.
  env.dispatch("touchend", env.document.body, { touches: [], changedTouches: [{ clientX: 156, clientY: 582 }] });
  const hits = env.messages.filter(message => message.fields?.hitX);
  assert.equal(hits.length, 2);
  for (const hit of hits) {
    for (let index = 0; index < 5; index++) assert.ok(hit.fields[`hitStack${index}`].length <= 64);
    assert.ok(JSON.stringify({ ...hit.fields, documentId: "a".repeat(32) }).length <= 1024);
  }
});

// Round 7 — the real progress input sits above the mini-player and inside a link.
function round7Environment() {
  const env = start();
  env.bar.setAttribute("hidden", "");
  const thumbnail = element("ytmusic-player");
  thumbnail.rect = { left: 16, top: 593, width: 48, height: 48 };
  const slider = element("input", { class: "ytMusicMiniPlayerProgressBar" });
  slider.rect = { left: 0, top: 582, width: 402, height: 3 };
  const wrapper = element("div", { class: "ytMusicMiniPlayerProgressBarWrapper" }, [slider]);
  wrapper.rect = slider.rect;
  const anchor = element("a", { href: "watch?v=AAAAAAAAAAA" }, [wrapper]);
  const mini = env.document.body.appendChild(element("ytmusic-miniplayer", { class: "ytMusicMiniPlayerHost" }, [thumbnail, anchor]));
  mini.rect = { left: 0, top: 585, width: 402, height: 64 };
  return { env, mini, thumbnail, anchor, slider };
}

test("Round 7: the linked mini-player progress input sends one exact seek above the host", () => {
  for (const detached of [false, true]) for (const visible of [true, false]) for (const direct of [true, false]) {
    const { env, mini, anchor, slider } = round7Environment();
    if (detached) {
      mini.children.splice(mini.children.indexOf(anchor), 1);
      env.document.body.appendChild(anchor);
    }
    slider.checkVisibility = () => visible;
    pointerTap(env, direct ? slider : env.document.body, 0.389 * 402, 582.33);
    const commands = env.messages.filter(message => message.type === "command");
    assert.deepEqual(commands.map(message => [message.command, message.position]), [["seek", 0.389 * env.snapshot.duration]]);
    assert.equal(env.messages.some(message => message.fields?.miniTapUnmapped), false);
    const fields = env.messages.find(message => message.fields?.hitX)?.fields;
    assert.ok(fields);
    assert.equal(fields.seekResolved, "true");
    assert.equal(fields.seekMissReason, "none");
    assert.equal(fields.seekRectWidth, "402");
    assert.equal(fields.seekRectY, "582");
  }
});

test("Round 7: Search, title, kebab and ordinary links never seek the underlying mini progress input", () => {
  for (const kind of ["search", "title", "kebab", "anchor"]) {
    const { env, mini, slider } = round7Environment();
    const target = mini.appendChild(kind === "search" ? element("input", { role: "combobox", "aria-label": "Search" }) :
      kind === "title" ? element("div", { class: "title" }) :
      kind === "kebab" ? element("button", { "aria-label": "More options" }) : element("a", { href: "browse/MPRE_album" }));
    target.rect = { left: 100, top: 595, width: 100, height: 48 };
    env.document.elementsFromPoint = () => [target, slider, mini];
    pointerTap(env, target, 150, 619);
    env.dispatch("click", target, { clientX: 150, clientY: 619 });
    assert.equal(env.messages.some(message => message.command === "seek"), false, kind);
    if (["search", "title", "anchor"].includes(kind)) {
      const fields = env.messages.find(message => message.fields?.hitX)?.fields;
      assert.ok(fields, kind);
      assert.equal(fields.seekResolved, "false", kind);
      assert.equal(fields.seekMissReason, "navigation", kind);
    }
  }
});

test("Round 7: aggregate diagnostics use the full-width mini-player, then prefer a visible wide player bar", () => {
  for (const visibleBar of [false, true]) {
    const { env } = round7Environment();
    env.bar.rect = { left: 0, top: 570, width: 402, height: 79 };
    if (visibleBar) env.bar.removeAttribute("hidden");
    env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: true });
    env.advance(1000);
    const fields = env.messages.find(message => message.fields?.aggregateRoot)?.fields;
    assert.ok(fields);
    assert.equal(fields.aggregateRoot, visibleBar ? "ytmusic-player-bar" : "ytmusic-miniplayer");
    assert.deepEqual([fields.barX, fields.barY, fields.barWidth, fields.barHeight],
      visibleBar ? ["0", "570", "402", "79"] : ["0", "585", "402", "64"]);
  }
});

test("Round 7: a thumbnail alone is never the aggregate player root", () => {
  const env = start();
  env.bar.setAttribute("hidden", "");
  const thumbnail = env.document.body.appendChild(element("ytmusic-player"));
  thumbnail.rect = { left: 16, top: 593, width: 48, height: 48 };
  env.window.Multimusic.applySnapshot({ ...env.snapshot, diagnosticsEnabled: true });
  env.advance(1000);
  const fields = env.messages.find(message => message.fields?.aggregateRoot)?.fields;
  assert.ok(fields);
  assert.equal(fields.aggregateRoot, "none");
  assert.deepEqual([fields.barX, fields.barY, fields.barWidth, fields.barHeight], ["0", "0", "0", "0"]);
});

// Narrow desktop layout (the app's iPhone view): no visible player bar; a layout-level ytmusic-miniplayer
// holds track info + Play/Next, and the 48px ytmusic-player video surface overlays its artwork.
function smallViewportMiniEnvironment({ withTitle = true } = {}) {
  const env = start();
  env.bar.setAttribute("hidden", "");
  const surface = env.document.body.appendChild(element("ytmusic-player", { id: "player" }, [
    element("button", { class: "ytp-play-button", hidden: "" })]));
  surface.rect = { left: 16, top: 818, width: 48, height: 48 };
  const link = element("a", { class: "ytAttributedStringLink", role: "button" }, [], "Ellisar");
  const info = element("ytmusic-track-info", { class: "ytmusicTrackInfoHost" }, [
    element("img", { class: "ytmusicTrackInfoThumbnail", src: "https://i.ytimg.com/vi/youtubeOwn/default.jpg" }),
    ...(withTitle ? [element("div", { class: "ytmusicTrackInfoTitle", title: "NOT ENOUGH" }, [element("span", {}, [], "NOT ENOUGH")])] : []),
    element("div", { class: "ytmusicTrackInfoByline" }, [element("span", { class: "ytmusicTrackInfoBylineItem", title: "Ellisar • NOT ENOUGH • 2026" }, [link])])]);
  const play = element("button", { title: "Play", "aria-label": "Play" }, [element("svg", {}, [element("path", { d: "M0" })])]);
  const next = element("button", { title: "Next", "aria-label": "Next" });
  const mini = env.document.body.appendChild(element("ytmusic-miniplayer", { slot: "player-bar", class: "ytMusicMiniPlayerHost ytMusicMiniPlayerHostSmallViewport" }, [
    element("div", { class: "ytMusicSmallViewportMiniplayerHost" }, [info, element("div", { class: "ytMusicSmallViewportMiniplayerControls" }, [play, next])])]));
  mini.rect = { left: 0, top: 802, width: 402, height: 72 };
  env.mutate([{ type: "childList", target: env.document.body, addedNodes: [surface, mini], removedNodes: [] }]);
  return { env, mini, link, play };
}

test("small-viewport mini-player is painted from Apple Music and the artwork surface is not a broken player", () => {
  const { env, mini, link, play } = smallViewportMiniEnvironment();
  const title = mini.querySelector(".ytmusicTrackInfoTitle");
  assert.equal(title.textContent, env.snapshot.title);
  assert.equal(title.getAttribute("title"), env.snapshot.title);
  assert.equal(link.textContent, env.snapshot.artist);
  assert.equal(mini.querySelector(".ytmusicTrackInfoBylineItem").getAttribute("title"), env.snapshot.artist);
  assert.equal(mini.querySelector("img.ytmusicTrackInfoThumbnail").getAttribute("src"), `https://i.ytimg.com/vi/${env.snapshot.sourceID}/hqdefault.jpg`);
  assert.ok(["Play", "Pause"].includes(play.getAttribute("aria-label")));
  assert.equal(env.messages.some(value => value.status === "adapterChanged"), false);
});

test("a visible mini-player that loses its title still reports adapterChanged", () => {
  const { env } = smallViewportMiniEnvironment({ withTitle: false });
  assert.equal(env.messages.some(value => value.status === "adapterChanged"), true);
});
