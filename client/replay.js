// One replay page for hosted WebSocket playback and a static ?replay= artifact.
(function () {
  "use strict";

  var loading = document.getElementById("loading");
  ParleyRenderer.bindFeedToggle(document.getElementById("feedtoggle"));
  function fail(error) {
    var message = String((error && error.message) || error);
    loading.textContent = "Replay failed: " + message;
    document.documentElement.setAttribute("data-replay-error", message);
  }
  function start(payload) {
    loading.style.display = "none";
    ParleyRenderer.attachReplay({
      canvas: document.getElementById("table"),
      feed: document.getElementById("feed"),
      followButton: document.getElementById("chat-follow"),
      scrub: document.getElementById("scrub"),
      playButton: document.getElementById("play"),
      previousButton: document.getElementById("previous"),
      nextButton: document.getElementById("next"),
      nowPlaying: document.getElementById("now-playing"),
      label: document.getElementById("pos"),
      clock: document.getElementById("clock"),
      scorebug: document.getElementById("scorebug"),
      endscreen: document.getElementById("endscreen"),
      assetBase: "./assets",
      reasoning: document.getElementById("reasoning-panel"),
      payload: payload,
    });
  }

  var replayUrl = new URLSearchParams(location.search).get("replay");
  if (replayUrl) {
    var parser = new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = "./parley_replay.js";
      script.onload = resolve;
      script.onerror = function () {
        reject(new Error("replay reader failed to load"));
      };
      document.head.appendChild(script);
    });
    var replay = fetch(replayUrl).then(function (response) {
      if (!response.ok) throw new Error("replay fetch " + response.status);
      return response.text();
    });
    Promise.all([parser, replay])
      .then(function (results) {
        start(JSON.parse(parleyLoadReplay(results[1])));
      })
      .catch(fail);
  } else if (location.pathname === "/client/replay") {
    var scheme = location.protocol === "https:" ? "wss://" : "ws://";
    var socket = new WebSocket(scheme + location.host + "/replay");
    socket.onmessage = function (frame) {
      var payload = JSON.parse(frame.data);
      if (payload.type !== "replay") return;
      start(payload);
      socket.onmessage = null;
    };
    socket.onerror = function () {
      fail("replay connection failed");
    };
  } else {
    fail("missing required ?replay= URL");
  }
})();
