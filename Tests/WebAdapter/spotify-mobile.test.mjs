import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import { fixture, element } from "./dom-fixture.mjs";

const source = readFileSync(new URL("../../Multimusic/Resources/Spotify.js", import.meta.url), "utf8");
const firstID = "45vsoreF31oxkbKL9V7d3R", nextID = "5HR2slVri2Y9wyhSKDj9w6";
const playlistID = "37i9dQZF1E8LNeh11GW481";

function row(id = firstID, title = "BIRDS: SLAYYYTER VERSION", artists = ["Turnstile", "Slayyyter"]) {
  const titleLink = element("a", { href: `/track/${id}` }, [], title);
  const artistLinks = artists.map((name, index) => element("a", {
    href: `/artist/${["2qnpHrOzdmOo1S4ox3j17x", "4QM5QCHicznALtX885CnZC"][index]}`
  }, [], name));
  const metadata = element("div", {}, [titleLink, ...artistLinks]);
  const like = element("button", { "aria-label": "Liked" });
  const more = element("button", { "aria-label": "More", "data-testid": "context-menu-action-button" });
  const node = element("div", { "data-testid": "track-row", role: "group", "aria-label": title }, [
    element("div", {}, [element("div", {}, [metadata])]), like, more
  ]);
  return { node, titleLink, artistLinks, like, more };
}

function setup(rows, options = {}) {
  const env = fixture([], { host: "open.spotify.com" });
  env.location.href = options.url ?? `https://open.spotify.com/playlist/${playlistID}`;
  const collection = element("div", {}, rows.map(value => value.node));
  const play = element("button", { "data-testid": "play-button", "aria-label": "Play" }, [element("svg")]);
  const collectionHeading = element("h1", {}, [], options.collectionTitle ?? "Radio mix");
  const headerMetadata = element("div", {}, [collectionHeading,
    element("a", { href: "/artist/4tZwfgrHOc3mvqYlEYSvVi" }, [], options.collectionArtist ?? "Daft Punk"),
    element("span", {}, [], "2001"), element("span", {}, [], "14 songs, 1 hr 1 min")]);
  const entityPlay = element("div", { "data-testid": "entity-play-button" }, [element("div", {}, [play])]);
  const header = element("div", {}, [headerMetadata, element("div", { "data-testid": "entity-bottom-section" }, [entityPlay])]);
  const entity = element("div", {}, [header, collection]);
  const main = element(options.noMain ? "div" : "main", {}, [entity]);
  env.document.body.appendChild(main);
  if (options.detail) {
    const header = element("div", {}, [element("h1", {}, [], options.detail.title ?? "BIRDS: SLAYYYTER VERSION"),
      element("a", { href: "/artist/2qnpHrOzdmOo1S4ox3j17x" }, [], options.detail.artist ?? "Turnstile"),
      element("span", {}, [], "NEVER ENOUGH: VERSIONS"), element("span", {}, [], "2026"),
      element("span", {}, [], options.detail.duration ?? "3:12")]);
    main.children = [];
    header.appendChild(element("div", { "data-testid": "entity-bottom-section" }, [
      element("div", { "data-testid": "entity-play-button" }, [play])
    ]));
    main.appendChild(element("div", { "data-testid": "track-view" }, [header]));
  }
  vm.runInNewContext(source, env);
  const snapshot = { ...env.snapshot, sourceID: firstID, sourceProvider: "spotify", playbackEnabled: false, revision: 1, deliveryId: 1 };
  assert.equal(env.window.Multimusic.activate("mobile-document", snapshot), true);
  env.messages.length = 0;
  return { ...env, collection, entity, collectionHeading, originalPlay: play, initialSnapshot: snapshot };
}

const selections = env => env.messages.filter(value => value.type === "selection");

