"use strict";
/* mri.js — MRI volume stage for the symbolic-biology dashboard.

   What this is: an in-browser NIfTI-1 (.nii, uncompressed) reader plus a
   seeded synthetic demo phantom, shown as three orthogonal slice panels
   and one hand-rolled maximum-intensity-projection (MIP) 3D view — a 2D
   canvas ray march in the molecule.js hologram style (no WebGL, no
   libraries). A percentile slider marks bright voxels with a warm overlay
   and reports them ONLY as image features. Clinical meaning is out of
   scope by design: the "ask the gate" button hands a prompt string to
   MRIStage.onResearch (wired elsewhere to the research lane, which
   answers with receipts). This module never states causes.

   Determinism: every random draw goes through conceptRng (conceptviz.js,
   loaded before this file). No built-in RNG anywhere.

   Public API:
     MRIStage.mount(containerEl)  — build the stage inside containerEl
     MRIStage.unmount()           — stop loops, empty the container
     MRIStage.onResearch = fn     — optional callback(promptString)      */

/* Permanent stage banner — verbatim, always visible while mounted. */
const MRI_BANNER =
  "RESEARCH VISUALIZATION — not a medical device, not diagnostic. " +
  "Bright-region overlays are image features, never findings. Clinical " +
  "meaning must come through the research gate with receipts.";

/* Verbatim label carried by the generated phantom wherever it shows. */
const MRI_DEMO_LABEL =
  "SYNTHETIC DEMO VOLUME — generated for demonstration, not a real scan.";

