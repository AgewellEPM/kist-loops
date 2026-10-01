# Kist typed decisions

Kist exposes `decide` and `decision_tool` inside normal agent turns and plan/execute
runs, including fast mode. Models can call them when a task benefits from a
small classification or rubric judgment. They are not automatically called before
every action.

For example: `Create a reusable decision_tool named triage, run it on a refund
ticket, and report the result.` Definition requests use a small tool surface and
do not start a compiler/planner mission. Real source builds retain that mission.
Ordinary chat, review, research and planning turns can use advisory decisions and
read/run saved definitions. Creating a definition requires mutation intent; a
decision alone never satisfies a research-evidence or build-verification gate.

`decide` takes an explicit evidence capsule and 1–64 named questions. It supports
Jev-style `choice`, `noul` (probability of true), and `score` questions. Results
contain validated option distributions. Kist computes the selected choice,
probability-weighted score and distribution concentration from those distributions.
Use a `none` or `unknown` choice when the evidence may not support an answer.

```json
{
  "state": {"ticket": "I was charged twice. Please refund the duplicate."},
  "questions": {
    "team": {
      "type": "choice",
      "instructions": "Which team handles this ticket?",
      "criteria": {"billing": "Payments and refunds", "technical": "Bugs", "other": null}
    },
    "refund": {"type": "noul", "instructions": "Does the customer explicitly request a refund?"},
    "urgency": {"type": "score", "instructions": "Rate urgency", "criteria": ["Routine", "Soon", "Urgent"]}
  }
}
```

To make a reusable tool, call `decision_tool` with `action: "create"`, a `name`,
optional `description`, and the same `questions` object. Then call it with
`action: "run"`, that name and a new `state` capsule. `list` enumerates saved tools;
`get` reads their definitions. Definitions persist in `.kist/decision-tools` under
the current project. They are data, not executable code. The model can use
`custom_tool` separately when it needs an executable parser or converter.

The default backend is the agent's configured provider/model (the worker binding
in plan/execute). Its probabilities are explicitly labeled `model_estimate`.
This is a typed decision service, not a newly trained neural model. It does not
claim the latency or calibration of a specialized decision model.

For an already installed Ollama decision model and an Ollama version supporting
`/v1/systemone`, select the native scoring backend in the host environment:

```sh
KIST_DECISION_BACKEND=systemone KIST_DECISION_MODEL=nimble kist
```

`KIST_DECISION_BASE_URL` optionally selects another loopback HTTP port; it defaults
to `http://127.0.0.1:11434`. Remote hosts, credentials in URLs and redirects are
rejected. No model is downloaded automatically. An unavailable configured backend
returns an error; it never silently switches to a paid provider. Native answer
token scores are labeled `answer_token_scores`.

Requests are limited to 64 KiB, questions to 26 choices/levels, and responses to
128 KiB. Exact repeated capsules use a 60-second in-memory session cache. The
engine shares the parent's token/dollar ledger and, in agent turns, its durable
provider-request cap. Failed or malformed calls do not become free retries.

Decision outputs are advisory. Concentration is not measured accuracy. These
tools cannot change tool permissions, activate generated code, sign receipts or
establish that a build/test succeeded. Existing execution and verification gates
remain authoritative. Standing autonomy settings remain unchanged.

Protocol reference: [Ollama's decision-model API](https://ollama.com/library/nimble).