test("the original playlist Play sends rendered songs in order and preserves repeated occurrences", () => {
  const rows = [row(), row(), row(nextID, "Music is Code you can Hear", ["DJ_Dave"])];
  const env = setup(rows);
  const original = rows[1].node.children.slice();
  assert.equal(env.dispatch("click", env.originalPlay).prevented, true);
  const [selection] = selections(env);
  assert.ok(selection, "the mobile row must reach the native bridge");
  assert.match(selection.commandId, /^[a-f0-9]{32}$/);
  assert.equal(selection.provider, "spotify");
  assert.equal(selection.token, "mobile-document");
  assert.deepEqual(selection.tracks.map(value => value.id), [firstID, firstID, nextID]);
  assert.equal(selection.tracks[0].title, "BIRDS: SLAYYYTER VERSION");
  assert.equal(selection.tracks[0].artist, "Turnstile & Slayyyter");
  assert.equal("duration" in selection.tracks[0], false);
  assert.equal("isExplicit" in selection.tracks[0], false);
  assert.deepEqual(selection.context, { provider: "spotify", kind: "playlist", collectionID: playlistID,
    selectedSourceID: firstID, selectedOrdinal: 0 });
  assert.equal(selection.omitted, 0);
  assert.deepEqual(rows[1].node.children, original);
  assert.equal(rows[1].titleLink.getAttribute("href"), `/track/${firstID}`);
  const second = env.dispatch("click", env.originalPlay);
  assert.equal(second.prevented, true);
  assert.deepEqual(selections(env)[1].tracks.map(value => value.id), [firstID, firstID, nextID]);
  assert.notEqual(selections(env)[1].commandId, selection.commandId);
});

test("mobile selection leaves artist links, More, Like, modified links and scrolling with Spotify", () => {
  const song = row();
  const env = setup([song]);
  for (const target of [song.node, song.titleLink, ...song.artistLinks, song.like, song.more]) {
    assert.equal(env.dispatch("click", target).prevented, false);
  }
  assert.equal(env.dispatch("click", song.titleLink, { metaKey: true }).prevented, false);
  assert.equal(env.dispatch("click", song.node, { isTrusted: false }).prevented, false);
  env.dispatch("touchstart", env.originalPlay, { touches: [{ identifier: 1, clientX: 10, clientY: 10 }] });
  assert.equal(env.dispatch("touchmove", env.originalPlay, { changedTouches: [{ identifier: 1, clientX: 10, clientY: 80 }] }).prevented, false);
  assert.equal(env.dispatch("touchend", env.originalPlay, { touches: [], changedTouches: [{ identifier: 1, clientX: 10, clientY: 80 }] }).prevented, false);
  assert.equal(selections(env).length, 0);
  env.dispatch("touchstart", env.originalPlay, { touches: [{ identifier: 2, clientX: 20, clientY: 20 }] });
  assert.equal(env.dispatch("touchend", env.originalPlay, { touches: [], changedTouches: [{ identifier: 2, clientX: 22, clientY: 22 }] }).prevented, true);
  assert.equal(selections(env).length, 1);
});

test("mobile track-row whitespace opens its associated song without app promotion or native playback", () => {
  const make = () => {
    const song = row("098ttCNmncrO4YvqWUNMvn", "High Life", ["Daft Punk"]);
    song.node.setAttribute("data-encore-id", "listRow");
    const primary = song.node.children[0];
    primary.setAttribute("class", "e-10860-legacy-list-row__on-click");
    return { song, primary, env: setup([song]) };
  };
  for (const kind of ["click", "touch"]) {
    const { song, primary, env } = make(), children = song.node.children.slice();
    if (kind === "touch") env.dispatch("touchstart", primary, { touches: [{ identifier: 7, clientX: 93, clientY: 189 }] });
    const event = kind === "click" ? env.dispatch("click", primary) : env.dispatch("touchend", primary,
      { touches: [], changedTouches: [{ identifier: 7, clientX: 93, clientY: 189 }] });
    assert.equal(event.prevented, true);
    assert.equal(env.location.href, "https://open.spotify.com/track/098ttCNmncrO4YvqWUNMvn");
    assert.equal(env.messages.length, 0);
    assert.equal(song.titleLink.getAttribute("href"), "/track/098ttCNmncrO4YvqWUNMvn");
    assert.deepEqual(song.node.children, children);
  }
  for (const gesture of ["title", "artist", "like", "more", "modified", "untrusted", "swipe"]) {
    const { song, primary, env } = make(), before = env.location.href;
    if (gesture === "swipe") {
      env.dispatch("touchstart", primary, { touches: [{ identifier: 9, clientX: 93, clientY: 189 }] });
      env.dispatch("touchend", primary, { touches: [], changedTouches: [{ identifier: 9, clientX: 93, clientY: 240 }] });
    } else {
      const target = { title: song.titleLink, artist: song.artistLinks[0], like: song.like, more: song.more }[gesture] || primary;
      assert.equal(env.dispatch("click", target, gesture === "modified" ? { metaKey: true } :
        gesture === "untrusted" ? { isTrusted: false } : {}).prevented, false);
    }
    assert.equal(env.location.href, before);
    assert.equal(env.messages.length, 0);
  }
  for (const corrupt of [song => song.titleLink.setAttribute("href", "https://other.example/track/098ttCNmncrO4YvqWUNMvn"),
    song => song.titleLink.setAttribute("href", "https://user:pass@open.spotify.com/track/098ttCNmncrO4YvqWUNMvn"),
    song => song.titleLink.setAttribute("href", "/track/short"),
    song => song.node.appendChild(element("a", { href: `/track/${nextID}` }, [], "Another song"))]) {
    const { song, primary, env } = make(), before = env.location.href;
    corrupt(song);
    env.dispatch("click", primary);
    assert.equal(env.location.href, before);
    assert.equal(selections(env).length, 0);
  }
});

