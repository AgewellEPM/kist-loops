"use strict";
/* Floor dashboard app — Jeeves layout: chats | PEEL | center | chat.
   Every renderer draws from API data that carries receipts. */

const $ = id => document.getElementById(id);
const api = (path, params) =>
  fetch(path + "?" + new URLSearchParams(params)).then(r => r.json());

const COLORS = { protein: "#f5a623", gene: "#4cc38a", disease: "#e5534b",
  structure: "#58a6ff", sequence: "#b083f0", organism: "#d29922",
  location: "#39c5cf", domain: "#ff9bce", claim: "#8b949e", peel: "#8b949e" };
const color = t => COLORS[t] || "#8b949e";
const fmtBytes = n => n > 1048576 ? (n/1048576).toFixed(1)+" MB" : (n/1024).toFixed(0)+" KB";
const short = id => { const [t, v] = id.split(/:(.*)/s);
  return v && v.length > 22 ? t + ":" + v.slice(0, 8) + "…" + v.slice(-6) : id; };
const esc = s => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");

let state = { db: null, nodes: [], edges: [], sel: null, drag: null, chatId: null };

/* ---------------- minds / dbs ---------------- */
async function loadDbs() {
  const data = await api("/api/dbs", {});
  const box = $("dbs"), sel = $("dbsel");
  box.innerHTML = ""; sel.innerHTML = "";
  for (const db of data.dbs) {
    sel.add(new Option(`${db.name} · ${db.edges} edges`, db.name));
    const row = document.createElement("div");
    row.className = "dbrow"; row.dataset.name = db.name;
    row.innerHTML = `<b>${db.name}</b> · ${db.edges} edges · ${db.nodes} nodes ·
      ${db.tiles} tiles · ${fmtBytes(db.size_bytes)}
      <div class="path">${db.path}</div>`;
    row.onclick = () => pick(db.name);
    box.appendChild(row);
  }
  const want = new URLSearchParams(location.search).get("db");
  if (data.dbs.length)
    pick(want && data.dbs.some(d => d.name === want) ? want
         : (state.db || data.dbs[0].name));
  else box.innerHTML = '<span class="empty">no floor DBs found</span>';
}

async function pick(name) {
  state.db = name; $("dbsel").value = name;
  document.querySelectorAll(".dbrow").forEach(r =>
    r.classList.toggle("active", r.dataset.name === name));
  const [srcs, g] = await Promise.all([
    api("/api/sources", { db: name }), api("/api/graph", { db: name })]);
  renderSources(srcs); startGraph(g);
  $("dbstat").textContent = `${g.edges.length} edges` +
    (g.truncated ? ` (capped at ${g.edge_cap})` : "");
  if ($("tab-ledger").classList.contains("active")) runLedger(true);
  loadHarvest("");
  const deep = new URLSearchParams(location.search).get("node");
  if (deep) {
    const hit = state.nodes.find(n => n.id === deep);
    if (hit) { state.sel = hit; showNode(hit.id); }
  }
}
$("dbsel").onchange = ev => pick(ev.target.value);

function renderSources(data) {
  const box = $("sources");
  if (!data.sources.length) { box.innerHTML = '<span class="empty">no provenance rows</span>'; return; }
  box.innerHTML = data.sources.map(s => `
    <div class="src">
      <div class="name">${s.source} <b style="float:right">${s.edges}</b></div>
      <div class="host">${Object.entries(s.hosts).map(([h,c]) => `${h} (${c})`).join(" · ")}</div>
      <div class="when">${(s.first_retrieved||"").slice(0,19)} → ${(s.last_retrieved||"").slice(0,19)}</div>
    </div>`).join("");
}

/* ---------------- center tabs ---------------- */
const TABS = ["graph", "ledger", "notebook"];
function showTab(name) {
  for (const t of TABS) {
    $("tab-" + t).classList.toggle("active", t === name);
    $(t + "view").style.display =
      t === name ? (t === "graph" ? "" : "block") : "none";
  }
  if (name === "ledger") runLedger(true);
  if (name === "notebook") loadNotebook();
}
for (const t of TABS) $("tab-" + t).onclick = () => showTab(t);
const wantTab = location.hash.slice(1);
if (TABS.includes(wantTab) && wantTab !== "graph")
  window.addEventListener("load", () => showTab(wantTab));

/* ---------------- peel column tabs ---------------- */
const PTABS = ["harvest", "research", "data"];
for (const t of PTABS)
  $("ptab-" + t).onclick = () => {
    for (const u of PTABS) {
      $("ptab-" + u).classList.toggle("active", u === t);
      $("p" + u).style.display = u === t ? "block" : "none";
    }
  };

