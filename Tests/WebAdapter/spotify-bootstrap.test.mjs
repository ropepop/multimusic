import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import { fixture, element } from "./dom-fixture.mjs";

const script = readFileSync(new URL("../../Multimusic/Resources/Spotify.js", import.meta.url), "utf8");

test("Spotify browsing gate acknowledges its document without intercepting or changing original controls", () => {
  const env = fixture([], { host: "open.spotify.com" });
  const link = element("a", { href: "/track/0123456789ABCDEFGHIJKL" }, [], "Original track");
  const play = element("button", { "aria-label": "Play" }, [element("svg")]);
  env.document.body.appendChild(link); env.document.body.appendChild(play);
  const original = env.document.body.children.slice();
  vm.runInNewContext(script, env);
  const snapshot = { ...env.snapshot, sourceProvider: "spotify", sourceID: "0123456789ABCDEFGHIJKL", revision: 3, deliveryId: 1 };
  assert.equal(env.window.Multimusic.activate("spotify-document", snapshot), true);
  assert.equal(env.dispatch("click", link).prevented, false);
  assert.equal(env.dispatch("click", play).prevented, false);
  assert.deepEqual(env.document.body.children, original);
  assert.equal(link.textContent, "Original track");
  assert.equal(play.getAttribute("aria-label"), "Play");
  assert.deepEqual(env.messages.map(({ provider, type }) => [provider, type]), [
    ["spotify", "snapshotAck"], ["spotify", "status"]
  ]);
  assert.equal(env.messages.some(message => ["command", "selection"].includes(message.type)), false);
  assert.equal(env.window.Multimusic.applySnapshot({ ...snapshot, revision: 2, deliveryId: 2 }).accepted, false);
  assert.equal(env.window.Multimusic.applySnapshot({ ...snapshot, sourceID: "AAAAAAAAAAA" }).accepted, false);
  assert.equal(env.window.Multimusic.applySnapshot({ ...snapshot, sourceProvider: "youtubeMusic" }).accepted, false);
  assert.equal(env.messages.length, 2);
  env.dispatch("pagehide", link);
  assert.equal(env.window.Multimusic.applySnapshot({ ...snapshot, deliveryId: 3 }).accepted, false);
  assert.equal(env.window.Multimusic.receiveAck({ token: "spotify-document" }), false);
});

test("the Spotify bridge is unavailable in a foreign document or subframe", () => {
  for (const mode of ["other host", "insecure", "subframe"]) {
    const env = fixture([], { host: mode === "other host" ? "accounts.spotify.com" : "open.spotify.com" });
    if (mode === "insecure") env.location.protocol = "http:";
    if (mode === "subframe") env.window.top = {};
    vm.runInNewContext(script, env);
    assert.equal(env.window.Multimusic, undefined);
    assert.equal(env.messages.length, 0);
  }
});
