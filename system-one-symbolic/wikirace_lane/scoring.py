"""Symbolic link scoring for Wikiracing. Pure functions, no network, no model.

Score = written-down lexical/structural rules against the TARGET context:
title-token overlap (strong), target-intro mentions (medium), generic-page
penalty. Same shape as the wiki wheel's should_follow_link heuristics, so
the racer and the harvester share one philosophy: relatedness is a rule,
not a vibe.
"""
from __future__ import annotations

import re

STOPWORDS = frozenset(
    "the a an of and or in on for to with by at from into during as is are was were".split())
GENERIC_PREFIXES = ("list of", "index of", "outline of", "timeline of",
                    "glossary of", "category:", "portal:", "help:", "wikipedia:")

TITLE_OVERLAP_WEIGHT = 5.0
INTRO_MENTION_WEIGHT = 1.5
GENERIC_PENALTY = -2.0
YEAR_PENALTY = -1.0


def tokens(text: str) -> frozenset[str]:
    return frozenset(
        t for t in re.findall(r"[a-z0-9]+", text.lower()) if t not in STOPWORDS)


def score_candidate(candidate_title: str, target_title_tokens: frozenset[str],
                    target_intro_tokens: frozenset[str]) -> float:
    """Higher = more likely to lead toward the target page."""
    candidate_tokens = tokens(candidate_title)
    if not candidate_tokens:
        return GENERIC_PENALTY
    score = 0.0

    title_hits = candidate_tokens & target_title_tokens
    if title_hits:
        score += TITLE_OVERLAP_WEIGHT * len(title_hits) / len(target_title_tokens)

    intro_hits = candidate_tokens & target_intro_tokens
    score += INTRO_MENTION_WEIGHT * len(intro_hits) / len(candidate_tokens)

    lowered = candidate_title.lower()
    if any(lowered.startswith(prefix) for prefix in GENERIC_PREFIXES):
        score += GENERIC_PENALTY
    if re.fullmatch(r"\d{3,4}", lowered):  # bare year pages are traps
        score += YEAR_PENALTY
    return score
