#!/usr/bin/env python3
"""Symbolic Wikiracer — TypeSafe's Wikiracing demo without the model.

Start page -> target page using only on-page links. Two stages per hop,
mirroring Jev's "score independently then choose": stage 1 is an exact
target check, stage 2 scores EVERY candidate with symbolic rules and picks
via the typed decision head (no 255-option cap). Stdlib HTTP only; the only
network calls are the Wikipedia API itself.

Usage: .venv/bin/python -m wikirace_lane.racer "Start Title" "Target Title"
"""
from __future__ import annotations

import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from decision_head import DecisionHead, DecisionSpace
from wikirace_lane.scoring import score_candidate, tokens

API = "https://en.wikipedia.org/w/api.php"
USER_AGENT = "science-loops-system-one-symbolic/0.1 (symbolic wikiracer; research)"
MAX_LINK_PAGES = 4  # API continuation pages per article (500 links each)
MIN_CALL_GAP_S = 1.0  # be a polite API citizen
_last_call = 0.0


def _api(params: dict) -> dict:
    global _last_call
    query = urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        wait = _last_call + MIN_CALL_GAP_S - time.perf_counter()
        if wait > 0:
            time.sleep(wait)
        try:
            _last_call = time.perf_counter()
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 3:
                raise
            time.sleep(float(error.headers.get("Retry-After") or 2 ** (attempt + 1)))
    raise RuntimeError("unreachable")


def get_links(title: str) -> list[str]:
    """All main-namespace links on a page (bounded API pagination)."""
    links, cont = [], {}
    for _ in range(MAX_LINK_PAGES):
        data = _api({"action": "query", "prop": "links", "titles": title,
                     "plnamespace": 0, "pllimit": "max", **cont})
        for page in data["query"]["pages"].values():
            links.extend(link["title"] for link in page.get("links", []))
        cont = data.get("continue", {})
        if not cont:
            break
    return links


def get_intro(title: str) -> str:
    data = _api({"action": "query", "prop": "extracts", "explaintext": 1,
                 "exintro": 1, "titles": title, "redirects": 1})
    pages = data["query"]["pages"]
    return next(iter(pages.values())).get("extract", "")


FRONTIER_CHOICE_CAP = 64  # typed decision space per expansion


def race(start: str, target: str, max_expansions: int = 25) -> dict:
    """Best-first search: a dead end costs one expansion, not the race."""
    target_title_tokens = tokens(target)
    target_intro_tokens = tokens(get_intro(target))
    frontier: dict[str, float] = {}   # candidate title -> score
    parent: dict[str, str] = {}       # child title -> page it was found on
    visited = {start.lower()}
    current = start
    hop_receipts = []
    wall_start = time.perf_counter()

    for expansion in range(max_expansions):
        links = get_links(current)
        # Stage 1: target directly reachable from the page being expanded?
        for link in links:
            if link.lower() == target.lower():
                parent[target] = current
                return _result(True, _path(parent, start, target), hop_receipts, wall_start)

        # Stage 2: score every new link symbolically into the frontier.
        for link in links:
            if link.lower() not in visited and link not in frontier:
                frontier[link] = score_candidate(
                    link, target_title_tokens, target_intro_tokens)
                parent[link] = current

        if not frontier:
            return _result(False, _path(parent, start, current), hop_receipts,
                           wall_start, note="frontier exhausted")

        # Choose the next page to expand via the typed head (top-K frontier).
        top = sorted(frontier, key=frontier.get, reverse=True)[:FRONTIER_CHOICE_CAP]
        if len(top) == 1:
            chosen = top[0]
        else:
            head = DecisionHead(DecisionSpace(f"wikirace.exp{expansion}", tuple(top)))
            decision = head.decide({t: frontier[t] for t in top}, evidence={
                "expanding_from": current, "target": target,
                "frontier_size": len(frontier)})
            hop_receipts.append({k: v for k, v in decision.receipt().items()
                                 if k not in ("probabilities", "scores")})
            chosen = decision.choice
        frontier.pop(chosen)
        visited.add(chosen.lower())
        print(f"  expand {expansion + 1}: {chosen} "
              f"(frontier {len(frontier)}, found on {parent[chosen]})")
        current = chosen

    return _result(False, _path(parent, start, current), hop_receipts,
                   wall_start, note="expansion budget")


def _path(parent: dict[str, str], start: str, end: str) -> list[str]:
    path = [end]
    while path[-1] != start:
        path.append(parent[path[-1]])
    return list(reversed(path))


def _result(won, path, receipts, wall_start, note=None):
    return {"won": won, "hops": len(path) - 1, "path": path, "note": note,
            "wall_seconds": round(time.perf_counter() - wall_start, 1),
            "receipts": receipts}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: racer.py 'Start Title' 'Target Title'")
    outcome = race(sys.argv[1], sys.argv[2])
    print(json.dumps({k: v for k, v in outcome.items() if k != "receipts"}, indent=2))
