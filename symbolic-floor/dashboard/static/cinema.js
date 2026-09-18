"use strict";
/* cinema.js — CellJourney: a cinematic, movie-style camera dive from the
   extracellular space down to a single protein backbone.

   HONESTY CONTRACT: every frame carries a permanent banner —
   "illustrative journey — structures stylized; names come from this mind's
   graph". Everything drawn is a stylized illustration; the ONLY grounded
   things on screen are the node ids (gene / protein) and the residue
   sequence handed in via context, which come from the selected mind's
   graph — the final backbone is generated from that REAL sequence by
   backboneFromSequence (conceptviz.js).

   House rules: plain 2D canvas, hand-rolled projection (molecule.js
   style), no libraries/WebGL; the RAF loop self-terminates when #cinema3d
   leaves the DOM; ALL randomness via the seeded conceptRng global.

   API: CellJourney.mount(el, {gene, protein, residues}) / unmount() /
        setContext(ctx) / isMounted()                                    */

const CellJourney = (() => {

  /* ------------------------------ state ------------------------------ */

  let host = null;                  // container element we own
  let stage = null;                 // canvas parent (drives sizing)
  let canvas = null, g = null;      // #cinema3d + its 2d context
  let runId = 0;                    // RAF generation token (remount safety)
  let startedAt = 0, lastStamp = 0; // clock origin (ambient motion only)

  let jctx = { gene: null, protein: null, residues: null };  // grounding
  let plan = [];                    // active waypoints, each with [t0,t1]
  let scene = null;                 // seeded static layouts
  let t = 0;                        // master timeline in [0,1]
  let tweenTo = null;               // animated-seek target (chip clicks)
  let playing = true;
  let scrubbing = false;
  const SPEEDS = [0.5, 1, 2];
  let speedIx = 1;
  const DURATION = 55;              // seconds start→end at 1×
  const FADE = 0.035;               // crossfade half-width on the timeline

  let ui = null;                    // { play, speed, scrub, chipBox, chips }
  let currentKey = "";              // waypoint whose chip is lit

  const BANNER =
    "illustrative journey — structures stylized; names come from this mind's graph";
  const FONT = "-apple-system, 'SF Pro Text', sans-serif";

  // A/T/G/C palette: prefer conceptviz's BASE_COLORS, else our own copy.
  const CJ_BASES = { A: "#4cc38a", T: "#e5534b", G: "#f5a623", C: "#58a6ff" };
  const basePal = () =>
    (typeof BASE_COLORS !== "undefined" && BASE_COLORS) ? BASE_COLORS : CJ_BASES;

  /* --------------------------- small math ----------------------------- */

  const clamp01 = v => v < 0 ? 0 : v > 1 ? 1 : v;
  const lerp = (a, b, k) => a + (b - a) * k;
  // cubic ease-in-out — the "filmed" camera feel inside each waypoint
  const easeC = k => k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
  const ramp = (v, a, b) => clamp01((v - a) / ((b - a) || 1e-9));

  /* -------------------- seeded scenery (layouts) ----------------------
     All positions are rolled ONCE per (db|gene|protein) seed — a given
     mind always plays the exact same journey. Animation phase comes from
     the wall clock (motion, not randomness).                             */

  function seedString() {
    const db = (typeof state !== "undefined" && state && state.db) ? state.db : "floor";
    return `cinema|${db}|${jctx.gene || ""}|${jctx.protein || ""}`;
  }

  function buildScenery() {
    const rng = conceptRng(seedString());
    const s = {};

    // 1 approach — drifting neighbor cells + parallax dust
    s.cells = Array.from({ length: 7 }, () => ({
      x: rng(), y: rng(), z: 0.3 + rng() * 0.7, r: 0.05 + rng() * 0.06 }));
    s.dust = Array.from({ length: 70 }, () => ({
      x: rng(), y: rng(), z: 0.25 + rng() * 0.75 }));

    // 2 membrane — per-lipid wobble phases
    s.lipids = Array.from({ length: 90 }, () => rng() * Math.PI * 2);

    // 3 cytoplasm — organelles at parallax depths z∈[0.9,2.4]
    const depth = () => 0.9 + rng() * 1.5;
    s.mito  = Array.from({ length: 6 },  () => ({ x: rng(), y: rng(), z: depth(), a: rng() * Math.PI }));
    s.er    = Array.from({ length: 3 },  () => ({ x: rng(), y: rng(), z: depth(), p: rng() * 6 }));
    s.golgi = Array.from({ length: 2 },  () => ({ x: rng(), y: rng(), z: depth() }));
    s.ves   = Array.from({ length: 10 }, () => ({ x: rng(), y: rng(), z: depth(), r: 4 + rng() * 7 }));

    // 4 nucleus — pore angles on the envelope; one pore is the camera's exit
    s.pores = Array.from({ length: 9 }, (_, i) => i * 0.698 + rng() * 0.3);
    s.poreTarget = s.pores[Math.floor(rng() * s.pores.length)];

    // 5 chromatin — strands with a tangled AND a condensed (X-shape) pose;
    //   the scene lerps between the two as it plays
    const P = 46, arms = [-2.356, -0.785, 0.785, 2.356];
    s.strands = [];
    for (let sI = 0; sI < 5; sI++) {
      let x = 0.2 + rng() * 0.6, y = 0.2 + rng() * 0.6;
      const arm = arms[sI % 4], pts = [];
      for (let i = 0; i < P; i++) {
        x = Math.min(0.92, Math.max(0.08, x + (rng() - 0.5) * 0.09));
        y = Math.min(0.92, Math.max(0.08, y + (rng() - 0.5) * 0.09));
        const f = i / (P - 1);                    // 0 = centromere → 1 = arm tip
        const jit = (rng() - 0.5) * 0.045 * (0.35 + f);
        pts.push({ tx: x, ty: y,                  // tangled pose
          cx: 0.5 + Math.cos(arm) * f * 0.30 + Math.cos(arm + Math.PI / 2) * jit,
          cy: 0.5 + Math.sin(arm) * f * 0.30 + Math.sin(arm + Math.PI / 2) * jit,
        });
      }
      s.strands.push(pts);
    }

    // 6/7 DNA — seeded illustrative base run + the highlighted gene span
    s.dnaBases = Array.from({ length: 36 }, () => "ATGC"[Math.floor(rng() * 4)]);
    const gl = 8 + Math.floor(rng() * 5), g0 = 5 + Math.floor(rng() * (36 - gl - 10));
    s.geneSpan = [g0, g0 + gl];

    // 8 protein — normalized backbone generated from the REAL sequence
    s.backbone = null;
    if (jctx.residues && typeof backboneFromSequence === "function") {
      let atoms = backboneFromSequence(jctx.protein || jctx.gene || "protein",
                                       jctx.residues);
      if (atoms.length > 600) {                   // keep the trace light
        const step = atoms.length / 600;
        atoms = Array.from({ length: 600 }, (_, i) => atoms[Math.floor(i * step)]);
      }
      const n = atoms.length || 1;
      let cx = 0, cy = 0, cz = 0;
      for (const a of atoms) { cx += a.x; cy += a.y; cz += a.z; }
      cx /= n; cy /= n; cz /= n;
      let maxR = 1;
      const pts = atoms.map(a => {
        const x = a.x - cx, y = a.y - cy, z = a.z - cz;
        maxR = Math.max(maxR, Math.hypot(x, y, z));
        return { x, y, z };
      });
      if (pts.length >= 2) s.backbone = { pts, maxR };
    }
    scene = s;
  }

  /* --------------------------- the timeline --------------------------- */

  const hasFinale = () => !!jctx.gene || !!(jctx.residues && scene && scene.backbone);

  // Draw functions are hoisted declarations, so direct references are safe.
  const SCENES = [
    { key: "approach", label: "approach", w: 1.1, need: () => true, draw: drawApproach,
      cap: () => "extracellular space — drifting toward the hero cell" },
    { key: "membrane", label: "membrane", w: 0.9, need: () => true, draw: drawMembrane,
      cap: () => "phospholipid bilayer — the membrane parts as we pass through" },
    { key: "cytoplasm", label: "cytoplasm", w: 1.3, need: () => true, draw: drawCytoplasm,
      cap: () => "cytoplasm — mitochondria, ER ribbons, golgi stacks, vesicles" },
    { key: "nucleus", label: "nucleus", w: 0.9, need: () => true, draw: drawNucleus,
      cap: () => "nuclear envelope — threading a nuclear pore" },
    { key: "chromatin", label: "chromatin", w: 1.0, need: () => true, draw: drawChromatin,
      cap: () => "chromatin strands condensing into a chromosome" },
    { key: "dna", label: "DNA", w: 1.3, need: () => true,
      draw: (gc, w2, h2, u, a, clk) => drawHelix(gc, w2, h2, u, a, clk, null),
      cap: () => hasFinale()
        ? "the double helix — base rungs A·T·G·C (illustrative pattern)"
        : "the double helix — select a gene or protein node to ground the finale" },
    { key: "gene", label: "gene", w: 0.9, need: () => !!jctx.gene,
      draw: (gc, w2, h2, u, a, clk) => drawHelix(gc, w2, h2, u, a, clk, scene.geneSpan),
      cap: () => `gene ${jctx.gene} — real node id from this mind's graph` },
    { key: "protein", label: "protein", w: 1.2, draw: drawProtein,
      need: () => !!(jctx.residues && scene && scene.backbone),
      cap: () => `protein ${jctx.protein || "(unnamed)"} — backbone generated ` +
                 `from its ${jctx.residues.length}-residue stored sequence` },
  ];

  // Missing context drops the gene/protein windows: the movie then ends on
  // the DNA scene, whose caption invites a node selection.
  function rebuildPlan() {
    const act = SCENES.filter(sc => sc.need());
    const total = act.reduce((sum, sc) => sum + sc.w, 0);
    let acc = 0;
    plan = act.map(sc => {
      const t0 = acc / total; acc += sc.w;
      return { ...sc, t0, t1: acc / total };
    });
  }

  // Opacity ramps overlap neighbor scenes so cuts feel filmed, not switched.
  function alphaOf(wp, i) {
    const fin  = i === 0 ? 1 : ramp(t, wp.t0 - FADE, wp.t0 + FADE);
    const fout = i === plan.length - 1 ? 1 : 1 - ramp(t, wp.t1 - FADE, wp.t1 + FADE);
    return fin * fout;
  }
  const localU = wp => (t - wp.t0) / (wp.t1 - wp.t0);

  /* --------------------------- scene: approach ------------------------ */

  function drawApproach(gc, w, h, u, a, clk) {
    const e = easeC(clamp01(u)), m = Math.min(w, h);
    // parallax dust specks
    gc.fillStyle = "#9ecbff"; gc.shadowBlur = 0;
    for (const d of scene.dust) {
      gc.globalAlpha = clamp01(a * 0.10 * d.z);
      gc.fillRect(d.x * w, ((d.y + clk * 0.004 * d.z) % 1) * h,
                  1.6 * d.z + 0.4, 1.6 * d.z + 0.4);
    }
    // drifting neighbor cells — deeper cells zoom slower (depth parallax)
    for (const c of scene.cells) {
      const zk = 1 + e * 2.0 * c.z;
      const px = w / 2 + (c.x - 0.5 + Math.sin(clk * 0.05 + c.z * 7) * 0.02) * w * zk;
      const py = h / 2 + (c.y - 0.5 + Math.cos(clk * 0.04 + c.z * 5) * 0.02) * h * zk;
      const r = c.r * m * zk;
      gc.globalAlpha = clamp01(a * 0.35 * c.z); gc.lineWidth = 1.5;
      gc.strokeStyle = "#39c5cf"; gc.shadowColor = "#39c5cf"; gc.shadowBlur = 10;
      gc.beginPath(); gc.ellipse(px, py, r, r * 0.82, c.z, 0, 7); gc.stroke();
      gc.globalAlpha = clamp01(a * 0.18 * c.z);
      gc.fillStyle = "#b083f0"; gc.shadowBlur = 0;
      gc.beginPath(); gc.arc(px + r * 0.15, py, r * 0.3, 0, 7); gc.fill();
    }
    // the hero cell — slow dolly until its membrane fills the frame
    const R = lerp(m * 0.14, m * 1.45, e);
    gc.globalAlpha = clamp01(a * 0.9); gc.lineWidth = lerp(2, 7, e);
    gc.strokeStyle = "#3ce6ff"; gc.shadowColor = "#3ce6ff"; gc.shadowBlur = 24;
    gc.beginPath(); gc.ellipse(w / 2, h / 2, R, R * 0.94, 0.1, 0, 7); gc.stroke();
    gc.globalAlpha = clamp01(a * 0.06); gc.fillStyle = "#3ce6ff"; gc.shadowBlur = 0;
    gc.beginPath(); gc.ellipse(w / 2, h / 2, R, R * 0.94, 0.1, 0, 7); gc.fill();
  }

  /* --------------------------- scene: membrane ------------------------ */

  function drawMembrane(gc, w, h, u, a, clk) {
    const e = easeC(clamp01(u));
    const gap = lerp(24, h * 1.5, e);             // leaflets part as we pass
    for (const sign of [-1, 1]) {                 // top / bottom leaflet
      const rowY = h / 2 + sign * gap / 2;
      for (let i = 0, x = -10; x < w + 10; x += 20, i++) {
        const ph = scene.lipids[i % scene.lipids.length];
        const y = rowY + Math.sin(clk * 1.6 + ph) * 2.5;
        // twin tails point INTO the bilayer (toward the parting seam)
        gc.strokeStyle = "#2e5d66"; gc.globalAlpha = clamp01(a * 0.8);
        gc.lineWidth = 2; gc.shadowBlur = 0;
        gc.beginPath(); gc.moveTo(x, y);
        gc.quadraticCurveTo(x + 3, y - sign * 9, x - 2, y - sign * 17); gc.stroke();
        gc.beginPath(); gc.moveTo(x + 6, y);
        gc.quadraticCurveTo(x + 9, y - sign * 9, x + 8, y - sign * 17); gc.stroke();
        // glowing head bead on the outside of the leaflet
        gc.fillStyle = "#39c5cf"; gc.shadowColor = "#39c5cf"; gc.shadowBlur = 9;
        gc.globalAlpha = clamp01(a * 0.9);
        gc.beginPath(); gc.arc(x + 3, y + sign * 3, 5, 0, 7); gc.fill();
      }
    }
    // speed streaks through the open seam once we're passing through
    gc.shadowBlur = 0;
    if (e > 0.25) {
      gc.strokeStyle = "#9ecbff"; gc.lineWidth = 1;
      gc.globalAlpha = clamp01(a * 0.35 * (e - 0.25));
      for (let k = 0; k < 14; k++) {
        const ph = scene.lipids[(k * 5) % scene.lipids.length];
        const x = (((ph / 6.3) + clk * 0.05 * (1 + k % 3)) % 1) * w;
        const len = 12 + (k % 4) * 8;
        gc.beginPath(); gc.moveTo(x, h / 2 - len); gc.lineTo(x, h / 2 + len); gc.stroke();
      }
    }
  }

  /* --------------------------- scene: cytoplasm -----------------------
     Flythrough: organelles at depth z scale 1/(z-camZ) as the camera
     advances — hand-rolled parallax, molecule.js school.                 */

  function drawCytoplasm(gc, w, h, u, a, clk) {
    const camZ = easeC(clamp01(u)) * 1.45;
    const proj = o => {
      const d = o.z - camZ;
      if (d < 0.12) return null;                  // passed behind the camera
      const s = 1 / d;
      return { x: w / 2 + (o.x - 0.5) * w * s, y: h / 2 + (o.y - 0.5) * h * s,
               s, fade: clamp01((d - 0.12) * 3) * clamp01((2.6 - d) * 1.2) };
    };
    // ER ribbons (green)
    for (const o of scene.er) {
      const p = proj(o); if (!p) continue;
      gc.strokeStyle = "#4cc38a"; gc.shadowColor = "#4cc38a"; gc.shadowBlur = 8;
      gc.lineWidth = Math.min(6, 2.2 * p.s);
      gc.globalAlpha = clamp01(a * 0.5 * p.fade);
      for (let rib = 0; rib < 3; rib++) {
        gc.beginPath();
        for (let k = 0; k <= 22; k++) {
          const x = p.x + (k - 11) * 9 * p.s,
                y = p.y + rib * 12 * p.s +
                    Math.sin(k * 0.6 + clk * 0.9 + o.p + rib) * 7 * p.s;
          k ? gc.lineTo(x, y) : gc.moveTo(x, y);
        }
        gc.stroke();
      }
    }
    // golgi stacks (amber nested arcs)
    for (const o of scene.golgi) {
      const p = proj(o); if (!p) continue;
      gc.strokeStyle = "#f5a623"; gc.shadowColor = "#f5a623"; gc.shadowBlur = 8;
      gc.globalAlpha = clamp01(a * 0.6 * p.fade);
      gc.lineWidth = Math.min(7, 3 * p.s);
      for (let k = 0; k < 4; k++) {
        gc.beginPath();
        gc.ellipse(p.x, p.y + k * 8 * p.s, (30 - k * 4) * p.s, 6 * p.s, 0, 0, 7);
        gc.stroke();
      }
    }
    // mitochondria (red lozenges with a cristae squiggle)
    for (const o of scene.mito) {
      const p = proj(o); if (!p) continue;
      gc.save(); gc.translate(p.x, p.y);
      gc.rotate(o.a + Math.sin(clk * 0.5 + o.z) * 0.1);
      gc.fillStyle = "#e5534b"; gc.shadowColor = "#e5534b"; gc.shadowBlur = 12;
      gc.globalAlpha = clamp01(a * 0.55 * p.fade);
      gc.beginPath(); gc.ellipse(0, 0, 30 * p.s, 13 * p.s, 0, 0, 7); gc.fill();
      gc.strokeStyle = "#ffb3ad"; gc.lineWidth = Math.min(3, 1.3 * p.s);
      gc.shadowBlur = 0; gc.globalAlpha = clamp01(a * 0.5 * p.fade);
      gc.beginPath();
      for (let k = 0; k <= 16; k++) {
        const x = (k - 8) * 3.2 * p.s;
        k ? gc.lineTo(x, Math.sin(k * 1.9) * 7 * p.s) : gc.moveTo(x, 0);
      }
      gc.stroke(); gc.restore();
    }
    // vesicles (blue), gently bobbing
    for (const o of scene.ves) {
      const p = proj(o); if (!p) continue;
      gc.fillStyle = "#58a6ff"; gc.shadowColor = "#58a6ff"; gc.shadowBlur = 10;
      gc.globalAlpha = clamp01(a * 0.55 * p.fade);
      gc.beginPath();
      gc.arc(p.x + Math.sin(clk * 0.8 + o.r) * 4, p.y, o.r * p.s * 2.2, 0, 7);
      gc.fill();
    }
  }

  /* --------------------------- scene: nucleus ------------------------- */

  function drawNucleus(gc, w, h, u, a, clk) {
    const e = easeC(clamp01(u)), m = Math.min(w, h);
    const R = lerp(m * 0.42, m * 3.4, e * e);     // envelope swells past frame
    const pa = scene.poreTarget;
    // recenter so the target pore glides to screen center as we thread it
    const cx = w / 2 - Math.cos(pa) * R * e, cy = h / 2 - Math.sin(pa) * R * e;
    // double membrane
    gc.strokeStyle = "#b083f0"; gc.shadowColor = "#b083f0"; gc.shadowBlur = 18;
    for (const [rr, lw, al] of [[R, 5, 0.85], [R * 0.965, 2.5, 0.5]]) {
      gc.globalAlpha = clamp01(a * al); gc.lineWidth = lw;
      gc.beginPath(); gc.arc(cx, cy, rr, 0, 7); gc.stroke();
    }
    // interior tint
    gc.globalAlpha = clamp01(a * 0.07); gc.fillStyle = "#b083f0"; gc.shadowBlur = 0;
    gc.beginPath(); gc.arc(cx, cy, R * 0.96, 0, 7); gc.fill();
    // pores studding the envelope; the target pore opens for the camera
    for (const p of scene.pores) {
      const px = cx + Math.cos(p) * R, py = cy + Math.sin(p) * R;
      const isT = p === scene.poreTarget;
      const pr = isT ? lerp(m * 0.02, m * 0.9, e * e * e) : m * 0.02 * (1 + e);
      gc.globalAlpha = clamp01(a * (isT ? 0.95 : 0.55));
      gc.strokeStyle = "#e6d7ff"; gc.shadowColor = "#e6d7ff";
      gc.shadowBlur = isT ? 20 : 8; gc.lineWidth = isT ? 4 : 2;
      gc.beginPath(); gc.arc(px, py, pr, 0, 7); gc.stroke();
      if (isT && e > 0.55) {                      // darkness inside the pore…
        gc.globalAlpha = clamp01(a * (e - 0.55) * 2);
        gc.fillStyle = "#05070d"; gc.shadowBlur = 0;
        gc.beginPath(); gc.arc(px, py, pr * 0.97, 0, 7); gc.fill();
        // …with faint chromatin glowing on the far side
        gc.globalAlpha = clamp01(a * (e - 0.55) * 0.8);
        gc.strokeStyle = "#e6d7ff"; gc.lineWidth = 1.5; gc.shadowBlur = 6;
        gc.beginPath();
        for (let k = 0; k <= 24; k++) {
          const x = px - pr * 0.5 + k * pr / 24,
                y = py + Math.sin(k * 0.8 + clk) * pr * 0.12;
          k ? gc.lineTo(x, y) : gc.moveTo(x, y);
        }
        gc.stroke();
      }
    }
  }

  /* --------------------------- scene: chromatin ----------------------- */

  function drawChromatin(gc, w, h, u, a, clk) {
    const e = easeC(clamp01(u)), m = Math.min(w, h);
    gc.lineWidth = 2.2; gc.shadowBlur = 10;
    for (let sI = 0; sI < scene.strands.length; sI++) {
      const pts = scene.strands[sI], col = sI % 2 ? "#b083f0" : "#e6d7ff";
      gc.strokeStyle = col; gc.shadowColor = col;
      gc.globalAlpha = clamp01(a * 0.75);
      gc.beginPath();
      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        // breathing wobble that stills as the strands condense
        const wob = Math.sin(clk * 0.8 + i * 0.5 + sI) * 3 * (1 - e);
        const x = lerp(p.tx, p.cx, e) * w + wob;
        const y = lerp(p.ty, p.cy, e) * h + wob * 0.6;
        i ? gc.lineTo(x, y) : gc.moveTo(x, y);
      }
      gc.stroke();
    }
    // centromere pinch glow once the X-shape has formed
    if (e > 0.6) {
      gc.globalAlpha = clamp01(a * (e - 0.6) * 2);
      gc.fillStyle = "#e6d7ff"; gc.shadowColor = "#e6d7ff"; gc.shadowBlur = 22;
      gc.beginPath(); gc.arc(w / 2, h / 2, m * 0.02, 0, 7); gc.fill();
    }
  }

  /* ---------------- scenes: DNA + gene highlight (one renderer) ------- */

  function drawHelix(gc, w, h, u, a, clk, hi) {
    const e = easeC(clamp01(u));
    const pal = basePal();
    const bases = scene.dnaBases, N = bases.length;
    const COMP = { A: "T", T: "A", G: "C", C: "G" };
    const rot = clk * 0.3 + e * 1.4;              // slow twist + gentle dolly
    const R = w * lerp(0.10, 0.17, e);
    const top = h * 0.07, pitch = (h * 0.86) / N;
    for (let i = 0; i < N; i++) {
      const th = rot + i * 0.55, y = top + i * pitch;
      const x1 = w / 2 + Math.cos(th) * R, z1 = Math.sin(th);
      const x2 = w / 2 + Math.cos(th + Math.PI) * R, z2 = -z1;
      const b = bases[i], c2 = COMP[b];
      const hot = hi && i >= hi[0] && i <= hi[1];
      const pulse = hot ? 0.75 + 0.25 * Math.sin(clk * 3) : 1;
      // rung halves colored by base + complement
      gc.lineWidth = hot ? 4.5 : 2.6; gc.shadowBlur = hot ? 14 : 4;
      gc.globalAlpha = clamp01(a * (0.3 + 0.3 * (z1 + 1) / 2) * pulse * (hot ? 1.5 : 1));
      gc.strokeStyle = pal[b]; gc.shadowColor = pal[b];
      gc.beginPath(); gc.moveTo(x1, y); gc.lineTo(w / 2, y); gc.stroke();
      gc.globalAlpha = clamp01(a * (0.3 + 0.3 * (z2 + 1) / 2) * pulse * (hot ? 1.5 : 1));
      gc.strokeStyle = pal[c2]; gc.shadowColor = pal[c2];
      gc.beginPath(); gc.moveTo(w / 2, y); gc.lineTo(x2, y); gc.stroke();
      // sugar-phosphate backbone beads
      for (const [x, z, col] of [[x1, z1, "#9ecbff"], [x2, z2, "#b083f0"]]) {
        gc.globalAlpha = clamp01(a * (0.4 + 0.5 * (z + 1) / 2) * (hot ? 1.2 : 1));
        gc.fillStyle = hot ? "#ffffff" : col;
        gc.shadowColor = hot ? "#ffffff" : col; gc.shadowBlur = hot ? 12 : 8;
        gc.beginPath();
        gc.arc(x, y, (hot ? 5.2 : 4.2) + 1.6 * (z + 1) / 2, 0, 7); gc.fill();
      }
    }
    // accent bracket marking the highlighted gene span
    if (hi) {
      const y0 = top + hi[0] * pitch - 8, y1 = top + hi[1] * pitch + 8;
      const bx = Math.max(10, w / 2 - R - 34);
      gc.strokeStyle = "#f5a623"; gc.shadowColor = "#f5a623"; gc.shadowBlur = 10;
      gc.lineWidth = 2; gc.globalAlpha = clamp01(a * 0.9);
      gc.beginPath(); gc.moveTo(bx + 8, y0); gc.lineTo(bx, y0);
      gc.lineTo(bx, y1); gc.lineTo(bx + 8, y1); gc.stroke();
    }
  }

  /* ------ scene: protein — REAL sequence grows into a glowing trace --- */

  function drawProtein(gc, w, h, u, a, clk) {
    const bb = scene.backbone; if (!bb) return;
    const e = easeC(clamp01(u)), n = bb.pts.length;
    const count = Math.max(2, Math.floor(clamp01(u * 1.12) * n));
    const rotX = 0.35 + Math.sin(clk * 0.07) * 0.1, rotY = 0.7 + clk * 0.12;
    const sx = Math.sin(rotX), cxr = Math.cos(rotX);
    const sy = Math.sin(rotY), cyr = Math.cos(rotY);
    const scale = (Math.min(w, h) / (2.6 * bb.maxR)) * lerp(0.7, 1.05, e);
    let prev = null;
    gc.lineWidth = 2; gc.strokeStyle = "#f5a623"; gc.shadowColor = "#f5a623";
    for (let i = 0; i < count; i++) {
      const p = bb.pts[i];
      const x1 = p.x * cyr + p.z * sy, z1 = -p.x * sy + p.z * cyr;
      const y2 = p.y * cxr - z1 * sx, z2 = p.y * sx + z1 * cxr;
      const persp = 1 / (1 + z2 / (4 * bb.maxR));
      const X = w / 2 + x1 * scale * persp, Y = h / 2 + y2 * scale * persp;
      if (prev) {
        gc.globalAlpha = clamp01(a * (0.8 - 0.4 * (z2 / (bb.maxR * 1.4))));
        gc.shadowBlur = 7;
        gc.beginPath(); gc.moveTo(prev.X, prev.Y); gc.lineTo(X, Y); gc.stroke();
      }
      prev = { X, Y };
    }
    if (prev) {                                   // bright leading residue
      gc.globalAlpha = clamp01(a * (count < n ? 1 : 0.6));
      gc.fillStyle = "#ffe2a8"; gc.shadowColor = "#ffe2a8";
      gc.shadowBlur = 18 + Math.sin(clk * 5) * 6;
      gc.beginPath(); gc.arc(prev.X, prev.Y, count < n ? 4.5 : 3, 0, 7); gc.fill();
    }
  }

  /* ------------------- letterbox, banner and caption ------------------ */

  function drawOverlay(w, h) {
    const bar = Math.max(26, Math.round(h * 0.085));
    g.globalAlpha = 1; g.shadowBlur = 0;
    g.fillStyle = "#000000";
    g.fillRect(0, 0, w, bar); g.fillRect(0, h - bar, w, bar);
    // permanent honesty banner — always on, every frame
    g.fillStyle = "#e8b854"; g.font = "11px " + FONT;
    g.textAlign = "left"; g.textBaseline = "middle";
    g.fillText("🧪 " + BANNER, 12, bar / 2);
    // caption of the dominant waypoint, faded with its scene
    let dom = null, domA = 0, domIx = 0;
    plan.forEach((wp, i) => { const al = alphaOf(wp, i);
      if (al > domA) { domA = al; dom = wp; domIx = i; } });
    if (dom) {
      g.globalAlpha = clamp01(domA);
      g.fillStyle = "#dbe2ea"; g.font = "13px " + FONT; g.textAlign = "center";
      g.fillText(dom.cap(), w / 2, h - bar / 2);
      g.globalAlpha = 0.85; g.fillStyle = "#7d8894";
      g.font = "11px " + FONT; g.textAlign = "right";
      g.fillText(`${domIx + 1}/${plan.length} · ${dom.label}`, w - 12, bar / 2);
    }
    g.globalAlpha = 1; g.textAlign = "left";
    return dom;
  }

  /* ------------------------------ RAF loop ---------------------------- */

  function frame(myRun, stamp) {
    if (myRun !== runId) return;                       // superseded by remount
    if (!document.getElementById("cinema3d")) return;  // canvas left the DOM
    const dt = Math.min(0.1, (stamp - lastStamp) / 1000 || 0);
    lastStamp = stamp; const clk = (stamp - startedAt) / 1000;
    // timeline: animated seek beats normal playback
    if (tweenTo !== null) {
      const k = 1 - Math.exp(-dt * 5);
      t += (tweenTo - t) * k;
      if (Math.abs(tweenTo - t) < 0.0015) { t = tweenTo; tweenTo = null; }
    } else if (playing && !scrubbing) {
      t = Math.min(1, t + dt * SPEEDS[speedIx] / DURATION);
      if (t >= 1) { playing = false; syncPlayBtn(); }  // hold the last frame
    }
    // size the backing store to the stage
    const W = stage.clientWidth, H = stage.clientHeight;
    if (W > 0 && H > 0 && (canvas.width !== W || canvas.height !== H)) {
      canvas.width = W; canvas.height = H;
    }
    if (canvas.width > 0 && canvas.height > 0) {
      const w = canvas.width, h = canvas.height;
      g.globalAlpha = 1; g.shadowBlur = 0;
      g.fillStyle = "#05070d"; g.fillRect(0, 0, w, h);
      plan.forEach((wp, i) => { const al = alphaOf(wp, i);
        if (al > 0.005) wp.draw(g, w, h, localU(wp), al, clk); });
      g.globalAlpha = 1; g.shadowBlur = 0;
      const dom = drawOverlay(w, h);
      if (dom && dom.key !== currentKey) { currentKey = dom.key; syncChips(); }
    }
    if (!scrubbing && ui) ui.scrub.value = String(Math.round(t * 1000));
    requestAnimationFrame(s => frame(myRun, s));
  }

  /* ------------------------------ controls ---------------------------- */

  function buildUI() {
    host.innerHTML = "";
    const wrap = document.createElement("div");
    wrap.style.cssText =
      "display:flex;flex-direction:column;height:100%;min-height:320px;background:#05070d";
    stage = document.createElement("div");
    stage.style.cssText = "flex:1;position:relative;overflow:hidden;min-height:220px";
    canvas = document.createElement("canvas");
    canvas.id = "cinema3d";
    canvas.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block";
    g = canvas.getContext("2d");
    stage.appendChild(canvas);

    const bar = document.createElement("div");
    bar.style.cssText = "display:flex;gap:8px;align-items:center;flex-wrap:wrap;" +
      "padding:7px 10px;border-top:1px solid var(--line);background:var(--panel)";

    const play = document.createElement("button");
    play.className = "btn small"; play.title = "play / pause";
    play.onclick = () => {
      if (t >= 1 && !playing) t = 0;              // replay from the top
      playing = !playing; tweenTo = null; syncPlayBtn();
    };
    const speed = document.createElement("button");
    speed.className = "btn small"; speed.title = "playback speed";
    speed.onclick = () => { speedIx = (speedIx + 1) % SPEEDS.length; syncSpeedBtn(); };

    const scrub = document.createElement("input");
    scrub.type = "range"; scrub.min = "0"; scrub.max = "1000"; scrub.value = "0";
    scrub.title = "scrub the journey";
    scrub.style.cssText = "flex:1;min-width:120px;accent-color:var(--accent)";
    scrub.onpointerdown = () => { scrubbing = true; };
    scrub.onpointerup = () => { scrubbing = false; };
    scrub.oninput = () => { tweenTo = null; t = Number(scrub.value) / 1000; };
    scrub.onchange = () => { scrubbing = false; };

    const chipBox = document.createElement("span");
    chipBox.style.cssText = "display:flex;flex-wrap:wrap;gap:2px";

    bar.append(play, speed, scrub, chipBox);
    wrap.append(stage, bar);
    host.appendChild(wrap);
    ui = { play, speed, scrub, chipBox, chips: [] };
    syncPlayBtn(); syncSpeedBtn(); rebuildChips();
  }

  function rebuildChips() {
    if (!ui) return;
    ui.chipBox.innerHTML = ""; ui.chips = [];
    for (const wp of plan) {
      const c = document.createElement("button");
      c.className = "chip"; c.textContent = wp.label; c.dataset.key = wp.key;
      c.style.cssText = "font:inherit;color:var(--ink)";
      c.onclick = () => { tweenTo = Math.min(0.999, wp.t0 + 0.001); };
      ui.chipBox.appendChild(c); ui.chips.push(c);
    }
    syncChips();
  }
  function syncChips() {
    if (!ui) return;
    for (const c of ui.chips) c.classList.toggle("on", c.dataset.key === currentKey);
  }
  function syncPlayBtn()  { if (ui) ui.play.textContent = playing ? "⏸" : "▶"; }
  function syncSpeedBtn() { if (ui) ui.speed.textContent = SPEEDS[speedIx] + "×"; }

  /* ---------------------------- public API ---------------------------- */

  function normCtx(c) {
    c = c || {};
    const str = v => (typeof v === "string" && v.length) ? v : null;
    return { gene: str(c.gene), protein: str(c.protein), residues: str(c.residues) };
  }

  function mount(containerEl, context) {
    if (!containerEl) return;
    unmount();                                    // idempotent remount
    host = containerEl;
    jctx = normCtx(context);
    buildScenery(); rebuildPlan();
    t = 0; tweenTo = null; playing = true; speedIx = 1; currentKey = "";
    buildUI();
    startedAt = performance.now(); lastStamp = startedAt;
    const myRun = ++runId; requestAnimationFrame(s => frame(myRun, s));
  }

  function unmount() {
    runId++;                                      // strands any live RAF loop
    if (host) host.innerHTML = "";
    host = stage = canvas = g = ui = null; plan = []; scene = null;
  }

  // Re-ground the journey without remounting; timeline position preserved.
  function setContext(context) {
    jctx = normCtx(context);
    buildScenery(); rebuildPlan(); rebuildChips();
    if (t > 1) t = 1;
  }

  const isMounted = () => !!host && !!document.getElementById("cinema3d");

  return { mount, unmount, setContext, isMounted };
})();
