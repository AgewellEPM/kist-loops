"use strict";
/* conceptviz.js — computer-GENERATED 3D concepts for graph nodes.

   Three lanes, every one honest about what it is:
     • molecule concept — a plausible 3D structure COMPUTED from the node's
       REAL stored residue sequence (helix/sheet/coil from residue
       propensities), drawn by its own hologram renderer: helix runs as
       thick glowing ribbons, sheet runs as flat arrowed strands, coil as a
       thin trace, plus one side-chain hint bead per residue sized by
       residue mass. Three color modes (secondary / hydropathy / charge)
       switchable live without reopening the modal. Deterministic: same
       sequence, same shape. ALWAYS bannered "GENERATED — not experimental
       coordinates".
     • DNA markup — an illustrative animated double helix for gene nodes
       (the floor stores no nucleotide sequence; the banner says so).
     • cell markup — an illustrative cell cross-section for location nodes,
       with the named compartment highlighted.

   Real experimental structures stay on viewStructure (molecule.js) — this
   file NEVER dresses generated output as real data. */

const CONCEPT_BANNER = (what) => `
  <div style="border:1px solid #b8862c;background:rgba(184,134,44,0.12);
       color:#e8b854;border-radius:6px;padding:6px 10px;margin:6px 0;font-size:12px">
    🧪 <b>GENERATED ${what}</b> — computed for visualisation, not experimental
    data. Every real fact stays in the graph with its receipt.</div>`;

/* ---------------- deterministic RNG ---------------- */

function conceptRng(seedStr) {
  let h = 2166136261;
  for (let i = 0; i < seedStr.length; i++) {
    h ^= seedStr.charCodeAt(i); h = Math.imul(h, 16777619);
  }
  return () => {
    h ^= h << 13; h ^= h >>> 17; h ^= h << 5;
    return ((h >>> 0) % 100000) / 100000;
  };
}

/* ---------------- animation lifecycle (shared by all three lanes) ----------------
   The dashboard's modal close gesture only HIDES #modal (app.js sets
   style.display = "none" and never clears #modalbody), and openModal()
   swaps #modalbody.innerHTML synchronously — so a by-id DOM check can
   never observe either event. Every RAF loop here therefore stops on
   EITHER of:
     • detach — THIS canvas element left the DOM. Identity check on the
       captured element (canvas.isConnected), never getElementById: a
       reopened modal inserts a same-id replacement within the same task
       (no frame fires in between), so a by-id lookup would latch a stale
       loop onto the NEW canvas forever.
     • hide — the modal closed but the canvas is still parked in the
       hidden #modalbody; display:none anywhere up the chain makes
       offsetParent null (no canvas here is position:fixed, so null
       reliably means "not rendered").
   Reopening always goes through openModal → fresh canvas + fresh loop,
   so stopping here never strands a live view. onStop runs exactly once
   at termination and unhooks whatever the view registered on window, so
   nothing accumulates per open. */

function conceptCanvasLive(canvas) {
  return canvas.isConnected && canvas.offsetParent !== null;
}