test("unreadable or ambiguous song evidence reports a skip without replacing the current queue", () => {
  for (const invalid of [row(firstID, "Song", []), row(firstID, "", ["Artist"]), row("not-a-public-id")]) {
    const env = setup([invalid]);
    assert.equal(env.dispatch("click", env.originalPlay).prevented, true);
    assert.equal(selections(env).length, 0);
    assert.equal(env.messages.at(-1).status, "unreadable");
  }
  const ambiguous = row();
  ambiguous.node.appendChild(element("a", { href: `/track/${nextID}` }, [], "Other song"));
  const env = setup([ambiguous]);
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env).length, 0);
  assert.equal(env.messages.at(-1).status, "unreadable");
});

test("a track detail Play uses its actual title, primary artist and duration without inventing secondary metadata", () => {
  const env = setup([], { url: `https://open.spotify.com/track/${firstID}`, detail: {} });
  assert.equal(env.dispatch("click", env.originalPlay).prevented, true);
  const [selection] = selections(env);
  assert.ok(selection);
  assert.deepEqual(selection.tracks, [{ id: firstID, title: "BIRDS: SLAYYYTER VERSION", artist: "Turnstile", duration: 192 }]);
  assert.equal(selection.context.kind, "watch");
  assert.equal(selection.context.selectedSourceID, firstID);
});

test("a recommendation Play inside a track detail never selects the header song", () => {
  const env = setup([], { url: `https://open.spotify.com/track/${firstID}`, detail: {} });
  const recommendation = row(nextID, "Music is Code you can Hear", ["DJ_Dave"]);
  const play = element("button", { "data-testid": "play-button", "aria-label": "Play" });
  recommendation.node.appendChild(play);
  env.originalPlay.closest('[data-testid="track-view"]').appendChild(recommendation.node);
  env.dispatch("click", play);
  assert.equal(selections(env).length, 0);
  assert.equal(env.messages.at(-1).status, "unreadable");
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env)[0].tracks[0].id, firstID);
});

test("the actual detail header Play stays usable beside recommendation and video Play buttons", () => {
  const env = setup([], { url: `https://open.spotify.com/track/${firstID}`, detail: {} });
  const detail = env.originalPlay.closest('[data-testid="track-view"]');
  const unrelatedPlay = element("button", { "data-testid": "play-button", "aria-label": "Play" });
  detail.appendChild(element("section", {}, [element("h2", {}, [], "Music video"), unrelatedPlay]));
  env.dispatch("click", unrelatedPlay);
  assert.equal(selections(env).length, 0, "a different Play must not borrow the header identity");
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env)[0]?.tracks[0].id, firstID, "the unique associated primary Play must work");
  const duplicate = element("button", { "data-testid": "play-button", "aria-label": "Play" });
  env.originalPlay.closest('[data-testid="entity-bottom-section"]').appendChild(duplicate);
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env).length, 1, "a genuinely ambiguous primary header must remain rejected");
});