/* ---------------- node search ---------------- */
$("nodesearch").addEventListener("change", ev => {
  const term = ev.target.value.trim().toLowerCase();
  if (!term) return;
  const hit = state.nodes.find(n => n.id.toLowerCase() === term) ||
              state.nodes.find(n => n.id.toLowerCase().includes(term));
  if (hit) { state.sel = hit; showTab("graph"); showNode(hit.id); }
  else chatCard(`<span class="empty">no node matching “${esc(ev.target.value)}”</span>`);
});

/* ---------------- graph (center) ---------------- */
const cv = $("cv"), ctx = cv.getContext("2d");
function startGraph(g) {
  const idx = new Map();
  state.nodes = g.nodes.map((n, i) => { idx.set(n.id, i); return {
    ...n, x: Math.cos(i*2.399)*(120+8*Math.sqrt(i)),
    y: Math.sin(i*2.399)*(120+8*Math.sqrt(i)), vx: 0, vy: 0 }; });
  state.edges = g.edges.map(e => ({ ...e, si: idx.get(e.source), ti: idx.get(e.target) }));
  const degree = new Array(state.nodes.length).fill(0);
  state.edges.forEach(e => { degree[e.si]++; degree[e.ti]++; });
  state.nodes.forEach((n, i) => n.r = 5 + Math.min(11, Math.sqrt(degree[i]) * 2.2));
  state.sel = null;
  const types = [...new Set(state.nodes.map(n => n.type))].sort();
  $("legend").innerHTML = types.map(t =>
    `<span class="lg"><span class="dot" style="background:${color(t)}"></span>${t}</span>`).join("");
  $("nodelist").innerHTML = g.nodes.map(n => `<option value="${n.id}">`).join("");
}

function step() {
  const N = state.nodes, E = state.edges;
  for (let i = 0; i < N.length; i++) for (let j = i+1; j < N.length; j++) {
    const a = N[i], b = N[j];
    let dx = b.x - a.x, dy = b.y - a.y;
    let d2 = dx*dx + dy*dy || 1;
    if (d2 < 40000) { const f = 900 / d2;
      const d = Math.sqrt(d2); dx /= d; dy /= d;
      a.vx -= dx*f; a.vy -= dy*f; b.vx += dx*f; b.vy += dy*f; }
  }
  for (const e of E) {
    const a = N[e.si], b = N[e.ti];
    if (!a || !b) continue;
    const dx = b.x - a.x, dy = b.y - a.y;
    const d = Math.sqrt(dx*dx + dy*dy) || 1, f = (d - 90) * 0.004;
    a.vx += dx/d*f; a.vy += dy/d*f; b.vx -= dx/d*f; b.vy -= dy/d*f;
  }
  for (const n of N) {
    if (n === state.drag) continue;
    n.vx *= 0.85; n.vy *= 0.85;
    n.x += n.vx; n.y += n.vy;
    n.x -= n.x * 0.002; n.y -= n.y * 0.002;
  }
}

function draw() {
  const w = cv.clientWidth, h = cv.clientHeight;
  if (w && cv.width !== w*devicePixelRatio) { cv.width = w*devicePixelRatio; cv.height = h*devicePixelRatio; }
  ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
  ctx.clearRect(0, 0, w, h);
  ctx.save(); ctx.translate(w/2, h/2);
  for (const e of state.edges) {
    const a = state.nodes[e.si], b = state.nodes[e.ti];
    if (!a || !b) continue;
    const hot = state.sel && (a === state.sel || b === state.sel);
    ctx.strokeStyle = hot ? "#f5a623" : "#2c3644"; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
  }
  for (const n of state.nodes) {
    ctx.fillStyle = color(n.type);
    ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, 7); ctx.fill();
    if (n === state.sel) { ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.stroke(); }
    if (n.r > 7 || n === state.sel) {
      ctx.fillStyle = "#dbe2ea"; ctx.font = "11px sans-serif";
      ctx.fillText(short(n.id), n.x + n.r + 3, n.y + 3);
    }
  }
  ctx.restore();
  step(); requestAnimationFrame(draw);
}
requestAnimationFrame(draw);

