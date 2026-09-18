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
  const params = new URLSearchParams(location.search);
  const deep = params.get("node");
  if (deep) {
    const hit = state.nodes.find(n => n.id === deep);
    if (hit) { state.sel = hit; showNode(hit.id); }
  }
  const mol = params.get("mol");
  if (mol) viewStructure(mol);
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
const TABS = ["graph", "ledger", "notebook", "scientist", "vision", "calendar"];
function showTab(name) {
  for (const t of TABS) {
    $("tab-" + t).classList.toggle("active", t === name);
    $(t + "view").style.display =
      t === name ? (t === "graph" ? "" : "block") : "none";
  }
  if (name === "ledger") runLedger(true);
  if (name === "notebook") loadNotebook();
  if (name === "scientist") loadScientist();
  if (name === "vision") mountVision(visionStage || "journey");
  else unmountVision();
  if (name === "calendar") {
    if (window.CalendarLane) CalendarLane.mount($("calendarlane"));
    else $("calendarlane").innerHTML = '<div class="empty pad">calendar module failed to load</div>';
  } else if (window.CalendarLane && CalendarLane.isMounted && CalendarLane.isMounted()) {
    CalendarLane.unmount();
  }
}
for (const t of TABS) $("tab-" + t).onclick = () => showTab(t);
const wantTab = location.hash.slice(1);
if (TABS.includes(wantTab) && wantTab !== "graph")
  window.addEventListener("load", () => showTab(wantTab));

/* ---------------- peel column tabs ---------------- */
const PTABS = ["harvest", "research", "trace"];
for (const t of PTABS)
  $("ptab-" + t).onclick = () => {
    for (const u of PTABS) {
      $("ptab-" + u).classList.toggle("active", u === t);
      $("p" + u).style.display = u === t ? "block" : "none";
    }
    if (t === "trace") loadTrace("");
  };

/* ---------------- popout modal (the Jeeves inspector) ---------------- */
function openModal(html) {
  $("modalbody").innerHTML = html;
  $("modal").style.display = "flex";
}
// Closing must EMPTY the modal, not just hide it — the 3D viewers stop their
// animation loops by watching their canvas leave the DOM (conceptviz review).
function closeModal() { $("modal").style.display = "none"; $("modalbody").innerHTML = ""; }
$("modal").onclick = ev => { if (ev.target === $("modal")) closeModal(); };
window.addEventListener("keydown", ev => {
  if (ev.key === "Escape") closeModal(); });

/* ---------------- node search ---------------- */
$("nodesearch").addEventListener("change", ev => {
  const term = ev.target.value.trim().toLowerCase();
  if (!term) return;
  const hit = state.nodes.find(n => n.id.toLowerCase() === term) ||
              state.nodes.find(n => n.id.toLowerCase().includes(term));
  if (hit) { state.sel = hit; showTab("graph"); Graph3D.focus(hit.id); showNode(hit.id); }
  else chatCard(`<span class="empty">no node matching “${esc(ev.target.value)}”</span>`);
});

/* ---------------- graph (center) — engine lives in graph3d.js ---------------- */
function startGraph(g) {
  const idx = new Map();
  state.nodes = g.nodes.map((n, i) => { idx.set(n.id, i); return { ...n }; });
  state.edges = g.edges.map(e => ({ ...e, si: idx.get(e.source), ti: idx.get(e.target) }));
  const degree = new Array(state.nodes.length).fill(0);
  state.edges.forEach(e => { degree[e.si]++; degree[e.ti]++; });
  state.nodes.forEach((n, i) => n.r = 5 + Math.min(11, Math.sqrt(degree[i]) * 2.2));
  state.sel = null;
  const types = [...new Set(state.nodes.map(n => n.type))].sort();
  $("legend").innerHTML = types.map(t =>
    `<span class="lg"><span class="dot" style="background:${color(t)}"></span>${t}</span>`).join("");
  $("nodelist").innerHTML = g.nodes.map(n => `<option value="${n.id}">`).join("");
  // the engine picks each mind's signature style; reflect it in the switcher
  $("gstyle").value = Graph3D.start(state, {
    color, label: short,
    onSelect: n => { state.sel = n; showNode(n.id); },
  });
}
$("gstyle").onchange = ev => Graph3D.setStyle(ev.target.value);
$("gspin").onclick = () => { Graph3D.setSpin(!Graph3D.spinning());
  $("gspin").classList.toggle("off", !Graph3D.spinning()); };
