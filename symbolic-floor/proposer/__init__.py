"""The proposer lane — a LOCAL model on top of the floor, never inside it.

The proposer (any LLM: our own Ollama-served LoRA, or a large commercial
model) emits typed PROPOSALS in the floor's grammar. It has zero write access
to the graph: every output goes through parse -> schema validation -> floor
verdict, and only the FLOOR decides what is admitted, executed, or refused.
That admission gate is what makes any model — small local or large remote —
airtight: the model can be wrong; the system cannot be wrong silently.

Roles in this package:
  contract.py   the proposal grammar + the system prompt that teaches it
  runtime.py    Ollama client + parse + floor admission (the gate)
  dataset.py    training pairs generated FROM the floor (witnessed only)
  evaluate.py   scored eval: parse / grounding / abstention / veto rates
"""
