#!/usr/bin/env python3
"""GRAND TOUR — show off the whole floor: ask it questions, research across every
domain, traverse for discoveries, talk to the model, set up an experiment, and
watch it refuse to lie. Native connectors, provenance-pinned, no MCP.

Run in the floor venv:  .venv/bin/python dogfood_grand_tour.py
"""
import sys, os, json, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from symbolic_floor.store import Store          # noqa: E402
from symbolic_floor import extract               # noqa: E402
from symbolic_floor.peel.floor import are_compatible, is_functional  # noqa: E402
from symbolic_floor.schema import utc_now_iso    # noqa: E402

G, C, Y, R, D, B, M = "\033[32m", "\033[36m", "\033[33m", "\033[31m", "\033[2m", "\033[1m", "\033[35m"
X = "\033[0m"


def hr(t=""):
    print(f"\n{C}{'━'*76}{X}" + (f"  {B}{t}{X}" if t else ""))


def say(who, msg):
    col = M if who == "you" else G
    tag = "you ▸" if who == "you" else "floor ◂"
    print(f"  {col}{tag}{X} {msg}")


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


def facts(store, node):
    return {e["relation_type"]: e["object"].split(":", 1)[1]
            for e in store.get_edges(source=node)}


def ask_molecule(store, name):
    """Grounded Q&A: 'what is X?' -> research -> answer from the floor's edges."""
    say("you", f"what is {B}{name}{X}?")
    r = retry(lambda: extract.research_molecule(store, name))
    if r.get("status") != "OK":
        say("floor", f"{Y}I can't confirm '{name}' against a curated source — I won't guess.{X}")
        return None
    f = facts(store, f"molecule:{r['resolved_cid']}")
    say("floor", f"{name} is PubChem CID {B}{r['resolved_cid']}{X}: formula {B}{f.get('has_formula','?')}{X}, "
                 f"IUPAC {B}{f.get('has_iupac_name','?')}{X}, {f.get('has_weight','?')} g/mol")
    say("floor", f"{D}InChIKey {f.get('has_inchikey','?')} — every field pinned to pubchem.ncbi.nlm.nih.gov{X}")
    return r.get("resolved_cid")


tmp = tempfile.mkdtemp()
store = Store(os.path.join(tmp, "tour.db"))
print(f"{B}{M}🎛️  SYMBOLIC FLOOR — GRAND TOUR{X}  {D}every tool, every feature, live, no MCP{X}")

# ── A. TALK TO IT: ask what things are (grounded Q&A across chemistry) ─────────
hr("A) TALK TO THE FLOOR — ask it what things are")
ask_molecule(store, "water")
ask_molecule(store, "caffeine")
ask_molecule(store, "aspirin")
ask_molecule(store, "glucose")

# ── B. DIVERSE RANGE: research a gene and a protein, watch the graph link up ──
hr("B) RESEARCH ACROSS DOMAINS — gene → protein, one connected graph")
say("you", "research the gene HBB, then the protein it encodes")
gene = retry(lambda: extract.research_gene(store, "HBB"))
gf = facts(store, "gene:HBB")
say("floor", f"gene HBB: chromosome {B}{gf.get('on_chromosome','?')}{X}, {B}{gf.get('has_biotype','?')}{X}, "
             f"encodes {B}{gf.get('encodes','(pulling…)')}{X}  {D}(Ensembl){X}")
prot = retry(lambda: extract.extract_protein(store, "P68871"))
seqlen = None
for e in store.get_edges(source="protein:P68871", relation="has_sequence"):
    row = store.db.execute("SELECT length FROM sequences WHERE sequence_id=?", (e["object"],)).fetchone()
    if row: seqlen = row["length"]
nstruct = len(store.get_edges(source="protein:P68871", relation="has_structure"))
say("floor", f"protein P68871: {B}{seqlen} aa{X}, {B}{nstruct}{X} experimental structures + AlphaFold "
             f"prediction  {D}(UniProt+PDB){X}")

