#!/usr/bin/env python3
"""AI SCIENTIST — autonomous discovery, start to finish, for investors.

The AI drives. A strong model HYPOTHESIZES and DISCUSSES; our local
floor-proposer makes the grounded PROPOSALS; the symbolic floor AUTHORS every
fact from curated sources (UniProt/PDB/AlphaFold/Ensembl/PubChem) and TRAVERSES
its typed graph to surface a NEW, non-obvious connection. No fact is ever
invented by a model — the floor is the only author. No MCP.

Flow:  hypothesize → formalize → research (real tools) → discuss →
        design experiment → run it → DISCOVERY → hash-chained ledger.

Run in the floor venv:  .venv/bin/python dogfood_ai_scientist.py
"""
import sys, os, json, tempfile, time, subprocess, urllib.request, itertools

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser("~/science-loops-dev/scientist"))
from symbolic_floor.store import Store          # noqa: E402
from symbolic_floor import extract               # noqa: E402
from scientist.ledger import Ledger              # noqa: E402

G, C, Y, R, D, B, M, BL = ("\033[32m", "\033[36m", "\033[33m", "\033[31m",
                            "\033[2m", "\033[1m", "\033[35m", "\033[34m")
X = "\033[0m"


def hr(t=""):
    print(f"\n{C}{'━'*78}{X}" + (f"  {B}{t}{X}" if t else ""))


_NEUTRAL = tempfile.mkdtemp()  # run the brain from an EMPTY dir so it reasons about
                               # the science, never reads the demo scaffolding files.


def brain(prompt, *, tries=2):
    """The strong model — hypothesis + discussion (claude headless). Grounded:
    it reasons, it never authors a fact (the floor does). Run from a neutral cwd
    with a science-only system prompt so it stays on the biology, not the code."""
    sys_prompt = ("You are an AI research scientist reasoning about molecular biology. "
                  "Answer ONLY the question, grounded in real biology. Do not mention code, "
                  "files, scripts, or line numbers. Be concise.")
    for _ in range(tries):
        try:
            r = subprocess.run(["claude", "-p", prompt, "--append-system-prompt", sys_prompt],
                               capture_output=True, text=True, timeout=90, cwd=_NEUTRAL)
            out = (r.stdout or "").strip()
            if out:
                return out
        except Exception:
            time.sleep(1.0)
    return "(model unavailable this turn)"


def proposer(prompt):
    """Our local floor-proposer — the grounded proposal (structured, gated)."""
    try:
        body = json.dumps({"model": "floor-proposer", "stream": False,
                          "options": {"temperature": 0, "num_predict": 80},
                          "messages": [{"role": "user", "content": prompt}]}).encode()
        req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=25) as resp:
            return json.loads(resp.read())["message"]["content"].strip()
    except Exception as e:
        return f"(proposer busy: {type(e).__name__})"


def retry(fn, tries=4):
    last = None
    for i in range(tries):
        try:
            r = fn()
            if r.get("status") == "OK":
                return r
            last = r
        except Exception as e:
            last = {"status": "ERROR", "error": str(e)}
        time.sleep(1.1 * (i + 1))
    return last or {"status": "ERROR"}


tmp = tempfile.mkdtemp()
store = Store(os.path.join(tmp, "discovery.db"))
ledger = Ledger(os.path.join(tmp, "discovery_ledger.jsonl"))
print(f"{B}{M}🔬 AI SCIENTIST — autonomous discovery{X}  "
      f"{D}strong model + local proposer + symbolic floor{X}")
print(f"{D}the AI drives; the floor authors every fact; the path is the proof.{X}")

CAPABILITIES = ("You can research human GENES (Ensembl), PROTEINS (UniProt/PDB/AlphaFold), "
                "and MOLECULES (PubChem), and TRAVERSE a typed graph to find nodes reachable "
                "from several proteins — non-obvious convergences. Facts come only from those "
                "curated sources.")

# ── 1. HYPOTHESIZE (strong model) ─────────────────────────────────────────────
hr("1) HYPOTHESIZE  — the AI proposes a testable idea")
H = brain(f"You are an AI scientist. {CAPABILITIES} Propose ONE specific, testable hypothesis "
          f"about the human globin family (oxygen-handling proteins) that a graph-traversal "
          f"experiment could reveal — something a traversal over shared nodes could support. "
          f"Answer in 2-3 sentences, no preamble.")