function nodeAt(mx, my) {
  const x = mx - cv.clientWidth/2, y = my - cv.clientHeight/2;
  for (let i = state.nodes.length - 1; i >= 0; i--) {
    const n = state.nodes[i], dx = n.x - x, dy = n.y - y;
    if (dx*dx + dy*dy <= (n.r+3)*(n.r+3)) return n;
  }
  return null;
}
cv.addEventListener("mousedown", ev => {
  const r = cv.getBoundingClientRect();
  const n = nodeAt(ev.clientX - r.left, ev.clientY - r.top);
  if (n) state.drag = n;
});
cv.addEventListener("mousemove", ev => {
  const r = cv.getBoundingClientRect();
  if (state.drag) {
    state.drag.x = ev.clientX - r.left - cv.clientWidth/2;
    state.drag.y = ev.clientY - r.top - cv.clientHeight/2;
  }
  cv.style.cursor = nodeAt(ev.clientX - r.left, ev.clientY - r.top) ? "pointer" : "default";
});
window.addEventListener("mouseup", ev => {
  const r = cv.getBoundingClientRect();
  const n = nodeAt(ev.clientX - r.left, ev.clientY - r.top);
  if (n && n === state.drag) { state.sel = n; showNode(n.id); }
  state.drag = null;
});

/* ---------------- node card -> chat column ---------------- */
function chatCard(html, cls) {
  const el = document.createElement("div");
  el.className = "floorbubble " + (cls || "");
  el.innerHTML = html;
  $("chatlog").appendChild(el);
  $("chatlog").scrollTop = $("chatlog").scrollHeight;
}
async function showNode(id) {
  const d = await api("/api/node", { db: state.db, id });
  const edgeHtml = (e, dir) => {
    const other = dir === "out" ? e.target : e.source;
    const p = e.provenance;
    return `<div class="edge-row">
      ${dir === "out" ? "→" : "←"} <span class="rel">${e.relation}</span> ${short(other)}
      ${p ? `<div><a href="${p.url}" target="_blank" rel="noopener">${p.url}</a></div>
             <div class="when">${p.source} · ${(p.retrieved_at||"").slice(0,19)} · edge ${e.id.slice(0,8)}</div>`
          : `<div class="when">no provenance row</div>`}
    </div>`;
  };
  chatCard(`<b>${d.node}</b>` +
    (d.outgoing.length + d.incoming.length
      ? d.outgoing.map(e => edgeHtml(e, "out")).join("") +
        d.incoming.map(e => edgeHtml(e, "in")).join("")
      : '<div class="empty">no edges</div>'), "nodecard");
}

/* ---------------- harvest: tile cards ---------------- */
async function loadHarvest(topic) {
  if (!state.db) return;
  const d = await api("/api/harvest", { db: state.db, topic });
  if (!topic) {
    $("htiles").innerHTML = "";
    $("htopics").innerHTML = (d.topics || []).length
      ? d.topics.map(t =>
          `<span class="chip" data-t="${t.topic}">${t.topic.replace("bio-structure:","")} · ${t.tiles}</span>`).join("")
      : '<span class="empty">no trace tiles in this db</span>';
    document.querySelectorAll("#htopics .chip").forEach(el =>
      el.onclick = () => loadHarvest(el.dataset.t));
    return;
  }
  document.querySelectorAll("#htopics .chip").forEach(el =>
    el.classList.toggle("on", el.dataset.t === topic));
  const srcHtml = d.sources.length
    ? `<div class="card" style="margin:8px 0"><h2>Collected from</h2>` +
      d.sources.map(s => `<div class="edge-row">
        <a href="${s.url}" target="_blank" rel="noopener">${s.url}</a>
        <div class="when">${s.source} · ${(s.retrieved_at || "").slice(0, 19)}</div>
      </div>`).join("") + "</div>"
    : "";
  $("htiles").innerHTML = srcHtml + d.tiles.map(t => `
    <div class="tilecard" data-topic="${esc(topic)}" data-turn="${t.turn_number}">
      <b>${t.emoji || "🧩"}</b> ${esc(t.sentence)}
      <div class="when">${esc(t.subcategory)} · depth ${t.depth_level} · turn ${t.turn_number}</div>
    </div>`).join("");
  document.querySelectorAll("#htiles .tilecard").forEach(el =>
    el.onclick = () => inspectTile(el.dataset.topic, el.dataset.turn));
}

async function inspectTile(topic, turn) {
  // Tile ids aren't in the list payload; re-query the topic and match turn.
  const d = await api("/api/harvest", { db: state.db, topic });
  const t = d.tiles.find(x => String(x.turn_number) === String(turn));
  if (!t) return;
  const conns = ["related_to","causes","requires","part_of","next_step","previous_step"]
    .filter(k => t[k]).map(k => `<div>· <span class="rel">${k}</span> ${esc(t[k])}</div>`).join("");
  chatCard(`<b>${t.emoji || "🧩"} tile — ${esc(topic)}</b>
    <div>${esc(t.sentence)}</div>
    <div class="when">${esc(t.subcategory)} · depth ${t.depth_level} · turn ${t.turn_number}</div>
    ${conns || '<div class="empty">no connectors</div>'}`, "nodecard");
}

