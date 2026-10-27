// Private trace files stay in this browser. They are never added to the public replay.
(function () {
  "use strict";

  function sameAction(left, right) {
    if (left === right) return true;
    if (!left || !right || typeof left !== "object" || typeof right !== "object") return false;
    var keys = Object.keys(left);
    return (
      keys.length === Object.keys(right).length &&
      keys.every(function (key) {
        return (
          Object.prototype.hasOwnProperty.call(right, key) && sameAction(left[key], right[key])
        );
      })
    );
  }

  function responseParts(raw) {
    var response = typeof raw === "string" ? JSON.parse(raw) : raw;
    var message = response.choices ? response.choices[0].message : response;
    if (Array.isArray(message.content)) {
      return {
        reasoning: message.content
          .filter(function (block) {
            return block.type === "thinking";
          })
          .map(function (block) {
            return block.thinking;
          })
          .join("\n\n"),
        action: message.content
          .filter(function (block) {
            return block.type === "text";
          })
          .map(function (block) {
            return block.text;
          })
          .join("\n"),
      };
    }
    return {
      reasoning: message.reasoning || message.reasoning_content || "",
      action: message.content,
    };
  }

  function parseTrace(text, payload) {
    var refs = payload.decisionRefs || [];
    if (!refs.length)
      throw new Error("This replay has no decision references for matching traces.");
    var records = text
      .trim()
      .split(/\r?\n/)
      .filter(Boolean)
      .map(function (line) {
        return JSON.parse(line);
      });
    var traces = new Map();
    records.forEach(function (record) {
      if (record.event_type === "episode" && record.game === "parley") return;
      var capture = record.protocol === "parley.inference-capture.v1";
      if (
        !capture &&
        !(
          record.event_type === "decision" &&
          record.game === "parley" &&
          record.schema_version === "1"
        )
      ) {
        throw new Error("Use Parley inference.jsonl or trajectory.jsonl.");
      }
      var ref = refs.find(function (candidate) {
        return String(candidate.id) === record.decision_id;
      });
      if (!ref || ref.seat !== Number(record.seat))
        throw new Error("Trace decision or seat does not match this replay.");
      var attempt = capture
        ? record
        : record.attempts.find(function (candidate) {
            return candidate.attempt_id === record.selected_attempt_id;
          });
      if (!attempt || attempt.raw_response == null) return;
      var parts = responseParts(attempt.raw_response);
      var action = capture ? JSON.parse(parts.action) : record.executed_action;
      if (!capture && !sameAction(action, ref.action))
        throw new Error("Trace action does not match this replay.");
      if (typeof parts.reasoning !== "string") throw new Error("Reasoning must be text.");
      if (traces.has(ref.id))
        throw new Error("Multiple traces for one decision. Load one episode at a time.");
      traces.set(ref.id, { text: parts.reasoning, request: attempt.request,
        response: parts.action, actionMatches: sameAction(action, ref.action) });
    });
    return traces;
  }

  function activeDecision(refs, index) {
    return refs.find(function (ref) {
      return ref.eventBefore < index && index <= ref.eventAfter;
    });
  }

  function attach(root, payload, names, seek) {
    var refs = payload.decisionRefs || [];
    var traces = new Map();
    var index = 0;
    var chosen = null;
    var chosenIndex = -1;
    var file = root.querySelector("input");
    var select = root.querySelector("select");
    var status = root.querySelector("[role=status]");
    var heading = root.querySelector("h2");
    var body = root.querySelector(".reasoning-text");
    var input = root.querySelector(".model-input");
    var response = root.querySelector(".model-response");
    var executed = root.querySelector(".executed-action");
    var match = root.querySelector(".trace-match");
    var tabs = root.parentNode.querySelectorAll("[data-replay-panel]");
    tabs.forEach(function (button) {
      button.onclick = function () {
        tabs.forEach(function (tab) {
          var selected = tab === button;
          tab.setAttribute("aria-pressed", String(selected));
          document.getElementById(tab.dataset.replayPanel).hidden = !selected;
        });
      };
    });
    function update(next) {
      index = next;
      if (index !== chosenIndex) chosen = null;
      var ref = chosen || activeDecision(refs, index);
      var trace = ref && traces.get(ref.id);
      match.textContent =
        trace && !trace.actionMatches
          ? "Saved response differs from the replay action. The game can normalize actions. Check that this file belongs to this episode."
          : "";
      heading.textContent = ref
        ? names.seat(ref.seat) + " · " + ref.phase + " · Decision " + ref.id
        : "Model input";
      select.value = ref && traces.has(ref.id) ? String(ref.id) : "";
      input.replaceChildren();
      if (trace && trace.request) trace.request.messages.forEach(function (message) {
        var role = document.createElement("h3");
        role.textContent = message.role;
        var content = document.createElement("pre");
        content.textContent = message.content;
        input.append(role, content);
      });
      response.textContent = trace ? trace.response : "No saved inference is available for this event.";
      executed.textContent = trace ? JSON.stringify(ref.action, null, 2) : "";
      body.textContent = trace && trace.text ? trace.text : "No saved reasoning.";
      body.scrollTop = 0;
    }
    function choose(ref) {
      chosen = ref;
      chosenIndex = Math.min(ref.eventBefore + 1, ref.eventAfter);
      seek(chosenIndex);
    }
    file.onchange = async function () {
      var selected = file.files[0];
      if (!selected) return;
      // Bound parsing and DOM costs for user-selected files.
      if (selected.size > 32 * 1024 * 1024) {
        status.textContent = "Trace file exceeds 32 MiB. Choose a single episode or player file.";
        return;
      }
      try {
        var loaded = parseTrace(await selected.text(), payload);
        traces = loaded;
        chosen = null;
        select.replaceChildren(new Option("Choose a decision", ""));
        refs.forEach(function (ref) {
          if (traces.has(ref.id))
            select.add(
              new Option(names.seat(ref.seat) + " · " + ref.phase + " · " + ref.id, String(ref.id)),
            );
        });
        select.disabled = traces.size === 0;
        status.textContent = traces.size
          ? traces.size +
            " decisions loaded locally. Matched by decision ID and seat; confirm the source episode."
          : "The file contains no saved inference.";
        update(index);
        if (traces.size)
          choose(
            refs.find(function (ref) {
              return traces.has(ref.id);
            }),
          );
      } catch (error) {
        status.textContent = "Could not load trace: " + error.message;
      }
    };
    select.onchange = function () {
      var ref = refs.find(function (ref) {
        return String(ref.id) === select.value;
      });
      if (ref) choose(ref);
    };
    update(0);
    return { update: update };
  }

  window.ParleyReasoning = {
    parseTrace: parseTrace,
    activeDecision: activeDecision,
    attach: attach,
  };
})();