function searchResult(options = {}) {
  const id = options.id ?? "2LD2gT7gwAurzdQDQtILds", title = "Veridis Quo";
  const labelID = `listrow-title-${id}`;
  const titleSpan = element("span", {}, [], title);
  const label = element("div", { id: labelID }, [titleSpan]);
  const subtitle = element("span", { "data-encore-id": "text" }, [], options.subtitle ?? "Song • Daft Punk");
  const more = element("button", { "aria-label": "More" });
  const artist = element("a", { href: "/artist/4tZwfgrHOc3mvqYlEYSvVi" }, [], "Daft Punk");
  const node = element("div", { role: "group", "aria-label": title, "aria-labelledby": labelID }, [label, subtitle, more, artist]);
  const env = setup([], { url: "https://open.spotify.com/search/results/Daft%20Punk%20Discovery" });
  const search = element("div", { "data-testid": "search-page" }, [node]);
  env.document.body.appendChild(search);
  return { env, node, titleSpan, label, subtitle, more, artist, search };
}

test("the observed accessible Search song association opens its public mobile detail without selecting music", () => {
  const result = searchResult(), { env } = result;
  assert.equal(env.dispatch("click", result.titleSpan).prevented, true);
  assert.equal(env.location.href, "https://open.spotify.com/track/2LD2gT7gwAurzdQDQtILds");
  assert.equal(selections(env).length, 0, "browsing to details must leave the live queue untouched");
  assert.equal(result.label.id, "listrow-title-2LD2gT7gwAurzdQDQtILds");
  const tapped = searchResult();
  tapped.env.dispatch("touchstart", tapped.titleSpan, { touches: [{ identifier: 7, clientX: 10, clientY: 10 }] });
  assert.equal(tapped.env.dispatch("touchend", tapped.titleSpan,
    { touches: [], changedTouches: [{ identifier: 7, clientX: 11, clientY: 11 }] }).prevented, true);
  assert.equal(tapped.env.location.href, "https://open.spotify.com/track/2LD2gT7gwAurzdQDQtILds");
});

test("Search navigation preserves other controls and rejects unreadable or mismatched public song associations", () => {
  for (const target of ["more", "artist"]) {
    const r = searchResult(), before = r.env.location.href;
    assert.equal(r.env.dispatch("click", r[target]).prevented, false);
    assert.equal(r.env.location.href, before);
  }
  for (const event of [{ metaKey: true }, { isTrusted: false }]) {
    const r = searchResult(), before = r.env.location.href;
    assert.equal(r.env.dispatch("click", r.titleSpan, event).prevented, false);
    assert.equal(r.env.location.href, before);
  }
  for (const subtitle of ["Album • Daft Punk", "Artist", "Playlist • Daft Punk"]) {
    const r = searchResult({ subtitle }), before = r.env.location.href;
    assert.equal(r.env.dispatch("click", r.titleSpan).prevented, false);
    assert.equal(r.env.location.href, before);
  }
  for (const corrupt of [r => r.node.setAttribute("aria-labelledby", "listrow-title-short"),
    r => r.node.setAttribute("aria-label", "Different song"), r => r.label.setAttribute("hidden", ""),
    r => { r.node.children = r.node.children.filter(e => e !== r.label); r.search.appendChild(r.label); }]) {
    const r = searchResult(), before = r.env.location.href;
    corrupt(r);
    r.env.dispatch("click", r.node);
    assert.equal(r.env.location.href, before, "invalid association cannot invent a public route");
    assert.equal(selections(r.env).length, 0);
    assert.equal(r.env.messages.at(-1)?.status, "unreadable");
  }
  const scrolled = searchResult(), before = scrolled.env.location.href;
  scrolled.env.dispatch("touchstart", scrolled.titleSpan, { touches: [{ identifier: 9, clientX: 10, clientY: 10 }] });
  scrolled.env.dispatch("touchmove", scrolled.titleSpan, { changedTouches: [{ identifier: 9, clientX: 10, clientY: 80 }] });
  assert.equal(scrolled.env.dispatch("touchend", scrolled.titleSpan,
    { touches: [], changedTouches: [{ identifier: 9, clientX: 10, clientY: 80 }] }).prevented, false);
  assert.equal(scrolled.env.location.href, before);
});