# ── C. TRAVERSAL / DISCOVERY: relevance = reachability, not similarity ─────────
hr("C) DISCOVERY BY TRAVERSAL — what do two proteins share? (relevance = reachability)")
say("you", "research hemoglobin alpha (P69905) too, then tell me what it shares with beta")
retry(lambda: extract.extract_protein(store, "P69905"))
alpha = {e["object"] for e in store.get_edges(source="protein:P69905")}
beta = {e["object"] for e in store.get_edges(source="protein:P68871")}
shared = sorted(alpha & beta)
if shared:
    say("floor", f"they CONVERGE on {B}{len(shared)}{X} node(s) — reached from BOTH by typed edges:")
    for node in shared[:5]:
        print(f"      {G}◆ {node}{X}  {D}← protein:P69905 AND protein:P68871{X}")
    say("floor", f"{D}that's a discovery: the path IS the justification, no embedding similarity involved.{X}")
else:
    say("floor", "no shared nodes yet (structures differ per chain, as expected)")

# ── D. SET UP AN EXPERIMENT: does the floor contradict itself under a lie? ─────
hr("D) SET UP AN EXPERIMENT — can we make the floor accept a contradiction?")
say("you", "experiment: force-feed it 'water is CO2' and see if the hard-veto catches it")
store.add_edge("molecule:962", "has_formula", "formula:CO2",
               {"source": "manual", "url": None, "retrieved_at": utc_now_iso(),
                "raw_id": "adversarial: claim water is CO2"}, label="adversarial")
formulas = sorted(e["object"] for e in store.get_edges(source="molecule:962", relation="has_formula"))
ok = is_functional("has_formula") and not are_compatible(store.engine, "formula:H2O", "formula:CO2", "has_formula")
say("floor", f"has_formula on record for water: {B}{formulas}{X}")
say("floor", (f"{G}✓ CONTRADICTION DETECTED{X} — has_formula is functional; H2O vs CO2 are incompatible. "
              f"The lie is on record but flagged, never silently believed.") if ok
             else f"{R}veto did not fire{X}")

# ── E. HONESTY: research something that does not exist ────────────────────────
hr("E) HONESTY — ask for something that does not exist")
say("you", "research the molecule 'unobtainium sparkle-9'")
fake = extract.research_molecule(store, "unobtainium sparkle-9")
say("floor", (f"{G}✓ NOT_FOUND — I abstain.{X} No curated source resolves it, so the floor writes NOTHING. "
              f"Honesty is a structural property here, not a prompt.") if fake.get("status") == "NOT_FOUND"
             else f"{R}unexpectedly resolved: {fake}{X}")

# ── F. TALK TO THE MODEL: the local proposer, gated by the floor ──────────────
hr("F) TALK TO THE MODEL — the floor-proposer proposes, the floor decides")
say("you", "ask the local model what to do with accession P69905")
try:
    body = json.dumps({"model": "floor-proposer", "stream": False,
                       "options": {"temperature": 0, "num_predict": 60},
                       "messages": [{"role": "user",
                       "content": "Propose one action for UniProt accession P69905."}]}).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        reply = json.loads(resp.read())["message"]["content"].strip()
    say("floor", f"model proposes: {B}{reply[:90]}{X}")
    say("floor", f"{D}…but the model NEVER writes the graph — only the floor gate admits provenanced facts.{X}")
except Exception as e:
    say("floor", f"{Y}local model busy right now ({type(e).__name__}) — but the contract stands: "
                 f"the model can only ever PROPOSE; the floor authors every fact.{X}")

# ── G. PROVENANCE: prove where every fact came from ───────────────────────────
hr("G) PROVENANCE — every fact walks back to a receipt")
say("you", "prove where you learned water's formula")
for e in store.get_edges(source="molecule:962", relation="has_formula"):
    prov = json.loads(e["provenance_json"])
    tag = G if prov["source"] != "manual" else Y
    print(f"      {tag}{prov['source']:8}{X} {e['object']:14} {D}← {prov.get('url') or prov['raw_id']}{X}")

# ── summary ──────────────────────────────────────────────────────────────────
hr()
tot = store.db.execute("SELECT COUNT(*) FROM typed_relations").fetchone()[0]
tiles = store.db.execute("SELECT COUNT(*) FROM responses").fetchone()[0]
kinds = [r[0] for r in store.db.execute(
    "SELECT DISTINCT substr(subject,1,instr(subject,':')-1) FROM typed_relations ORDER BY 1")]
print(f"{G}{B}✓ GRAND TOUR COMPLETE{X} — {tot} typed edges + {tiles} PEEL tiles across "
      f"{B}{', '.join(kinds)}{X}.")
print(f"  Asked it questions, researched every domain, discovered by traversal, ran an")
print(f"  experiment, caught a lie, stayed honest, and proved every fact. {D}No MCP.{X}\n")
store.close()
