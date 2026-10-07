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