test("hidden retained metadata and controls cannot alter a visible song capture", () => {
  const song = row(), env = setup([song]);
  const hidden = element("div", { hidden: "" }, [
    element("a", { href: `/track/${nextID}` }, [], "Unrelated song"),
    element("a", { href: "/artist/4QM5QCHicznALtX885CnZC" }, [], "Wrong artist"),
    element("span", {}, [], "9:59"), element("span", { "aria-label": "Explicit" }),
    element("button", { "data-testid": "play-button", "aria-label": "Play" })
  ]);
  song.node.appendChild(hidden);
  env.dispatch("click", env.originalPlay);
  const [selection] = selections(env);
  assert.ok(selection);
  assert.equal(selection.tracks[0].artist, "Turnstile & Slayyyter");
  assert.equal("duration" in selection.tracks[0], false);
  assert.equal("isExplicit" in selection.tracks[0], false);
});

test("an album without an associated header artist preserves the queue and explains the unreadable selection", () => {
  const first = row(), next = row(nextID, "Other song", ["Other artist"]);
  const env = setup([first, next], { url: "https://open.spotify.com/album/0123456789ABCDEFGHIJKL", collectionArtist: "" });
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env).length, 0);
  assert.equal(env.messages.at(-1).status, "unreadable");
});

test("the actual mobile entity shape needs no main ancestor and preserves exact album edition context", () => {
  const first = row("0DiWol3AO6WpXZgp0goxAV", "One More Time", ["Daft Punk"]), next = row(nextID, "Another recording", ["Daft Punk"]);
  const env = setup([first, next], { noMain: true, url: "https://open.spotify.com/album/2noRn2Aes5aoNVsU6iWThc",
    collectionTitle: "Discovery (Deluxe Edition)", collectionArtist: "Daft Punk" });
  env.dispatch("click", env.originalPlay);
  const [selection] = selections(env);
  assert.ok(selection, "the rendered entity scope must work without an invented main wrapper");
  assert.deepEqual(selection.tracks.map(value => value.id), [first.titleLink.getAttribute("href").split("/").at(-1), nextID]);
  assert.deepEqual(selection.context, { provider: "spotify", kind: "album", collectionID: "2noRn2Aes5aoNVsU6iWThc",
    title: "Discovery (Deluxe Edition)", artist: "Daft Punk", selectedSourceID: "0DiWol3AO6WpXZgp0goxAV", selectedOrdinal: 0 });
  assert.equal("duration" in selection.tracks[0], false);
  assert.equal("isExplicit" in selection.tracks[0], false);
});

test("the nearest entity scope excludes sibling recommendations and rejects competing headers", () => {
  const env = setup([row()], { noMain: true });
  const other = row(nextID, "Unrelated recommendation", ["Other artist"]);
  env.entity.parentElement.appendChild(element("div", {}, [element("h1", {}, [], "Other collection"),
    element("button", { "data-testid": "play-button", "aria-label": "Play" }), other.node]));
  env.dispatch("click", env.originalPlay);
  assert.deepEqual(selections(env)[0].tracks.map(value => value.id), [firstID]);
  const ambiguous = setup([row()], { noMain: true });
  ambiguous.entity.appendChild(element("h1", {}, [], "Competing collection"));
  ambiguous.dispatch("click", ambiguous.originalPlay);
  assert.equal(selections(ambiguous).length, 0);
  assert.equal(ambiguous.messages.at(-1).status, "unreadable");
});

test("an empty or loading collection cannot borrow outer recommendation rows", () => {
  for (const loading of [false, true]) {
    const own = row("0DiWol3AO6WpXZgp0goxAV", "One More Time", ["Daft Punk"]);
    if (loading) own.node.setAttribute("hidden", "");
    const env = setup(loading ? [own] : [], { noMain: true,
      url: "https://open.spotify.com/album/2noRn2Aes5aoNVsU6iWThc", collectionTitle: "Discovery" });
    env.entity.parentElement.appendChild(element("section", {}, [element("h2", {}, [], "Recommended"),
      row(nextID, "Unrelated recommendation", ["Other artist"]).node]));
    env.dispatch("click", env.originalPlay);
    assert.equal(selections(env).length, 0, "outer rows must never be relabelled as this album");
    assert.equal(env.messages.at(-1).status, "unreadable");
  }
});