$("gfit").onclick = () => Graph3D.fit();

/* ---------------- vision stage (center): cinema / molecule / MRI --------------
   Modules own their stages (cinema.js, mri.js, conceptviz.js); this is only the
   mounting glue. Everything generated banners itself inside the modules. */
let visionStage = null;

function unmountVision() {
  if (window.CellJourney && CellJourney.isMounted && CellJourney.isMounted())
    CellJourney.unmount();
  if (window.MRIStage && MRIStage.unmount) MRIStage.unmount();
}

function mountVision(stage) {
  const box = $("visionstage");
  if (!box) return;
  unmountVision();
  box.innerHTML = "";
  visionStage = stage;
  for (const s of ["journey", "molecule", "mri"])
    $("vstage-" + s).classList.toggle("active", s === stage);
  if (stage === "journey") {
    if (!window.CellJourney) { box.innerHTML = '<div class="empty pad">cinema module failed to load</div>'; return; }
    CellJourney.mount(box, {});
    groundJourney();
  } else if (stage === "mri") {
    if (!window.MRIStage) { box.innerHTML = '<div class="empty pad">MRI module failed to load</div>'; return; }
    // "what does it mean" NEVER answers here — it routes to the research gate
    MRIStage.onResearch = prompt => {
      $("ptab-research").click();
      $("rq").value = prompt;
      $("rq").focus();
      chatCard("🩻 MRI feature routed to the Research gate — the answer comes " +
               "with receipts or not at all.");
    };
    MRIStage.mount(box);
  } else {
    mountMoleculeStage(box);
  }
}

// Ground the journey in THIS mind's real data: prefer the selected protein,
// else the first protein carrying a stored sequence; captions then show real
// node ids and the backbone forms from the REAL residue string.
async function groundJourney() {
  const prots = state.nodes.filter(n => n.type === "protein");
  const pick = (state.sel && state.sel.type === "protein") ? state.sel : prots[0];
  if (!pick) return;
  const nd = await api("/api/node", { db: state.db, id: pick.id }).catch(() => null);
  if (!nd || !window.CellJourney || !CellJourney.isMounted()) return;
  const edges = [...(nd.outgoing || []), ...(nd.incoming || [])];
  const gene = edges.find(e => e.relation === "encodes" && e.source.startsWith("gene:"));
  const seq = edges.find(e => e.relation === "has_sequence" && e.target.startsWith("sequence:"));
  let residues = null;
  if (seq) {
    const d = await api("/api/sequence", { db: state.db, id: seq.target }).catch(() => null);
    if (d && !d.error) residues = d.residues;
  }
  if (CellJourney.isMounted())
    CellJourney.setContext({ gene: gene ? gene.source : null,
                             protein: pick.id, residues });
}

function mountMoleculeStage(box) {
  const buildable = state.nodes.filter(n =>
    n.type === "protein" || n.type === "sequence" || n.type === "structure");
  box.innerHTML = `<div class="pad">
    <div class="sub" style="margin:8px 0">Full 3D structural build from this
      mind's stored data — a REAL archived structure when the graph holds one,
      otherwise a generated concept computed from the REAL residue sequence
      (and it will say so on a banner).</div>
    ${buildable.length ? `
      <select id="vmolpick" style="max-width:340px">${buildable.map(n =>
        `<option value="${n.id}">${n.id}</option>`).join("")}</select>
      <button class="btn" id="vmolgo">🧪 Build 3D</button>` :
      '<div class="empty">this mind holds no protein / sequence / structure nodes — run the wheel or Import first</div>'}
  </div>`;
  const go = $("vmolgo");
  if (go) go.onclick = () => { const v = $("vmolpick").value; if (v) viewConcept(v); };
}

