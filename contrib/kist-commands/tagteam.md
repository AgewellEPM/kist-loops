Tag-team build-and-review mode. You are the BUILDER. Work in this loop until the
review panel is clean:

1. BUILD the task: $ARGUMENTS
   (If the args contain `reviewers=a,b`, use those reviewers; otherwise default to
   `deepseek,codex`. As many reviewers as named, all run in parallel.)

2. SELF-CHECK first. Re-read your own diff, fix the obvious mistakes you can see, and
   make sure it builds/tests before handing off. Don't waste reviewers on sloppy work.

3. TAG-TEAM REVIEW your diff:
   `designflow tagteam review --reviewers <selected>`
   (Fans the working-tree diff out to every selected reviewer in parallel and
   aggregates to SHIP or MUST-FIX. Any single objecting reviewer ⇒ MUST-FIX.)

4. If the panel says MUST-FIX (exit 3): FIX EVERY FINDING each reviewer raised — not
   just the first, not just the easy ones. Adjudicate honestly: if a finding is a
   false positive, say why and prove it (a test), don't hand-wave. Then GO BACK TO
   STEP 3 and re-review. Repeat until no reviewer objects.

5. When the panel is clean, REPORT: what each reviewer found, what you fixed, and any
   findings you refuted (with evidence). Label the result honestly (PROTOTYPE /
   PILOT / PRODUCTION).

Rules:
- The habit is BUILD → TAG-TEAM REVIEW → FIX ALL → repeat. Never ship on the first
  build without a review pass.
- A single reviewer's BLOCKER outweighs every other reviewer's approval.
- Never silence a reviewer or weaken a check to make the panel pass. Fix the code.