/* ---------------- research (peel column) ---------------- */
async function runResearch() {
  const prompt = $("rq").value.trim();
  if (!prompt || !state.db) return;
  $("rgo").disabled = true;
  let d;
  try {
    d = await fetch("/api/research", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ db: state.db, prompt }) }).then(r => r.json());
  } catch (e) { d = { admitted: "request_failed", error: String(e) }; }
  $("rgo").disabled = false;
  let detail = "";
  if (d.admitted === "extract") {
    const x = d.extraction || {};
    detail = `status ${x.status} · ${x.edges_written ?? 0} new edges` +
      (x.pdb_xrefs_total != null ? ` · ${x.pdb_xrefs_total} PDB xrefs` : "");
  } else if (d.admitted === "claim") detail = `verdict: <b>${(d.verdict || {}).verdict}</b>`;
  else if (d.admitted === "abstain") detail = `reason: ${esc((d.proposal || {}).reason || "")}`;
  else detail = esc(d.error || "");
  $("rout").insertAdjacentHTML("afterbegin", `<div class="edge-row">
    <b>»</b> ${esc(prompt)}
    <div><span class="kind kind-edge">${d.admitted}</span>
      ${(d.proposal && d.proposal.subject) ? " " + d.proposal.subject : ""}</div>
    <div class="when">${detail}</div></div>`);
  if (d.admitted === "extract") pick(state.db);
}
$("rgo").onclick = runResearch;
$("rq").addEventListener("keydown", ev => { if (ev.key === "Enter") runResearch(); });

/* ---------------- ledger (center) ---------------- */
const lstate = { offset: 0, limit: 200, kind: "", source: "", relation: "", total: 0 };
function lparams() {
  return { db: state.db, q: $("lq").value, from: $("lfrom").value,
    to: $("lto").value, kind: lstate.kind, source: lstate.source,
    relation: lstate.relation, limit: lstate.limit, offset: lstate.offset };
}
async function runLedger(reset) {
  if (!state.db) return;
  if (reset) { lstate.offset = 0; $("lrows").innerHTML = ""; }
  const d = await api("/api/ledger", lparams());
  lstate.total = d.total;
  renderFacets(d.facets);
  $("lcount").textContent =
    `${d.total} events — showing ${Math.min(d.offset + d.limit, d.total)}`;
  $("lrows").insertAdjacentHTML("beforeend", d.events.map(e => `
    <tr>
      <td class="when">${e.when ? e.when.replace("T", " ").slice(0, 19) : "—"}</td>
      <td><span class="kind kind-${e.kind}">${e.kind}</span></td>
      <td>${esc(e.text)}</td>
      <td>${e.url ? `<a href="${e.url}" target="_blank" rel="noopener">${e.url}</a>`
                  : (e.source || '<span class="empty">local</span>')}</td>
      <td class="when">${e.retrieved_at ? e.retrieved_at.slice(0, 19) : "—"}</td>
    </tr>`).join(""));
  $("lmore").style.display = d.offset + d.events.length < d.total ? "" : "none";
}
function chip(group, key, count) {
  const on = lstate[group] === key;
  return `<span class="chip ${on ? "on" : ""}" data-g="${group}" data-k="${key}">
    ${key} ${count}</span>`;
}
function renderFacets(f) {
  $("lfacets").innerHTML =
    Object.entries(f.kinds).map(([k, c]) => chip("kind", k, c)).join("") +
    Object.entries(f.sources).map(([k, c]) => chip("source", k, c)).join("") +
    Object.entries(f.relations).map(([k, c]) => chip("relation", k, c)).join("");
  document.querySelectorAll("#lfacets .chip").forEach(el => el.onclick = () => {
    const g = el.dataset.g, k = el.dataset.k;
    lstate[g] = lstate[g] === k ? "" : k;
    runLedger(true);
  });
}
$("lgo").onclick = () => runLedger(true);
$("lq").addEventListener("keydown", ev => { if (ev.key === "Enter") runLedger(true); });
$("lclear").onclick = () => {
  $("lq").value = ""; $("lfrom").value = ""; $("lto").value = "";
  lstate.kind = lstate.source = lstate.relation = "";
  runLedger(true);
};
$("lmore").onclick = () => { lstate.offset += lstate.limit; runLedger(false); };
const dl = fmt => {
  const p = new URLSearchParams({ ...lparams(), format: fmt, offset: 0 });
  window.open("/api/export?" + p, "_blank");
};
$("lcsv").onclick = () => dl("csv");
$("ljson").onclick = () => dl("json");