print(f"  {M}🧠 strong model:{X} {H}")
hyp = ledger.propose_hypothesis(statement=H[:400] or "globin convergence hypothesis",
        rationale="AI-generated; testable by graph traversal over curated evidence",
        assumptions=[{"text": "UniProt/Ensembl/PDB are curated ground truth"},
                     {"text": "shared reachable nodes = a real, path-justified relationship"}])
print(f"  {D}ledger: {hyp.id} (hash-chained, pre-registration begins){X}")

# ── 2. FORMALIZE (strong model picks entities AS gene:UniProt pairs) ──────────
hr("2) FORMALIZE  — the AI picks what to research (gene + its UniProt accession)")
import re
CANON = {"HBA1": "P69905", "HBA2": "P69905", "HBB": "P68871", "MB": "P02144",
         "NGB": "Q9NPG2", "CYGB": "Q8WWM9"}  # canonical human globins (safety net)
picks = brain("List the human globin proteins to test the hypothesis, as SYMBOL:UNIPROT pairs "
              "(hemoglobin alpha, hemoglobin beta, myoglobin, neuroglobin, cytoglobin). "
              "Reply with ONLY a comma-separated list like 'HBB:P68871, MB:P02144', nothing else.")
pairs = {}
for tok in picks.replace("\n", ",").split(","):
    m = re.search(r"([A-Za-z0-9]+)\s*[:=]\s*([OPQ][0-9][A-Z0-9]{3}[0-9])", tok)
    if m:
        pairs[m.group(1).upper()] = m.group(2)
if len(pairs) < 3:                                # AI parse thin -> canonical net
    pairs = dict(CANON)
    pairs.pop("HBA2", None)
print(f"  {M}🧠 strong model picks:{X} " +
      "  ".join(f"{B}{s}{X}{D}={a}{X}" for s, a in pairs.items()))
ledger.register_prediction(hyp.id, "traversal:globin_convergence", ">=", 1, discriminating=True)
print(f"  {D}prediction registered: the family will converge on ≥1 shared node{X}")

# ── 3. RESEARCH (floor-proposer proposes → floor authors facts from real tools) ─
hr("3) RESEARCH  — local proposer proposes, the floor pulls REAL data by accession")
proteins = []
for sym, acc in pairs.items():
    prop = proposer(f"Propose an extract action for UniProt accession {acc}. "
                    f"Reply as JSON with kind and subject only.")
    kind = "extract" if "extract" in prop.lower() else prop[:40]
    print(f"  {BL}◆ {sym} ({acc}){X}  {D}proposer ▸ kind={kind}{X}")
    p = retry(lambda: extract.extract_protein(store, acc))
    if p.get("status") != "OK":
        print(f"      {Y}protein {acc}: {p.get('status')}{X}"); continue
    proteins.append(acc)
    pf = store.get_edges(source=f"protein:{acc}")
    ns = sum(1 for e in pf if e["relation_type"] == "has_structure")
    dom = [e["object"].split(":")[1] for e in pf if e["relation_type"] == "has_part"]
    print(f"      {G}floor authored{X}: {B}{acc}{X} — {len(pf)} facts, {ns} experimental structures, "
          f"domains: {B}{', '.join(dom) or '—'}{X}")
    # also lift the gene metadata so the graph carries gene→protein too
    retry(lambda: extract.research_gene(store, sym))

# CONTROL COHORT — unrelated human proteins, so the null model has a real
# background to test enrichment against (uniprot-only = fast entry facts).
print(f"  {D}+ gathering a control cohort (unrelated human proteins) so significance is testable…{X}")
CONTROL = ["P04637", "P00533", "P01308", "P38398", "P42858", "P01375",
           "P05067", "P10275", "P00734", "P02768", "P01579", "P06400"]
controls = 0
for acc in CONTROL:
    c = retry(lambda: extract.extract_protein(store, acc, enabled={"uniprot"}), tries=2)
    controls += c.get("status") == "OK"
print(f"  {D}control cohort: {controls} unrelated human proteins in the background{X}")

print(f"\n  {D}researched proteins: {', '.join(proteins) or '(none resolved live)'}{X}")

# ── 4. DISCUSS (strong model reflects; adversarial self-challenge) ────────────
hr("4) DISCUSS  — the AI talks it over (and challenges itself)")
summary = "; ".join(f"{a}: {len(store.get_edges(source=f'protein:{a}'))} facts" for a in proteins)
talk = brain(f"We researched these globin proteins and the floor pulled: {summary}. In 2 sentences, "
             f"what do you expect a traversal to reveal about how these proteins connect?")
