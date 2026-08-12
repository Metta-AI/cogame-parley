// Parley shared renderer + drivers.
//
// One canvas scene (round table, cogs, hearts, speech bubbles, paint) fed by
// three drivers: live /global websocket, live /player websocket, and replay
// (from the game's /replay websocket or the static wasm bundle). All state
// derivation happens server-side / wasm-side; this file only draws.
(function () {
  "use strict";

  // Ink & Print team palette, matching the coworld-ctf broadcast chrome.
  var COLORS = ["red", "blue", "green", "yellow"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var BUBBLE_MS = 5200;
  var SHOT_MS = 900;
  var SPLAT_MS = 2600;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = [];
    COLORS.forEach(function (c) {
      names.push("soldier_" + c + "_front.png");
      names.push("soldier_" + c + "_front_gun.png");
    });
    names.push("heart_red.png", "arena_floor.png", "paintgun.png");
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function seatPosition(index, count, width, height) {
    // Seat 0 at the bottom, going clockwise around the table.
    var angle = Math.PI / 2 + (index * 2 * Math.PI) / count;
    var cx = width / 2;
    var cy = height / 2 - 12;
    var rx = width * 0.36;
    var ry = height * 0.33;
    return {
      x: cx + rx * Math.cos(angle),
      y: cy + ry * Math.sin(angle)
    };
  }

  function splatBlobs(seed, radius) {
    // Deterministic per-seed blob layout so replays look stable.
    var blobs = [];
    var s = seed * 2654435761 % 4294967296;
    function next() {
      s = (s * 1103515245 + 12345) % 2147483648;
      return s / 2147483648;
    }
    for (var i = 0; i < 7; i++) {
      var a = next() * Math.PI * 2;
      var d = next() * radius;
      blobs.push({
        x: Math.cos(a) * d,
        y: Math.sin(a) * d,
        r: radius * (0.18 + next() * 0.3)
      });
    }
    return blobs;
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var count = Math.max(seats.length, 2);
    var now = view.now || Date.now();

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      var pattern = ctx.createPattern(floor, "repeat");
      ctx.fillStyle = pattern;
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Table.
    var cx = w / 2, cy = h / 2 - 12;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(1, 0.62);
    var tableR = w * 0.26;
    var grad = ctx.createRadialGradient(0, 0, tableR * 0.2, 0, 0, tableR);
    grad.addColorStop(0, "#6d4a2f");
    grad.addColorStop(1, "#4a3120");
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(0, 0, tableR, 0, Math.PI * 2);
    ctx.fill();
    ctx.lineWidth = 10;
    ctx.strokeStyle = "#2e1f14";
    ctx.stroke();
    ctx.restore();

    // Old paint splats on the table (from shot history).
    (view.splats || []).forEach(function (splat) {
      var age = now - splat.at;
      if (age > SPLAT_MS) return;
      var pos = seatPosition(splat.seat, count, w, h);
      var toward = { x: cx + (pos.x - cx) * 0.55, y: cy + (pos.y - cy) * 0.55 };
      var alpha = Math.max(0, 1 - age / SPLAT_MS) * 0.85;
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.fillStyle = COLOR_HEX[seatColor(splat.from)];
      splatBlobs(splat.seat * 31 + splat.turn * 7, 26).forEach(function (b) {
        ctx.beginPath();
        ctx.arc(toward.x + b.x, toward.y + b.y * 0.6, b.r, 0, Math.PI * 2);
        ctx.fill();
      });
      ctx.restore();
    });

    // Paintball in flight.
    if (view.shot && now - view.shot.at < SHOT_MS) {
      var t = (now - view.shot.at) / SHOT_MS;
      var from = seatPosition(view.shot.from, count, w, h);
      var to = seatPosition(view.shot.to, count, w, h);
      var bx = from.x + (to.x - from.x) * t;
      var by = from.y + (to.y - from.y) * t - Math.sin(Math.PI * t) * 40;
      ctx.save();
      ctx.fillStyle = COLOR_HEX[seatColor(view.shot.from)];
      ctx.beginPath();
      ctx.arc(bx, by, 7, 0, Math.PI * 2);
      ctx.fill();
      ctx.globalAlpha = 0.35;
      ctx.beginPath();
      ctx.arc(bx - (to.x - from.x) * 0.04, by - (to.y - from.y) * 0.04, 5, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    // Cogs.
    seats.forEach(function (seat, index) {
      var pos = seatPosition(index, count, w, h);
      var color = seatColor(index);
      var spriteName = "soldier_" + color + "_front" + (seat.isIt ? "_gun" : "") + ".png";
      var sprite = images[spriteName];
      var size = Math.min(84, w / count * 0.9);

      ctx.save();
      ctx.translate(pos.x, pos.y);
      if (!seat.alive) {
        ctx.globalAlpha = 0.35;
        ctx.rotate(Math.PI / 2);
      }
      if (sprite && sprite.width) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
      } else {
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
      }
      ctx.restore();

      // IT halo.
      if (seat.isIt && seat.alive) {
        ctx.save();
        ctx.strokeStyle = "#e8a33d";
        ctx.lineWidth = 3;
        ctx.setLineDash([6, 5]);
        ctx.beginPath();
        ctx.arc(pos.x, pos.y, size * 0.62, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // Name.
      ctx.save();
      ctx.font = "600 13px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = seat.alive ? PAPER : GHOST;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      var label = seat.name + (seat.isIt && seat.alive ? "  ◀ IT" : "");
      ctx.fillText(label, pos.x, pos.y + size * 0.62 + 14);
      ctx.restore();

      // Hearts.
      var heart = images["heart_red.png"];
      var hp = Math.max(seat.hp, 0);
      var maxHp = view.hitPoints || 3;
      var hw = 14;
      var startX = pos.x - (maxHp * hw) / 2;
      for (var i = 0; i < maxHp; i++) {
        ctx.save();
        ctx.globalAlpha = i < hp ? 1 : 0.18;
        if (heart && heart.width) {
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(heart, startX + i * hw, pos.y + size * 0.62 + 20, 12, 12);
        } else {
          ctx.fillStyle = i < hp ? "#e0523a" : "#3a2f24";
          ctx.fillRect(startX + i * hw, pos.y + size * 0.62 + 20, 10, 10);
        }
        ctx.restore();
      }

      // This round's secret cards dealt under the cog, side by side: a
      // green-framed FRIEND card and a red-framed ENEMY card, each showing
      // the target cog's portrait.
      if (seat.friend >= 0 && seat.enemy >= 0 && seat.alive) {
        var cardY = pos.y + size * 0.62 + 60;
        drawCard(ctx, images, pos.x - 21, cardY,
          seat.friend, "#45a85e", "\u2665", -0.05);
        drawCard(ctx, images, pos.x + 21, cardY,
          seat.enemy, "#e0523a", "\u2715", 0.05);
      }
    });

    // Speech bubbles (drawn last, on top).
    (view.bubbles || []).forEach(function (bubble) {
      var age = now - bubble.at;
      if (age > BUBBLE_MS) return;
      var pos = seatPosition(bubble.seat, count, w, h);
      var alpha = age > BUBBLE_MS - 600 ? (BUBBLE_MS - age) / 600 : 1;
      drawBubble(ctx, w, pos.x, pos.y - 58, bubble.text, alpha);
    });

  }

  function drawCard(ctx, images, x, y, targetSeat, frameColor, glyph, tilt) {
    var cw = 34, chh = 46;
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(tilt);
    // Paper face with a thick friend-green / enemy-red frame.
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = frameColor;
    ctx.lineWidth = 3;
    roundRect(ctx, -cw / 2, -chh / 2, cw, chh, 4);
    ctx.fill();
    ctx.stroke();
    // The target cog's portrait.
    var sprite = images["soldier_" + seatColor(targetSeat) + "_front.png"];
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -13, -15, 26, 26);
    }
    // Corner glyph naming the relationship.
    ctx.fillStyle = frameColor;
    ctx.font = "700 12px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(glyph, 0, chh / 2 - 8);
    ctx.restore();
  }

  function drawBubble(ctx, canvasWidth, x, y, text, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = "13px 'rajdhani', system-ui, sans-serif";
    var maxWidth = 220;
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    lines = lines.slice(0, 4);
    var widest = 0;
    lines.forEach(function (l) {
      widest = Math.max(widest, ctx.measureText(l).width);
    });
    var pad = 8;
    var bw = widest + pad * 2;
    var bh = lines.length * 16 + pad * 2 - 4;
    var bx = Math.max(6, Math.min(x - bw / 2, canvasWidth - bw - 6));
    var by = y - bh;

    ctx.fillStyle = "rgba(242, 232, 216, 0.96)";
    ctx.strokeStyle = "rgba(42, 31, 22, 0.9)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, bx, by, bw, bh, 8);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x - 6, by + bh);
    ctx.lineTo(x + 6, by + bh);
    ctx.lineTo(x, by + bh + 8);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = INK;
    lines.forEach(function (l, i) {
      ctx.fillText(l, bx + pad, by + pad + 11 + i * 16);
    });
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Event feed ----------------------------------------------------------

  function describeEvent(event, names) {
    function name(i) { return names[i] || ("Seat " + i); }
    switch (event.kind) {
      case "roundStart":
        return "New deal — every cog back to full hp.";
      case "it": return name(event.seat) + " is IT.";
      case "say": return name(event.seat) + ": “" + event.text + "”";
      case "shot":
        return name(event.seat) + " shoots " + name(event.target) +
          " (" + Math.max(event.hpAfter, 0) + " hp left)";
      case "death": return name(event.seat) + " is OUT!";
      case "roundEnd":
        return name(event.seat) + " WINS round " + (event.round + 1) + "!";
      default: return JSON.stringify(event);
    }
  }

  // Renders the full transcript grouped into one sub-section per turn.
  // currentIndex (replay) marks how far playback has reached: later events
  // render dimmed, and the section containing the playhead is highlighted
  // and scrolled into view. Omit currentIndex for live views (everything is
  // "played"; the feed follows the bottom).
  function renderFeed(element, events, names, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastKey = null;
    var lastRound = null;
    var open = false;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      if (event.kind === "deal") continue;  // cards render on the table
      var key = event.round + ":" + event.turn;
      if (event.round !== lastRound) {
        if (open) { html += "</div>"; open = false; }
        html += '<div class="feed-round-head">ROUND ' +
          (event.round + 1) + "</div>";
        lastRound = event.round;
        lastKey = null;
      }
      if (key !== lastKey) {
        if (open) html += "</div>";
        var label = event.turn === 0 ? "The table gathers" :
          "Turn " + event.turn;
        html += '<div class="feed-turn" data-key="' + key + '">' +
          '<div class="feed-turn-head">' + label + "</div>";
        lastKey = key;
        open = true;
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "roundEnd" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, names)) + "</div>";
    }
    if (open) html += "</div>";
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var activeEvent = limit > 0 ? events[limit - 1] :
      (events.length ? events[0] : null);
    if (!activeEvent) return;
    var activeKey = activeEvent.round + ":" + activeEvent.turn;
    var sections = element.querySelectorAll(".feed-turn");
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s];
      if (section.getAttribute("data-key") === activeKey) {
        section.classList.add("feed-active");
        // Only scroll when the playhead enters a new section, so autoplay
        // doesn't fight the user's own scrolling within a section — and
        // keep the two previous sections visible above it for context.
        if (element.dataset.activeKey !== activeKey) {
          element.dataset.activeKey = activeKey;
          var anchor = sections[Math.max(0, s - 2)];
          element.scrollTo({
            top: Math.max(anchor.offsetTop - element.offsetTop - 8, 0),
            behavior: "smooth"
          });
        }
      }
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects.
  function makeEffects() {
    var seen = 0;
    var bubbles = [];
    var splats = [];
    var shot = null;
    var hold = null; // pre-shot seat state, shown until the paintball lands
    return {
      // prevSeats is the seat state from just BEFORE the newly absorbed
      // events; while the paintball is in flight the viewers keep drawing
      // it so hp, deaths, and the IT marker only change on impact.
      absorb: function (events, prevSeats) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          if (event.kind === "say") {
            bubbles = bubbles.filter(function (b) { return b.seat !== event.seat; });
            bubbles.push({ seat: event.seat, text: event.text, at: now });
          } else if (event.kind === "shot") {
            shot = { from: event.seat, to: event.target, at: now };
            if (prevSeats) {
              hold = { seats: prevSeats, until: now + SHOT_MS };
            }
            splats.push({
              from: event.seat, seat: event.target, turn: event.turn,
              at: now + SHOT_MS
            });
          }
        }
        var cutoff = now - Math.max(BUBBLE_MS, SPLAT_MS) - SHOT_MS;
        bubbles = bubbles.filter(function (b) { return b.at > cutoff; });
        splats = splats.filter(function (s) { return s.at > cutoff; });
      },
      reset: function () {
        seen = 0; bubbles = []; splats = []; shot = null; hold = null;
      },
      seats: function (currentSeats, now) {
        if (hold && now < hold.until) return hold.seats;
        return currentSeats;
      },
      view: function () {
        return { bubbles: bubbles, splats: splats, shot: shot };
      }
    };
  }


  // ---- Scorebug, endscreen, feed toggle -----------------------------------

  // Per-cog plates for the top band: colored name, cumulative match score,
  // one amber pip per round win, and an IT chip on the armed cog.
  function updateScorebug(container, seats) {
    if (!container || !seats) return;
    var html = "";
    seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < (seat.roundWins || 0); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      html += '<div class="plate ' + seatColor(index) +
        (seat.alive ? "" : " dead") + '">' +
        '<span class="plate-name">' + escapeHtml(seat.name) + "</span>" +
        (seat.isIt ? '<span class="plate-it">IT</span>' : "") +
        '<span class="plate-score">' + (seat.score || 0) + "</span>" +
        '<span class="plate-label">pts</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // Final standings overlay, paintbot-endscreen style: verdict up top,
  // ranked rows of score / round wins / knockouts below.
  function updateEndscreen(container, results, show) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = results.names || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      return (results.scores[b] || 0) - (results.scores[a] || 0);
    });
    var winners = [];
    names.forEach(function (name, i) {
      if (results.win && results.win[i]) winners.push(name);
    });
    var verdictColor = "";
    if (results.win) {
      var winnerIndex = results.win.indexOf(true);
      if (winnerIndex >= 0) verdictColor = seatColor(winnerIndex);
    }
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL \u2014 ' + (results.rounds || 1) +
      ' ROUND' + ((results.rounds || 1) > 1 ? "S" : "") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' +
      escapeHtml(winners.join(" & ") || "NOBODY") + " WINS THE MATCH</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">total</span>' +
      '<span class="end-head">survivor</span>' +
      '<span class="end-head">friend</span>' +
      '<span class="end-head">foe</span>';
    order.forEach(function (i, rank) {
      var winner = results.win && results.win[i];
      var cell = function (value) {
        return '<span class="end-cell' + (winner ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' + (winner ? " end-row-winner" : "") +
        '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (winner ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(results.scores[i] || 0) +
        cell(((results.roundWins || [])[i] || 0) * 3) +
        cell((results.friendPoints || [])[i] || 0) +
        cell((results.foePoints || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button) {
    if (!button) return;
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ? "\u00ab LOG" : "LOG \u00bb";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function attachLive(options) {
    // options: {canvas, feed, status, clock, assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            var prevSeats = latest ? latest.seats : null;
            if (data.type === "state") latest = data;
            if (latest) effects.absorb(latest.events || [], prevSeats);
            if (options.feed && latest) {
              renderFeed(options.feed, latest.events || [],
                seatNames(latest), undefined);
            }
            if (options.clock && latest) {
              options.clock.textContent =
                "ROUND " + ((latest.round || 0) + 1) + " / " +
                (latest.rounds || 1) + " \u00b7 TURN " + latest.turn;
            }
            if (latest) updateScorebug(options.scorebug, latest.seats);
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true);
            }
            if (latest && latest.done) setStatus("final", false);
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = effects.view();
          view.seats = effects.seats(latest.seats, Date.now());
          view.hitPoints = latest.hitPoints;
          view.done = latest.done;
          view.now = Date.now();
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // CTF-transport-style scrubber: a click/drag-to-seek track with a paper
  // fill, an amber playhead, and one beat marker per shot (colored by the
  // shooter's seat; knockouts draw taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    // Alternating round spans + boundary separators, so the timeline
    // reads as rounds at a glance; winner chips flag each round verdict.
    var roundStarts = [];
    events.forEach(function (event, i) {
      if (event.kind === "roundStart") roundStarts.push(i);
    });
    roundStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < roundStarts.length ?
        roundStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "shot" && kind !== "death" && kind !== "roundEnd") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker seat" + (event.seat % 4) +
        (kind === "death" ? " death" : "") +
        (kind === "roundEnd" ? " rwin" : "");
      if (kind === "roundEnd") {
        marker.title = "Round " + (event.round + 1) + " winner";
      }
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () { dragging = false; });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock,
    //           assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var names = payload.names || [];
    var maxTurns = (payload.config || {}).maxTurns || 0;
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function setIndex(next, jumped) {
        var previous = index;
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
          effects.absorb(events.slice(0, index));
        } else {
          // states[i] is the world after events[0..<i], so states[previous]
          // is the pre-event view the paintball animation should fly over.
          effects.absorb(events.slice(0, index), states[previous]);
        }
        if (options.feed) renderFeed(options.feed, events, names, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          var current = index > 0 ? events[index - 1] : null;
          var round = current ? current.round : 0;
          var turn = current ? current.turn : 0;
          options.clock.textContent = "ROUND " + (round + 1) + " / " +
            ((payload.config || {}).rounds || 1) + " \u00b7 TURN " + turn;
        }
        updateScorebug(options.scorebug,
          states[Math.min(index, states.length - 1)]);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        var stepMs = events[index] && events[index].kind === "say" ? 1500 : 900;
        if (playing && index < events.length && timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var state = states[Math.min(index, states.length - 1)] || [];
        var view = effects.view();
        view.seats = effects.seats(state, Date.now());
        view.hitPoints = (payload.config || {}).hitPoints || 3;
        view.done = index >= events.length && events.length > 0;
        view.winners = (payload.results || {}).win;
        view.now = Date.now();
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.ParleyRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
