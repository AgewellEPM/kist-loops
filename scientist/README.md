# scientist — iterative scientific inquiry, symbolically governed

**Label: PILOT-READY** (honest scope below). A machine that runs the loop

> Hypothesis → Experiment → Receipt → Critic → Blame → Learning → New hypothesis

where **failure is a hypothesis generator**, not a discarded sample, and the symbolic layer
— not the model — owns what may be claimed, what counts as evidence, and when a hypothesis
changes state.

## The five learning jobs (and where they live)

| Job | Question | Module | Day-one implementation |
|---|---|---|---|
| Perception | what happened? | `adapters/` | typed extraction from raw bytes, receipt-digested |
| Hypothesizer | what could explain it? | `roles.propose_competing` | operator/generator; **≥2 competing enforced** |
| Designer | which experiment reduces uncertainty most? | `selector.py` | discrimination count from the ledger, deterministic |
| Critic | did reality match? | `critic.py` | arithmetic over pre-registered predictions, no model text |
| Scientist | why was I wrong? | `blame.py` | mechanical suspicion + auto-generated follow-up hypotheses |

Every rule module is version-tagged (`*_RULE_VERSION`) so a learned model can replace it
later **without touching the ledger contract**: whatever thinks, it may only speak through
ledger proposals, and proposals that break the rules raise — they are never half-recorded.

## The non-negotiables (each is pinned by tests)

- **Append-only, hash-chained ledger** (`events.py`): every mutation is an event carrying the
  sha256 of its predecessor; edit or delete any past line and replay refuses to load. A
  fsynced head sidecar (`<log>.head`) additionally catches clean truncation from the END —
  the one rewrite a hash chain alone cannot see. The model cannot quietly rewrite history.
- **Pre-registration** (`ledger.record_verdict`): a prediction is only gradable if its
  registration event precedes the receipt event in the chain, and only against an experiment
  that declared it at design time. Postdiction and post-hoc matching are both refused.
- **Mechanical confidence** (`confidence.py`): Laplace-smoothed support ratio; a refuted
  *discriminating* prediction hard-caps confidence at 0.05. The model proposes; arithmetic
  disposes.
- **State machine** (`ledger.py`): PROPOSED→TESTABLE→EXPERIMENTING→SUPPORTED/CONTESTED/
  REJECTED/REVISED, transitions justified by verdicts on record. REJECTED requires a
  discriminating refutation; SUPPORTED requires zero refutations; CONTESTED is a one-way
  gate (a refutation never un-happens — rehabilitation is a REVISED successor, which must
  itself be non-terminal).
- **Ungameable knowledge objective** (`knowledge.py`): credit only for experiments that
  refute something or settle a live disagreement, never for re-proving the proven or lone
  confirmations of the uncontested. "Validated knowledge gained per experiment" is an
  auditable event count.
- **Failure → hypothesis** (`blame.py`): assumptions of refuted hypotheses gain suspicion
  (siblings that passed exonerate shared assumptions); past threshold, a `generator:`-origin
  hypothesis "assumption X is false" is proposed automatically.

## Live proof

`python3 run_live.py` runs the loop **twice** on a real question (length of human hemoglobin
subunit alpha, UniProt P69905) with two competing hypotheses per cycle: cycle 1 rejects 141
against a live receipt (answer: 142), the loser's failure generates "the excludes-initiator-Met
assumption is false", and cycle 2 confirms it live (`initiator_met_removed == True`) while the
devil's-advocate rival is rejected — whose failure generates the next hypothesis. Committed
evidence: `dogfood/hemoglobin-P69905/` (34 hash-chained events, 2/2 experiments credited).

## Tests

```
python3 -m unittest discover -s tests    # 31 tests, no network (live probe = run_live.py)
```

## Honest scope (what PILOT-READY means here)

- No LLM is wired into any role yet — by design. The seams are the role modules; the
  training corpus is the ledger itself (hypothesis, registered prediction, receipt, error,
  blamed assumption — witnessed by construction).
- One adapter (UniProt REST). The wetware/bio-mcp lane is the obvious next adapter.
- Blame credit-assignment is rule v1 (deliberately simple, versioned for replacement).
- Single-process, single-ledger; no concurrency story yet.
- Not wired into kist or any always-on runtime.