$("vstage-journey").onclick = () => mountVision("journey");
$("vstage-molecule").onclick = () => mountVision("molecule");
$("vstage-mri").onclick = () => mountVision("mri");

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
  const molBtn = d.node.startsWith("structure:")
    ? `<button class="btn" onclick="viewStructure('${d.node.slice(10)}')"
         style="margin-bottom:8px">🧬 View 3D structure</button>` : "";
  const conceptBtn = /^(gene|location|protein|sequence):/.test(d.node)
    ? `<button class="btn" onclick="viewConcept('${d.node}')" style="margin-bottom:8px">${
        d.node.startsWith("gene:") ? "🧬 DNA markup 3D"
        : d.node.startsWith("location:") ? "🧫 Cell markup 3D"
        : "🧪 3D view (real structure, or generated from sequence)"}</button>` : "";
  openModal(`<h2>${d.node}</h2>` + molBtn + conceptBtn +
    (d.outgoing.length + d.incoming.length
      ? d.outgoing.map(e => edgeHtml(e, "out")).join("") +
        d.incoming.map(e => edgeHtml(e, "in")).join("")
      : '<div class="empty">no edges</div>') +
    (d.tiles.length
      ? `<h2 style="margin-top:10px">Trace tiles</h2>` +
        d.tiles.map(t => `<div class="edge-row">${t.emoji || ""} ${esc(t.sentence)}</div>`).join("")
      : ""));
}

/* ---------------- harvest: tile cards ---------------- */
let harvestTopics = [], currentTopic = "";
async function loadHarvest(topic) {
  if (!state.db) return;
  currentTopic = topic;
  const d = await api("/api/harvest", { db: state.db, topic });
  if (!topic) {
    harvestTopics = d.topics || [];
    $("htiles").innerHTML = "";
    renderTopicChips();
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
    <div class="tilecard" data-id="${t.id}">
      <b>${t.emoji || "🧩"}</b> ${esc(t.sentence)}
      <div class="when">${esc(t.subcategory)} · depth ${t.depth_level} · turn ${t.turn_number}</div>
    </div>`).join("");
  document.querySelectorAll("#htiles .tilecard").forEach(el =>
    el.onclick = () => inspectTile(el.dataset.id));
}
function renderTopicChips() {
  const filter = ($("catsearch").value || "").toLowerCase();
  const shown = harvestTopics.filter(t => t.topic.toLowerCase().includes(filter));
  $("htopics").innerHTML = shown.length
    ? shown.map(t =>
        `<span class="chip" data-t="${t.topic}">${t.topic.replace("bio-structure:","")} · ${t.tiles}</span>`).join("")
    : '<span class="empty">no matching topics</span>';
  document.querySelectorAll("#htopics .chip").forEach(el =>
    el.onclick = () => loadHarvest(el.dataset.t));
}
$("catsearch").addEventListener("input", renderTopicChips);
$("latestharvest").onclick = () =>
  harvestTopics.length && loadHarvest(harvestTopics[0].topic);
$("refreshharvest").onclick = () => loadHarvest(currentTopic);

async function inspectTile(id) {
  // The Jeeves popout: the tile's FULL dataset — every stored field.
  const t = await api("/api/tile", { db: state.db, id });
  if (t.error) return;
  const skip = new Set(["id", "conversation_id", "sentence", "emoji"]);
  const fields = Object.entries(t)
    .filter(([k, v]) => !skip.has(k) && v !== "" && v !== null)
    .map(([k, v]) => `<div class="edge-row"><span class="rel">${k}</span> ${esc(v)}</div>`)
    .join("");
  openModal(`<h2>${t.emoji || "🧩"} ${esc(t.sentence)}</h2>${fields}
    <div class="when" style="margin-top:8px">tile ${esc(t.id)}</div>`);
}

/* ---------------- trace tab ---------------- */
async function loadTrace(topic) {
  if (!state.db) return;
  if (!topic) {
    $("ttrace").innerHTML = "";
    $("tsubjects").innerHTML = harvestTopics.length
      ? harvestTopics.map(t =>
          `<span class="chip" data-t="${t.topic}">${t.topic.replace("bio-structure:","")}</span>`).join("")
      : '<span class="empty">no traces yet</span>';
    document.querySelectorAll("#tsubjects .chip").forEach(el =>
      el.onclick = () => loadTrace(el.dataset.t));
    return;
  }
  document.querySelectorAll("#tsubjects .chip").forEach(el =>
    el.classList.toggle("on", el.dataset.t === topic));
  const d = await api("/api/harvest", { db: state.db, topic });
  $("ttrace").innerHTML =
    d.tiles.map(t => `<div class="edge-row">
      <span class="kind kind-node">turn ${t.turn_number}</span>
      ${t.emoji || ""} ${esc(t.sentence)}
      <div class="when">${esc(t.subcategory)} · depth ${t.depth_level}</div>
    </div>`).join("") +
    (d.sources.length
      ? `<div class="card" style="margin:8px 0"><h2>Sources</h2>` +
        d.sources.map(s => `<div class="edge-row">
          <a href="${s.url}" target="_blank" rel="noopener">${s.url}</a></div>`).join("") + "</div>"
      : "");
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
      body: JSON.stringify({ db: state.db, prompt, model: $("modelsel").value,
                             libraries: selectedLibraries() }) }).then(r => r.json());
  } catch (e) { d = { admitted: "request_failed", error: String(e) }; }
  window.lastReply = d;
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
      <span class="rowops">
        <button data-op="rename" title="Rename">✏️</button>
        <button data-op="delete" title="Delete">🗑</button>
      </span>
      ${esc(c.title)}
      <div class="when">${(c.created_at || "").replace("T", " ").slice(0, 16)}</div>
    </div>`).join("") || '<div class="empty" style="padding:10px">no conversations yet</div>';
  document.querySelectorAll(".chatrow").forEach(el => {
    el.onclick = () => openChat(el.dataset.id);
    el.querySelectorAll(".rowops button").forEach(b => b.onclick = ev => {
      ev.stopPropagation();
      if (b.dataset.op === "delete") {
        if (confirm("Delete this conversation?")) manageChat("delete", el.dataset.id);
      } else {
        const t = prompt("New title:");
        if (t) manageChat("rename", el.dataset.id, t);
      }
    });
  });
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
      body: JSON.stringify({ db: state.db, chat_id: state.chatId, text,
                             model: $("modelsel").value,
                             libraries: selectedLibraries() }) })
      .then(r => r.json());
  } catch (e) { d = { reply: { kind: "error", text: String(e) } }; }
  $("csend").disabled = false;
  $("chatlog").lastElementChild.remove();   // the “thinking” bubble
  if (d.error) { renderTurn({ role: "floor", kind: "error", text: d.error }); return; }
  state.chatId = d.chat_id;
  window.lastReply = d.reply;
  renderTurn({ role: "floor", ...d.reply });
  if (d.reply.kind === "extract") pick(state.db);
  loadChats();
}
$("csend").onclick = sendMsg;
$("cmsg").addEventListener("keydown", ev => { if (ev.key === "Enter") sendMsg(); });
const newChat = () => { state.chatId = null; $("chatlog").innerHTML = "";
  chatCard("🧬 New conversation — message Lois."); loadChats(); };