test("native acknowledgements settle one selection and retries retain its exact command ID", () => {
  const song = row(), env = setup([song]);
  env.dispatch("click", env.originalPlay);
  const first = selections(env)[0];
  assert.ok(first);
  env.advance(1000);
  assert.equal(selections(env).length, 2);
  assert.equal(selections(env)[1].commandId, first.commandId);
  assert.equal(env.window.Multimusic.receiveAck({ token: "old-document", commandId: first.commandId, status: "completed" }), false);
  assert.equal(env.window.Multimusic.receiveAck({ token: first.token, commandId: first.commandId, status: "pending" }), true);
  env.advance(1000);
  assert.equal(selections(env).length, 2);
  env.advance(500);
  assert.equal(selections(env).length, 3);
  assert.equal(selections(env)[2].commandId, first.commandId);
  assert.equal(env.window.Multimusic.receiveAck({ token: first.token, commandId: first.commandId, status: "completed",
    snapshot: { ...env.initialSnapshot, revision: 4, position: 50, deliveryId: 4 } }), true);
  assert.equal(env.window.Multimusic.applySnapshot({ ...env.initialSnapshot, revision: 3, deliveryId: 5 }).accepted, false);
  env.advance(5000);
  assert.equal(selections(env).length, 3);
});

test("a failed bridge post remains retryable, and page replacement retires the old request", () => {
  const song = row(), env = setup([song]);
  const handler = env.window.webkit.messageHandlers.multimusic;
  const original = handler.postMessage;
  let rejected;
  handler.postMessage = payload => { rejected = payload; handler.postMessage = original; throw new Error("delivery failed"); };
  assert.doesNotThrow(() => env.dispatch("click", env.originalPlay));
  assert.ok(rejected, "a selected song must attempt delivery");
  env.advance(1000);
  assert.equal(selections(env)[0].commandId, rejected.commandId);
  const request = selections(env)[0];
  env.window.Multimusic.activate("new-document", { ...env.initialSnapshot, revision: 1 });
  env.advance(5000);
  assert.equal(selections(env).length, 1);
  assert.equal(env.window.Multimusic.receiveAck({ token: request.token, commandId: request.commandId, status: "completed" }), false);
  env.dispatch("pagehide", song.node);
  assert.equal(env.dispatch("click", env.originalPlay).prevented, false);
});

test("progress snapshots do no row scans and failed snapshot receipts can retry", () => {
  const env = setup([row()]);
  env.initialSnapshot.diagnosticsEnabled = true;
  const nodes = [env.document, ...env.document.querySelectorAll("*")];
  let scans = 0;
  for (const node of nodes) {
    const query = node.querySelectorAll.bind(node);
    node.querySelectorAll = selector => { scans++; return query(selector); };
  }
  for (let revision = 2; revision <= 12; revision++) {
    assert.equal(env.window.Multimusic.applySnapshot({ ...env.initialSnapshot, position: revision, revision, deliveryId: revision }).accepted, true);
  }
  assert.equal(scans, 0);
  env.advance(1000);
  assert.equal(scans, 0, "diagnostic flush must not scan the page either");
  assert.equal(env.messages.find(message => message.type === "diagnostic")?.fields.progressRowsScanned, "0");
  const handler = env.window.webkit.messageHandlers.multimusic;
  const post = handler.postMessage;
  handler.postMessage = () => { throw new Error("receipt failed"); };
  const value = { ...env.initialSnapshot, revision: 13, deliveryId: 13 };
  assert.equal(env.window.Multimusic.applySnapshot(value).accepted, false);
  handler.postMessage = post;
  assert.equal(env.window.Multimusic.applySnapshot(value).accepted, true);
  assert.equal(env.messages.at(-1).deliveryId, 13);
});


const diagnosticRows = env => env.messages.filter(value => value.type === "diagnostic" && value.event === "web.aggregate");