const MRIStage = (function () {

  /* ---------------- module state ---------------- */

  let root = null;          // container element while mounted
  let ui = null;            // data-r → element cache
  let vol = null;           // { data:Float32Array, nx, ny, nz }
  let hist = null;          // { counts, lo, w, B, n } for percentile lookups
  let win = { lo: 0, hi: 1 };   // robust display window (p0.5 .. p99.5)
  let thrPct = 98.0;        // percentile slider position
  let thrVal = Infinity;    // absolute intensity at that percentile
  let feature = null;       // { count, cx, cy, cz, octant } above threshold
  let slice = { ax: 0, co: 0, sa: 0 };   // current slice indices (z, y, x)
  let mip = null;           // ≤64³ max-pooled copy for the 3D view
  let view = { rx: 0.5, ry: 0.6, zoom: 1, drag: false, lx: 0, ly: 0, spin: true };
  let gen = 0;              // generation token — bumping retires old RAF loops
  let onWinMouseUp = null;  // window listener we must detach on unmount
  let featurePending = false;

  const MIP_OUT = 112;      // ray-march output grid, upscaled onto the canvas
  const escHtml = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const fmtV = v => Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(1);

  const stage = { mount, unmount, onResearch: null };

  /* ---------------- mount / unmount ---------------- */

  function mount(container) {
    unmount();                       // idempotent — never double-mount
    root = container;
    root.innerHTML = template();
    ui = {};
    root.querySelectorAll("[data-r]").forEach(el => { ui[el.dataset.r] = el; });
    wire();
  }

  function unmount() {
    gen++;                           // retires any live RAF loop immediately
    if (onWinMouseUp) { window.removeEventListener("mouseup", onWinMouseUp); onWinMouseUp = null; }
    if (root) root.innerHTML = "";
    root = null; ui = null; vol = null; hist = null; mip = null; feature = null;
  }

  /* ---------------- markup ---------------- */

  function template() {
    return `
<div class="mri-stage">
  <style>
    .mri-stage .mri-banner { border:1px solid #b8862c; background:rgba(184,134,44,.12);
      color:#e8b854; border-radius:6px; padding:7px 10px; margin:6px 0;
      font-size:12px; font-weight:700; }
    .mri-stage .mri-row { display:flex; gap:8px; align-items:center;
      flex-wrap:wrap; margin:8px 0; }
    .mri-stage .mri-grid { display:grid; gap:10px; margin-top:8px;
      grid-template-columns:repeat(auto-fit, minmax(240px, 1fr)); }
    .mri-stage .mri-panel { background:var(--panel); border:1px solid var(--line);
      border-radius:8px; padding:8px; }
    .mri-stage .mri-panel h3 { font-size:11px; text-transform:uppercase;
      letter-spacing:.08em; color:var(--dim); margin:0 0 6px; }
    /* height:auto overrides the dashboard's global canvas{height:100%} */
    .mri-stage canvas { display:block; width:100%; height:auto;
      background:#05070d; border:1px solid var(--line); border-radius:6px; }
    .mri-stage .mri-slice { image-rendering:pixelated; }
    .mri-stage input[type=range] { width:100%; accent-color:var(--accent); }
    .mri-stage .mri-err { border:1px solid var(--bad); color:var(--bad);
      border-radius:6px; padding:6px 10px; margin:6px 0; font-size:12px; display:none; }
    .mri-stage .mri-summary { background:var(--panel); border:1px solid var(--line);
      border-left:3px solid #ff9b3c; border-radius:8px; padding:8px 10px;
      margin-top:10px; font-size:13px; }
    .mri-stage .mri-prompt { border:1px dashed var(--line); border-radius:6px;
      padding:6px 10px; margin-top:6px; font-size:12px; color:var(--dim);
      display:none; word-break:break-word; }
  </style>
  <div class="mri-banner">${MRI_BANNER}</div>
  <div class="mri-row">
    <label class="btn" style="cursor:pointer">load .nii file
      <input type="file" accept=".nii" data-r="file" style="display:none"></label>
    <button class="btn" data-r="demo">load synthetic demo volume</button>
    <span class="sub" data-r="status"></span>
  </div>
  <div class="mri-err" data-r="err"></div>
  <div class="sub" data-r="src"></div>
  <div data-r="views" style="display:none">
    <div class="mri-grid">
      <div class="mri-panel"><h3>axial · <span data-r="axn"></span></h3>
        <canvas data-r="axc" class="mri-slice" width="8" height="8"></canvas>
        <input type="range" data-r="axs" min="0" max="0" value="0"></div>
      <div class="mri-panel"><h3>coronal · <span data-r="con"></span></h3>
        <canvas data-r="coc" class="mri-slice" width="8" height="8"></canvas>
        <input type="range" data-r="cos" min="0" max="0" value="0"></div>
      <div class="mri-panel"><h3>sagittal · <span data-r="san"></span></h3>
        <canvas data-r="sac" class="mri-slice" width="8" height="8"></canvas>
        <input type="range" data-r="sas" min="0" max="0" value="0"></div>
      <div class="mri-panel"><h3>3D maximum-intensity projection</h3>
        <canvas data-r="mipc" width="340" height="340" style="cursor:grab"></canvas>
        <div class="sub" style="margin-top:6px">drag to rotate · wheel to zoom ·
          max-pooled ≤64³ grid, parallel-ray march</div></div>
    </div>
    <div class="mri-row" style="margin-top:10px">
      <span class="sub" style="white-space:nowrap">bright-region percentile</span>
      <input type="range" data-r="thr" min="90" max="99.9" step="0.1" value="98"
        style="flex:1; min-width:140px">
      <b data-r="thrlab" style="color:#ff9b3c">p98.0</b>
    </div>
    <div class="mri-summary" data-r="sum"></div>
    <div class="sub" data-r="axes" style="margin-top:6px"></div>
    <div class="mri-row">
      <button class="btn" data-r="gate">ask the gate about this feature</button>
    </div>
    <div class="mri-prompt" data-r="prompt"></div>
  </div>
</div>`;
  }

  /* ---------------- event wiring ---------------- */

  function wire() {
    ui.file.onchange = loadFile;
    ui.demo.onclick = loadDemo;
    ui.axs.oninput = () => { slice.ax = +ui.axs.value; drawSlices(); };
    ui.cos.oninput = () => { slice.co = +ui.cos.value; drawSlices(); };
    ui.sas.oninput = () => { slice.sa = +ui.sas.value; drawSlices(); };
    ui.thr.oninput = () => {
      thrPct = parseFloat(ui.thr.value);
      ui.thrlab.textContent = "p" + thrPct.toFixed(1);
      if (!vol) return;
      thrVal = pctValue(thrPct);
      scheduleFeature();
    };
    ui.gate.onclick = askGate;
    const c = ui.mipc;                 // molecule.js interaction pattern
    c.onmousedown = e => { view.drag = true; view.spin = false;
      view.lx = e.offsetX; view.ly = e.offsetY; c.style.cursor = "grabbing"; };
    c.onmousemove = e => {
      if (!view.drag) return;
      view.ry += (e.offsetX - view.lx) * 0.01;
      view.rx += (e.offsetY - view.ly) * 0.01;
      view.lx = e.offsetX; view.ly = e.offsetY;
    };
    c.onwheel = e => { e.preventDefault();
      view.zoom = Math.min(5, Math.max(0.4, view.zoom * (e.deltaY < 0 ? 1.1 : 0.9))); };
    onWinMouseUp = () => { view.drag = false; if (ui) ui.mipc.style.cursor = "grab"; };
    window.addEventListener("mouseup", onWinMouseUp);
  }

  function setStatus(t) { if (ui) ui.status.textContent = t; }
  function showError(t) { if (ui) { ui.err.style.display = ""; ui.err.textContent = t; } }
  function hideError() { if (ui) { ui.err.style.display = "none"; ui.err.textContent = ""; } }

  /* ---------------- loading: real file ---------------- */

  async function loadFile(ev) {
    const f = ev.target.files && ev.target.files[0];
    if (!f) return;
    hideError();
    setStatus(`reading ${f.name} (${(f.size / 1048576).toFixed(1)} MB) …`);
    // Generation ticket: the await below yields to the event loop, and the
    // stage can unmount — or another volume can land — before the bytes
    // arrive. gen bumps on both unmount() and setVolume(), so a stale
    // continuation must bail BEFORE touching module state; otherwise it
    // would repin a possibly-huge parsed volume (512³ float32 ≈ 537 MB)
    // behind a dead UI, then throw on the nulled element cache.
    const myGen = gen;
    try {
      const buf = await f.arrayBuffer();
      if (myGen !== gen || !ui) return;  // unmounted or superseded mid-read:
      // drop silently — the stage is gone, or a newer load owns the UI now.
      const p = parseNifti(buf);
      setVolume(p, `loaded from local file <b>${escHtml(f.name)}</b> — NIfTI-1, ` +
        `${p.typeName}, ${p.nx}×${p.ny}×${p.nz} voxels` +
        (p.note ? ` · ${escHtml(p.note)}` : ""));
    } catch (e) {
      showError(String((e && e.message) || e));
      setStatus("");
    }
    ev.target.value = "";              // allow re-loading the same file
  }

  const NIFTI_TYPES = { 2: "uint8", 4: "int16", 16: "float32" };
  const NIFTI_KNOWN = { 1: "binary", 8: "int32", 32: "complex64", 64: "float64",
    128: "rgb24", 256: "int8", 512: "uint16", 768: "uint32", 1024: "int64",
    1280: "uint64", 1536: "float128", 1792: "complex128" };

  /* Parse an uncompressed single-file NIfTI-1 buffer. Throws honest,
     specific Errors naming exactly what was unsupported. */
  function parseNifti(buf) {
    if (buf.byteLength >= 2) {
      const m = new Uint8Array(buf, 0, 2);
      if (m[0] === 0x1f && m[1] === 0x8b)
        throw new Error("this file is gzip-compressed (.nii.gz) — decompress " +
          "to plain .nii first; this parser reads uncompressed NIfTI-1 only");
    }
    if (buf.byteLength < 352)
      throw new Error(`file is ${buf.byteLength} bytes — too small for a ` +
        "NIfTI-1 header (348 bytes + magic)");
    const dv = new DataView(buf);
    // magic "n+1\0" (single-file) or "ni1\0" (hdr/img pair) at byte 344
    const m0 = dv.getUint8(344), m1 = dv.getUint8(345),
          m2 = dv.getUint8(346), m3 = dv.getUint8(347);
    if (!(m0 === 0x6e && (m1 === 0x2b || m1 === 0x69) && m2 === 0x31 && m3 === 0))
      throw new Error('magic bytes at offset 344 are not "n+1\\0" or "ni1\\0" ' +
        "— this is not a NIfTI-1 file");
    // Endianness probe: dim[0] (int16 at 40) must land in 1..7. If it does
    // not, the file was written on the other byte order — flip and re-read
    // every header field with the flipped order.
    let le = true;
    let ndim = dv.getInt16(40, le);
    if (ndim < 1 || ndim > 7) { le = false; ndim = dv.getInt16(40, le); }
    if (ndim < 1 || ndim > 7)
      throw new Error("dim[0] is out of range 1..7 in both byte orders — corrupt or unsupported header");
    const dim = [];
    for (let i = 0; i < 8; i++) dim.push(dv.getInt16(40 + 2 * i, le));
    const nx = Math.max(1, dim[1]);
    const ny = ndim >= 2 ? Math.max(1, dim[2]) : 1;
    const nz = ndim >= 3 ? Math.max(1, dim[3]) : 1;
    const dtype = dv.getInt16(70, le);
    const typeName = NIFTI_TYPES[dtype];
    if (!typeName)
      throw new Error(`unsupported NIfTI datatype code ${dtype}` +
        (NIFTI_KNOWN[dtype] ? ` (${NIFTI_KNOWN[dtype]})` : "") +
        " — this viewer reads uint8 (2), int16 (4) and float32 (16) only");
    let off = Math.round(dv.getFloat32(108, le));   // vox_offset
    if (off < 352) off = 352;
    const n = nx * ny * nz;
    const bytesPer = dtype === 2 ? 1 : dtype === 4 ? 2 : 4;
    if (off + n * bytesPer > buf.byteLength)
      throw new Error(`voxel block truncated: need ${n * bytesPer} bytes at ` +
        `offset ${off}, file only has ${buf.byteLength - off} after the header`);
    // scl_slope / scl_inter (floats at 112/116): the header's linear rescale
    let slope = dv.getFloat32(112, le), inter = dv.getFloat32(116, le);
    if (!isFinite(slope) || slope === 0) { slope = 1; inter = 0; }
    if (!isFinite(inter)) inter = 0;
    const data = new Float32Array(n);
    if (dtype === 2) {
      const u8 = new Uint8Array(buf, off, n);        // bytes are endian-free
      for (let i = 0; i < n; i++) data[i] = u8[i] * slope + inter;
    } else if (dtype === 4) {
      for (let i = 0; i < n; i++) data[i] = dv.getInt16(off + 2 * i, le) * slope + inter;
    } else {
      for (let i = 0; i < n; i++) data[i] = dv.getFloat32(off + 4 * i, le) * slope + inter;
    }
    let note = le ? "" : "big-endian file (byte-swapped on read)";
    if (ndim > 3 && dim[4] > 1)
      note += (note ? " · " : "") + `4D file with ${dim[4]} volumes — showing volume 1 only`;
    return { data, nx, ny, nz, typeName, note };
  }

  /* ---------------- loading: synthetic demo phantom ---------------- */

  /* g³ lattice of seeded uniforms, trilinearly interpolated → a smooth,
     fully deterministic noise field over [0,1]³. */
  function latticeNoise(rng, g) {
    const l = new Float32Array(g * g * g);
    for (let i = 0; i < l.length; i++) l[i] = rng();
    const lerp = (a, b, t) => a + (b - a) * t;
    return (u, v, w) => {
      const x = Math.min(g - 1.001, Math.max(0, u * (g - 1)));
      const y = Math.min(g - 1.001, Math.max(0, v * (g - 1)));
      const z = Math.min(g - 1.001, Math.max(0, w * (g - 1)));
      const x0 = x | 0, y0 = y | 0, z0 = z | 0;
      const fx = x - x0, fy = y - y0, fz = z - z0;
      const at = (a, b, c) => l[a + g * (b + g * c)];
      const c00 = lerp(at(x0, y0, z0),     at(x0 + 1, y0, z0),     fx);
      const c10 = lerp(at(x0, y0 + 1, z0), at(x0 + 1, y0 + 1, z0), fx);
      const c01 = lerp(at(x0, y0, z0 + 1),     at(x0 + 1, y0, z0 + 1),     fx);
      const c11 = lerp(at(x0, y0 + 1, z0 + 1), at(x0 + 1, y0 + 1, z0 + 1), fx);
      return lerp(lerp(c00, c10, fy), lerp(c01, c11, fy), fz);
    };
  }

  /* Head-like phantom: bright ellipsoidal shell, smooth-noise interior,
     two darker ventricle-ish lobes, ONE bright blob at a seeded off-center
     spot. Same seed → same phantom, every load, every machine. */
  function makePhantom() {
    const nx = 96, ny = 112, nz = 96;            // longer front-to-back
    const rng = conceptRng("mri-stage-demo-phantom-v1");
    const coarse = latticeNoise(rng, 7);         // slow tissue texture
    const fine = latticeNoise(rng, 17);          // finer grain
    // one bright blob: seeded direction + distance, in ellipsoid coords
    const th = rng() * Math.PI * 2, ph = Math.acos(2 * rng() - 1);
    const rf = 0.30 + rng() * 0.28;              // 30–58% out from center
    const bu = rf * Math.sin(ph) * Math.cos(th);
    const bv = rf * Math.sin(ph) * Math.sin(th);
    const bw = rf * Math.cos(ph) * 0.7;          // keep clear of the poles
    const blobR = 0.085 + rng() * 0.02;          // ≈7–10 voxel radius
    const cx = nx / 2, cy = ny / 2, cz = nz / 2;
    const rx = nx * 0.42, ry = ny * 0.44, rz = nz * 0.42;
    const LOBES = [-1, 1];
    const data = new Float32Array(nx * ny * nz);
    let i = 0;
    for (let z = 0; z < nz; z++)
      for (let y = 0; y < ny; y++)
        for (let x = 0; x < nx; x++, i++) {
          const ux = (x - cx) / rx, uy = (y - cy) / ry, uz = (z - cz) / rz;
          const r = Math.sqrt(ux * ux + uy * uy + uz * uz);
          const fn = fine(x / nx, y / ny, z / nz);
          let v;
          if (r > 1.0) v = 2 + fn * 5;                       // air
          else if (r > 0.94)   // shell > interior; radial, noise-free profile:
            // symmetric by construction, so the above-threshold rim pulls the
            // centroid nowhere — the seeded blob alone decides the octant words
            v = 148 + 14 * (1 - Math.abs(r - 0.97) / 0.03);
          else {
            v = 108 + (coarse(x / nx, y / ny, z / nz) - 0.5) * 34 + (fn - 0.5) * 12;
            for (const s of LOBES) {                          // darker lobes
              const dx = (ux - s * 0.16) / 0.13;
              const dy = (uy + 0.04) / 0.34;
              const dz = (uz - 0.06) / 0.15;
              const d = Math.sqrt(dx * dx + dy * dy + dz * dz);
              if (d < 1.25) {
                const m = Math.min(1, (1.25 - d) / 0.5);      // soft edge
                v = v * (1 - m) + (42 + fn * 8) * m;
              }
            }
            const gx = (ux - bu) / blobR, gy = (uy - bv) / blobR, gz = (uz - bw) / blobR;
            v += 175 * Math.exp(-(gx * gx + gy * gy + gz * gz) * 0.5);
          }
          data[i] = v;
        }
    return { data, nx, ny, nz };
  }

  function loadDemo() {
    hideError();
    setStatus("generating seeded phantom …");
    // let the status line paint before ~1M voxels of synthesis block the thread
    setTimeout(() => {
      if (!root) return;
      const v = makePhantom();
      setVolume(v, `<b style="color:#e8b854">${MRI_DEMO_LABEL}</b> — ` +
        `${v.nx}×${v.ny}×${v.nz} voxels, seeded via conceptRng (same every load)`);
    }, 30);
  }

  /* ---------------- volume install ---------------- */

  function setVolume(v, sourceHtml) {
    // Hard gate: never install a volume into an unmounted stage. Async
    // callers carry their own generation tickets (loadFile); this guard is
    // the mechanical backstop for every caller, present and future — it
    // runs before ANY module-state mutation, so nothing gets pinned.
    if (!ui) return;
    gen++;                             // retire the previous MIP loop, if any
    vol = { data: v.data, nx: v.nx, ny: v.ny, nz: v.nz };
    buildHistogram();
    win = displayWindow();
    thrPct = parseFloat(ui.thr.value);
    thrVal = pctValue(thrPct);
    slice = { ax: v.nz >> 1, co: v.ny >> 1, sa: v.nx >> 1 };
    mip = buildMip(vol);
    ui.src.innerHTML = sourceHtml;
    ui.views.style.display = "";
    ui.prompt.style.display = "none";
    setStatus("");
    ui.axs.max = v.nz - 1; ui.axs.value = slice.ax;
    ui.cos.max = v.ny - 1; ui.cos.value = slice.co;
    ui.sas.max = v.nx - 1; ui.sas.value = slice.sa;
    ui.axc.width = v.nx; ui.axc.height = v.ny;    // axial: x across, y down
    ui.coc.width = v.nx; ui.coc.height = v.nz;    // coronal: x across, z down
    ui.sac.width = v.ny; ui.sac.height = v.nz;    // sagittal: y across, z down
    computeFeature();
    drawSlices();
    startMipLoop();
  }

  /* ---------------- histogram / percentiles ---------------- */

  function buildHistogram() {
    const d = vol.data;
    let lo = Infinity, hi = -Infinity;
    for (let i = 0; i < d.length; i++) {
      const v = d[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (!(hi > lo)) hi = lo + 1;                  // constant-volume guard
    const B = 4096, counts = new Uint32Array(B), w = (hi - lo) / B;
    for (let i = 0; i < d.length; i++) {
      let b = ((d[i] - lo) / w) | 0;
      if (b >= B) b = B - 1;
      counts[b]++;
    }
    hist = { counts, lo, w, B, n: d.length };
  }

  /* Histogram-approximated percentile → absolute intensity. The exact voxel
     count at that intensity is then computed over the full-res volume. */
  function pctValue(p) {
    const target = (p / 100) * hist.n;
    let cum = 0;
    for (let b = 0; b < hist.B; b++) {
      cum += hist.counts[b];
      if (cum >= target) return hist.lo + (b + 0.5) * hist.w;
    }
    return hist.lo + hist.B * hist.w;
  }

  function displayWindow() {
    const lo = pctValue(0.5), hi = pctValue(99.5);   // robust contrast window
    return hi > lo ? { lo, hi } : { lo: hist.lo, hi: hist.lo + hist.B * hist.w };
  }

  /* ---------------- bright-region feature ---------------- */

  function scheduleFeature() {   // at most one full-res pass per frame
    if (featurePending) return;
    featurePending = true;
    requestAnimationFrame(() => {
      featurePending = false;
      if (!vol || !root) return;
      computeFeature();
      drawSlices();              // threshold changed → repaint overlays
    });
  }

  function computeFeature() {
    const d = vol.data, nx = vol.nx, ny = vol.ny, nz = vol.nz, t = thrVal;
    let count = 0, sx = 0, sy = 0, sz = 0, i = 0;
    for (let z = 0; z < nz; z++)
      for (let y = 0; y < ny; y++)
        for (let x = 0; x < nx; x++, i++)
          if (d[i] >= t) { count++; sx += x; sy += y; sz += z; }
    if (!count) { feature = null; renderSummary(); return; }
    const cx = sx / count, cy = sy / count, cz = sz / count;
    // octant words from centroid vs volume center — image-space, approximate
    const octant = [
      cx > nx / 2 ? "right" : "left",
      cy > ny / 2 ? "anterior" : "posterior",
      cz > nz / 2 ? "superior" : "inferior",
    ].join(", ");
    feature = { count, cx, cy, cz, octant };
    renderSummary();
  }

  function renderSummary() {
    ui.thrlab.textContent = "p" + thrPct.toFixed(1);
    if (!feature) {
      ui.sum.innerHTML = "bright-region image feature (hyperintensity " +
        `candidate): <b>0 voxels</b> at or above p${thrPct.toFixed(1)} ` +
        `(intensity ≥ ${fmtV(thrVal)}) — nothing to report at this threshold`;
      ui.gate.disabled = true;
    } else {
      ui.sum.innerHTML = "bright-region image feature (hyperintensity " +
        `candidate): <b>${feature.count.toLocaleString()} voxels</b> ≥ ` +
        `p${thrPct.toFixed(1)} (intensity ≥ ${fmtV(thrVal)}) · centroid ` +
        `(${feature.cx.toFixed(1)}, ${feature.cy.toFixed(1)}, ` +
        `${feature.cz.toFixed(1)}) vox · approximate octant: <b>${feature.octant}</b>`;
      ui.gate.disabled = false;
    }
    ui.axes.textContent = "octant words assume RAS-like voxel order " +
      "(x→right, y→anterior, z→superior); the header affine is not applied, " +
      "so left/right etc. are approximate image-space words, not verified anatomy.";
  }

  /* ---------------- slice rendering ---------------- */

  function drawSlices() {
    if (!vol) return;
    drawSlice(ui.axc, "ax");
    drawSlice(ui.coc, "co");
    drawSlice(ui.sac, "sa");
    ui.axn.textContent = `z = ${slice.ax}/${vol.nz - 1}`;
    ui.con.textContent = `y = ${slice.co}/${vol.ny - 1}`;
    ui.san.textContent = `x = ${slice.sa}/${vol.nx - 1}`;
  }

  function drawSlice(canvas, plane) {
    const { data, nx, ny, nz } = vol;
    const w = canvas.width, h = canvas.height;
    const g = canvas.getContext("2d");
    let img = canvas._img;
    if (!img || img.width !== w || img.height !== h)
      img = canvas._img = g.createImageData(w, h);
    const px = img.data, span = win.hi - win.lo || 1, t = thrVal;
    let o = 0;
    for (let r = 0; r < h; r++)
      for (let c = 0; c < w; c++, o += 4) {
        let v;
        if (plane === "ax")                          // anterior up
          v = data[c + nx * ((ny - 1 - r) + ny * slice.ax)];
        else if (plane === "co")                     // superior up
          v = data[c + nx * (slice.co + ny * (nz - 1 - r))];
        else                                         // superior up
          v = data[slice.sa + nx * (c + ny * (nz - 1 - r))];
        let nv = (v - win.lo) / span;
        nv = nv < 0 ? 0 : nv > 1 ? 1 : nv;
        const gray = Math.round(nv * 235);
        if (v >= t) {                                // warm overlay above thr
          px[o]     = Math.round(gray * 0.35 + 255 * 0.65);
          px[o + 1] = Math.round(gray * 0.35 + 150 * 0.65);
          px[o + 2] = Math.round(gray * 0.35 + 60 * 0.65);
        } else {                                     // cool holographic gray
          px[o] = Math.round(gray * 0.85);
          px[o + 1] = Math.round(gray * 0.95);
          px[o + 2] = gray;
        }
        px[o + 3] = 255;
      }
    g.putImageData(img, 0, 0);
  }

  /* ---------------- 3D maximum-intensity projection ---------------- */

  /* Max-pool the volume to ≤64³ once per load. Max (not mean) keeps bright
     voxels bright, and pooled ≥ threshold ⇔ some source voxel ≥ threshold,
     so the 3D overlay stays consistent with the slice overlay. */
  function buildMip(v) {
    const f = Math.max(1, Math.ceil(Math.max(v.nx, v.ny, v.nz) / 64));
    const dnx = Math.ceil(v.nx / f), dny = Math.ceil(v.ny / f), dnz = Math.ceil(v.nz / f);
    const d = new Float32Array(dnx * dny * dnz).fill(-Infinity);
    let i = 0;
    for (let z = 0; z < v.nz; z++) {
      const dz = (z / f) | 0;
      for (let y = 0; y < v.ny; y++) {
        const row = dnx * (((y / f) | 0) + dny * dz);
        for (let x = 0; x < v.nx; x++, i++) {
          const di = ((x / f) | 0) + row;
          if (v.data[i] > d[di]) d[di] = v.data[i];
        }
      }
    }
    return { d, nx: dnx, ny: dny, nz: dnz, f };
  }

  /* Parallel rays through the rotated grid, nearest-neighbor samples,
     max wins. Runs on an OUT×OUT buffer then upscales — molecule.js glow
     aesthetic (cool cyan ramp, additive second pass). */
  function renderMip(img) {
    const { d, nx, ny, nz } = mip;
    const px = img.data;
    const cx = nx / 2, cy = ny / 2, cz = nz / 2;
    const R = 0.55 * Math.sqrt(nx * nx + ny * ny + nz * nz);
    const sxr = Math.sin(view.rx), cxr = Math.cos(view.rx);
    const syr = Math.sin(view.ry), cyr = Math.cos(view.ry);
    // inverse of molecule.js's rotate-Y-then-X: undo X, then undo Y
    const inv = (x, y, z) => {
      const y1 = y * cxr + z * sxr, z1 = -y * sxr + z * cxr;
      return [x * cyr - z1 * syr, y1, x * syr + z1 * cyr];
    };
    const ex = inv(1, 0, 0), ey = inv(0, 1, 0), ez = inv(0, 0, 1);
    const span = (2 * R) / view.zoom;
    const stepLen = 1.25, steps = Math.ceil((2 * R) / stepLen);
    const dxs = ez[0] * stepLen, dys = ez[1] * stepLen, dzs = ez[2] * stepLen;
    const wlo = win.lo, wspan = (win.hi - win.lo) || 1, t = thrVal;
    const hotDen = Math.max(1e-6, win.hi - t);
    let o = 0;
    for (let j = 0; j < MIP_OUT; j++) {
      const vv = (0.5 - j / MIP_OUT) * span;        // screen up = +y view axis
      for (let i = 0; i < MIP_OUT; i++, o += 4) {
        const uu = (i / MIP_OUT - 0.5) * span;
        let x = cx + uu * ex[0] + vv * ey[0] - R * ez[0];
        let y = cy + uu * ex[1] + vv * ey[1] - R * ez[1];
        let z = cz + uu * ex[2] + vv * ey[2] - R * ez[2];
        let best = -Infinity;
        for (let s = 0; s < steps; s++, x += dxs, y += dys, z += dzs) {
          if (x < 0 || y < 0 || z < 0) continue;
          const ix = x | 0, iy = y | 0, iz = z | 0;
          if (ix >= nx || iy >= ny || iz >= nz) continue;
          const val = d[ix + nx * (iy + ny * iz)];
          if (val > best) best = val;
        }
        let nv = (best - wlo) / wspan;
        if (!(nv > 0)) nv = 0;
        if (nv > 1) nv = 1;
        nv = Math.pow(nv, 0.85);
        let r0 = nv * 60 + nv * nv * 130;           // cyan ramp toward white
        let g0 = nv * 210 + nv * nv * 45;
        let b0 = nv * 255;
        if (best >= t) {                            // warm overlay in 3D too
          let m = (best - t) / hotDen;
          m = 0.5 + 0.4 * (m < 0 ? 0 : m > 1 ? 1 : m);
          r0 = r0 * (1 - m) + 255 * m;
          g0 = g0 * (1 - m) + 150 * m;
          b0 = b0 * (1 - m) + 60 * m;
        }
        px[o] = r0 | 0; px[o + 1] = g0 | 0; px[o + 2] = b0 | 0; px[o + 3] = 255;
      }
    }
  }

  function startMipLoop() {
    const my = gen;                    // this loop's generation ticket
    const cnv = ui.mipc, g = cnv.getContext("2d");
    const off = document.createElement("canvas");
    off.width = MIP_OUT; off.height = MIP_OUT;
    const og = off.getContext("2d");
    const img = og.createImageData(MIP_OUT, MIP_OUT);
    function frame() {
      // self-terminate: stage unmounted, volume replaced, or canvas removed
      if (my !== gen || !cnv.isConnected) return;
      if (view.spin && !view.drag) view.ry += 0.004;
      renderMip(img);
      og.putImageData(img, 0, 0);
      const w = cnv.width, h = cnv.height;
      g.fillStyle = "#05070d";
      g.fillRect(0, 0, w, h);
      g.imageSmoothingEnabled = true;
      g.drawImage(off, 0, 0, w, h);
      // cheap glow: additive, slightly enlarged, translucent second pass
      g.globalCompositeOperation = "lighter";
      g.globalAlpha = 0.30;
      g.drawImage(off, -w * 0.01, -h * 0.01, w * 1.02, h * 1.02);
      g.globalCompositeOperation = "source-over";
      g.globalAlpha = 1;
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  /* ---------------- research gate handoff ---------------- */

  function gatePrompt() {
    return `MRI bright-region image feature, centroid ${feature.octant}, ` +
      `${feature.count} voxels above p${thrPct.toFixed(1)}: pull provenanced ` +
      "evidence about causes of MRI hyperintensities in this region";
  }

  function askGate() {
    if (!feature || !vol) return;
    const p = gatePrompt();
    ui.prompt.style.display = "";
    if (typeof stage.onResearch === "function") {
      stage.onResearch(p);
      ui.prompt.textContent = "sent to the research gate: " + p;
    } else {
      ui.prompt.textContent = "research lane not wired on this page yet — " +
        "the research gate answers questions like this with receipts. Prompt: " + p;
    }
  }

  return stage;
})();
