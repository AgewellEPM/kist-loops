#!/usr/bin/env python3
"""FULL SCIENCE LOOP dogfood — hypothesis → pre-register → research → verdict.

Ties the two systems Luke built together, end to end:
  • the scientist Ledger (hash-chained, append-only, pre-registration ENFORCED
    mechanically — a prediction registered after the result can never be graded)
  • the symbolic floor (native connectors: protein=UniProt/PDB, molecule=PubChem,
    gene=Ensembl — every fact provenance-pinned, no MCP, no model authoring facts)

A cross-domain hypothesis about hemoglobin is pre-registered, then researched by
pulling REAL data through the floor, then each prediction is graded against what
was actually pulled. The hash chain proves the predictions came first.

Run in the floor venv:  .venv/bin/python dogfood_science_loop.py
"""
import sys, os, json, hashlib, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser("~/science-loops-dev/scientist"))  # the scientist pkg

from symbolic_floor.store import Store          # noqa: E402
from symbolic_floor import extract               # noqa: E402
from scientist.ledger import Ledger              # noqa: E402

G, C, Y, R, D, B, M = "\033[32m", "\033[36m", "\033[33m", "\033[31m", "\033[2m", "\033[1m", "\033[35m"
X = "\033[0m"


def hr(t=""):
    print(f"\n{C}{'━'*74}{X}" + (f"  {B}{t}{X}" if t else ""))