$("newchat").onclick = newChat;

/* ---------------- chats: search + organize ---------------- */
$("chatsearch").addEventListener("input", ev => {
  const f = ev.target.value.toLowerCase();
  document.querySelectorAll(".chatrow").forEach(el =>
    el.style.display = el.textContent.toLowerCase().includes(f) ? "" : "none");
});
$("organize").onclick = () => $("chatscol").classList.toggle("organizing");
async function manageChat(op, id, title) {
  await fetch("/api/chats/manage", { method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ op, id, title }) });
  if (op === "delete" && id === state.chatId) newChat();
  loadChats();
}

/* ---------------- Knowledge Categories lane ---------------- */
async function pollHealth() {
  const h = await api("/api/health", {}).catch(() => ({ status: "server unreachable", ollama: false }));
  const pill = $("readypill");
  pill.textContent = h.status;
  pill.classList.toggle("down", !(h.ok && h.ollama));
  setTimeout(pollHealth, 30000);
}
$("newmind").onclick = async () => {
  const name = prompt("Name the new mind (a-z 0-9 _ -):");
  if (!name) return;
  const r = await fetch("/api/minds", { method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }) }).then(x => x.json());
  if (r.error) { openModal(`<h2>Create New Mind</h2><div class="empty">${esc(r.error)}</div>`); return; }
  await loadDbs(); pick(r.created);
};

$("exportbtn").onclick = () =>
  window.open("/api/export?" + new URLSearchParams({ db: state.db, format: "json" }), "_blank");
