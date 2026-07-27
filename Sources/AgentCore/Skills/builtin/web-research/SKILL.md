---
name: web-research
description: Use when the task needs current information, comparisons, source discovery, version/release facts, prices, docs lookups, or anything you cannot answer from the repo and your own knowledge alone. Covers any "find out / look up / what's the latest / compare X vs Y" request.
user-invocable: true
license: MIT
---

# Web research procedure

Goal: produce an answer grounded in real sources, never guessed URLs or hallucinated facts.

## Procedure

1. **Start with `web_search`.** Turn the question into 1–3 focused queries. Do NOT guess a
   website URL and fetch it directly — search first and let results supply the URLs.
2. **Read before trusting.** Use `fetch_url` only on URLs the user gave you or that
   `web_search` returned. Open the 2–3 most relevant results, not just the first.
3. **Cross-check claims.** For any factual claim that matters (a version number, a price, a
   limit, a date), confirm it appears in at least two independent sources before stating it.
   If sources disagree, say so and give both.
4. **Cite.** In your final answer, attribute each non-obvious fact to the source it came from
   (title + URL). The user must be able to verify every claim.
5. **Say what you couldn't find.** If a sub-question has no good source, state that plainly
   rather than filling the gap with a plausible guess.

## Anti-patterns

- Fetching `https://<product>.com/pricing` from memory instead of searching — the path is
  often wrong and you'll report stale or invented numbers.
- Treating the first search snippet as ground truth without opening the page.
- Reporting a single-source fact as settled when it's contested.
