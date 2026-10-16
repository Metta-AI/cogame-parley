const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");
const sandbox = vm.createContext({ window: {}, Map });
vm.runInContext(readFileSync(path.join(__dirname, "../client/reasoning.js"), "utf8"), sandbox);
const { parseTrace, activeDecision, attach } = sandbox.window.ParleyReasoning;
const action = { say: "A bargain", shoot: "Gizmo", aim: "hip" };
const payload = {
  decisionRefs: [{ id: 10, seat: 4, phase: "shot", action, eventBefore: 22, eventAfter: 25 }],
};
function capture(reasoning = "Keep my friend alive.") {
  return {
    protocol: "parley.inference-capture.v1",
    decision_id: "10",
    seat: 4,
    raw_response: JSON.stringify({
      choices: [{ message: { content: JSON.stringify(action), reasoning } }],
    }),
  };
}

test("saved player artifact reasoning joins to its replay decision", () => {
  const result = parseTrace(JSON.stringify(capture()), payload);
  assert.equal(result.get(10).text, "Keep my friend alive.");
  assert.equal(activeDecision(payload.decisionRefs, 22), undefined);
  assert.equal(activeDecision(payload.decisionRefs, 23).id, 10);
  assert.equal(activeDecision(payload.decisionRefs, 25).id, 10);
  assert.equal(activeDecision(payload.decisionRefs, 26), undefined);
});

test("canonical trajectory selects only the executed attempt", () => {
  const record = {
    schema_version: "1",
    event_type: "decision",
    game: "parley",
    decision_id: "10",
    seat: "4",
    selected_attempt_id: "accepted",
    executed_action: action,
    attempts: [
      { attempt_id: "rejected", raw_response: "not a response" },
      { attempt_id: "accepted", raw_response: capture().raw_response },
    ],
  };
  const episode = { event_type: "episode", game: "parley" };
  assert.equal(
    parseTrace(JSON.stringify(record) + "\n" + JSON.stringify(episode), payload).size,
    1,
  );
});

test("supports saved reasoning_content and native thinking blocks", () => {
  const record = capture();
  for (const message of [
    { content: JSON.stringify(action), reasoning_content: "A saved reason" },
    {
      content: [
        { type: "thinking", thinking: "A saved reason" },
        { type: "text", text: JSON.stringify(action) },
      ],
    },
  ]) {
    record.raw_response = JSON.stringify({ choices: [{ message }] });
    assert.equal(parseTrace(JSON.stringify(record), payload).get(10).text, "A saved reason");
  }
});

test("missing reasoning never treats public speech as private reasoning", () => {
  assert.equal(parseTrace(JSON.stringify(capture(null)), payload).size, 0);
  assert.equal(parseTrace(JSON.stringify(capture("  ")), payload).size, 0);
});

test("wrong replay, wrong seat, duplicate decisions, and malformed files fail explicitly", () => {
  const record = capture();
  assert.throws(
    () => parseTrace(JSON.stringify({ ...record, decision_id: "11" }), payload),
    /decision or seat/,
  );
  assert.throws(
    () => parseTrace(JSON.stringify({ ...record, seat: 0 }), payload),
    /decision or seat/,
  );
  const other = structuredClone(payload);
  other.decisionRefs[0].action.say = "Another episode";
  assert.equal(parseTrace(JSON.stringify(record), other).get(10).actionMatches, false);
  assert.throws(
    () => parseTrace(JSON.stringify(record) + "\n" + JSON.stringify(record), payload),
    /Multiple traces/,
  );
  assert.throws(() => parseTrace("not json", payload));
  assert.throws(() => parseTrace(JSON.stringify(record), {}), /no decision references/);
  assert.throws(() => parseTrace("{}", payload), /Use Parley/);
});

test("panel loads locally, seeks, clears on unmatched events, and renders HTML as text", async () => {
  const elements = Object.fromEntries(
    ["input", "select", "[role=status]", "h2", ".reasoning-text", ".trace-match"].map((key) => [
      key,
      {
        value: "",
        textContent: "",
        options: [],
        replaceChildren(option) {
          this.options = [option];
        },
        add(option) {
          this.options.push(option);
        },
      },
    ]),
  );
  sandbox.Option = function (text, value) {
    this.text = text;
    this.value = value;
  };
  const root = {
    querySelector: (key) => elements[key],
    parentNode: { querySelectorAll: () => [] },
  };
  const seeks = [];
  const panelPayload = structuredClone(payload);
  const panel = attach(root, panelPayload, { seat: () => "Flywheel" }, (index) => {
    seeks.push(index);
    panel.update(index);
  });
  elements.input.files = [
    { size: 100, text: async () => JSON.stringify(capture('<img src=x onerror="attack()">')) },
  ];
  await elements.input.onchange();
  assert.deepEqual(seeks, [23]);
  assert.match(elements["h2"].textContent, /Flywheel.*shot.*10/);
  assert.equal(elements[".reasoning-text"].textContent, '<img src=x onerror="attack()">');
  assert.match(elements["[role=status]"].textContent, /1 reasoning traces/);
  panel.update(22);
  assert.match(elements[".reasoning-text"].textContent, /No reasoning trace/);
  elements.select.value = "10";
  elements.select.onchange();
  assert.deepEqual(seeks, [23, 23]);
  // A silent reaction has no event interval but remains selectable.
  panelPayload.decisionRefs[0].eventAfter = 22;
  elements.select.value = "10";
  elements.select.onchange();
  assert.equal(seeks.at(-1), 22);
  assert.match(elements["h2"].textContent, /Decision 10/);
  assert.equal(elements[".reasoning-text"].textContent, '<img src=x onerror="attack()">');
  panel.update(23);
  assert.match(elements[".reasoning-text"].textContent, /No reasoning trace/);
  elements.input.files = [{ size: 100, text: async () => "{}" }];
  await elements.input.onchange();
  assert.match(elements["[role=status]"].textContent, /Could not load trace/);
  elements.input.files = [{ size: 33 * 1024 * 1024 }];
  await elements.input.onchange();
  assert.match(elements["[role=status]"].textContent, /exceeds 32 MiB/);
});

test("engine-normalized actions do not discard saved reasoning", () => {
  const record = capture();
  record.raw_response = JSON.stringify({
    choices: [
      {
        message: {
          content: JSON.stringify({
            say: " A bargain ",
            shoot: "Gizmo",
            aim: "HIP",
            whisper: null,
          }),
          reasoning: "A saved reason",
        },
      },
    ],
  });
  const trace = parseTrace(JSON.stringify(record), payload).get(10);
  assert.equal(trace.text, "A saved reason");
  assert.equal(trace.actionMatches, false);
  const canonical = {
    schema_version: "1",
    event_type: "decision",
    game: "parley",
    decision_id: "10",
    seat: "4",
    executed_action: action,
    selected_attempt_id: "selected",
    attempts: [{ attempt_id: "selected", raw_response: record.raw_response }],
  };
  assert.equal(parseTrace(JSON.stringify(canonical), payload).get(10).actionMatches, true);
  canonical.executed_action = { ...action, shoot: "Another cog" };
  assert.throws(() => parseTrace(JSON.stringify(canonical), payload), /action does not match/);
});
