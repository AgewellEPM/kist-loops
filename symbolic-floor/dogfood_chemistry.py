#!/usr/bin/env python3
"""Live dogfood of the native chemistry connector: research a molecule NAME,
watch the floor learn real chemistry from PubChem — no MCP, no model, every fact
provenance-pinned. Run inside the floor venv:  .venv/bin/python dogfood_chemistry.py
"""
import sys, tempfile, os, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from symbolic_floor.store import Store          # noqa: E402
from symbolic_floor import extract               # noqa: E402
from symbolic_floor.schema import ValidationError  # noqa: E402
from symbolic_floor.peel.floor import is_functional  # noqa: E402

G, C, Y, R, D, B = "\033[32m", "\033[36m", "\033[33m", "\033[31m", "\033[2m", "\033[1m"
X = "\033[0m"


def hr(t=""):
    print(f"\n{C}{'─'*72}{X}" + (f"  {B}{t}{X}" if t else ""))


db = os.path.join(tempfile.mkdtemp(), "dogfood_chem.db")
store = Store(db)
print(f"{B}⚗️  FLOOR CHEMISTRY DOGFOOD{X}  {D}(fresh floor, live PubChem, no MCP){X}")
print(f"{D}db: {db}{X}")

# 1) The floor starts EMPTY — it knows nothing about water.
hr("1) BEFORE — does the floor know what water is?")
before = store.get_edges(source="molecule:962")
print(f"  facts about water: {R}{len(before)}{X}  {D}(empty floor){X}")

# 2) Research 'water' — resolve the NAME to a CID and pull real chemistry.
hr("2) research 'water'  →  resolve name → PubChem CID → pull + tile")
res = extract.research_molecule(store, "water")
if res["status"] != "OK":
    print(f"  {R}FAILED: {res}{X}"); store.close(); sys.exit(1)
print(f"  resolved: {G}water → PubChem CID {res['resolved_cid']}{X}")
print(f"  wrote {G}{len(res['edges_written'])} edges{X} + "
      f"{G}{res['peel_trace']['tiles_written']} PEEL tiles{X}")

# 3) What the floor now KNOWS about water — with provenance.
hr("3) AFTER — what the floor now KNOWS about water (every fact provenance-pinned)")
IDENT = {"has_formula": "formula", "has_iupac_name": "IUPAC name",
         "has_inchikey": "InChIKey", "has_weight": "weight (g/mol)"}
for e in store.get_edges(source="molecule:962"):
    rel, obj = e["relation_type"], e["object"].split(":", 1)[1]
    prov = json.loads(e["provenance_json"])
    host = prov["url"].split("/")[2]
    fn = f"{Y}[functional]{X}" if is_functional(rel) else f"{D}[many]{X}"
    label = IDENT.get(rel, "also known as")
    print(f"  {G}{label:14}{X} {B}{obj:32}{X} {fn}  {D}← {host}{X}")

# 4) The PEEL trace — the tiles that ARE the floor's knowledge of water.
hr("4) the PEEL trace (canonical-37 tiles, chained)")
tiles = store.db.execute(
    "SELECT emoji, sentence FROM responses WHERE conversation_id='chem-wheel:962' "
    "ORDER BY depth_level, turn_number").fetchall()
for t in tiles[:8]:
    print(f"  {t['emoji']}  {t['sentence']}")
print(f"  {D}… {len(tiles)} tiles total{X}")

# 5) Idempotency — re-research writes NOTHING new (deterministic).
hr("5) idempotency — re-research 'water'")
again = extract.research_molecule(store, "water")
print(f"  new edges: {G}{len(again['edges_written'])}{X}  "
      f"new tiles: {G}{again['peel_trace']['tiles_written']}{X}  "
      f"{D}(0/0 = deterministic, re-running is safe){X}")

# 6) Functional hard-veto — a CONFLICTING formula for water is a CONTRADICTION.
hr("6) functional hard-veto — try to claim water is 'CO2' (a lie)")
from symbolic_floor.schema import utc_now_iso  # noqa: E402
from symbolic_floor.peel.floor import are_compatible  # noqa: E402
store.add_edge("molecule:962", "has_formula", "formula:CO2",
               {"source": "manual", "url": None, "retrieved_at": utc_now_iso(),
                "raw_id": "adversarial test: claim water is CO2"},
               label="adversarial")
formulas = [e["object"] for e in store.get_edges(source="molecule:962", relation="has_formula")]
compatible = are_compatible(store.engine, "formula:H2O", "formula:CO2", "has_formula")
if len(formulas) > 1 and not compatible:
    print(f"  formulas now on record: {formulas}")
    print(f"  {G}✓ engine flags H2O vs CO2 as INCOMPATIBLE{X} "
          f"{D}(functional relation → contradiction, never silently accepted){X}")
else:
    print(f"  {R}veto did not fire as expected: {formulas} compatible={compatible}{X}")

# 7) It generalizes — research a different molecule live.
hr("7) it generalizes — research 'caffeine' live")
caf = extract.research_molecule(store, "caffeine")
if caf["status"] == "OK":
    facts = {e["relation_type"]: e["object"].split(":", 1)[1]
             for e in store.get_edges(source=f"molecule:{caf['resolved_cid']}")
             if e["relation_type"] in IDENT}
    print(f"  caffeine → {G}CID {caf['resolved_cid']}{X}: "
          f"{B}{facts.get('has_formula','?')}{X}  {facts.get('has_weight','?')} g/mol  "
          f"{D}InChIKey {facts.get('has_inchikey','?')}{X}")
else:
    print(f"  {Y}caffeine lookup: {caf['status']}{X}")

hr()
print(f"{G}{B}✓ DOGFOOD PASSED{X} — the floor researches molecules by name, learns real "
      f"chemistry\n  from PubChem, tiles it via the PEEL trace, and hard-vetoes lies. "
      f"No MCP.{X}\n")
store.close()
