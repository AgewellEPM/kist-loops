"use strict";
/* molecule.js — hologram-style 3D backbone viewer for structure nodes.
   Real coordinates only (/api/structure -> C-alpha trace from the actual
   archive file); drag to rotate, wheel to zoom, auto-spins when idle.
   No third-party libraries — a hand-rolled projection is enough for a
   backbone hologram. */

const CHAIN_GLOW = ["#3ce6ff", "#f5a623", "#4cc38a", "#ff9bce",
                    "#b083f0", "#e5534b", "#58a6ff", "#d2d922"];

async function viewStructure(structId) {
  openModal(`<h2>🧬 ${structId}</h2><div class="empty">fetching real coordinates…</div>`);
  const d = await api("/api/structure", { id: structId });
  if (d.error) {
    openModal(`<h2>🧬 ${structId}</h2><div class="empty">${esc(d.error)}</div>`);
    return;
  }
  openModal(`<h2>🧬 ${d.id} — C-alpha backbone, ${d.atoms.length} residues,
      ${d.chains.length} chain(s)${d.truncated ? ` (drawn first ${d.atoms.length} of ${d.ca_total})` : ""}</h2>
    <canvas id="mol3d" width="640" height="440"
      style="width:100%;border:1px solid var(--line);border-radius:8px;background:#05070d;cursor:grab"></canvas>
    <div class="when" style="margin-top:6px">
      drag to rotate · wheel to zoom · coordinates from
      <a href="${d.source_url}" target="_blank" rel="noopener">${d.source_url}</a>
      ${d.cached ? " (cached)" : ""}</div>
    <div class="sub">${d.chains.map((c, i) =>
      `<span style="color:${CHAIN_GLOW[i % CHAIN_GLOW.length]}">● chain ${c}</span>`).join("  ")}</div>`);
  startMolecule(d);
}

function startMolecule(d) {
  const canvas = document.getElementById("mol3d");
  if (!canvas) return;
  const g = canvas.getContext("2d");

  // Center + normalize the point cloud once.
  const n = d.atoms.length || 1;
  let cx = 0, cy = 0, cz = 0;
  for (const a of d.atoms) { cx += a.x; cy += a.y; cz += a.z; }
  cx /= n; cy /= n; cz /= n;
  let maxR = 1;
  const pts = d.atoms.map(a => {
    const x = a.x - cx, y = a.y - cy, z = a.z - cz;
    maxR = Math.max(maxR, Math.hypot(x, y, z));
    return { x, y, z, c: d.chains.indexOf(a.c) };
  });

  let rotX = 0.4, rotY = 0.6, zoom = 1, dragging = false, lastX = 0, lastY = 0;
  let idleSpin = true;

  canvas.onmousedown = e => { dragging = true; idleSpin = false;
    lastX = e.offsetX; lastY = e.offsetY; canvas.style.cursor = "grabbing"; };
  window.addEventListener("mouseup", () => { dragging = false;
    if (canvas) canvas.style.cursor = "grab"; });
  canvas.onmousemove = e => {
    if (!dragging) return;
    rotY += (e.offsetX - lastX) * 0.01;
    rotX += (e.offsetY - lastY) * 0.01;
    lastX = e.offsetX; lastY = e.offsetY;
  };
  canvas.onwheel = e => { e.preventDefault();
    zoom = Math.min(4, Math.max(0.3, zoom * (e.deltaY < 0 ? 1.1 : 0.9))); };

  function frame() {
    if (!document.getElementById("mol3d")) return;   // modal closed
    if (idleSpin) rotY += 0.004;
    const w = canvas.width, h = canvas.height;
    const scale = (Math.min(w, h) / (2.4 * maxR)) * zoom;
    const sx = Math.sin(rotX), cxr = Math.cos(rotX);
    const sy = Math.sin(rotY), cyr = Math.cos(rotY);
    g.clearRect(0, 0, w, h);

    const proj = pts.map(p => {
      // rotate around Y then X, simple perspective
      const x1 = p.x * cyr + p.z * sy;
      const z1 = -p.x * sy + p.z * cyr;
      const y2 = p.y * cxr - z1 * sx;
      const z2 = p.y * sx + z1 * cxr;
      const persp = 1 / (1 + z2 / (4 * maxR));
      return { X: w / 2 + x1 * scale * persp,
               Y: h / 2 + y2 * scale * persp,
               depth: z2, c: p.c };
    });

    // backbone lines per chain (consecutive residues), glow style
    g.lineWidth = 1.4;
    for (let i = 1; i < proj.length; i++) {
      if (proj[i].c !== proj[i - 1].c) continue;
      const col = CHAIN_GLOW[proj[i].c % CHAIN_GLOW.length];
      const a = 0.75 - 0.4 * (proj[i].depth / (maxR * 1.4));
      g.strokeStyle = col;
      g.globalAlpha = Math.max(0.12, Math.min(1, a));
      g.shadowColor = col; g.shadowBlur = 6;
      g.beginPath();
      g.moveTo(proj[i - 1].X, proj[i - 1].Y);
      g.lineTo(proj[i].X, proj[i].Y);
      g.stroke();
    }
    // residue dots, nearest brightest
    g.shadowBlur = 10;
    for (const p of proj) {
      const col = CHAIN_GLOW[p.c % CHAIN_GLOW.length];
      const a = 0.85 - 0.45 * (p.depth / (maxR * 1.4));
      g.globalAlpha = Math.max(0.1, Math.min(1, a));
      g.fillStyle = col; g.shadowColor = col;
      g.beginPath();
      g.arc(p.X, p.Y, 1.6, 0, 7);
      g.fill();
    }
    g.globalAlpha = 1; g.shadowBlur = 0;
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}
