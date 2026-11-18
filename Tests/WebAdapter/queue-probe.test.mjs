import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../../Multimusic/Resources/QueueProbe.js', import.meta.url), 'utf8');
test('queue probe is opt-in, hashes row identities, samples capture/+1/+10 and cancels when disabled', () => {
  const events = [], timers = new Map(); let sequence = 0;
  const row = { getClientRects: () => [1], querySelector: () => ({ getAttribute: () => '/watch?v=privateSong&list=privateList' }), getAttribute: key => key === 'aria-selected' ? 'true' : null, hasAttribute: () => false };
  const video = { paused: true, currentTime: 21.5 };
  const document = { addEventListener() {}, querySelectorAll: selector => selector === 'ytmusic-player-queue-item' ? [row] : selector === 'video' ? [video] : [] };
  const window = { addEventListener() {} }; window.top = window;
  const context = { window, document, location: { href: 'https://music.youtube.com/watch?v=privateSong&list=privateList' }, URL,
    setInterval: fn => { timers.set(++sequence, fn); return sequence; }, clearInterval: id => timers.delete(id),
    setTimeout: (fn, ms) => { timers.set(++sequence, { fn, ms }); return sequence; }, clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(source, context);
  const probe = window.MultimusicQueueProbe;
  probe.capture(); assert.equal(events.length, 0); assert.equal(timers.size, 0);
  probe.configure(true, fields => events.push(fields)); probe.capture();
  assert(events.some(e => e.qpKind === 'row' && e.qpRowID.match(/^[0-9a-f]{8}$/)));
  assert(events.some(e => e.qpKind === 'capture' && e.qpSelected === '0' && e.qpTime === '21500'));
  for (const [id, entry] of [...timers]) if (entry.fn) { timers.delete(id); entry.fn(); }
  assert(events.some(e => e.qpKind === 'plus1')); assert(events.some(e => e.qpKind === 'plus10'));
  assert(!JSON.stringify(events).includes('private'));
  probe.configure(false, fields => events.push(fields)); const count = events.length;
  probe.capture(); assert.equal(events.length, count); assert.equal(timers.size, 0);
});
test('image-only queue rows use the existing public thumbnail identity convention', () => {
  const events = [];
  const row = { getClientRects: () => [1], querySelector: () => null,
    querySelectorAll: selector => selector === 'img' ? [{ currentSrc: 'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg' }] : [],
    getAttribute: () => null, hasAttribute: () => false };
  const document = { addEventListener() {}, querySelectorAll: selector => selector === 'ytmusic-player-queue-item' ? [row] : [] };
  const window = { addEventListener() {} }; window.top = window;
  vm.runInNewContext(source, { window, document, location: { href: 'https://music.youtube.com/' }, URL,
    setInterval: () => 1, clearInterval() {}, setTimeout: () => 2, clearTimeout() {} });
  window.MultimusicQueueProbe.configure(true, fields => events.push(fields));
  assert(events.some(e => e.qpKind === 'row' && /^[0-9a-f]{8}$/.test(e.qpRowID)));
  assert(!JSON.stringify(events).includes('abcdefghijk'));
});
test('window capture records header and queue taps before the adapter stops propagation', () => {
  const events = [], handlers = {};
  const document = { querySelectorAll: () => [] };
  const window = { addEventListener: (type, fn, options) => { assert(options.capture && options.passive); handlers[type] = fn; } }; window.top = window;
  vm.runInNewContext(source, { window, document, location: { href: 'https://music.youtube.com/' }, URL,
    setInterval: () => 1, clearInterval() {}, setTimeout: () => 2, clearTimeout() {} });
  window.MultimusicQueueProbe.configure(true, fields => events.push(fields));
  for (const action of ['Play', 'Shuffle']) {
    const button = { matches: selector => selector.includes('button'), getAttribute: () => action };
    const header = { matches: selector => selector.includes('header-renderer') };
    handlers.touchend({ composedPath: () => [button, header] });
  }
  handlers.touchend({ composedPath: () => [{ matches: selector => selector === 'ytmusic-player-queue-item' }] });
  assert(events.some(e => e.qpKind === 'headerPlay'));
  assert(events.some(e => e.qpKind === 'headerShuffle'));
  assert(events.some(e => e.qpKind === 'queueTap'));
});
