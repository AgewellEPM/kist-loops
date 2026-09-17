#!/usr/bin/env python3
"""Play Doom (defend_the_center) with the typed symbolic decision head.

Headless, local, $0/hour. Prints per-decision latency, decisions/sec, kills,
and outcome-grounded calibration for ATTACK decisions (an ATTACK is 'correct'
if the kill counter rises within HIT_WINDOW tics). Receipts -> receipts.jsonl.

Usage: .venv/bin/python -m doom_lane.play [episodes]
"""
from __future__ import annotations

import json
import pathlib
import statistics
import sys
import time

import vizdoom as vzd

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from calibration import OutcomeLog
from decision_head import DecisionHead, DecisionSpace
from doom_lane.perception import extract_state
from doom_lane.policy import ACTIONS, score_actions

FRAME_SKIP = 2
HIT_WINDOW = 10  # tics an ATTACK has to raise KILLCOUNT to count as correct


def build_game() -> vzd.DoomGame:
    game = vzd.DoomGame()
    game.load_config(str(pathlib.Path(vzd.scenarios_path) / "defend_the_center.cfg"))
    game.set_window_visible(False)
    game.set_labels_buffer_enabled(True)
    game.set_available_game_variables(
        [vzd.GameVariable.HEALTH, vzd.GameVariable.AMMO2, vzd.GameVariable.KILLCOUNT])
    game.init()
    return game


def run(episodes: int = 5) -> dict:
    game = build_game()
    space = DecisionSpace("doom.defend_the_center", ACTIONS)
    head = DecisionHead(space, temperature=0.5)
    outcomes = OutcomeLog()
    receipts_path = pathlib.Path(__file__).parent / "receipts.jsonl"
    latencies, total_kills, total_decisions = [], 0.0, 0
    one_hot = {name: [1 if i == j else 0 for j in range(len(ACTIONS))]
               for i, name in enumerate(ACTIONS)}
    wall_start = time.perf_counter()

    with receipts_path.open("w") as receipts:
        for episode in range(episodes):
            game.new_episode()
            pending_attacks = []  # (decision_tic, confidence, kills_at_decision)
            kills = 0.0
            while not game.is_episode_finished():
                state = game.get_state()
                if state is None:
                    break
                health, ammo, kills = state.game_variables
                facts = extract_state(state, game.get_screen_width(), health, ammo, kills)

                decision = head.decide(score_actions(facts), evidence=facts.evidence())
                latencies.append(decision.latency_us)
                total_decisions += 1
                receipts.write(json.dumps(decision.receipt()) + "\n")

                # Settle ATTACK outcomes whose window has passed.
                tic = state.tic
                still_pending = []
                for decided_tic, confidence, kills_then in pending_attacks:
                    if kills > kills_then:
                        outcomes.record(confidence, True)
                    elif tic - decided_tic > HIT_WINDOW:
                        outcomes.record(confidence, False)
                    else:
                        still_pending.append((decided_tic, confidence, kills_then))
                pending_attacks = still_pending
                if decision.choice == "ATTACK":
                    pending_attacks.append((tic, decision.confidence, kills))

                game.make_action(one_hot[decision.choice], FRAME_SKIP)

            for _, confidence, kills_then in pending_attacks:
                outcomes.record(confidence, kills > kills_then)
            total_kills += kills
            print(f"episode {episode + 1}: kills={kills:.0f}")

    wall = time.perf_counter() - wall_start
    game.close()

    report = {
        "episodes": episodes,
        "total_kills": total_kills,
        "decisions": total_decisions,
        "decisions_per_sec_wall": round(total_decisions / wall, 1),
        "decision_latency_us_median": round(statistics.median(latencies), 1),
        "decision_latency_us_p99": round(sorted(latencies)[int(0.99 * len(latencies))], 1),
        "attack_outcomes_recorded": len(outcomes),
        "brier_score": round(outcomes.brier_score(), 4) if len(outcomes) else None,
        "receipts": str(receipts_path),
    }
    if len(outcomes) >= 10:
        report["reliability"] = [
            {"bin": f"{b.lo:.1f}-{b.hi:.1f}", "n": b.count,
             "mean_conf": round(b.mean_confidence, 3), "accuracy": round(b.accuracy, 3)}
            for b in outcomes.reliability(bins=5)]
    print(json.dumps(report, indent=2))
    return report


if __name__ == "__main__":
    run(int(sys.argv[1]) if len(sys.argv) > 1 else 5)