def sha(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def retry(fn, tries=4, label=""):
    """Ensembl/PubChem are flaky under the training-network load — retry."""
    last = None
    for i in range(tries):
        try:
            r = fn()
            if r.get("status") == "OK":
                return r
            last = r
        except Exception as e:
            last = {"status": "ERROR", "error": str(e)}
        time.sleep(1.2 * (i + 1))
    return last or {"status": "ERROR"}


tmp = tempfile.mkdtemp()
store = Store(os.path.join(tmp, "loop_floor.db"))
ledger = Ledger(os.path.join(tmp, "loop_ledger.jsonl"))

print(f"{B}{M}🧪 FULL SCIENCE LOOP{X}  {D}scientist Ledger × symbolic floor — live, no MCP{X}")
print(f"{D}floor: {store}{X}".replace("<symbolic_floor.store.Store object at", "db @"))

# ── 1. HYPOTHESIS ────────────────────────────────────────────────────────────
hr("1) HYPOTHESIS")
H = ("Human hemoglobin subunit beta (UniProt P68871) is a real, experimentally-"
     "characterized protein encoded by the HBB gene on chromosome 11, and the "
     "oxygen-carrying heme cofactor is an iron-containing molecule.")
hyp = ledger.propose_hypothesis(
    statement=H, rationale="cross-domain grounding across protein/gene/molecule",
    assumptions=[{"text": "UniProt/PDB/Ensembl/PubChem are curated ground truth"},
                 {"text": "the floor only writes provenance-pinned facts"}])
print(f"  {hyp.id}: {B}{H}{X}")

# ── 2. PRE-REGISTER PREDICTIONS (before any research — the hash chain proves it) ─
hr("2) PRE-REGISTER PREDICTIONS  (hash-chained, BEFORE research)")
PREDS = [
    ("P68871 canonical sequence length",  "uniprot:P68871:seq_len",     "==", 147),
    ("P68871 has ≥1 experimental structure","uniprot:P68871:pdb_count",  ">=", 1),
    ("heme molecular weight is porphyrin-scale","pubchem:heme:mw",       "in_range", [500, 750]),
    ("HBB is on chromosome 11",           "ensembl:HBB:chromosome",      "==", "11"),
    ("HBB is protein-coding",             "ensembl:HBB:biotype",         "==", "protein_coding"),
]
pred_ids = {}
for desc, var, rel, exp in PREDS:
    p = ledger.register_prediction(hyp.id, var, rel, exp, discriminating=(rel == "=="))
    pred_ids[var] = p["id"]
    print(f"  {D}{p['id']}{X}  {desc}: {B}{rel} {exp}{X}")

# ── 3. RESEARCH (pull REAL data through the floor's native connectors) ─────────
hr("3) RESEARCH  (floor pulls live — every fact provenance-pinned)")
prot = retry(lambda: extract.extract_protein(store, "P68871"), label="protein")
seq_len = None
for e in store.get_edges(source="protein:P68871", relation="has_sequence"):
    row = store.db.execute("SELECT length FROM sequences WHERE sequence_id=?", (e["object"],)).fetchone()
    if row: seq_len = row["length"]
pdb_count = len(store.get_edges(source="protein:P68871", relation="has_structure"))
print(f"  {G}protein P68871{X}: seq_len={B}{seq_len}{X}  experimental_structures={B}{pdb_count}{X}  {D}(UniProt+PDB){X}")

mol = retry(lambda: extract.research_molecule(store, "heme"), label="molecule")
heme_cid = mol.get("resolved_cid")
heme_mw = heme_formula = None
if heme_cid:
    for e in store.get_edges(source=f"molecule:{heme_cid}"):
        if e["relation_type"] == "has_weight":  heme_mw = float(e["object"].split(":")[1])
        if e["relation_type"] == "has_formula": heme_formula = e["object"].split(":")[1]
print(f"  {G}molecule heme{X}: CID={heme_cid} formula={B}{heme_formula}{X} mw={B}{heme_mw}{X}  {D}(PubChem){X}")

gene = retry(lambda: extract.research_gene(store, "HBB"), label="gene")
chrom = biotype = None
for e in store.get_edges(source="gene:HBB"):
    if e["relation_type"] == "on_chromosome": chrom = e["object"].split(":")[1]
    if e["relation_type"] == "has_biotype":   biotype = e["object"].split(":")[1]
print(f"  {G}gene HBB{X}: chromosome={B}{chrom}{X}  biotype={B}{biotype}{X}  {D}(Ensembl){X}")

# ── 4. EXPERIMENT + RECEIPT (the observation, hashed) ─────────────────────────
hr("4) RECORD RECEIPT  (the observation, sha256-sealed)")
observations = {"uniprot:P68871:seq_len": seq_len, "uniprot:P68871:pdb_count": pdb_count,
                "pubchem:heme:mw": heme_mw, "ensembl:HBB:chromosome": chrom,
                "ensembl:HBB:biotype": biotype}
exp = ledger.design_experiment(
    question="pull P68871 + heme + HBB through the floor",
    adapter="symbolic-floor", request={"protein": "P68871", "molecule": "heme", "gene": "HBB"},
    prediction_ids=list(pred_ids.values()))
ledger.record_receipt(exp["id"], observations, raw_digest=sha(observations),
                      adapter_meta={"connectors": ["uniprot", "pdb", "pubchem", "ensembl"]})
print(f"  {D}{exp['id']}{X}  receipt sealed  {D}sha256={sha(observations)[:16]}…{X}")

# ── 5. VERDICT (grade each prediction against what was actually pulled) ────────
hr("5) VERDICT  (grade predictions vs reality — honest, per-prediction)")
def grade(rel, exp_v, actual):
    if actual is None: return "INCONCLUSIVE"
    try:
        if rel == "==":       return "PASSED" if str(actual) == str(exp_v) else "REFUTED"
        if rel == ">=":       return "PASSED" if float(actual) >= float(exp_v) else "REFUTED"
        if rel == "<=":       return "PASSED" if float(actual) <= float(exp_v) else "REFUTED"
        if rel == "in_range": return "PASSED" if exp_v[0] <= float(actual) <= exp_v[1] else "REFUTED"
    except (TypeError, ValueError):
        return "INCONCLUSIVE"
    return "INCONCLUSIVE"

passed = 0
for desc, var, rel, exp_v in PREDS:
    actual = observations[var]
    outcome = grade(rel, exp_v, actual)
    ledger.record_verdict(pred_ids[var], exp["id"], outcome, actual=actual,
                          error=None if outcome != "REFUTED" else {"expected": exp_v, "actual": actual})
    col = G if outcome == "PASSED" else (R if outcome == "REFUTED" else Y)
    mark = "✓" if outcome == "PASSED" else ("✗" if outcome == "REFUTED" else "?")
    passed += outcome == "PASSED"
    print(f"  {col}{mark} {outcome:12}{X} {desc}: predicted {B}{rel} {exp_v}{X}, "
          f"actual {B}{actual}{X}")

# ── 6. CONFIDENCE + LEDGER INTEGRITY ─────────────────────────────────────────
hr("6) HYPOTHESIS CONFIDENCE + LEDGER INTEGRITY")
conf = hyp.confidence(ledger)
counts = hyp.verdict_counts(ledger)
print(f"  predictions graded: {B}{passed}/{len(PREDS)} PASSED{X}")
print(f"  mechanical confidence: {B}{conf:.3f}{X}  {D}(Laplace-smoothed support ratio, un-gameable){X}")
# Reload the ledger from disk: the constructor RE-VERIFIES the whole hash chain.
reloaded = Ledger(os.path.join(tmp, "loop_ledger.jsonl"))
n_events = sum(1 for _ in open(os.path.join(tmp, "loop_ledger.jsonl")))
print(f"  {G}✓ hash chain re-verified on reload{X}: {n_events} append-only events, "
      f"pre-registration held  {D}(predictions provably precede the receipt){X}")

# ── 7. THE FLOOR IS NOW A CROSS-DOMAIN GRAPH ─────────────────────────────────
hr("7) THE FLOOR NOW HOLDS A CROSS-DOMAIN GRAPH")
tot = store.db.execute("SELECT COUNT(*) FROM typed_relations").fetchone()[0]
tiles = store.db.execute("SELECT COUNT(*) FROM responses").fetchone()[0]
kinds = store.db.execute("SELECT DISTINCT substr(subject,1,instr(subject,':')-1) k "
                         "FROM typed_relations ORDER BY k").fetchall()
print(f"  {tot} typed edges + {tiles} PEEL tiles across: "
      f"{B}{', '.join(k['k'] for k in kinds)}{X}")
print(f"  {D}protein P68871 ← encodes ← gene HBB ;  heme molecule stands beside them —"
      f" one graph, provenance-pinned.{X}")

hr()
verdict = f"{G}{B}✓ LOOP CLOSED{X}" if passed >= 4 else f"{Y}{B}◐ LOOP RAN (honest mixed verdict){X}"
print(f"{verdict} — hypothesis pre-registered, researched live through the floor, "
      f"graded\n  against real evidence, sealed in a hash-chained ledger. No MCP, "
      f"no model authored a fact.\n")
store.close()