$("importbtn").onclick = () => {
  openModal(`<h2>📥 Import — run the wheel on accessions</h2>
    <div class="sub">One UniProt accession per line (max 10 per run). The floor
    pulls each one directly — every edge provenance-pinned. No model involved.</div>
    <textarea id="implist" rows="6" style="width:100%;margin:8px 0;background:var(--bg);
      color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px"></textarea>
    <button class="btn" id="imprun">Run import</button><div id="impout"></div>`);
  $("imprun").onclick = async () => {
    const accs = $("implist").value.split(/\s+/).filter(Boolean);
    if (!accs.length) return;
    $("imprun").disabled = true;
    $("impout").innerHTML = '<div class="empty">running the wheel…</div>';
    const r = await fetch("/api/import", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ db: state.db, accessions: accs,
        libraries: selectedLibraries() }) }).then(x => x.json());
    $("imprun").disabled = false;
    $("impout").innerHTML = r.error ? `<div class="empty">${esc(r.error)}</div>`
      : r.results.map(x => `<div class="edge-row">${x.accession} —
          <b>${x.status}</b>${x.edges_written != null ? ` · ${x.edges_written} new edges` : ""}</div>`).join("") +
        (r.requested > r.processed
          ? `<div class="when">${r.requested - r.processed} skipped (cap ${r.cap}/run)</div>` : "");
    pick(state.db);
  };
};

/* ---------------- toolbar (all buttons do something real) ------------- */
window.lastReply = null;
$("t-new").onclick = newChat;
$("t-learn").onclick = async () => {
  const d = await api("/api/notebook", { limit: 100, kind: "learning" });
  openModal(`<h2>🧠 Learnings</h2>` + (d.entries.length
    ? d.entries.slice().reverse().map(e => `<div class="edge-row">${esc(e.text)}
        <div class="when">${(e.at || "").slice(0, 19)}</div></div>`).join("")
    : '<div class="empty">no learnings journaled yet</div>'));
};
$("learnings").onclick = $("t-learn").onclick;
$("t-rules").onclick = async () => {
  const r = await api("/api/rules", {});
  const rel = list => list.map(x =>
    `<div class="edge-row"><span class="rel">${x.relation}</span> ${x.source} → ${x.target}</div>`).join("");
  openModal(`<h2>📜 Rules — the floor's law</h2>
    <div class="sub">Rendered from the schema constants — this cannot drift from the code.</div>
    <h2 style="margin-top:10px">Core relations</h2>${rel(r.core_relations)}
    <h2 style="margin-top:10px">Extraction relations</h2>${rel(r.extraction_relations)}
    <h2 style="margin-top:10px">Laws</h2>` +
    r.laws.map(l => `<div class="edge-row">${esc(l)}</div>`).join("") +
    `<h2 style="margin-top:10px">Allowlisted hosts</h2>
     <div class="sub">${r.allowlisted_hosts.join(" · ")}</div>`);
};
$("rulesbtn").onclick = $("t-rules").onclick;
$("t-sources").onclick = async () => {
  const s = await api("/api/sources", { db: state.db });
  openModal(`<h2>🌐 Where the data came from — ${esc(state.db)}</h2>` +
    s.sources.map(x => `<div class="edge-row"><b>${x.source}</b> · ${x.edges} edges
      <div class="sub">${Object.entries(x.hosts).map(([h, c]) => `${h} (${c})`).join(" · ")}</div>
      <div class="when">${(x.first_retrieved || "").slice(0, 19)} → ${(x.last_retrieved || "").slice(0, 19)}</div>
    </div>`).join(""));
};
$("t-notebook").onclick = () => showTab("notebook");
$("t-raw").onclick = () => openModal(`<h2>&lt;/&gt; Last reply — raw</h2>
  <pre style="white-space:pre-wrap;font-size:12px">${esc(JSON.stringify(window.lastReply, null, 2)
    || "no reply yet")}</pre>`);
$("t-theme").onclick = () => {
  document.body.classList.toggle("light");
  localStorage.setItem("loisTheme", document.body.classList.contains("light") ? "light" : "dark");
};
if (localStorage.getItem("loisTheme") === "light") document.body.classList.add("light");
$("t-find").onclick = () => $("nodesearch").focus();
$("t-focus").onclick = () => document.body.classList.toggle("focus");