function conceptAnimate(canvas, draw, onStop) {
  function tick() {
    if (!conceptCanvasLive(canvas)) { if (onStop) onStop(); return; }
    draw();
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
}

/* ---------------- molecule concept from a REAL sequence ---------------- */

// residue propensities (coarse Chou–Fasman spirit): helix vs sheet formers
const HELIX_SET = new Set("AELMQKRH");
const SHEET_SET = new Set("VIFYWTC");

function secondaryGuess(residues) {
  // windowed majority, then smoothed into runs (helix ≥ 4, sheet ≥ 3)
  const raw = [...residues].map((c, i) => {
    let hN = 0, sN = 0;
    for (let k = -2; k <= 2; k++) {
      const r = residues[i + k];
      if (!r) continue;
      if (HELIX_SET.has(r)) hN++;
      if (SHEET_SET.has(r)) sN++;
    }
    return hN >= 3 ? "H" : sN >= 3 ? "S" : "C";
  });
  const out = [...raw];
  let i = 0;
  while (i < out.length) {
    let j = i;
    while (j < out.length && out[j] === out[i]) j++;
    const run = j - i, kind = out[i];
    if ((kind === "H" && run < 4) || (kind === "S" && run < 3))
      for (let k = i; k < j; k++) out[k] = "C";
    i = j;
  }
  return out;
}

function backboneFromSequence(id, residues) {
  const ss = secondaryGuess(residues);
  const rng = conceptRng(id + residues.length);
  const atoms = [];
  // walk a heading frame; helix winds tightly, sheet extends, coil wanders
  let px = 0, py = 0, pz = 0;
  let dir = { x: 1, y: 0, z: 0 }, phase = 0;
  const turn = (v, ax, ang) => {   // rotate v around axis ax by ang (Rodrigues)
    const s = Math.sin(ang), c = Math.cos(ang);
    const dot = v.x * ax.x + v.y * ax.y + v.z * ax.z;
    return {
      x: v.x * c + (ax.y * v.z - ax.z * v.y) * s + ax.x * dot * (1 - c),
      y: v.y * c + (ax.z * v.x - ax.x * v.z) * s + ax.y * dot * (1 - c),
      z: v.z * c + (ax.x * v.y - ax.y * v.x) * s + ax.z * dot * (1 - c),
    };
  };
  for (let i = 0; i < ss.length; i++) {
    const kind = ss[i];
    if (kind === "H") {            // 100°/residue wind around the heading
      phase += 1.745;
      const r = 2.3;
      atoms.push({ x: px + Math.cos(phase) * r, y: py + Math.sin(phase) * r,
                   z: pz, c: "A" });
      px += dir.x * 1.5; py += dir.y * 1.5; pz += dir.z * 1.5;
    } else if (kind === "S") {     // extended zigzag strand
      atoms.push({ x: px, y: py + (i % 2 ? 0.9 : -0.9), z: pz, c: "A" });
      px += dir.x * 3.3; py += dir.y * 3.3; pz += dir.z * 3.3;
    } else {                       // coil: seeded gentle wander
      dir = turn(dir, { x: 0, y: 1, z: 0 }, (rng() - 0.5) * 1.1);
      dir = turn(dir, { x: 0, y: 0, z: 1 }, (rng() - 0.5) * 1.1);
      atoms.push({ x: px, y: py, z: pz, c: "A" });
      px += dir.x * 3.0; py += dir.y * 3.0; pz += dir.z * 3.0;
    }
    if (ss[i + 1] && ss[i + 1] !== kind) {   // segment boundary: new heading
      dir = turn(dir, { x: 0, y: 1, z: 0 }, (rng() - 0.5) * 2.4);
      dir = turn(dir, { x: rng(), y: 0, z: 1 - rng() }, (rng() - 0.5) * 1.6);
      const len = Math.hypot(dir.x, dir.y, dir.z) || 1;
      dir = { x: dir.x / len, y: dir.y / len, z: dir.z / len };
    }
  }
  return atoms;
}

/* ---------------- residue property tables (published constants) ----------------
   Small hard-coded tables so the renderer stays honest about WHAT the colors
   and sizes mean. Values are standard textbook numbers, not measurements
   of this molecule. */

// side-chain contribution to residue mass (Da, rounded) — bead radius scale.
// G smallest, W largest.
const RESIDUE_MASS = {
  G: 57,  A: 71,  S: 87,  P: 97,  V: 99,  T: 101, C: 103, I: 113, L: 113,
  N: 114, D: 115, Q: 128, K: 128, E: 129, M: 131, H: 137, F: 147, R: 156,
  Y: 163, W: 186,
};
const RESIDUE_MASS_DEFAULT = 110;         // unknown letter (X etc.)
const MASS_MIN = 57, MASS_MAX = 186;

// Kyte–Doolittle hydropathy index (+ = hydrophobic, − = hydrophilic)
const KD_HYDROPATHY = {
  I: 4.5, V: 4.2, L: 3.8, F: 2.8, C: 2.5, M: 1.9, A: 1.8, G: -0.4,
  T: -0.7, S: -0.8, W: -0.9, Y: -1.3, P: -1.6, H: -3.2, E: -3.5,
  Q: -3.5, D: -3.5, N: -3.5, K: -3.9, R: -4.5,
};

const SS_COLORS = { H: "#f5a623", S: "#58a6ff", C: "#7d8894" };
const CHARGE_NEG = new Set("DE");         // acidic → red
const CHARGE_POS = new Set("KRH");        // basic  → blue
const CHARGE_COLORS = { neg: "#e5534b", pos: "#58a6ff", none: "#8b949e" };
const HYDRO_COOL = [88, 166, 255];        // hydrophilic
const HYDRO_WARM = [255, 122, 61];        // hydrophobic

function conceptLerpRgb(a, b, t) {
  t = Math.max(0, Math.min(1, t));
  const m = i => Math.round(a[i] + (b[i] - a[i]) * t);
  return `rgb(${m(0)},${m(1)},${m(2)})`;
}

function conceptResidueColor(mode, res, kind) {
  if (mode === "hydropathy")
    return conceptLerpRgb(HYDRO_COOL, HYDRO_WARM,
                          ((KD_HYDROPATHY[res] ?? 0) + 4.5) / 9);
  if (mode === "charge")
    return CHARGE_NEG.has(res) ? CHARGE_COLORS.neg
         : CHARGE_POS.has(res) ? CHARGE_COLORS.pos : CHARGE_COLORS.none;
  return SS_COLORS[kind] || SS_COLORS.C;  // "secondary"
}

function conceptLegendHtml(mode) {
  const sw = c => `<span style="display:inline-block;width:9px;height:9px;
    border-radius:50%;background:${c};margin:0 4px 0 10px"></span>`;
  if (mode === "hydropathy")
    return `<span style="display:inline-block;width:64px;height:8px;
        border-radius:4px;margin:0 4px 0 10px;background:linear-gradient(90deg,
        ${conceptLerpRgb(HYDRO_COOL, HYDRO_WARM, 0)},
        ${conceptLerpRgb(HYDRO_COOL, HYDRO_WARM, 1)})"></span>
      hydrophilic → hydrophobic (Kyte–Doolittle)`;
  if (mode === "charge")
    return `${sw(CHARGE_COLORS.neg)}D/E − ${sw(CHARGE_COLORS.pos)}K/R/H +
      ${sw(CHARGE_COLORS.none)}neutral`;
  return `${sw(SS_COLORS.H)}helix ${sw(SS_COLORS.S)}sheet ${sw(SS_COLORS.C)}coil`;
}

/* ---------------- concept molecule: build + renderer ----------------
   The build step turns the REAL stored sequence into geometry once
   (backboneFromSequence keeps its contract; beads are derived from it).
   The renderer is the same hand-rolled projection style as molecule.js;
   the lifecycle runs through conceptAnimate — the loop stops on detach
   OR hidden modal, then removes its window listener (see the lifecycle
   note above). The canvas id is "cmol3d", deliberately NOT molecule.js's
   "mol3d": molecule.js checks liveness by that id, so sharing it would
   let a stale real-structure loop latch onto this generated canvas. */

function conceptMoleculeBuild(nodeId, residues) {
  const ss = secondaryGuess(residues);
  const backbone = backboneFromSequence(nodeId, residues); // 1 point/residue
  // contiguous secondary-structure runs (drives glow passes + arrowheads)
  const runs = [];
  let i = 0;
  while (i < ss.length) {
    let j = i;
    while (j < ss.length && ss[j] === ss[i]) j++;
    runs.push({ kind: ss[i], a: i, b: j - 1 });
    i = j;
  }
  // one side-chain HINT bead per residue: offset perpendicular to the local
  // backbone tangent, fanned by the golden angle so neighbours don't stack.
  // Fully deterministic — no RNG needed here.
  const sub = (a, b) => ({ x: a.x - b.x, y: a.y - b.y, z: a.z - b.z });
  const cross = (a, b) => ({ x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x });
  const norm = a => { const l = Math.hypot(a.x, a.y, a.z) || 1;
    return { x: a.x / l, y: a.y / l, z: a.z / l }; };
  const beads = backbone.map((p, k) => {
    const prev = backbone[Math.max(0, k - 1)];
    const next = backbone[Math.min(backbone.length - 1, k + 1)];
    const t = norm(sub(next, prev));
    const ref = Math.abs(t.y) < 0.9 ? { x: 0, y: 1, z: 0 } : { x: 1, y: 0, z: 0 };
    const n1 = norm(cross(t, ref)), n2 = cross(t, n1);
    const ang = k * 2.399963;                       // golden angle
    const res = (residues[k] || "X").toUpperCase();
    const mass = RESIDUE_MASS[res] ?? RESIDUE_MASS_DEFAULT;
    const massT = Math.max(0, Math.min(1, (mass - MASS_MIN) / (MASS_MAX - MASS_MIN)));
    const off = 1.7 + massT * 1.3;                  // heavier sits further out
    const dx = n1.x * Math.cos(ang) + n2.x * Math.sin(ang);
    const dy = n1.y * Math.cos(ang) + n2.y * Math.sin(ang);
    const dz = n1.z * Math.cos(ang) + n2.z * Math.sin(ang);
    return { x: p.x + dx * off, y: p.y + dy * off, z: p.z + dz * off,
             res, kind: ss[k], massT };
  });
  return { backbone, beads, ss, runs, residues };
}

function startConceptMolecule(build, modeRef) {
  const canvas = document.getElementById("cmol3d");   // own id — see note above
  if (!canvas) return;
  const g = canvas.getContext("2d");
  const { ss, runs, residues } = build;

  // center + normalize over backbone AND beads so nothing clips at the edge
  const all = build.backbone.concat(build.beads);
  const n = all.length || 1;
  let cx = 0, cy = 0, cz = 0;
  for (const p of all) { cx += p.x; cy += p.y; cz += p.z; }
  cx /= n; cy /= n; cz /= n;
  let maxR = 1;
  const center = p => {
    const x = p.x - cx, y = p.y - cy, z = p.z - cz;
    maxR = Math.max(maxR, Math.hypot(x, y, z));
    return { x, y, z };
  };
  const bb = build.backbone.map(center);
  const beads = build.beads.map(p => Object.assign(center(p),
    { res: p.res, kind: p.kind, massT: p.massT }));

  // interaction — same feel as molecule.js: drag rotate, wheel zoom, idle spin
  let rotX = 0.4, rotY = 0.6, zoom = 1, dragging = false, lastX = 0, lastY = 0;
  let idleSpin = true;
  canvas.onmousedown = e => { dragging = true; idleSpin = false;
    lastX = e.offsetX; lastY = e.offsetY; canvas.style.cursor = "grabbing"; };
  // named so conceptAnimate's onStop can remove it — an anonymous window
  // listener here leaked once per open, pinning the canvas backing store
  // and this scope's geometry arrays for the life of the page.
  const onWindowUp = () => { dragging = false; canvas.style.cursor = "grab"; };
  window.addEventListener("mouseup", onWindowUp);
  canvas.onmousemove = e => {
    if (!dragging) return;
    rotY += (e.offsetX - lastX) * 0.01;
    rotX += (e.offsetY - lastY) * 0.01;
    lastX = e.offsetX; lastY = e.offsetY;
  };
  canvas.onwheel = e => { e.preventDefault();
    zoom = Math.min(4, Math.max(0.3, zoom * (e.deltaY < 0 ? 1.1 : 0.9))); };

  const depthAlpha = (depth, base) =>
    Math.max(0.12, Math.min(1, base - 0.4 * (depth / (maxR * 1.4))));

  function frame() {                // liveness + stop live in conceptAnimate
    if (idleSpin) rotY += 0.004;
    const w = canvas.width, h = canvas.height;
    const scale = (Math.min(w, h) / (2.6 * maxR)) * zoom;
    const sx = Math.sin(rotX), cxr = Math.cos(rotX);
    const sy = Math.sin(rotY), cyr = Math.cos(rotY);
    const project = p => {          // rotate Y then X, simple perspective
      const x1 = p.x * cyr + p.z * sy;
      const z1 = -p.x * sy + p.z * cyr;
      const y2 = p.y * cxr - z1 * sx;
      const z2 = p.y * sx + z1 * cxr;
      const persp = 1 / (1 + z2 / (4 * maxR));
      return { X: w / 2 + x1 * scale * persp,
               Y: h / 2 + y2 * scale * persp, depth: z2, persp };
    };
    g.clearRect(0, 0, w, h);
    const P = bb.map(project);
    const mode = modeRef.mode;

    // pass 1 — soft outer glow under every helix ribbon
    g.lineCap = "round";
    for (let i = 1; i < P.length; i++) {
      if (ss[i] !== "H") continue;
      const col = conceptResidueColor(mode, residues[i], "H");
      g.strokeStyle = col; g.shadowColor = col; g.shadowBlur = 22;
      g.lineWidth = 13;
      g.globalAlpha = 0.1 * depthAlpha((P[i].depth + P[i - 1].depth) / 2, 0.9);
      g.beginPath(); g.moveTo(P[i - 1].X, P[i - 1].Y);
      g.lineTo(P[i].X, P[i].Y); g.stroke();
    }

    // pass 2 — the backbone itself: helix ribbon 6px, sheet strand 8px,
    // coil thin trace. Segment i inherits residue i's kind + color.
    for (let i = 1; i < P.length; i++) {
      const kind = ss[i];
      const col = conceptResidueColor(mode, residues[i], kind);
      g.strokeStyle = col; g.shadowColor = col;
      g.lineWidth = kind === "H" ? 6 : kind === "S" ? 8 : 1.6;
      g.shadowBlur = kind === "C" ? 5 : 10;
      g.globalAlpha = depthAlpha((P[i].depth + P[i - 1].depth) / 2, 0.8);
      g.beginPath(); g.moveTo(P[i - 1].X, P[i - 1].Y);
      g.lineTo(P[i].X, P[i].Y); g.stroke();
    }

    // pass 3 — arrowhead at the C-terminal end of every sheet run
    for (const run of runs) {
      if (run.kind !== "S") continue;
      const tail = P[run.b], from = P[run.b > run.a ? run.b - 1
                                    : Math.max(0, run.a - 1)];
      let dx = tail.X - from.X, dy = tail.Y - from.Y;
      const len = Math.hypot(dx, dy);
      if (len < 0.5) continue;                       // edge-on: skip cleanly
      dx /= len; dy /= len;
      const size = (9 + 5 * tail.persp), px = -dy, py = dx;
      const col = conceptResidueColor(mode, residues[run.b], "S");
      g.fillStyle = col; g.shadowColor = col; g.shadowBlur = 10;
      g.globalAlpha = depthAlpha(tail.depth, 0.85);
      g.beginPath();
      g.moveTo(tail.X + dx * size * 1.5, tail.Y + dy * size * 1.5);  // tip
      g.lineTo(tail.X + px * size * 0.8, tail.Y + py * size * 0.8);
      g.lineTo(tail.X - px * size * 0.8, tail.Y - py * size * 0.8);
      g.closePath(); g.fill();
    }

    // pass 4 — side-chain hint beads, drawn far→near so near ones read on top
    const B = beads.map(p => Object.assign(project(p),
      { res: p.res, kind: p.kind, massT: p.massT }));
    B.sort((a, b) => b.depth - a.depth);
    for (const p of B) {
      const col = conceptResidueColor(mode, p.res, p.kind);
      g.fillStyle = col; g.shadowColor = col; g.shadowBlur = 8;
      g.globalAlpha = 0.8 * depthAlpha(p.depth, 0.85);
      const r = (1.2 + p.massT * 2.8) * p.persp * Math.sqrt(zoom);
      g.beginPath(); g.arc(p.X, p.Y, r, 0, 7); g.fill();
    }

    g.globalAlpha = 1; g.shadowBlur = 0;
  }
  conceptAnimate(canvas, frame,
    () => window.removeEventListener("mouseup", onWindowUp));
}

function viewGeneratedMolecule(nodeId, residues) {
  residues = String(residues || "");
  if (!residues.length) {
    openModal(`<h2>🧪 ${esc(nodeId)} — generated molecule concept</h2>
      <div class="empty">the stored sequence is empty — nothing honest to
      build a 3D concept from.</div>`);
    return;
  }
  const ss = secondaryGuess(residues);
  const h = ss.filter(k => k === "H").length;
  const s = ss.filter(k => k === "S").length;
  openModal(`<h2>🧪 ${esc(nodeId)} — generated molecule concept</h2>
    ${CONCEPT_BANNER("MOLECULE CONCEPT")}
    <div class="sub">${residues.length} residues from the stored sequence ·
      layout guessed as ${h} helix / ${s} sheet / ${residues.length - h - s}
      coil positions · deterministic: same sequence → same shape</div>
    <div id="molmodes" style="display:flex;gap:6px;align-items:center;
        flex-wrap:wrap;margin:6px 0">
      <button class="btn small" data-mode="secondary">secondary</button>
      <button class="btn small" data-mode="hydropathy">hydropathy</button>
      <button class="btn small" data-mode="charge">charge</button>
      <span id="mollegend" class="sub"></span>
    </div>
    <canvas id="cmol3d" width="640" height="440"
      style="width:100%;border:1px solid var(--line);border-radius:8px;background:#05070d;cursor:grab"></canvas>
    <div class="when" style="margin-top:6px">drag to rotate · wheel to zoom ·
      auto-spins when idle · side-chain beads are size hints (residue mass),
      not atom positions</div>`);
  // color-mode switching: the RAF loop reads modeRef every frame, so a
  // click re-renders live without reopening the modal.
  const modeRef = { mode: "secondary" };
  const paint = () => {
    const legend = document.getElementById("mollegend");
    if (legend) legend.innerHTML = conceptLegendHtml(modeRef.mode);
    document.querySelectorAll("#molmodes .btn").forEach(b => {
      const on = b.dataset.mode === modeRef.mode;
      b.style.borderColor = on ? "var(--accent)" : "";
      b.style.color = on ? "var(--accent)" : "";
    });
  };
  document.querySelectorAll("#molmodes .btn").forEach(b => {
    b.onclick = () => { modeRef.mode = b.dataset.mode; paint(); };
  });
  paint();
  startConceptMolecule(conceptMoleculeBuild(nodeId, residues), modeRef);
}

/* ---------------- DNA markup (gene nodes) ---------------- */

const BASE_COLORS = { A: "#4cc38a", T: "#e5534b", G: "#f5a623", C: "#58a6ff" };

function viewDNA(geneId) {
  openModal(`<h2>🧬 ${esc(geneId)} — DNA markup</h2>
    ${CONCEPT_BANNER("DNA MARKUP")}
    <div class="sub">Illustrative double helix — the floor stores no
      nucleotide sequence for this gene, so the base pattern is a seeded
      illustration, not the real gene.</div>
    <canvas id="dna3d" width="640" height="420"
      style="width:100%;border:1px solid var(--line);border-radius:8px;background:#05070d;cursor:grab"></canvas>`);
  const canvas = document.getElementById("dna3d");
  const g = canvas.getContext("2d");
  const rng = conceptRng(geneId);
  const bases = Array.from({ length: 42 }, () => "ATGC"[Math.floor(rng() * 4)]);
  let rot = 0, dragging = false, lastX = 0, vel = 0.012;
  canvas.onmousedown = e => { dragging = true; lastX = e.offsetX; };
  const onWindowUp = () => { dragging = false; };  // removed by onStop below
  window.addEventListener("mouseup", onWindowUp);
  canvas.onmousemove = e => {
    if (dragging) { vel = (e.offsetX - lastX) * 0.002; rot += (e.offsetX - lastX) * 0.01;
                    lastX = e.offsetX; }
  };
  conceptAnimate(canvas, () => {
    if (!dragging) rot += vel; vel = vel * 0.99 + 0.012 * 0.01;
    const w = canvas.width, h = canvas.height;
    g.clearRect(0, 0, w, h);
    const R = 64, pitch = h / bases.length;
    for (let i = 0; i < bases.length; i++) {
      const t = rot + i * 0.55, y = 20 + i * pitch * 0.92;
      const x1 = w / 2 + Math.cos(t) * R, z1 = Math.sin(t);
      const x2 = w / 2 + Math.cos(t + Math.PI) * R, z2 = Math.sin(t + Math.PI);
      const base = bases[i], comp = { A: "T", T: "A", G: "C", C: "G" }[base];
      // rung halves, colored by base + complement
      g.lineWidth = 3;
      g.globalAlpha = 0.35 + 0.3 * (z1 + 1) / 2;
      g.strokeStyle = BASE_COLORS[base];
      g.beginPath(); g.moveTo(x1, y); g.lineTo(w / 2, y); g.stroke();
      g.globalAlpha = 0.35 + 0.3 * (z2 + 1) / 2;
      g.strokeStyle = BASE_COLORS[comp];
      g.beginPath(); g.moveTo(w / 2, y); g.lineTo(x2, y); g.stroke();
      // strand beads
      for (const [x, z, col] of [[x1, z1, "#9ecbff"], [x2, z2, "#b083f0"]]) {
        g.globalAlpha = 0.45 + 0.5 * (z + 1) / 2;
        g.fillStyle = col; g.shadowColor = col; g.shadowBlur = 8;
        g.beginPath(); g.arc(x, y, 4.4 + 1.8 * (z + 1) / 2, 0, 7); g.fill();
      }
      g.shadowBlur = 0;
    }
    g.globalAlpha = 1;
  }, () => window.removeEventListener("mouseup", onWindowUp));
}

/* ---------------- cell markup (location nodes) ---------------- */

const CELL_PARTS = [
  { key: /nucle|chromosom/i, name: "nucleus" },
  { key: /cytoplasm|cytosol/i, name: "cytoplasm" },
  { key: /membrane/i, name: "membrane" },
  { key: /secret|extracell/i, name: "secreted" },
  { key: /mitochond/i, name: "mitochondria" },
  { key: /reticulum|\bER\b/i, name: "er" },
  { key: /golgi/i, name: "golgi" },
  { key: /endosom|lysosom|vesic/i, name: "vesicles" },
];

function viewCell(locationId) {
  const label = locationId.split(":", 2)[1] || locationId;
  const hit = CELL_PARTS.find(p => p.key.test(label));
  const highlight = hit ? hit.name : "cytoplasm";
  openModal(`<h2>🧫 ${esc(locationId)} — cell markup</h2>
    ${CONCEPT_BANNER("CELL MARKUP")}
    <div class="sub">Illustrative cell cross-section; the stored fact is the
      compartment name — the highlighted region shows where
      “${esc(label)}” lives.</div>
    <canvas id="cell3d" width="640" height="440"
      style="width:100%;border:1px solid var(--line);border-radius:8px;background:#05070d"></canvas>`);
  const canvas = document.getElementById("cell3d");
  const g = canvas.getContext("2d");
  const rng = conceptRng(locationId);
  const mito = Array.from({ length: 5 }, () => ({
    x: 0.22 + rng() * 0.56, y: 0.2 + rng() * 0.6, a: rng() * Math.PI }));
  const ves = Array.from({ length: 7 }, () => ({
    x: 0.2 + rng() * 0.6, y: 0.2 + rng() * 0.6, r: 5 + rng() * 7 }));
  let t = 0;
  const glow = name => highlight === name
    ? 0.85 + 0.15 * Math.sin(t * 0.06) : 0.35;
  conceptAnimate(canvas, () => {  // no window listeners here → no onStop
    t++;
    const w = canvas.width, h = canvas.height, cx = w / 2, cy = h / 2;
    g.clearRect(0, 0, w, h);
    // membrane
    g.lineWidth = highlight === "membrane" ? 6 : 3;
    g.strokeStyle = "#39c5cf"; g.globalAlpha = glow("membrane");
    g.shadowColor = "#39c5cf"; g.shadowBlur = highlight === "membrane" ? 22 : 8;
    g.beginPath(); g.ellipse(cx, cy, w * 0.4, h * 0.4, 0, 0, 7); g.stroke();
    // cytoplasm tint
    g.globalAlpha = highlight === "cytoplasm" ? 0.22 : 0.08;
    g.fillStyle = "#39c5cf"; g.shadowBlur = 0;
    g.beginPath(); g.ellipse(cx, cy, w * 0.4, h * 0.4, 0, 0, 7); g.fill();
    // secreted arrows leaving the membrane
    if (highlight === "secreted") {
      g.strokeStyle = "#e8b854"; g.globalAlpha = 0.9; g.lineWidth = 2.5;
      for (let k = 0; k < 6; k++) {
        const a = k * 1.047 + t * 0.01;
        const r0 = w * 0.4, r1 = r0 + 26 + 8 * Math.sin(t * 0.08 + k);
        const x0 = cx + Math.cos(a) * r0 * 1.0, y0 = cy + Math.sin(a) * h / w * r0;
        const x1 = cx + Math.cos(a) * r1, y1 = cy + Math.sin(a) * h / w * r1;
        g.beginPath(); g.moveTo(x0, y0); g.lineTo(x1, y1); g.stroke();
      }
    }
    // nucleus (+ chromosome squiggle)
    g.globalAlpha = glow("nucleus");
    g.fillStyle = "#b083f0"; g.shadowColor = "#b083f0";
    g.shadowBlur = highlight === "nucleus" ? 26 : 10;
    g.beginPath(); g.ellipse(cx - w * 0.08, cy - h * 0.05, 62, 52, 0.3, 0, 7); g.fill();
    g.shadowBlur = 0; g.strokeStyle = "#e6d7ff"; g.lineWidth = 2;
    g.globalAlpha = Math.min(1, glow("nucleus") + 0.1);
    g.beginPath();
    for (let k = 0; k <= 40; k++) {
      const x = cx - w * 0.08 - 40 + k * 2;
      const y = cy - h * 0.05 + Math.sin(k * 0.7 + t * 0.03) * 14;
      k ? g.lineTo(x, y) : g.moveTo(x, y);
    }
    g.stroke();
    // mitochondria
    for (const m of mito) {
      g.globalAlpha = glow("mitochondria");
      g.fillStyle = "#e5534b"; g.shadowColor = "#e5534b";
      g.shadowBlur = highlight === "mitochondria" ? 18 : 6;
      g.save();
      g.translate(m.x * w, m.y * h); g.rotate(m.a + Math.sin(t * 0.02) * 0.08);
      g.beginPath(); g.ellipse(0, 0, 22, 10, 0, 0, 7); g.fill();
      g.restore();
    }
    g.shadowBlur = 0;
    // ER ribbons around the nucleus
    g.strokeStyle = "#4cc38a"; g.lineWidth = 2.5; g.globalAlpha = glow("er");
    for (let ring = 0; ring < 3; ring++) {
      g.beginPath();
      for (let k = 0; k <= 30; k++) {
        const a = -0.6 + k * 0.075;
        const R = 78 + ring * 13 + Math.sin(k * 0.9 + t * 0.03 + ring) * 4;
        const x = cx - w * 0.08 + Math.cos(a) * R;
        const y = cy - h * 0.05 + Math.sin(a) * R * 0.8;
        k ? g.lineTo(x, y) : g.moveTo(x, y);
      }
      g.stroke();
    }
    // golgi stack
    g.strokeStyle = "#f5a623"; g.globalAlpha = glow("golgi"); g.lineWidth = 3.5;
    for (let k = 0; k < 4; k++) {
      g.beginPath();
      g.ellipse(cx + w * 0.16, cy + h * 0.12 + k * 9, 34 - k * 4, 6, 0, 0, 7);
      g.stroke();
    }
    // vesicles
    for (const v of ves) {
      g.globalAlpha = glow("vesicles");
      g.fillStyle = "#9ecbff"; g.shadowColor = "#9ecbff";
      g.shadowBlur = highlight === "vesicles" ? 14 : 4;
      g.beginPath();
      g.arc(v.x * w + Math.sin(t * 0.02 + v.r) * 4, v.y * h, v.r, 0, 7); g.fill();
    }
    g.shadowBlur = 0; g.globalAlpha = 1;
  });
}

/* ---------------- dispatcher (node inspector buttons call this) ---------------- */

async function viewConcept(nodeId) {
  const type = nodeId.split(":", 1)[0];
  if (type === "structure") { viewStructure(nodeId.slice(10)); return; }
  if (type === "gene") { viewDNA(nodeId); return; }
  if (type === "location") { viewCell(nodeId); return; }
  if (type === "sequence") {
    const d = await api("/api/sequence", { db: state.db, id: nodeId });
    if (d.error) { openModal(`<h2>${esc(nodeId)}</h2><div class="empty">${esc(d.error)}</div>`); return; }
    viewGeneratedMolecule(nodeId, d.residues);
    return;
  }
  if (type === "protein") {
    // prefer the REAL structure if the graph holds one; else generate from
    // the REAL sequence; be honest when neither exists.
    const nd = await api("/api/node", { db: state.db, id: nodeId });
    const edges = [...(nd.outgoing || []), ...(nd.incoming || [])];
    const struct = edges.find(e => (e.relation === "has_structure" ||
      e.relation === "predicts_structure") && e.target.startsWith("structure:"));
    if (struct) { viewStructure(struct.target.slice(10)); return; }
    const seq = edges.find(e => e.relation === "has_sequence" &&
      e.target.startsWith("sequence:"));
    if (seq) {
      const d = await api("/api/sequence", { db: state.db, id: seq.target });
      if (!d.error) { viewGeneratedMolecule(nodeId, d.residues); return; }
    }
    openModal(`<h2>${esc(nodeId)}</h2><div class="empty">no stored structure
      or sequence to build a 3D view from — run the wheel on it first.</div>`);
  }
}
