"use strict";
/* CalendarLane — the science calendar for the dashboard center lane.
   Month grid over /api/calendar day rollups; click a day for /api/day
   detail (digest → notebook entries → recorder line); "update now"
   pokes /api/partner/tick and re-fetches. All month arithmetic is done
   by hand from the "YYYY-MM" string — no ISO-string Date parsing.

   Uses globals from app.js: $, api(path, params), state.db, esc.
   Wiring (tab button + container) lives elsewhere; this file only
   defines the global CalendarLane { mount, unmount, isMounted }. */

window.CalendarLane = (() => {

  /* ---------------- constants ---------------- */
  const KIND_DOT = { observation: "#58a6ff", discovery: "#4cc38a",
    learning: "#f5a623", anomaly: "#e5534b", reflection: "#b083f0" };
  const KIND_ORDER = ["observation", "discovery", "learning", "anomaly", "reflection"];
  // reuse the existing .kind-* chip classes (same mapping as the notebook view)
  const KIND_BADGE = { observation: "node", discovery: "edge", learning: "claim",
                       anomaly: "tile", reflection: "sequence" };
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July",
                  "August", "September", "October", "November", "December"];
  const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const HEAT_CAP = 40;          // recorded observations at which the tint saturates
  const HEAT_MAX_ALPHA = 0.22;  // even a saturated day stays a subtle tint
  const REFRESH_MS = 60000;
  const FLASH_MS = 6000;
  const BANNER = "auto-notes and daily digests are deterministic rollups of the " +
    "science recorder — model-free; every auto-note refs its exact observation " +
    "range; your personal LIST is never read";

  /* ---------------- module state ---------------- */
  let root = null;         // container element while mounted
  let timer = null;        // 60s auto-refresh interval
  let flashTimer = null;
  let month = null;        // shown month, "YYYY-MM"
  let monthDays = {};      // days map from the last /api/calendar fetch
  let selDate = null;      // open day "YYYY-MM-DD" | null
  let monthReq = 0;        // stale-response guards (bumped per request + on unmount)
  let dayReq = 0;

  /* ------------- month math, by hand from "YYYY-MM" -------------
     Hand-verified:
       shiftMonth("2026-01", -1): total = 2026*12 + 0 - 1 = 24311
         → floor(24311/12) = 2025, 24311 % 12 = 11 → "2025-12"   (year boundary back)
       shiftMonth("2025-12", +1): total = 2025*12 + 11 + 1 = 24312
         → 2026, remainder 0 → "2026-01"                          (year boundary fwd)
       daysInMonth("2026-02") → 2026 not leap → 28
       daysInMonth("2024-02") → 2024 % 4 = 0, not % 100 → 29
       daysInMonth("2100-02") → % 100 = 0, not % 400 → 28
       firstWeekdayMon0("2026-09") → new Date(2026, 8, 1) is a Tuesday
         → (2 + 6) % 7 = 1 (Mon-first index)                                    */
  const pad2 = n => String(n).padStart(2, "0");
  const ymParts = ym => ym.split("-").map(Number);        // "2026-09" → [2026, 9]
  const isLeap = y => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const DIM = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  const daysInMonth = ym => {
    const [y, m] = ymParts(ym);
    return m === 2 && isLeap(y) ? 29 : DIM[m - 1];
  };
  const shiftMonth = (ym, delta) => {
    const [y, m] = ymParts(ym);
    const total = y * 12 + (m - 1) + delta;               // 0-based month count
    return `${Math.floor(total / 12)}-${pad2(((total % 12) + 12) % 12 + 1)}`;
  };
  const firstWeekdayMon0 = ym => {
    const [y, m] = ymParts(ym);
    // getDay(): 0=Sun … 6=Sat → shift to 0=Mon … 6=Sun
    return (new Date(y, m - 1, 1).getDay() + 6) % 7;
  };
  const monthTitle = ym => { const [y, m] = ymParts(ym); return `${MONTHS[m - 1]} ${y}`; };
  const todayISO = () => {
    const d = new Date();
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  };
  const hhmm = at => String(at || "").slice(11, 16);      // "HH:MM" from ISO

  /* ---------------- skeleton ---------------- */
  const slot = name => root ? root.querySelector(`[data-slot="${name}"]`) : null;

  function skeleton() {
    root.innerHTML = `
      <div class="pad" style="padding-top:12px;max-width:960px">
        <div class="sub" style="border:1px solid var(--line);border-radius:8px;
          padding:6px 10px;margin-bottom:10px">🧾 ${BANNER}</div>
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;flex-wrap:wrap">
          <button class="btn small" data-act="prev" title="previous month">‹</button>
          <b data-slot="title" style="min-width:150px;text-align:center"></b>
          <button class="btn small" data-act="next" title="next month">›</button>
          <button class="btn small" data-act="today">Today</button>
          <span style="flex:1"></span>
          <span class="sub" data-slot="flash"></span>
          <button class="btn" data-act="update" title="run the recorder rollup now">⟳ update now</button>
        </div>
        <div data-slot="grid" style="display:grid;grid-template-columns:repeat(7,1fr);gap:4px"></div>
        <div data-slot="detail"></div>
      </div>`;
  }

  /* ---------------- month grid ---------------- */
  function renderGrid() {
    const grid = slot("grid");
    if (!grid) return;
    slot("title").textContent = monthTitle(month);
    const today = todayISO();
    const cells = WEEKDAYS.map(w =>
      `<div class="sub" style="text-align:center;padding:2px 0">${w}</div>`);
    for (let i = 0; i < firstWeekdayMon0(month); i++) cells.push("<div></div>");
    const last = daysInMonth(month);
    for (let d = 1; d <= last; d++) {
      const date = `${month}-${pad2(d)}`;
      const day = monthDays[date];
      const rec = day ? (day.recorded || 0) : 0;
      const heat = rec > 0
        ? `background:rgba(88,166,255,${(Math.min(rec, HEAT_CAP) / HEAT_CAP * HEAT_MAX_ALPHA).toFixed(3)});`
        : "";
      const border = date === selDate ? "var(--blue)" : "var(--line)";
      const outline = date === today ? "outline:1px solid var(--accent);" : "";
      const dots = day
        ? KIND_ORDER.filter(k => ((day.byKind || {})[k] || 0) > 0).map(k =>
            `<span title="${k}" style="display:inline-block;width:6px;height:6px;` +
            `border-radius:50%;background:${KIND_DOT[k]};margin-right:3px"></span>`).join("")
        : "";
      const tick = day && day.hasDigest
        ? '<span title="daily digest written" style="float:right;color:var(--ok);font-size:10px">✓</span>'
        : "";
      const tip = day ? ` title="${rec} recorded · ${day.notes || 0} notes"` : "";
      cells.push(`<div class="cal-day" data-date="${date}"${tip}
        style="min-height:56px;border:1px solid ${border};border-radius:8px;
        padding:4px 6px;cursor:pointer;${heat}${outline}">
        <span style="font-size:11px;color:${day ? "var(--ink)" : "var(--dim)"}">${d}</span>
        ${tick}<div style="margin-top:4px;line-height:1">${dots}</div></div>`);
    }
    grid.innerHTML = cells.join("");
  }

  async function loadMonth() {
    if (!root) return;
    slot("title").textContent = monthTitle(month);
    if (!state.db) {
      slot("grid").innerHTML =
        '<div class="empty" style="grid-column:1/-1;padding:10px">no mind selected — pick a floor DB first</div>';
      return;
    }
    const req = ++monthReq, forMonth = month;
    let d;
    try { d = await api("/api/calendar", { db: state.db, month: forMonth }); }
    catch (e) { d = { error: String(e) }; }
    if (!root || req !== monthReq || month !== forMonth) return;   // unmounted / stale
    if (d.error) {
      monthDays = {};
      slot("grid").innerHTML =
        `<div class="empty" style="grid-column:1/-1;padding:10px">calendar unavailable — ${esc(d.error)}</div>`;
      return;
    }
    monthDays = d.days || {};
    renderGrid();
  }

  /* ---------------- day detail ---------------- */
  async function loadDay(date, silent) {
    if (!root || !state.db) return;
    selDate = date;
    renderGrid();                                   // show the selection ring
    const box = slot("detail");
    if (!silent) box.innerHTML =
      `<div class="sub" style="padding:8px 0">loading ${date}…</div>`;
    const req = ++dayReq;
    let d;
    try { d = await api("/api/day", { db: state.db, date }); }
    catch (e) { d = { error: String(e) }; }
    if (!root || req !== dayReq) return;            // unmounted / stale
    if (d.error) {
      slot("detail").innerHTML =
        `<div class="empty" style="padding:8px 0">day unavailable — ${esc(d.error)}</div>`;
      return;
    }
    renderDay(d);
  }

  function renderDay(d) {
    const digest = d.digest
      ? `<div class="edge-row"><span class="kind kind-claim">digest</span>
           ${esc(d.digest.text)}
           <div class="when">${hhmm(d.digest.at)}${d.digest.session ? " · " + esc(d.digest.session) : ""}</div>
         </div>`
      : '<div class="sub" style="padding:6px 0">no digest yet — digests write themselves after the day closes</div>';
    const entries = (d.entries || []).map(e => `<div class="edge-row">
        <span class="kind kind-${KIND_BADGE[e.kind] || "tile"}">${esc(e.kind)}</span>
        <span class="when">${hhmm(e.at)}</span> ${esc(e.text)}
        ${e.session ? `<span class="when"> · ${esc(e.session)}</span>` : ""}
        ${e.refs && e.refs.length
          ? `<div class="when">refs: ${e.refs.slice(0, 6).map(r => esc(String(r).slice(0, 26))).join(", ")}${e.refs.length > 6 ? " …" : ""}</div>`
          : ""}
      </div>`).join("");
    const rec = d.recorder || {};
    const topSubjects = Object.entries(rec.by_subject || {})
      .sort((a, b) => b[1] - a[1]).slice(0, 3)
      .map(([s, c]) => `${esc(s)} (${c})`).join(" · ");
    slot("detail").innerHTML = `<div class="card" style="margin:12px 0 0">
      <h2>${esc(d.date)}</h2>
      ${digest}
      ${entries || '<div class="sub" style="padding:6px 0">no notebook entries this day</div>'}
      <div class="when" style="margin-top:8px;white-space:normal">science recorder:
        ${rec.total || 0} observations${topSubjects ? " · " + topSubjects : ""}</div>
    </div>`;
  }

  /* ---------------- "update now" (recorder tick) ---------------- */
  function flash(text) {
    const el = slot("flash");
    if (!el) return;
    el.textContent = text;
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => {
      const e2 = slot("flash");
      if (e2) e2.textContent = "";
    }, FLASH_MS);
  }

  async function updateNow() {
    const btn = root.querySelector('[data-act="update"]');
    if (btn) btn.disabled = true;
    let line;
    try {
      const r = await fetch("/api/partner/tick", { method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}) }).then(x => x.json());
      line = r.line || r.error || "tick complete";
    } catch (e) { line = "update failed: " + e; }
    if (!root) return;                              // unmounted mid-flight
    const b2 = root.querySelector('[data-act="update"]');
    if (b2) b2.disabled = false;
    flash(line);
    await loadMonth();
    if (selDate) await loadDay(selDate, true);
  }

  /* ---------------- events (one delegated listener) ---------------- */
  function onClick(ev) {
    if (!root) return;
    const act = ev.target.closest("[data-act]");
    if (act && root.contains(act)) {
      const a = act.dataset.act;
      if (a === "prev") { month = shiftMonth(month, -1); loadMonth(); }
      else if (a === "next") { month = shiftMonth(month, 1); loadMonth(); }
      else if (a === "today") {
        month = todayISO().slice(0, 7);
        loadMonth();
        loadDay(todayISO());
      }
      else if (a === "update") updateNow();
      return;
    }
    const cell = ev.target.closest(".cal-day");
    if (cell && root.contains(cell) && cell.dataset.date) loadDay(cell.dataset.date);
  }

  /* ---------------- lifecycle ---------------- */
  function mount(containerEl) {
    if (root) unmount();          // double-mount guard: never two intervals
    root = containerEl;
    month = todayISO().slice(0, 7);
    selDate = null;
    monthDays = {};
    skeleton();
    root.addEventListener("click", onClick);
    loadMonth();
    timer = setInterval(() => {   // auto-refresh the shown month while mounted
      loadMonth();
      if (selDate) loadDay(selDate, true);
    }, REFRESH_MS);
  }

  function unmount() {
    clearInterval(timer); timer = null;
    clearTimeout(flashTimer); flashTimer = null;
    monthReq++; dayReq++;         // drop any in-flight responses
    if (root) {
      root.removeEventListener("click", onClick);
      root.innerHTML = "";
    }
    root = null;
    selDate = null;
    monthDays = {};
  }

  const isMounted = () => !!root;

  return { mount, unmount, isMounted };
})();