$("t-history").onclick = async () => {
  const d = await api("/api/chats", {});
  openModal(`<h2>🕰 Conversation history</h2>` + (d.chats.length
    ? d.chats.map(c => `<div class="edge-row" style="cursor:pointer"
        onclick="openChat('${c.id}');document.getElementById('modal').style.display='none'">
        ${esc(c.title)}<div class="when">${(c.created_at || "").replace("T", " ").slice(0, 16)}</div>
      </div>`).join("")
    : '<div class="empty">no conversations yet</div>'));
};

$("t-run").onclick = async () => {
  const s = await api("/api/session", {});
  if (s.running) {
    openModal(`<h2>▶ Session running (pid ${s.pid})</h2>
      <pre style="white-space:pre-wrap;font-size:12px">${esc(s.log_tail)}</pre>
      <div class="sub">Watch it dictate live in the Notebook tab.</div>`);
    return;
  }
  const r = await fetch("/api/session", { method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ db: state.db }) }).then(x => x.json());
  openModal(r.error
    ? `<h2>▶ Run session</h2><div class="empty">${esc(r.error)}</div>`
    : `<h2>▶ Session started (pid ${r.pid})</h2>
       <div class="sub">Full loop on ${esc(state.db)}: extract → claims →
       probes → discovery → ponder. Open the Notebook tab to watch it
       dictate in real time.</div>`);
  showTab("notebook");
};

$("t-report").onclick = async () => {
  const r = await api("/api/report", {});
  openModal(`<h2>📖 Latest session report</h2>` + (r.md
    ? `<pre style="white-space:pre-wrap;font-size:12px">${esc(r.md)}</pre>`
    : `<div class="empty">${esc(r.note)}</div>`));
};

$("t-diag").onclick = async () => {
  const d = await api("/api/diagnostics", { db: state.db });
  openModal(`<h2>🔧 Diagnostics — ${esc(state.db)}</h2>` +
    d.checks.map(c => `<div class="edge-row">${c.ok ? "✅" : "❌"}
      <b>${esc(c.check)}</b><div class="when">${esc(c.detail)}</div></div>`).join("") +
    `<div class="sub" style="margin-top:8px">${Object.entries(d.counts)
      .map(([k, v]) => `${k} ${v}`).join(" · ")}</div>`);
};

$("t-teach").onclick = async () => {
  const r = await api("/api/rules", {});
  const rels = [...r.core_relations, ...r.extraction_relations];
  openModal(`<h2>✏️ Teach — a cited manual edge</h2>
    <div class="sub">Same validation as every edge: fixed direction, typed
    nodes, functional veto. The citation IS the provenance.</div>
    <div style="display:grid;gap:6px;margin:10px 0">
      <input type="text" id="tsubj" placeholder="subject, e.g. protein:P69905">
      <select id="trel">${rels.map(x =>
        `<option value="${x.relation}">${x.relation} (${x.source} → ${x.target})</option>`).join("")}</select>
      <input type="text" id="tobj" placeholder="object, e.g. domain:globin">
      <input type="text" id="tcite" placeholder="citation, e.g. PMID:12345678">
    </div><button class="btn" id="tgo">Teach</button><div id="tout"></div>`);
  $("tgo").onclick = async () => {
    const out = await fetch("/api/teach", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ db: state.db, subject: $("tsubj").value,
        relation: $("trel").value, object: $("tobj").value,
        citation: $("tcite").value }) }).then(x => x.json());
    $("tout").innerHTML = out.ok
      ? `<div class="edge-row">✅ ${out.created ? "written" : "already known"} — edge ${out.edge_id.slice(0, 8)}</div>`
      : `<div class="edge-row">❌ rejected: ${esc(out.rejected || out.error)}</div>`;
    if (out.ok) pick(state.db);
  };
};

$("t-hypo").onclick = () => {
  openModal(`<h2>🧪 Hypothesis — a claim through the gate</h2>
    <div class="sub">Name a protein; the proposer shapes the claim, the floor
    verdicts it: SUPPORTED / CONFLICTING / UNKNOWN.</div>
    <input type="text" id="hsubj" placeholder="e.g. P68871 or “myoglobin”"
      style="width:100%;margin:10px 0">
    <button class="btn" id="hgo">Ask the floor</button><div id="hout"></div>`);
  $("hgo").onclick = async () => {
    $("hgo").disabled = true;
    const d = await fetch("/api/research", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ db: state.db, model: $("modelsel").value,
        prompt: `Verify the structural consistency of ${$("hsubj").value}.` }) })
      .then(x => x.json());
    $("hgo").disabled = false;
    window.lastReply = d;
    $("hout").innerHTML = d.admitted === "claim"
      ? `<div class="edge-row">verdict: <b>${(d.verdict || {}).verdict}</b>
         (${((d.verdict || {}).trace || []).length} evidence edges)</div>`
      : `<div class="edge-row">${d.admitted}: ${esc(d.error || (d.proposal || {}).reason || "")}</div>`;
  };
};