/* ---------------- notebook (center) ---------------- */
const NBCOLOR = { observation: "node", discovery: "edge", learning: "claim",
                  anomaly: "tile", reflection: "sequence" };
let nbKind = "", nbTimer = null;
async function loadNotebook() {
  const d = await api("/api/notebook", { limit: 300, kind: nbKind });
  const kinds = {};
  d.entries.forEach(e => kinds[e.kind] = (kinds[e.kind] || 0) + 1);
  $("nbkinds").innerHTML = Object.entries(kinds).map(([k, c]) =>
    `<span class="chip ${nbKind === k ? "on" : ""}" data-k="${k}">${k} ${c}</span>`).join("");
  document.querySelectorAll("#nbkinds .chip").forEach(el => el.onclick = () => {
    nbKind = nbKind === el.dataset.k ? "" : el.dataset.k; loadNotebook();
  });
  $("nbentries").innerHTML = d.entries.length
    ? d.entries.slice().reverse().map(e => `<div class="edge-row">
        <span class="kind kind-${NBCOLOR[e.kind] || "tile"}">${e.kind}</span>
        ${esc(e.text)}
        <div class="when">${(e.at || "").replace("T", " ").slice(0, 19)}
          · ${e.session || ""}${e.refs && e.refs.length
            ? " · refs: " + e.refs.slice(0, 6).map(r => r.slice(0, 26)).join(", ")
            : ""}</div>
      </div>`).join("")
    : '<span class="empty">no notes yet — run a research session and the system will start dictating</span>';
  clearTimeout(nbTimer);
  if ($("tab-notebook").classList.contains("active"))
    nbTimer = setTimeout(loadNotebook, 4000);
}

/* ---------------- chat with the floor ---------------- */
const KINDBADGE = { recall: "node", extract: "edge", claim: "claim",
                    abstain: "sequence", intent: "sequence", error: "tile" };
async function loadChats() {
  const d = await api("/api/chats", {});
  $("chatlist").innerHTML = d.chats.map(c => `
    <div class="chatrow ${c.id === state.chatId ? "active" : ""}" data-id="${c.id}">
      ${esc(c.title)}
      <div class="when">${(c.created_at || "").replace("T", " ").slice(0, 16)}</div>
    </div>`).join("") || '<div class="empty" style="padding:10px">no conversations yet</div>';
  document.querySelectorAll(".chatrow").forEach(el =>
    el.onclick = () => openChat(el.dataset.id));
}
async function openChat(id) {
  state.chatId = id;
  const d = await api("/api/chat", { id });
  $("chatlog").innerHTML = "";
  for (const t of d.turns) renderTurn(t);
  loadChats();
}
function renderTurn(t) {
  if (t.role === "user") chatCard(esc(t.text)), // eslint-disable-line
    $("chatlog").lastElementChild.className = "userbubble";
  else chatCard(
    `<span class="kind kind-${KINDBADGE[t.kind] || "tile"}">${t.kind || "floor"}</span>` +
    esc(t.text));
}
async function sendMsg() {
  const text = $("cmsg").value.trim();
  if (!text || !state.db) return;
  $("cmsg").value = ""; $("csend").disabled = true;
  renderTurn({ role: "user", text });
  chatCard('<span class="empty">thinking through the gate…</span>');
  let d;
  try {
    d = await fetch("/api/chat", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ db: state.db, chat_id: state.chatId, text }) })
      .then(r => r.json());
  } catch (e) { d = { reply: { kind: "error", text: String(e) } }; }
  $("csend").disabled = false;
  $("chatlog").lastElementChild.remove();   // the “thinking” bubble
  if (d.error) { renderTurn({ role: "floor", kind: "error", text: d.error }); return; }
  state.chatId = d.chat_id;
  renderTurn({ role: "floor", ...d.reply });
  if (d.reply.kind === "extract") pick(state.db);
  loadChats();
}
$("csend").onclick = sendMsg;
$("cmsg").addEventListener("keydown", ev => { if (ev.key === "Enter") sendMsg(); });
$("newchat").onclick = () => { state.chatId = null; $("chatlog").innerHTML = "";
  chatCard("🧬 New conversation — message Lois."); loadChats(); };

loadChats();
loadDbs();
