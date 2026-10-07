const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const context = vm.createContext({ window: {} });
vm.runInContext(readFileSync(path.join(__dirname, "../client/renderer.js"), "utf8"), context);
const { renderFeed } = context.window.ParleyRenderer;
const names = { seat: (i) => ["Sprocket", "Gizmo"][i], text: (text) => text };

function feed() {
  return { dataset: {}, innerHTML: "", scrollTop: 0, scrollHeight: 1000 };
}

test("chat follows the played event prefix when seeking forward and backward", () => {
  const events = Object.freeze([
    Object.freeze({ kind: "say", seat: 0, round: 0, turn: 1, text: "An opening bargain" }),
    Object.freeze({ kind: "say", seat: 1, round: 0, turn: 2, text: "A future reply" }),
  ]);
  const element = feed();
  renderFeed(element, events, names, 1);
  assert.match(element.innerHTML, /An opening bargain/);
  assert.doesNotMatch(element.innerHTML, /A future reply/);
  renderFeed(element, events, names, 2);
  assert.match(element.innerHTML, /A future reply/);
  renderFeed(element, events, names, 0);
  assert.doesNotMatch(element.innerHTML, /An opening bargain|A future reply/);
});

test("full speech is escaped, and redacted whispers remain private", () => {
  const element = feed();
  const text = "An alliance worth discussing. ".repeat(30) + '\n<img src=x onerror="alert(1)">';
  const events = [
    { kind: "say", seat: 0, round: 0, turn: 1, text },
    { kind: "whisper", seat: 1, target: 0, round: 0, turn: 1 },
  ];
  renderFeed(element, events, names);
  assert.ok(element.innerHTML.includes("An alliance worth discussing. ".repeat(30)));
  assert.match(element.innerHTML, /\n&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
  assert.doesNotMatch(element.innerHTML, /<img|undefined/);
  assert.match(element.innerHTML, /Gizmo → Sprocket/);
});

test("reading earlier chat preserves the scroll position until follow resumes", () => {
  const element = feed();
  element.dataset.follow = "false";
  element.scrollTop = 150;
  const events = [{ kind: "say", seat: 0, round: 0, turn: 1, text: "A new message" }];
  renderFeed(element, events, names, 1);
  assert.equal(element.scrollTop, 150);
  element.dataset.follow = "true";
  renderFeed(element, events, names, 1);
  assert.equal(element.scrollTop, 1000);
});

function replayFixture() {
  const images = [];
  let frame;
  const drawing = new Proxy({}, {
    get: (target, key) => target[key] || (() => {}),
  });
  drawing.measureText = (text) => ({ width: text.length * 6 });
  function element() {
    return {
      ...feed(),
      attributes: {},
      listeners: {},
      style: { setProperty() {} },
      classList: { toggle() {} },
      appendChild() {},
      setAttribute(name, value) { this.attributes[name] = value; },
      addEventListener(name, callback) { this.listeners[name] = callback; },
      getContext: () => drawing,
    };
  }
  const window = { devicePixelRatio: 1, addEventListener() {} };
  const sandbox = vm.createContext({
    window,
    document: { createElement: element, documentElement: element() },
    Image: class { constructor() { images.push(this); } },
    requestAnimationFrame: (callback) => { frame = callback; },
  });
  vm.runInContext(readFileSync(path.join(__dirname, "../client/renderer.js"), "utf8"), sandbox);
  const options = {
    canvas: Object.assign(element(), { clientWidth: 960, clientHeight: 600 }),
    feed: element(), scrub: element(), label: element(), nowPlaying: element(),
    previousButton: element(), nextButton: element(), playButton: element(),
    assetBase: "/assets",
    payload: {
      names: ["Sprocket"],
      events: [
        { kind: "say", seat: 0, round: 0, turn: 1, text: "Opening bargain" },
        { kind: "say", seat: 0, round: 0, turn: 2, text: "Future promise" },
      ],
      states: [[], [], []],
    },
  };
  window.ParleyRenderer.attachReplay(options);
  images.forEach((image) => image.onload());
  return { options, window, drawing, draw: () => frame(0) };
}

test("canvas resolution follows zoom and container resize without changing table proportions", () => {
  const { options, window, drawing, draw } = replayFixture();
  const scales = [];
  drawing.scale = (x, y) => scales.push([x, y]);
  window.devicePixelRatio = 2;
  draw();
  assert.equal(options.canvas.width, 1920);
  assert.equal(options.canvas.height, 1200);
  assert.deepEqual(scales.pop(), [1, 1]);

  // A sidebar can resize the canvas without a window resize event.
  options.canvas.clientWidth = 600;
  options.canvas.clientHeight = 300;
  window.devicePixelRatio = 1.5;
  draw();
  assert.equal(options.canvas.width, 900);
  assert.equal(options.canvas.height, 450);
  assert.deepEqual(scales.pop(), [0.5, 0.5]);
});

test("keyboard seeking and event buttons keep the caption and transcript on the played prefix", () => {
  const { options } = replayFixture();
  const key = (value) => options.scrub.listeners.keydown({ key: value, preventDefault() {} });
  key("ArrowRight");
  assert.match(options.nowPlaying.innerHTML, /Opening bargain/);
  assert.doesNotMatch(options.feed.innerHTML, /Future promise/);
  options.nextButton.onclick();
  assert.match(options.nowPlaying.innerHTML, /Future promise/);
  assert.equal(options.nextButton.disabled, true);
  options.previousButton.onclick();
  assert.doesNotMatch(options.feed.innerHTML, /Future promise/);
  key("Home");
  assert.equal(options.previousButton.disabled, true);
  assert.doesNotMatch(options.feed.innerHTML, /Opening bargain|Future promise/);
  key("End");
  assert.match(options.feed.innerHTML, /Future promise/);
  assert.equal(options.scrub.attributes["aria-valuenow"], "2");
});