$("t-doc").onclick = () => {
  openModal(`<h2>📄 Document scan</h2>
    <div class="sub">Paste any text (abstract, notes, references). Lois finds
    accession-shaped tokens and curated protein names — candidates only;
    importing is your click. Binary PDF parsing is not pretended.</div>
    <textarea id="dtext" rows="7" style="width:100%;margin:8px 0;background:var(--bg);
      color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px"></textarea>
    <button class="btn" id="dscan">Scan</button><div id="dout"></div>`);
  $("dscan").onclick = async () => {
    const d = await fetch("/api/docscan", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: $("dtext").value }) }).then(x => x.json());
    $("dout").innerHTML = d.candidates.length
      ? d.candidates.map(c => `<div class="edge-row">${c.accession}
          <span class="when">${esc(c.why)}</span></div>`).join("") +
        `<button class="btn" id="dimp" style="margin-top:8px">Import all (cap 10)</button>`
      : '<div class="empty">no candidates found</div>';
    const b = $("dimp");
    if (b) b.onclick = async () => {
      const r = await fetch("/api/import", { method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ db: state.db,
          accessions: d.candidates.map(c => c.accession),
          libraries: selectedLibraries() }) }).then(x => x.json());
      $("dout").innerHTML = r.results.map(x =>
        `<div class="edge-row">${x.accession} — <b>${x.status}</b>${
          x.edges_written != null ? ` · ${x.edges_written} new edges` : ""}</div>`).join("");
      pick(state.db);
    };
  };
};

