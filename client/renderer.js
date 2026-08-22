// Parley shared renderer + drivers.
//
// One canvas scene (round table, cogs, hearts, speech bubbles, paint) fed by
// three drivers: live /global websocket, live /player websocket, and replay
// (from the game's /replay websocket or the static wasm bundle). All state
// derivation happens server-side / wasm-side; this file only draws.
(function () {
  "use strict";

  // Ink & Print team palette, matching the coworld-ctf broadcast chrome.
  // Four cog skins ship with the CTF art; the fifth seat is tinted from the
  // red one at load (see tintedSprite) so no two cogs share an identity.
  var COLORS = ["red", "blue", "green", "yellow", "violet"];
  var TINTED_FROM = { violet: "red" };
  var TINT_ROTATE = { violet: 265 };
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var BUBBLE_MS = 5200;
  var SHOT_MS = 900;
  var SPLAT_MS = 2600;
  // How long the HIT / MISS verdict hangs over the target after impact.
  var VERDICT_MS = 1400;

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

  // Recolors a shipped sprite via an offscreen canvas, so a seat with no art
  // of its own still reads as its own cog instead of a duplicate.
  function tintedSprite(source, degrees) {
    if (!source || !source.width) return source;
    var off = document.createElement("canvas");
    off.width = source.width;
    off.height = source.height;
    var octx = off.getContext("2d");
    octx.filter = "hue-rotate(" + degrees + "deg) saturate(1.15)";
    octx.imageSmoothingEnabled = false;
    octx.drawImage(source, 0, 0);
    return off;
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    // Pointer position in canvas pixels (the canvas may be CSS-scaled), or
    // null when the pointer is off the table. Hovering a cog lights up the
    // two cogs on its secret cards.
    var hover = null;
    canvas.addEventListener("pointermove", function (evt) {
      var rect = canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      hover = {
        x: (evt.clientX - rect.left) * canvas.width / rect.width,
        y: (evt.clientY - rect.top) * canvas.height / rect.height
      };
    });
    canvas.addEventListener("pointerleave", function () { hover = null; });
    var names = [];
    COLORS.forEach(function (c) {
      if (TINTED_FROM[c]) return;
      names.push("soldier_" + c + "_front.png");
      names.push("soldier_" + c + "_front_gun.png");
    });
    names.push("heart_red.png", "arena_floor.png", "paintgun.png");
    loadImages(assetBase, names, function (images) {
      Object.keys(TINTED_FROM).forEach(function (color) {
        var base = TINTED_FROM[color];
        ["_front.png", "_front_gun.png"].forEach(function (suffix) {
          images["soldier_" + color + suffix] = tintedSprite(
            images["soldier_" + base + suffix], TINT_ROTATE[color]
          );
        });
      });
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view, hover); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Nominal cog size; everything below a cog (name, hearts, cards) is measured
  // as a multiple of it so the whole seat scales as one block.
  var SEAT_BASE = 84;
  var CARD_W = 34, CARD_H = 46, CARD_GAP = 21, CARD_DROP = 60;
  var BUBBLE_MAX_W = 220, BUBBLE_LINES = 4, BUBBLE_LINE_H = 16;
  var BUBBLE_PAD = 8, BUBBLE_TAIL = 8, BUBBLE_RISE = 0.69;

  function bubbleHeight(lines) {
    return lines * BUBBLE_LINE_H + BUBBLE_PAD * 2 - 4;
  }

  function seatExtent(size) {
    // How far one seat reaches above and below its cog's centre. The stack is
    // lopsided — a speech bubble above, four stacked rows below — so the ring
    // has to be centred on the extent rather than on the canvas.
    //
    // The bubble's headroom is reserved at its WORST case (a full four lines)
    // even while nobody is talking. Bubbles are transient and arrive without
    // warning; sizing the ring to the quiet table would clip the one thing on
    // screen anyone is reading. Their width needs no reserve — drawBubble
    // already clamps the box inside the canvas.
    var scale = size / SEAT_BASE;
    return {
      above: size * BUBBLE_RISE + bubbleHeight(BUBBLE_LINES) * scale,
      below: size * 0.62 + (CARD_DROP + CARD_H / 2 + 8) * scale,
      half: Math.max(size / 2, (CARD_GAP + CARD_W / 2 + 2) * scale)
    };
  }

  function seatsCollide(count, layout, ext) {
    // A seat's SOLID footprint: the cog plus its name/hearts/cards stack.
    // Bubble headroom is deliberately not part of this test — bubbles are
    // transient, drawn last on top, and already clamp themselves into the
    // canvas — so it should not pull seats toward each other.
    var solidAbove = layout.size / 2;
    for (var i = 0; i < count; i++) {
      var a = seatPosition(i, count, layout);
      var b = seatPosition((i + 1) % count, count, layout);
      var dx = Math.abs(a.x - b.x);
      var dy = Math.abs(a.y - b.y);
      if (dx < ext.half * 2 && dy < solidAbove + ext.below) return true;
    }
    return false;
  }

  function computeLayout(width, height, count) {
    // Every seat is allocated one spot — bubble headroom above the cog, the
    // name/hearts/cards stack below, ext.half to each side — and the ring is
    // pushed all the way to the canvas edges so the table FILLS the panel
    // instead of huddling in the middle. Cogs only shrink when neighbouring
    // spots would actually collide. Callers embed this viewer at wildly
    // different sizes (a league page's featured panel is far shorter than a
    // standalone tab), so the fit is solved per frame rather than assumed.
    var margin = 10;
    var size = Math.min(SEAT_BASE, (width / count) * 0.9);
    var layout;
    for (var attempt = 0; attempt < 40; attempt++) {
      var ext = seatExtent(size);
      // The largest ellipse whose top seat still has full bubble headroom,
      // whose bottom seat's cards still fit, and whose side seats stay in.
      var rx = (width - 2 * margin - 2 * ext.half) / 2;
      var ry = (height - 2 * margin - ext.above - ext.below) / 2;
      layout = {
        size: size,
        scale: size / SEAT_BASE,
        cx: width / 2,
        cy: margin + ext.above + Math.max(ry, 0),
        rx: Math.max(rx, 0),
        ry: Math.max(ry, 0)
      };
      if (rx > 0 && ry > 0 && !seatsCollide(count, layout, ext)) break;
      size *= 0.92;
    }
    return layout;
  }

  function seatPosition(index, count, layout) {
    // Seat 0 at the bottom, going clockwise around the table.
    var angle = Math.PI / 2 + (index * 2 * Math.PI) / count;
    return {
      x: layout.cx + layout.rx * Math.cos(angle),
      y: layout.cy + layout.ry * Math.sin(angle)
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

  function hoveredSeat(seats, count, layout, hover) {
    if (!hover) return -1;
    var best = -1, bestD = Infinity;
    seats.forEach(function (seat, index) {
      var pos = seatPosition(index, count, layout);
      var d = Math.hypot(hover.x - pos.x, hover.y - pos.y);
      if (d < layout.size * 0.7 && d < bestD) { best = index; bestD = d; }
    });
    return best;
  }

  function drawSpotlight(ctx, pos, size, color, label, scale) {
    // A coloured pool of light under the cog plus a ring and a tag, so the
    // relationship reads at a glance from across the room.
    var r = size * 0.78;
    ctx.save();
    var glow = ctx.createRadialGradient(pos.x, pos.y, size * 0.2, pos.x, pos.y, r);
    glow.addColorStop(0, color + "66");
    glow.addColorStop(1, color + "00");
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, r, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, size * 0.66, 0, Math.PI * 2);
    ctx.stroke();
    if (label) {
      ctx.font = "700 " + Math.round(12 * scale) + "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      var tw = ctx.measureText(label).width + 12 * scale;
      var ty = pos.y - size * 0.66 - 10 * scale;
      ctx.fillStyle = color;
      roundRect(ctx, pos.x - tw / 2, ty - 8 * scale, tw, 16 * scale, 3);
      ctx.fill();
      ctx.fillStyle = INK;
      ctx.fillText(label, pos.x, ty);
    }
    ctx.restore();
  }

  function drawReticle(ctx, pos, size, aim, t) {
    // Where the shooter is aiming, drawn on the target while the ball is in
    // flight: a tight crosshair on the head for a head-shot, a loose dashed
    // ring wobbling around the hip for a hip-shot. With the aim withheld
    // (a player's view of someone else's shot) a neutral ring sits centre.
    var y = pos.y;
    var r = size * 0.22;
    if (aim === "head") { y = pos.y - size * 0.24; r = size * 0.17; }
    else if (aim === "hip") {
      y = pos.y + size * 0.18 + Math.sin(t * 23) * size * 0.05;
      r = size * 0.32 + Math.cos(t * 17) * size * 0.04;
    }
    var x = pos.x + (aim === "hip" ? Math.cos(t * 19) * size * 0.06 : 0);
    ctx.save();
    ctx.strokeStyle = aim === "hip" ? AMBER : "#ff3b2f";
    ctx.lineWidth = 2.5;
    ctx.shadowColor = "rgba(0,0,0,0.7)";
    ctx.shadowBlur = 3;
    if (aim === "hip") ctx.setLineDash([5, 4]);
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
    var gap = r * 0.45, arm = r * 1.45;
    [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(function (d) {
      ctx.beginPath();
      ctx.moveTo(x + d[0] * gap, y + d[1] * gap);
      ctx.lineTo(x + d[0] * arm, y + d[1] * arm);
      ctx.stroke();
    });
    if (aim) {
      ctx.fillStyle = ctx.strokeStyle;
      ctx.font = "700 " + Math.round(size * 0.14) + "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "middle";
      ctx.fillText(aim.toUpperCase(), x + arm + 4, y);
    }
    ctx.restore();
  }

  function drawVerdict(ctx, pos, size, miss, age, scale) {
    // HIT / MISS stamped over the target after the ball lands; it lifts and
    // fades so the next shot's reticle never competes with it.
    var k = Math.min(age / VERDICT_MS, 1);
    var alpha = k < 0.75 ? 1 : (1 - k) / 0.25;
    var text = miss ? "MISS" : "HIT";
    var color = miss ? PAPER : "#ff3b2f";
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.translate(pos.x, pos.y - size * 0.45 - k * 22 * scale);
    ctx.rotate(miss ? -0.12 : 0.1);
    ctx.font = "900 " + Math.round(26 * scale) + "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.lineWidth = 5;
    ctx.strokeStyle = INK;
    ctx.lineJoin = "round";
    ctx.strokeText(text, 0, 0);
    ctx.fillStyle = color;
    ctx.fillText(text, 0, 0);
    ctx.restore();
  }

  function draw(ctx, canvas, images, view, hover) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var count = Math.max(seats.length, 2);
    var now = view.now || Date.now();
    var layout = computeLayout(w, h, count);
    var hovered = hoveredSeat(seats, count, layout, hover);

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

    // No table is drawn: the cogs and their cards are the composition.
    // cx/cy stay the center the paint splats and seat ring reference.
    var cx = layout.cx, cy = layout.cy;

    // Old paint splats on the table (from shot history).
    (view.splats || []).forEach(function (splat) {
      var age = now - splat.at;
      if (age > SPLAT_MS) return;
      var pos = seatPosition(splat.seat, count, layout);
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
      var from = seatPosition(view.shot.from, count, layout);
      var to = seatPosition(view.shot.to, count, layout);
      if (view.shot.miss) {
        // A missed ball overshoots the seat and drifts wide of it.
        var dx = to.x - from.x, dy = to.y - from.y;
        var len = Math.max(Math.hypot(dx, dy), 1);
        to = { x: to.x + dx * 0.35 - dy / len * 40, y: to.y + dy * 0.35 + dx / len * 40 };
      }
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

    // Hover: the cog under the pointer and the two on its cards. Only views
    // that know the cards (spectators; a player for its own seat) can light
    // anything, since a redacted seat carries -1 for both.
    if (hovered >= 0) {
      var hs = seats[hovered];
      var hpos = seatPosition(hovered, count, layout);
      drawSpotlight(ctx, hpos, layout.size, PAPER, null, layout.scale);
      if (hs.friend >= 0 && hs.friend < seats.length) {
        drawSpotlight(ctx, seatPosition(hs.friend, count, layout), layout.size,
          COLOR_HEX.green, "FRIEND", layout.scale);
      }
      if (hs.enemy >= 0 && hs.enemy < seats.length) {
        drawSpotlight(ctx, seatPosition(hs.enemy, count, layout), layout.size,
          COLOR_HEX.red, "ENEMY", layout.scale);
      }
    }

    // Cogs.
    seats.forEach(function (seat, index) {
      var pos = seatPosition(index, count, layout);
      var color = seatColor(index);
      var spriteName = "soldier_" + color + "_front" + (seat.isIt ? "_gun" : "") + ".png";
      var sprite = images[spriteName];
      var size = layout.size;
      var scale = layout.scale;

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
      ctx.font = "600 " + Math.round(13 * scale) + "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = seat.alive ? PAPER : GHOST;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      // The dashed halo already marks IT; no text tag needed. Seat names come
      // from policy display names, which can run long enough to collide with
      // the neighbouring seat, so clamp them to the seat's own width.
      ctx.fillText(ellipsize(ctx, seat.name, size * 1.35), pos.x, pos.y + size * 0.62 + 14);
      ctx.restore();

      // Hearts.
      var heart = images["heart_red.png"];
      var hp = Math.max(seat.hp, 0);
      var maxHp = view.hitPoints || 3;
      var hw = 14 * scale;
      var hs = 12 * scale;
      var startX = pos.x - (maxHp * hw) / 2;
      for (var i = 0; i < maxHp; i++) {
        ctx.save();
        ctx.globalAlpha = i < hp ? 1 : 0.18;
        if (heart && heart.width) {
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(heart, startX + i * hw, pos.y + size * 0.62 + 20 * scale, hs, hs);
        } else {
          ctx.fillStyle = i < hp ? "#e0523a" : "#3a2f24";
          ctx.fillRect(startX + i * hw, pos.y + size * 0.62 + 20 * scale, hs, hs);
        }
        ctx.restore();
      }

      // This round's secret cards dealt under the cog, side by side: a
      // green-framed FRIEND card and a red-framed ENEMY card, each showing
      // the target cog's portrait.
      if (seat.friend >= 0 && seat.enemy >= 0 && seat.alive) {
        var cardY = pos.y + size * 0.62 + CARD_DROP * scale;
        drawCard(ctx, images, pos.x - CARD_GAP * scale, cardY,
          seat.friend, "#45a85e", "\u2665", -0.05, false, scale);
        drawCard(ctx, images, pos.x + CARD_GAP * scale, cardY,
          seat.enemy, "#e0523a", "\u2715", 0.05, seat.enemyDone, scale);
      }
    });

    // Aim and verdict on the target: the reticle rides the ball's flight,
    // then HIT or MISS lands with it.
    if (view.shot) {
      var shotAge = now - view.shot.at;
      var tpos = seatPosition(view.shot.to, count, layout);
      if (shotAge < SHOT_MS) {
        drawReticle(ctx, tpos, layout.size, view.shot.aim, shotAge / 120);
      } else if (shotAge < SHOT_MS + VERDICT_MS) {
        drawVerdict(ctx, tpos, layout.size, view.shot.miss, shotAge - SHOT_MS,
          layout.scale);
      }
    }

    // Speech bubbles (drawn last, on top).
    (view.bubbles || []).forEach(function (bubble) {
      var age = now - bubble.at;
      if (age > BUBBLE_MS) return;
      var pos = seatPosition(bubble.seat, count, layout);
      var alpha = age > BUBBLE_MS - 600 ? (BUBBLE_MS - age) / 600 : 1;
      drawBubble(ctx, w, pos.x, pos.y - layout.size * BUBBLE_RISE, bubble.text,
        alpha, layout.scale);
    });

  }

  function drawCard(ctx, images, x, y, targetSeat, frameColor, glyph, tilt,
    checked, scale) {
    var s = scale || 1;
    var cw = CARD_W, chh = CARD_H;
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(s, s);
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
    if (checked) {
      // The card has been cashed in: a big check across the face.
      ctx.strokeStyle = "#45a85e";
      ctx.lineWidth = 4;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(-9, 0);
      ctx.lineTo(-2, 8);
      ctx.lineTo(11, -11);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawBubble(ctx, canvasWidth, x, y, text, alpha, scale) {
    var s = scale || 1;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(13 * s) + "px 'rajdhani', system-ui, sans-serif";
    var maxWidth = BUBBLE_MAX_W * s;
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
    // Never cut a line off silently: mark the overflow so a long say reads
    // as trimmed, not as a bug.
    var overflow = lines.length > BUBBLE_LINES;
    lines = lines.slice(0, BUBBLE_LINES);
    if (overflow && lines.length) {
      lines[lines.length - 1] += "…";
    }
    var widest = 0;
    lines.forEach(function (l) {
      widest = Math.max(widest, ctx.measureText(l).width);
    });
    var pad = BUBBLE_PAD * s;
    var lineH = BUBBLE_LINE_H * s;
    var bw = widest + pad * 2;
    var bh = lines.length * lineH + pad * 2 - 4 * s;
    var bx = Math.max(6, Math.min(x - bw / 2, canvasWidth - bw - 6));
    var by = y - bh;

    ctx.fillStyle = "rgba(242, 232, 216, 0.96)";
    ctx.strokeStyle = "rgba(42, 31, 22, 0.9)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, bx, by, bw, bh, 8 * s);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x - 6 * s, by + bh);
    ctx.lineTo(x + 6 * s, by + bh);
    ctx.lineTo(x, by + bh + BUBBLE_TAIL * s);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = INK;
    lines.forEach(function (l, i) {
      ctx.fillText(l, bx + pad, by + pad + 11 * s + i * lineH);
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

  // The agents only ever hear anonymous table names ("Tinker", "Gasket");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED — seat labels and
  // the spoken lines both — while the underlying events keep the aliases.
  // The platform fills empty seats with "Baseline" / "Baseline (N)" policies.
  // Mapping those seats back to their policy name tells a spectator nothing,
  // so they keep their table alias instead — already a cute robot name.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    // One combined pattern, one pass: replacing alias-by-alias would rescan
    // text it just inserted, which garbles the table whenever a policy NAME
    // collides with another seat's alias (certification seats a policy
    // literally named "Gizmo").
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  // Render-time application of the name map: copies, never mutates, because
  // the seat states and bubble list are the drivers' bookkeeping.
  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function renameBubbles(bubbles, nameMap) {
    return (bubbles || []).map(function (bubble) {
      return { seat: bubble.seat, text: nameMap.text(bubble.text), at: bubble.at };
    });
  }

  function describeEvent(event, nameMap) {
    // Long policy display names otherwise swamp the line they appear in.
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "roundStart":
        return "New deal — every cog back to full hp.";
      case "it": return name(event.seat) + " is IT.";
      case "say":
        return name(event.seat) + ": “" + nameMap.text(event.text) + "”";
      case "skip":
        return name(event.seat) + " holds fire — the table keeps talking.";
      case "shot":
        // Spectators see the aim; players never do (the server strips it).
        var aim = event.aim === "hip" ? " from the hip" : "";
        if (event.miss) {
          return name(event.seat) + " shoots at " + name(event.target) +
            aim + " \u2014 MISS (" + Math.max(event.hpAfter, 0) + " hp)";
        }
        return name(event.seat) + " shoots " + name(event.target) + aim +
          " (" + Math.max(event.hpAfter, 0) + " hp left)";
      case "death": return name(event.seat) + " is OUT!";
      case "roundEnd":
        return name(event.seat) + " WINS round " + (event.round + 1) + "!";
      case "score":
        var reason = "";
        if (event.text === "foe") {
          reason = "fatally shot " + name(event.target) + " (FOE)";
        } else if (event.text === "survivor") {
          reason = "last cog standing";
        } else if (event.text === "friend") {
          reason = name(event.target) + " survived (FRIEND)";
        }
        return name(event.seat) + " +" + event.points + " \u2014 " + reason;
      default: return JSON.stringify(event);
    }
  }

  // Renders the full transcript grouped into one sub-section per turn.
  // currentIndex (replay) marks how far playback has reached: later events
  // render dimmed, and the section containing the playhead is highlighted
  // and scrolled into view. Omit currentIndex for live views (everything is
  // "played"; the feed follows the bottom).
  function renderFeed(element, events, nameMap, currentIndex) {
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
        (event.kind === "score" ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap)) + "</div>";
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
    // The seat this view plays as (player view), or -1 for spectators and
    // replays. The server omits the aim on head-shots, so a missing aim on
    // the view's OWN shot means "head"; on anyone else's it means withheld.
    var absorbOwnSeat = -1;
    var bubbles = [];
    var splats = [];
    var shot = null;
    var hold = null; // pre-shot seat state, shown until the paintball lands
    return {
      // prevSeats is the seat state from just BEFORE the newly absorbed
      // events; while the paintball is in flight the viewers keep drawing
      // it so hp, deaths, and the IT marker only change on impact.
      absorb: function (events, prevSeats, ownSeat) {
        var now = Date.now();
        if (typeof ownSeat === "number") absorbOwnSeat = ownSeat;
        for (; seen < events.length; seen++) {
          var event = events[seen];
          if (event.kind === "say") {
            bubbles = bubbles.filter(function (b) { return b.seat !== event.seat; });
            bubbles.push({ seat: event.seat, text: event.text, at: now });
          } else if (event.kind === "shot") {
            shot = {
              from: event.seat, to: event.target, at: now,
              miss: !!event.miss,
              // "head" / "hip" for spectators; undefined when the server
              // withheld it (another seat's shot, seen as a player).
              aim: event.aim ||
                ((absorbOwnSeat < 0 || event.seat === absorbOwnSeat) ? "head" : undefined)
            };
            if (prevSeats) {
              hold = { seats: prevSeats, until: now + SHOT_MS };
            }
            // A miss sails past: no paint on the target.
            if (!event.miss) {
              splats.push({
                from: event.seat, seat: event.target, turn: event.turn,
                at: now + SHOT_MS
              });
            }
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
  // Policy display names are arbitrary strings; a long one blows out whatever
  // row it lands in. One clamp, used by every place a name is shown as text.
  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "\u2026" : n;
  }

  // The episode's drawn table, plus which of those facts the cogs were actually
  // told. Rounds and the survivor count are sampled per episode and each is
  // independently announced or withheld, so a spectator needs both the value
  // and whether the table could see it — a round count the players are blind to
  // changes how their play should be read.
  function matchHeader(config, round, turn) {
    var c = config || {};
    var hidden = function (known) { return known === false ? " (hidden)" : ""; };
    var rounds = c.rounds || 1;
    var survivors = c.survivors || 1;
    var parts = [
      "ROUND " + (round + 1) + " / " + rounds + hidden(c.roundsKnown),
      "TURN " + turn,
      survivors + (survivors === 1 ? " SURVIVES" : " SURVIVE") +
        hidden(c.survivorsKnown)
    ];
    if (c.hitPoints) parts.push(c.hitPoints + " HP");
    return parts.join(" \u00b7 ");
  }

  function updateScorebug(container, seats, nameMap) {
    if (!container || !seats) return;
    var html = "";
    seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < (seat.roundWins || 0); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) +
        (seat.alive ? "" : " dead") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) + "</span>" +
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
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    // Results carry policy names; route them through the seat name map so
    // baseline fillers rank under their table alias here too.
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
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
        cell((results.scores[i] || 0).toFixed(2)) +
        cell(((results.roundWins || [])[i] || 0) * 3) +
        cell((results.friendPoints || [])[i] || 0) +
        cell((results.foePoints || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    // Replays open on the table, not the transcript: the log is a click away
    // and the arena gets the whole frame until someone asks for it.
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      // The page sized its canvas before this ran; let the collapse reflow
      // land, then tell it to re-measure against the now-full-width arena.
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
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
      // Player pages get no policyNames (they must not learn who is behind a
      // seat), so their map degrades to the anonymous table names.
      var nameMap = makeNameMap([], null);
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
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || [], prevSeats,
                typeof latest.slot === "number" ? latest.slot : -1);
            }
            if (options.feed && latest) {
              renderFeed(options.feed, latest.events || [],
                nameMap, undefined);
            }
            if (options.clock && latest) {
              options.clock.textContent =
                matchHeader(latest, latest.round || 0, latest.turn);
            }
            if (latest) updateScorebug(options.scorebug, latest.seats, nameMap);
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
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
          view.seats = applyNames(effects.seats(latest.seats, Date.now()), nameMap);
          view.bubbles = renameBubbles(view.bubbles, nameMap);
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
      marker.className = "beat-marker seat" + (event.seat % COLORS.length) +
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
    var nameMap = makeNameMap(payload.names, payload.policyNames);
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
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          var current = index > 0 ? events[index - 1] : null;
          var round = current ? current.round : 0;
          var turn = current ? current.turn : 0;
          options.clock.textContent =
            matchHeader(payload.config, round, turn);
        }
        updateScorebug(options.scorebug,
          states[Math.min(index, states.length - 1)], nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
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
        view.seats = applyNames(effects.seats(state, Date.now()), nameMap);
        view.bubbles = renameBubbles(view.bubbles, nameMap);
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
