/* Symbolic subject resolver — live, client-side, deterministic.
 *
 * A faithful browser port of the research floor's proposer/resolver.py:
 * a protein subject exists ONLY if the user's own words ground it — a literal
 * UniProt accession, or a curated-name match (word-boundary, longest-first,
 * extension-word-blocked so "cytochrome c oxidase" never binds "cytochrome c").
 * None grounded, or ambiguous -> abstain. Exactly one -> bind.
 *
 * No model. No network. This is the anti-hallucination layer itself, running
 * in your browser. The canonical implementation is Python; this port exists so
 * a visitor can try to break it by hand. It cannot invent a subject the text
 * did not ground — the one proposer failure the floor could not otherwise
 * catch (a well-formed proposal about the WRONG protein) is impossible here.
 */
(() => {
  "use strict";
  if (window.__resolverDemoMounted) return;
  window.__resolverDemoMounted = true;

  // Curated, verified name -> accession mappings (textbook proteins; public
  // facts, not a moat). Mirrors KNOWN_PROTEINS in the floor's dataset.py.
  const KNOWN = {
    "hemoglobin alpha": "P69905",
    "hemoglobin subunit alpha": "P69905",
    "p53": "P04637",
    "tumor protein p53": "P04637",
    "human serum albumin": "P02768",
    "insulin": "P01308",
    "lysozyme c": "P61626",
    "myoglobin": "P02144",
    "cytochrome c": "P99999",
    "ubiquitin": "P0CG48",
  };
  const NAMES = Object.keys(KNOWN).sort((a, b) => b.length - a.length);

  // A curated-name match is void when the next word extends it into a
  // DIFFERENT protein ("insulin receptor", "cytochrome c oxidase").
  const EXT = new Set(["receptor", "receptors", "subunit", "ligase", "oxidase",
    "kinase", "reductase", "synthase", "phosphatase", "protein", "alpha",
    "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "kappa",
    "sigma", "omega", "ii", "iii", "iv", "like", "variant", "precursor",
    "isoform", "homolog", "family", "chain", "complex"]);

  // Standard UniProt accession forms (6 or 10 chars) — same shape as the
  // floor's _ACCESSION_RE.
  const ACC_RE =
    /\b([OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9](?:[A-Z][A-Z0-9]{2}[0-9]){1,2})\b/gi;

  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  // Grounding: every accession the user's own words justify, plus a trace of
  // curated names bound and curated names SEEN but blocked as extensions.
  function analyze(text) {
    const low = text.toLowerCase();
    const grounded = new Set();
    const curated = [];
    const blocked = [];
    for (const name of NAMES) {
      const re = new RegExp("\\b" + esc(name) + "\\b", "g");
      let m;
      while ((m = re.exec(low))) {
        const rest = low.slice(m.index + m[0].length);
        const nx = rest.match(/^[\s-]+(\w+)/);
        if (nx && EXT.has(nx[1])) { blocked.push({ name, ext: nx[1] }); continue; }
        if (!grounded.has(KNOWN[name])) curated.push({ name, acc: KNOWN[name] });
        grounded.add(KNOWN[name]);
        break;
      }
    }
    const literal = [];
    let a;
    ACC_RE.lastIndex = 0;
    while ((a = ACC_RE.exec(text))) {
      const acc = a[1].toUpperCase();
      if (!literal.includes(acc)) literal.push(acc);
      grounded.add(acc);
    }
    return { grounded, curated, blocked, literal };
  }

  // Verdict: resolve() collapsed to the grounding decision. pass/repair both
  // reduce to "the floor accepts exactly the grounded subject"; 0 or >1 -> abstain.
  function verdict(g) {
    if (g.size === 0) return { kind: "abstain", why: "empty" };
    if (g.size === 1) return { kind: "bind", acc: [...g][0] };
    return { kind: "abstain", why: "ambiguous" };
  }

  const ZH = document.documentElement.lang === "zh-Hans";
  const T = ZH ? {
    title: "🛡️ 不会幻觉的那道线",
    tag: "实时 · 确定性 · 在你的浏览器中运行 · 无需模型",
    intro: "只有当你的措辞给它落地时，蛋白质主体才成立 —— 一个真实的 UniProt 编号，或一个规范名称。输入一个请求，看符号层将它绑定，或拒绝猜测。",
    ph: "例如：verify hemoglobin alpha",
    go: "落地",
    tryLabel: "试试：",
    groundedLabel: "已落地的主体",
    blockedLabel: "看到但未绑定",
    bind: "绑定",
    bindNote: (a) => `主体依据你的请求钉定为 ${a}。模型可以提议任何编号；底座会把错误的猜测修正为它 —— 或直接拒绝。它无法替换成另一种蛋白质。`,
    abstain: "弃权",
    emptyNote: "此请求中没有落地的蛋白质。模型在这里给出的任何编号都是猜测 —— 底座拒绝它。",
    ambigTag: "弃权 · 有歧义",
    ambigNote: "落地了不止一种蛋白质，且没有指明其中之一。底座不会猜你指的是哪一个。",
    howLiteral: "字面编号",
    howCurated: "规范名称",
    blk: (n, e) => `“${n}” → 被拦截（扩展词：${e}）`,
    foot: "底座解析器的忠实浏览器移植。规范层为 Python —— 这个放在这里，让你亲手把它推到极限。",
  } : {
    title: "🛡️ The line that can’t hallucinate",
    tag: "Live · deterministic · runs in your browser · no model",
    intro: "A protein subject exists only if your words ground it — a real UniProt accession, or a curated name. Type a request and watch the symbolic layer bind it, or refuse to guess.",
    ph: "e.g. Verify hemoglobin alpha",
    go: "Ground it",
    tryLabel: "Try:",
    groundedLabel: "Grounded subjects",
    blockedLabel: "Seen but not bound",
    bind: "BIND",
    bindNote: (a) => `The subject is pinned to ${a} from your request. A model may propose any accession; the floor repairs a wrong guess to this one — or rejects it. It cannot substitute a different protein.`,
    abstain: "ABSTAIN",
    emptyNote: "No protein is grounded in this request. Any accession a model emitted here would be a guess — the floor refuses it.",
    ambigTag: "ABSTAIN · ambiguous",
    ambigNote: "More than one protein is grounded and none is singled out. The floor won’t guess which you meant.",
    howLiteral: "literal accession",
    howCurated: "curated name",
    blk: (n, e) => `“${n}” → blocked (extension word: ${e})`,
    foot: "Faithful browser port of the floor’s resolver. The canonical layer is Python — this one is here so you can try to break it yourself.",
  };

  const EXAMPLES = [
    "Verify hemoglobin alpha",
    "Pull the evidence for P68871",
    "Does glorbulin-7 have a validated structure?",
    "Verify cytochrome c oxidase",
    "Compare insulin and myoglobin",
  ];

  const STYLE = `
  .rz-card{background:linear-gradient(180deg,#0f1a24,#0c141d);border:1px solid #24405a;
    border-radius:10px;margin:10px;padding:12px 13px;
    font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#c3ccd8;
    box-shadow:0 0 0 1px rgba(130,222,207,.06),0 10px 24px rgba(0,0,0,.35)}
  .rz-card h3{margin:0 0 2px;font-size:14px;color:#eaf3f0;font-weight:650;letter-spacing:.2px}
  .rz-tag{font-size:10.5px;color:#5fb2a0;text-transform:uppercase;letter-spacing:.7px;margin-bottom:7px}
  .rz-intro{font-size:12px;color:#8f9cac;line-height:1.5;margin-bottom:9px}
  .rz-row{display:flex;gap:6px;margin-bottom:8px}
  .rz-row input{flex:1;background:#070d14;border:1px solid #2a3a4c;
    border-radius:7px;color:#e6edf5;padding:8px 10px;font-size:13px;outline:none}
  .rz-row input:focus{border-color:#3d7fb5}
  .rz-go{background:#122a3a;border:1px solid #2f5f80;color:#8fd8ff;border-radius:7px;
    padding:0 14px;font-size:13px;font-weight:600;cursor:pointer;white-space:nowrap}
  .rz-go:hover{background:#173547}
  .rz-ex{display:flex;flex-wrap:wrap;gap:5px;align-items:center;margin-bottom:4px}
  .rz-ex .rz-lbl{font-size:11px;color:#6c7889}
  .rz-chip{background:#0e1a24;border:1px solid #274056;color:#9fd0e6;border-radius:20px;
    padding:3px 9px;font-size:11px;cursor:pointer}
  .rz-chip:hover{background:#13293a;border-color:#3a6a8c}
  .rz-out{margin-top:10px}
  .rz-block-lbl{font-size:11px;color:#7d8697;margin:8px 0 3px;text-transform:uppercase;letter-spacing:.5px}
  .rz-sub{display:inline-flex;align-items:center;gap:6px;background:#0b1922;border:1px solid #2b5a4e;
    border-radius:7px;padding:4px 9px;margin:0 5px 5px 0;font-size:12px}
  .rz-sub b{color:#7ff0d3;font-weight:650;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  .rz-how{font-size:10.5px;color:#6f95a0}
  .rz-blocked{font-size:11.5px;color:#c79a55;margin:2px 0}
  .rz-blocked s{color:#8a7a55;text-decoration-color:#8a5a3a}
  .rz-verdict{margin-top:10px;border-radius:8px;padding:9px 11px;font-size:12px;line-height:1.5}
  .rz-verdict .rz-vtag{font-size:13px;font-weight:750;letter-spacing:.5px;margin-bottom:3px;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  .rz-bind{background:rgba(52,209,168,.08);border:1px solid #2f6f5c}
  .rz-bind .rz-vtag{color:#57e6bd}
  .rz-abstain{background:rgba(224,163,62,.08);border:1px solid #7a5f2f}
  .rz-abstain .rz-vtag{color:#e6b24e}
  .rz-foot{margin-top:9px;font-size:10.5px;color:#5c6675;line-height:1.5;border-top:1px solid #1e2a38;padding-top:7px}`;

  function el(tag, cls, html) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }
  const escHtml = (s) => s.replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  function render(out, text) {
    out.textContent = "";
    if (!text.trim()) return;
    const { grounded, curated, blocked, literal } = analyze(text);
    const v = verdict(grounded);

    if (grounded.size) {
      out.appendChild(el("div", "rz-block-lbl", T.groundedLabel));
      const wrap = el("div");
      const seen = new Set();
      for (const c of curated) {
        if (seen.has(c.acc)) continue; seen.add(c.acc);
        wrap.appendChild(el("span", "rz-sub",
          `<b>${c.acc}</b> <span class="rz-how">${T.howCurated}: ${escHtml(c.name)}</span>`));
      }
      for (const acc of literal) {
        if (seen.has(acc)) continue; seen.add(acc);
        wrap.appendChild(el("span", "rz-sub",
          `<b>${acc}</b> <span class="rz-how">${T.howLiteral}</span>`));
      }
      out.appendChild(wrap);
    }

    const shownBlocks = blocked.filter((b) => !grounded.has(KNOWN[b.name]));
    if (shownBlocks.length) {
      out.appendChild(el("div", "rz-block-lbl", T.blockedLabel));
      const seen = new Set();
      for (const b of shownBlocks) {
        const k = b.name + "/" + b.ext;
        if (seen.has(k)) continue; seen.add(k);
        out.appendChild(el("div", "rz-blocked",
          T.blk(`<s>${escHtml(b.name)}</s>`, escHtml(b.ext))));
      }
    }

    const box = el("div", "rz-verdict " + (v.kind === "bind" ? "rz-bind" : "rz-abstain"));
    if (v.kind === "bind") {
      box.appendChild(el("div", "rz-vtag", `${T.bind} → ${v.acc}`));
      box.appendChild(el("div", null, T.bindNote(v.acc)));
    } else if (v.why === "ambiguous") {
      box.appendChild(el("div", "rz-vtag", T.ambigTag));
      box.appendChild(el("div", null, T.ambigNote));
    } else {
      box.appendChild(el("div", "rz-vtag", T.abstain));
      box.appendChild(el("div", null, T.emptyNote));
    }
    out.appendChild(box);
  }

  function build() {
    const card = el("section", "rz-card");
    card.appendChild(el("h3", null, T.title));
    card.appendChild(el("div", "rz-tag", T.tag));
    card.appendChild(el("div", "rz-intro", T.intro));

    const row = el("div", "rz-row");
    const input = el("input");
    input.type = "text";
    input.placeholder = T.ph;
    input.setAttribute("aria-label", T.title);
    const go = el("button", "rz-go", T.go);
    row.appendChild(input);
    row.appendChild(go);
    card.appendChild(row);

    const ex = el("div", "rz-ex");
    ex.appendChild(el("span", "rz-lbl", T.tryLabel));
    for (const e of EXAMPLES) {
      const chip = el("span", "rz-chip", escHtml(e));
      chip.addEventListener("click", () => { input.value = e; render(out, e); input.focus(); });
      ex.appendChild(chip);
    }
    card.appendChild(ex);

    const out = el("div", "rz-out");
    card.appendChild(out);
    card.appendChild(el("div", "rz-foot", T.foot));

    const run = () => render(out, input.value);
    go.addEventListener("click", run);
    input.addEventListener("input", run);
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") run(); });

    // Seed with the fictional example so the abstain behavior is visible at rest.
    input.value = EXAMPLES[2];
    render(out, input.value);
    return card;
  }

  function mount() {
    const style = el("style");
    style.textContent = STYLE;
    document.head.appendChild(style);
    const card = build();
    // First-class "Resolver" tab — not the sidebar (Luke: it's the demo's
    // headline asset for the Yale pilots & VCs, not clutter). Fall back to the
    // PEEL rail only if the tab container isn't present (older shells).
    const host = document.getElementById("resolverview")
      || document.getElementById("peelcol")
      || document.getElementById("presearch");
    if (host) {
      host.insertBefore(card, host.firstChild);
    } else {
      card.style.cssText = "position:fixed;right:14px;bottom:14px;max-width:360px;z-index:9999";
      document.body.appendChild(card);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }
})();
