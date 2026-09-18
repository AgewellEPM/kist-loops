"use strict";
/* graph3d.js — the floor graph as a hand-rolled 3D hologram. No libraries.

   Five visual styles, every one drawing the SAME receipts-backed data:
     orbit  — free 3D force layout, orbiting camera (the flagship)
     helix  — nodes ride a double helix, grouped by type (the Peel look)
     sphere — nodes on a shell, banded by type latitude
     rings  — concentric rings per type, tilted into depth
     flat   — the original 2D force graph, exactly as v1 drew it

   Each mind opens with its own deterministic style (hash of the DB name),
   so different minds LOOK different by default; the switcher overrides and
   the override is remembered per mind. Selection, node drag, hover and
   click-to-inspect all behave as before — the engine only changes how the
   graph is DRAWN, never what it says. */

const Graph3D = (() => {
  const STYLES = ["orbit", "helix", "sphere", "rings", "flat"];
  const AUTO_STYLES = ["orbit", "helix", "sphere", "rings"]; // per-DB signature
  const FOCAL = 900;            // perspective focal length
  const PARTICLE_EDGE_MAX = 300; // edge-flow sparkle budget

  let cv = null, ctx = null, hooks = {}, S = null;   // S = shared app state
  let style = "orbit", spin = true, raf = 0, tick = 0;
  let cam = { yaw: 0.5, pitch: 0.35, dist: 620, cx: 0, cy: 0 };
  let drag = null, orbiting = false, lastX = 0, lastY = 0, hover = null;
  let typeIndex = new Map();

  /* ---------------- helpers ---------------- */

  const hash = s => { let h = 2166136261;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0; };

  const styleKey = db => "g3d-style:" + (db || "");

  function autoStyle(db) {
    const saved = localStorage.getItem(styleKey(db));
    if (saved && STYLES.includes(saved)) return saved;
    return AUTO_STYLES[hash(db || "floor") % AUTO_STYLES.length];
  }

  /* ---------------- layout targets per style ---------------- */

  function seedPositions() {
    const N = S.nodes;
    for (let i = 0; i < N.length; i++) {
      const n = N[i], a = i * 2.399, r = 120 + 8 * Math.sqrt(i);
      const jz = ((hash(n.id) % 1000) / 1000 - 0.5);
      n.x = Math.cos(a) * r; n.y = Math.sin(a) * r;
      n.z = style === "flat" ? 0 : jz * 240;
      n.vx = n.vy = n.vz = 0;
    }
    typeIndex = new Map();
    [...new Set(N.map(n => n.type))].sort()
      .forEach((t, i) => typeIndex.set(t, i));
  }

  // Where a node WANTS to sit for the sculpted styles (helix/sphere/rings).
  // Deterministic per node: same mind always sculpts the same shape.
  function target(n, i, count) {
    const ti = typeIndex.get(n.type) || 0, types = typeIndex.size || 1;
    if (style === "helix") {
      const strand = ti % 2, t = (n.ord / Math.max(1, count - 1)) * 4 * Math.PI;
      const phase = t + strand * Math.PI;
      return { x: Math.cos(phase) * 150,
               y: (n.ord / Math.max(1, count - 1) - 0.5) * 560,
               z: Math.sin(phase) * 150 };
    }
    if (style === "sphere") {
      const lat = Math.PI * ((ti + 1) / (types + 1)) - Math.PI / 2;
      const lon = (n.ord * 2.399) + ti;
      const R = 260;
      return { x: Math.cos(lat) * Math.cos(lon) * R,
               y: Math.sin(lat) * R * 0.9,
               z: Math.cos(lat) * Math.sin(lon) * R };
    }
    if (style === "rings") {
      const R = 90 + ti * 62, a = n.ord * (2 * Math.PI / Math.max(1, n.ringN));
      return { x: Math.cos(a) * R, y: Math.sin(a) * R,
               z: Math.sin(a * 2 + ti) * 26 };
    }
    return null; // orbit + flat: pure force
  }

  function prepareOrdinals() {
    // per-type ordinal (rings/sphere) and global ordinal (helix), stable sort
    const N = [...S.nodes].sort((a, b) =>
      (typeIndex.get(a.type) - typeIndex.get(b.type)) || a.id.localeCompare(b.id));
    const perType = new Map();
    N.forEach((n, i) => {
      n.ord = style === "helix" ? i : (perType.get(n.type) || 0);
      perType.set(n.type, (perType.get(n.type) || 0) + 1);
    });
    N.forEach(n => { n.ringN = perType.get(n.type) || 1; });
  }

  /* ---------------- physics ---------------- */

  function step() {
    const N = S.nodes, E = S.edges, sculpted = style !== "orbit" && style !== "flat";
    const big = N.length > 350;
    for (let i = 0; i < N.length; i++) {
      // repulsion (sampled when large: every node vs a rotating slice)
      const jStart = big ? ((i * 7 + tick) % N.length) : i + 1;
      const jEnd = big ? Math.min(jStart + 60, N.length) : N.length;
      for (let j = jStart; j < jEnd; j++) {
        if (j === i) continue;
        const a = N[i], b = N[j];
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
        const d2 = dx * dx + dy * dy + dz * dz || 1;
        if (d2 < 40000) {
          const d = Math.sqrt(d2), f = (sculpted ? 420 : 900) / d2;
          dx /= d; dy /= d; dz /= d;
          a.vx -= dx * f; a.vy -= dy * f; a.vz -= dz * f;
          b.vx += dx * f; b.vy += dy * f; b.vz += dz * f;
        }
      }
    }
    for (const e of E) {
      const a = N[e.si], b = N[e.ti];
      if (!a || !b) continue;
      const dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
      const d = Math.hypot(dx, dy, dz) || 1;
      const f = (d - 90) * (sculpted ? 0.0015 : 0.004);
      a.vx += dx / d * f; a.vy += dy / d * f; a.vz += dz / d * f;
      b.vx -= dx / d * f; b.vy -= dy / d * f; b.vz -= dz / d * f;
    }
    let i = 0;
    for (const n of N) {
      if (n !== drag) {
        const t = target(n, i, N.length);
        if (t) { n.vx += (t.x - n.x) * 0.02; n.vy += (t.y - n.y) * 0.02;
                 n.vz += (t.z - n.z) * 0.02; }
        n.vx *= 0.85; n.vy *= 0.85; n.vz *= 0.85;
        n.x += n.vx; n.y += n.vy; n.z += n.vz;
        if (!t) { n.x -= n.x * 0.002; n.y -= n.y * 0.002; n.z -= n.z * 0.002; }
        if (style === "flat") { n.z = 0; n.vz = 0; }
      }
      i++;
    }
  }

  /* ---------------- projection ---------------- */

  function project(n, w, h) {
    if (style === "flat") {
      n.sx = w / 2 + n.x; n.sy = h / 2 + n.y; n.sd = 0; n.sp = 1; return;
    }
    const sy = Math.sin(cam.yaw), cy = Math.cos(cam.yaw);
    const sp = Math.sin(cam.pitch), cp = Math.cos(cam.pitch);
    const x1 = n.x * cy + n.z * sy;
    const z1 = -n.x * sy + n.z * cy;
    const y2 = n.y * cp - z1 * sp;
    const z2 = n.y * sp + z1 * cp;
    const persp = FOCAL / (FOCAL + z2 + cam.dist - 620);
    n.sx = w / 2 + (x1 + cam.cx) * persp;
    n.sy = h / 2 + (y2 + cam.cy) * persp;
    n.sd = z2; n.sp = persp;
  }

  const fog = d => Math.max(0.18, Math.min(1, 0.82 - d / 700));

  /* ---------------- render ---------------- */

  function nebula(w, h) {
    const g1 = ctx.createRadialGradient(w * 0.28, h * 0.3, 0, w * 0.28, h * 0.3, w * 0.5);
    g1.addColorStop(0, "rgba(38,58,96,0.16)"); g1.addColorStop(1, "transparent");
    const g2 = ctx.createRadialGradient(w * 0.75, h * 0.72, 0, w * 0.75, h * 0.72, w * 0.45);
    g2.addColorStop(0, "rgba(64,34,84,0.13)"); g2.addColorStop(1, "transparent");
    ctx.fillStyle = g1; ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = g2; ctx.fillRect(0, 0, w, h);
  }

  function draw() {
    if (!document.body.contains(cv)) { stop(); return; }
    const w = cv.clientWidth, h = cv.clientHeight, dpr = devicePixelRatio || 1;
    if (w && cv.width !== w * dpr) { cv.width = w * dpr; cv.height = h * dpr; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (style !== "flat") nebula(w, h);

    if (spin && !orbiting && !drag && style !== "flat") cam.yaw += 0.0035;
    tick++;

    const N = S.nodes, E = S.edges;
    for (const n of N) project(n, w, h);

    // edges first, depth-shaded, gradient source-type -> target-type
    for (const e of E) {
      const a = N[e.si], b = N[e.ti];
      if (!a || !b) continue;
      const hot = S.sel && (a === S.sel || b === S.sel);
      const depth = (a.sd + b.sd) / 2;
      if (style === "flat") {
        ctx.strokeStyle = hot ? "#f5a623" : "#2c3644";
        ctx.globalAlpha = 1;
      } else {
        const grad = ctx.createLinearGradient(a.sx, a.sy, b.sx, b.sy);
        grad.addColorStop(0, hooks.color(a.type));
        grad.addColorStop(1, hooks.color(b.type));
        ctx.strokeStyle = hot ? "#f5a623" : grad;
        ctx.globalAlpha = (hot ? 0.95 : 0.34) * fog(depth);
      }
      ctx.lineWidth = hot ? 1.6 : 1;
      ctx.beginPath(); ctx.moveTo(a.sx, a.sy); ctx.lineTo(b.sx, b.sy); ctx.stroke();

      // flow sparkle: evidence quietly travelling its edge
      if (style !== "flat" && E.length <= PARTICLE_EDGE_MAX) {
        const t = ((tick * 0.6 + e.si * 37 + e.ti * 91) % 240) / 240;
        const px = a.sx + (b.sx - a.sx) * t, py = a.sy + (b.sy - a.sy) * t;
        ctx.globalAlpha = 0.5 * fog(depth);
        ctx.fillStyle = "#9ecbff";
        ctx.beginPath(); ctx.arc(px, py, 1.1, 0, 7); ctx.fill();
      }
    }
    ctx.globalAlpha = 1;

    // nodes back-to-front so near spheres overlap far ones
    const order = [...N].sort((a, b) => b.sd - a.sd);
    const labelAll = N.length <= 90;
    for (const n of order) {
      const r = Math.max(1.6, n.r * (style === "flat" ? 1 : n.sp));
      const col = hooks.color(n.type);
      const a = style === "flat" ? 1 : fog(n.sd);
      if (style === "flat") {
        ctx.fillStyle = col;
        ctx.beginPath(); ctx.arc(n.sx, n.sy, n.r, 0, 7); ctx.fill();
      } else {
        const g = ctx.createRadialGradient(n.sx - r * 0.35, n.sy - r * 0.35, r * 0.15,
                                           n.sx, n.sy, r * 1.05);
        g.addColorStop(0, "#ffffff"); g.addColorStop(0.25, col);
        g.addColorStop(1, "rgba(0,0,0,0.25)");
        ctx.globalAlpha = a;
        ctx.shadowColor = col; ctx.shadowBlur = 12 * a;
        ctx.fillStyle = g;
        ctx.beginPath(); ctx.arc(n.sx, n.sy, r, 0, 7); ctx.fill();
        ctx.shadowBlur = 0;
      }
      if (n === S.sel) {
        ctx.strokeStyle = "#fff"; ctx.lineWidth = 2;
        ctx.globalAlpha = 1;
        ctx.beginPath();
        ctx.arc(n.sx, n.sy, r + 2.5 + Math.sin(tick * 0.15) * 1.5, 0, 7);
        ctx.stroke();
      }
      if (labelAll || n.r > 7 || n === S.sel || n === hover) {
        ctx.globalAlpha = style === "flat" ? 1 : Math.max(0.3, a);
        ctx.fillStyle = "#dbe2ea"; ctx.font = "11px sans-serif";
        ctx.fillText(hooks.label(n.id), n.sx + r + 3, n.sy + 3);
      }
      ctx.globalAlpha = 1;
    }

    step();
    raf = requestAnimationFrame(draw);
  }

  /* ---------------- interaction ---------------- */

  function nodeAt(mx, my) {
    const N = S.nodes;
    let best = null, bestD = 1e9;
    for (let i = N.length - 1; i >= 0; i--) {
      const n = N[i], dx = n.sx - mx, dy = n.sy - my;
      const rr = (Math.max(4, n.r * (n.sp || 1)) + 4);
      const d2 = dx * dx + dy * dy;
      if (d2 <= rr * rr && (style === "flat" || n.sd < bestD)) {
        best = n; bestD = style === "flat" ? 0 : n.sd;
        if (style === "flat") break;
      }
    }
    return best;
  }

  // move a dragged node in the camera plane at its current depth
  function dragTo(n, mx, my, w, h) {
    if (style === "flat") { n.x = mx - w / 2; n.y = my - h / 2; return; }
    const persp = n.sp || 1;
    const x1 = (mx - w / 2) / persp - cam.cx;
    const y2 = (my - h / 2) / persp - cam.cy;
    const sy = Math.sin(cam.yaw), cy = Math.cos(cam.yaw);
    const sp = Math.sin(cam.pitch), cp = Math.cos(cam.pitch);
    const z2 = n.sd;                       // keep the node at its current depth
    const y = y2 * cp + z2 * sp;           // exact inverse of the view rotation
    const z1 = -y2 * sp + z2 * cp;
    n.x = x1 * cy - z1 * sy;
    n.z = x1 * sy + z1 * cy;
    n.y = y;
    n.vx = n.vy = n.vz = 0;
  }

  function bind() {
    cv.onmousedown = ev => {
      const r = cv.getBoundingClientRect();
      const mx = ev.clientX - r.left, my = ev.clientY - r.top;
      const n = nodeAt(mx, my);
      if (n) drag = n;
      else if (style !== "flat") { orbiting = true; lastX = mx; lastY = my; }
    };
    cv.onmousemove = ev => {
      const r = cv.getBoundingClientRect();
      const mx = ev.clientX - r.left, my = ev.clientY - r.top;
      if (drag) dragTo(drag, mx, my, cv.clientWidth, cv.clientHeight);
      else if (orbiting) {
        cam.yaw += (mx - lastX) * 0.006;
        cam.pitch = Math.max(-1.4, Math.min(1.4, cam.pitch + (my - lastY) * 0.006));
        lastX = mx; lastY = my;
      }
      hover = drag ? null : nodeAt(mx, my);
      cv.style.cursor = drag ? "grabbing" : hover ? "pointer"
        : style === "flat" ? "default" : "grab";
    };
    window.addEventListener("mouseup", ev => {
      if (!cv) return;
      const r = cv.getBoundingClientRect();
      const n = nodeAt(ev.clientX - r.left, ev.clientY - r.top);
      if (n && n === drag && hooks.onSelect) hooks.onSelect(n);
      drag = null; orbiting = false;
    });
    cv.onwheel = ev => {
      if (style === "flat") return;
      ev.preventDefault();
      cam.dist = Math.max(160, Math.min(2400,
        cam.dist * (ev.deltaY > 0 ? 1.08 : 0.925)));
    };
    cv.ondblclick = () => fit();
  }

  /* ---------------- public API ---------------- */

  function start(appState, h) {
    S = appState; hooks = h;
    if (!cv) { cv = document.getElementById("cv"); ctx = cv.getContext("2d"); bind(); }
    style = autoStyle(S.db);
    cam = { yaw: 0.5, pitch: 0.35, dist: 620, cx: 0, cy: 0 };
    seedPositions(); prepareOrdinals();
    if (!raf) raf = requestAnimationFrame(draw);
    return style;
  }

  function setStyle(name, remember = true) {
    if (!STYLES.includes(name) || !S) return style;
    style = name;
    if (remember) localStorage.setItem(styleKey(S.db), name);
    seedPositions(); prepareOrdinals();
    cam = { yaw: 0.5, pitch: style === "rings" ? 0.85 : 0.35, dist: 620, cx: 0, cy: 0 };
    return style;
  }

  function fit() {
    if (!S || !S.nodes.length || style === "flat") return;
    let maxR = 1;
    for (const n of S.nodes) maxR = Math.max(maxR, Math.hypot(n.x, n.y, n.z));
    cam.dist = Math.max(200, Math.min(2400, maxR * 2.1));
    cam.cx = 0; cam.cy = 0;
  }

  function focus(id) {
    const n = S && S.nodes.find(x => x.id === id);
    if (!n) return;
    S.sel = n;
    if (style !== "flat") { cam.cx = -n.x; cam.cy = -n.y; }
  }

  function stop() { if (raf) cancelAnimationFrame(raf); raf = 0; }

  return { start, setStyle, getStyle: () => style, fit, focus, stop,
           setSpin: b => { spin = !!b; }, spinning: () => spin, STYLES };
})();