$("t-rec").onclick = async () => {
  if (!state.chatId) { openModal("<h2>⏺ Export</h2><div class='empty'>no conversation open</div>"); return; }
  const d = await api("/api/chat", { id: state.chatId });
  const md = d.turns.map(t =>
    (t.role === "user" ? "**You:** " : `**Lois (${t.kind}):** `) + t.text).join("\n\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([md], { type: "text/markdown" }));
  a.download = `lois-chat-${state.chatId}.md`;
  a.click();
};

/* ---------------- model switcher ---------------- */
async function loadModels() {
  const d = await api("/api/models", {});
  const sel = $("modelsel");
  sel.innerHTML = "";
  if (!d.models.length) { sel.add(new Option("model runtime down", "")); return; }
  for (const m of d.models) sel.add(new Option(m, m));
  sel.value = d.models.includes("floor-proposer") ? "floor-proposer" : d.models[0];
}

/* ---------------- research libraries picker ---------------- */
let LIBS = [];
function selectedLibraries() {
  const boxes = [...document.querySelectorAll("#libbox input[type=checkbox]")];
  if (!boxes.length) return null;
  const on = boxes.filter(b => b.checked).map(b => b.value);
  return on.length === boxes.length ? null : on;   // null = all (default)
}
async function loadLibraries() {
  const d = await api("/api/libraries", {});
  LIBS = d.libraries;
  const saved = JSON.parse(localStorage.getItem("loisLibs") || "null");
  $("libbox").innerHTML = LIBS.map(l => `<label class="librow" title="${esc(l.role)}">
      <input type="checkbox" value="${l.key}"
        ${l.required ? "checked disabled" : ""}
        ${!l.required && saved && !saved.includes(l.key) ? "" : "checked"}>
      <b>${esc(l.name)}</b> <span class="when">${esc(l.host)}</span>
      ${l.required ? '<span class="when">(root — always on)</span>' : ""}
      <div class="sub">${esc(l.role)}</div>
    </label>`).join("");
  document.querySelectorAll("#libbox input").forEach(b => b.onchange = () => {
    const on = [...document.querySelectorAll("#libbox input")]
      .filter(x => x.checked).map(x => x.value);
    localStorage.setItem("loisLibs", JSON.stringify(on));
  });
}

loadLibraries();
loadModels();
pollHealth();
loadChats();
loadDbs();


/* ---------------- scientist lane (terminal feeds the dashboard) ---------------- */
const SCI_STATE_COLORS = { PROPOSED: "#8b949e", TESTABLE: "#58a6ff",
  EXPERIMENTING: "#d29922", SUPPORTED: "#3fb950", CONTESTED: "#d29922",
  REJECTED: "#f85149", REVISED: "#a371f7" };

async function loadScientist() {
  const data = await fetch("/api/scientist/runs").then(r => r.json());
  const box = $("sciruns");
  if (!data.runs.length) {
    box.innerHTML = `<div class="empty" style="padding:14px">no scientist runs found under
      ${data.roots.join(" · ")} — run one in the terminal
      (<code>python3 run_live.py</code>) and refresh</div>`;
    $("scidetail").innerHTML = "";
    return;
  }
  box.innerHTML = data.runs.map(r => `
    <div class="src sci-run" data-name="${r.name}" style="cursor:pointer">
      <div class="name">🧪 ${r.name}
        <b style="float:right;color:${r.integrity === "ok" ? "#3fb950" : "#f85149"}">
          ${r.integrity === "ok" ? "chain ✓" : "⚠ " + r.integrity}</b></div>
      <div class="host">${r.integrity === "ok"
        ? `${r.hypotheses} hypotheses · ${r.experiments} experiments · ` +
          `${r.credited} credited · ${r.events} chained events`
        : r.path}</div>
    </div>`).join("");
  for (const el of box.querySelectorAll(".sci-run"))
    el.onclick = () => showScientistRun(el.dataset.name);
  showScientistRun(data.runs[0].name);
}

async function showScientistRun(name) {
  const d = await fetch("/api/scientist/run?name=" + encodeURIComponent(name))
    .then(r => r.json());
  const box = $("scidetail");
  if (d.integrity !== "ok") {
    box.innerHTML = `<div class="empty" style="padding:14px">⚠ ${name}: ${d.integrity}</div>`;
    return;
  }
  const stateChip = s => `<b style="color:${SCI_STATE_COLORS[s] || "#8b949e"}">${s}</b>`;
  const hyps = d.hypotheses.map(h => `
    <tr><td>${stateChip(h.state)}</td>
      <td>${h.statement}
        ${h.assumptions.length ? `<div class="sub">assumes: ${h.assumptions.join(" · ")}</div>` : ""}
      </td>
      <td class="sub">${h.origin}</td>
      <td>${h.passed}✓ ${h.refuted}✗ ${h.inconclusive}∅</td></tr>`).join("");
  const exps = d.experiments.map(e => `
    <tr><td>${e.question}</td><td class="sub">${e.adapter}</td>
      <td>${e.verdicts.map(v =>
        `<div>${v.outcome === "PASSED" ? "✓" : v.outcome === "REFUTED" ? "✗" : "∅"}
          predicted <code>${JSON.stringify(v.predicted)}</code> · actual
          <code>${JSON.stringify(v.actual)}</code></div>`).join("")}</td>
      <td class="sub">${e.receipt ? "receipt " + e.receipt.raw_digest.slice(0, 12) + "…" : "no receipt"}</td></tr>`).join("");
  const credits = d.knowledge_credits.map(c =>
    `<div class="sub">${c.credited ? "🟢 CREDITED" : "⚪ withheld"} — ${c.reason}</div>`).join("");
  box.innerHTML = `
    <div class="sub" style="margin:8px 0">${d.events} events · head
      <code>${d.head_sha.slice(0, 16)}…</code> · ${d.path}</div>
    <table class="ledger"><thead><tr><th>State</th><th>Hypothesis</th>
      <th>Origin</th><th>Verdicts</th></tr></thead><tbody>${hyps}</tbody></table>
    <h3 style="margin:14px 0 6px">Experiments</h3>
    <table class="ledger"><thead><tr><th>Question</th><th>Adapter</th>
      <th>Verdicts (pre-registered vs receipt)</th><th>Receipt</th></tr></thead>
      <tbody>${exps}</tbody></table>
    <h3 style="margin:14px 0 6px">Knowledge credit</h3>${credits}`;
}
if (document.getElementById("scirefresh"))
  $("scirefresh").onclick = () => loadScientist();