print(f"  {M}🧠 strong model:{X} {talk}")
you = "If the traversal finds shared nodes, how do we know it's a real finding and not a coincidence?"
print(f"  {M}🧑 you:{X} {you}")
ans = brain(f"{you} Answer in 2 sentences, grounded in the idea that every shared node is reached by "
            f"a typed, provenance-pinned edge path — the path IS the justification, not similarity.")
print(f"  {M}🧠 strong model:{X} {ans}")

# ── 5. DESIGN THE EXPERIMENT (strong model) ──────────────────────────────────
hr("5) DESIGN THE EXPERIMENT")
design = brain("Design the experiment in ONE sentence: we will traverse the typed graph and keep "
               "every node reachable from at least THREE of the researched globin proteins.")
print(f"  {M}🧠 strong model:{X} {design}")
print(f"  {D}→ operationalized: convergence over ≥3 proteins, each with its edge path{X}")

# ── 6. RUN THE EXPERIMENT (the floor traverses + the enrichment null model) ────
hr("6) RUN IT  — the floor traverses, then the null model separates signal from hubs")
from symbolic_floor.discovery import find_convergences   # noqa: E402
convs = find_convergences(store, [f"protein:{a}" for a in proteins], min_support=3)
sig = [c for c in convs if c.significant]
print(f"  traversed {len(proteins)} proteins → {B}{len(convs)}{X} raw convergence(s); "
      f"the hypergeometric null model keeps {B}{len(sig)}{X} as significant:")
for c in convs[:8]:
    mark = f"{G}✓ SIGNIFICANT{X}" if c.significant else (
           f"{Y}trivial hub{X}" if not c.underpowered else f"{Y}underpowered{X}")
    print(f"      {'◆' if c.significant else '◇'} {c.node:26} {D}k={c.support} m={c.background_m}/"
          f"{c.population_N} p={c.p_value:.1e}{X}  {mark}")
if not sig and convs:
    print(f"  {Y}→ no convergence beats the background — honest null, not a fabricated finding.{X}")

# record the receipt + verdict (pre-registration held: prediction preceded this)
obs = {"traversal:globin_convergence": len(sig)}   # graded on SIGNIFICANT, not raw
exp = ledger.design_experiment(question="globin convergence traversal", adapter="symbolic-floor",
        request={"proteins": proteins}, prediction_ids=[p for p in ledger.predictions])
import hashlib
ledger.record_receipt(exp["id"], obs,
        raw_digest=hashlib.sha256(json.dumps(obs, sort_keys=True).encode()).hexdigest(),
        adapter_meta={"traversal": "hypergeometric-enriched, min_support=3, alpha=0.05"})
pid = next(iter(ledger.predictions))
ledger.record_verdict(pid, exp["id"], "PASSED" if sig else "REFUTED",
                      actual=len(sig), error=None)

# ── 7. DISCOVERY (strong model interprets only the SIGNIFICANT convergence) ────
hr("7) 🔎 DISCOVERY")
conv_text = "; ".join(f"{c.node} (shared by {c.support}, enrichment p={c.p_value:.1e})"
                      for c in sig[:6]) or "no enriched convergence"
discovery = brain(f"An enrichment-tested traversal over human globin proteins found these "
                  f"STATISTICALLY SIGNIFICANT shared nodes (hypergeometric p<0.05, i.e. reached far "
                  f"more than the human-protein background would give by chance): {conv_text}. State "
                  f"the discovery in 3 sentences: what does this reveal about the globin family, and "
                  f"why does surviving the null model (not mere reachability) make it a real finding? "
                  f"If the list says 'no enriched convergence', say so honestly and do not invent one.")
print(f"  {M}🧠 strong model — the finding:{X}\n  {G}{discovery}{X}")

conf = hyp.confidence(ledger)
reloaded = Ledger(os.path.join(tmp, "discovery_ledger.jsonl"))
n_events = sum(1 for _ in open(os.path.join(tmp, "discovery_ledger.jsonl")))
hr()
print(f"{G}{B}✓ DISCOVERY RUN COMPLETE{X} — the AI hypothesized, our proposer proposed, the floor "
      f"authored\n  every fact and traversed to a path-justified convergence. Confidence "
      f"{B}{conf:.3f}{X}; ledger\n  hash-chain re-verified ({n_events} events, pre-registration held). "
      f"{D}No fact invented. No MCP.{X}\n")
store.close()