test("opt-in diagnostics measure one slow capture through nested touch handling without painting or exposing metadata", () => {
  const song = row(), env = setup([song]);
  env.advance(2000);
  assert.equal(diagnosticRows(env).length, 0, "diagnostics must remain quiet by default");
  assert.equal(env.window.Multimusic.applySnapshot({ ...env.initialSnapshot, diagnosticsEnabled: true,
    sourceProvider: "youtubeMusic", revision: 2, deliveryId: 2 }).accepted, false);
  env.advance(1000);
  assert.equal(diagnosticRows(env).length, 0, "a rejected snapshot cannot enable diagnostics");
  const originalChildren = song.node.children.slice(), originalAttributes = [...song.node.attributes];
  let runtime = 0;
  env.performance.now = () => runtime;
  const query = song.node.querySelectorAll.bind(song.node);
  song.node.querySelectorAll = selector => {
    if (selector === 'a[href*="/track/"]') runtime += 60;
    return query(selector);
  };
  assert.equal(env.window.Multimusic.applySnapshot({ ...env.initialSnapshot, diagnosticsEnabled: true,
    revision: 2, deliveryId: 2 }).accepted, true);
  env.dispatch("touchstart", env.originalPlay, { touches: [{ identifier: 8, clientX: 20, clientY: 20 }] });
  env.dispatch("touchend", env.originalPlay, { touches: [], changedTouches: [{ identifier: 8, clientX: 20, clientY: 20 }] });
  assert.equal(selections(env).length, 1);
  env.advance(999);
  assert.equal(diagnosticRows(env).length, 0, "measurement must not emit on the input path");
  env.advance(1);
  const [message] = diagnosticRows(env);
  assert.ok(message, "trusted opt-in must emit measured runtime through the existing native bridge");
  assert.deepEqual(message.fields, { adapterTaskMaxMs: "60", adapterOver50Count: "1", rowsScanned: "1", progressRowsScanned: "0" });
  assert.equal(message.provider, "spotify");
  assert.equal(message.token, "mobile-document");
  assert.deepEqual(song.node.children, originalChildren);
  assert.deepEqual([...song.node.attributes], originalAttributes);
  assert.equal("renders" in message.fields, false, "an adapter that does not paint must not manufacture render samples");
});

test("OFF clears unsent measurements and page replacement retires diagnostics until a fresh opt-in", () => {
  const song = row(), env = setup([song]);
  let runtime = 0;
  env.performance.now = () => runtime;
  const query = song.node.querySelectorAll.bind(song.node);
  song.node.querySelectorAll = selector => {
    if (selector === 'a[href*="/track/"]') runtime += 60;
    return query(selector);
  };
  const snapshot = (revision, diagnosticsEnabled) => ({ ...env.initialSnapshot, revision, deliveryId: revision, diagnosticsEnabled });
  env.window.Multimusic.applySnapshot(snapshot(2, true));
  env.dispatch("click", env.originalPlay);
  env.window.Multimusic.applySnapshot(snapshot(3, false));
  env.advance(2000);
  assert.equal(diagnosticRows(env).length, 0, "OFF must stop the timer and discard unsent old measurements");
  env.window.Multimusic.applySnapshot(snapshot(4, true));
  env.advance(1000);
  assert.ok(diagnosticRows(env).at(-1), "a fresh opt-in must emit a new measurement interval");
  assert.deepEqual(diagnosticRows(env).at(-1).fields,
    { adapterTaskMaxMs: "0", adapterOver50Count: "0", rowsScanned: "0", progressRowsScanned: "0" });
  const count = diagnosticRows(env).length;
  env.dispatch("pagehide", song.node);
  env.advance(2000);
  assert.equal(diagnosticRows(env).length, count, "retiring a document must cancel its diagnostic timer");
  env.window.Multimusic.activate("fresh-document", { ...env.initialSnapshot, revision: 1, deliveryId: 1, diagnosticsEnabled: false });
  env.advance(2000);
  assert.equal(diagnosticRows(env).length, count, "a new document cannot inherit the old opt-in");
});

test("CSS-hidden duration cells are read without admitting explicitly hidden stale metadata", () => {
  for (const explicitlyHidden of [false, true]) {
    const song = row();
    const cell = element("div", { "data-testid": "tracklist-row-duration", ...(explicitlyHidden ? { hidden: "" } : {}) }, [], "3:12");
    cell.getClientRects = () => [];
    song.node.appendChild(cell);
    const env = setup([song]);
    env.dispatch("click", env.originalPlay);
    assert.equal(selections(env)[0].tracks[0].duration, explicitlyHidden ? undefined : 192);
  }
});

test("Spotify capture sends declared count and the 50-row cap", () => {
  const rows = Array.from({ length: 55 }, () => row());
  const env = setup(rows);
  env.collectionHeading.parentElement.querySelectorAll("span").find(node => node.textContent.includes("songs")).textContent = "153 songs";
  env.dispatch("click", env.originalPlay);
  assert.equal(selections(env)[0].tracks.length, 50);
  assert.equal(selections(env)[0].declaredCount, 153);
  assert.equal(selections(env)[0].capped, true);
});
