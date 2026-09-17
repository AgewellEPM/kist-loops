#!/usr/bin/env python3
"""Play Doom (defend_the_center) with the typed symbolic decision head.

Modes:
  headless (default)   benchmark speed — engine runs as fast as it can
  --watch              game window + LIVE decision-graph panel, real-time
                       35fps: watch the symbolic system control the game
                       and see exactly which rules fire per action
  --record out.mp4     record gameplay WITH the decision panel composited
                       beside every frame (works with or without --watch)

Local, $0/hour. Every decision's receipt carries the full justification
graph (facts -> rule firings -> scores -> choice) in receipts.jsonl.

Usage: .venv/bin/python -m doom_lane.play [episodes] [--watch] [--record out.mp4]
"""
from __future__ import annotations

import argparse
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
from doom_lane.policy import ACTIONS, score_actions_traced

HIT_WINDOW = 10  # tics an ATTACK has to raise KILLCOUNT to count as correct


def build_game(watch: bool, record: bool) -> vzd.DoomGame:
    game = vzd.DoomGame()
    game.load_config(str(pathlib.Path(vzd.scenarios_path) / "defend_the_center.cfg"))
    game.set_window_visible(watch)
    # ASYNC = engine runs wall-clock 35fps regardless of decision speed —
    # the honest way to show the head keeps up in real time (it needs ~2us).
    game.set_mode(vzd.Mode.ASYNC_PLAYER if watch else vzd.Mode.PLAYER)
    if watch or record:
        game.set_screen_resolution(vzd.ScreenResolution.RES_640X480)
        game.set_screen_format(vzd.ScreenFormat.RGB24)
        game.set_render_hud(True)
    game.set_labels_buffer_enabled(True)
    game.set_available_game_variables(
        [vzd.GameVariable.HEALTH, vzd.GameVariable.AMMO2, vzd.GameVariable.KILLCOUNT])
    game.init()
    return game


def run(episodes: int, watch: bool = False, record: str | None = None) -> dict:
    game = build_game(watch, bool(record))
    frame_skip = 1 if (watch or record) else 2
    game_size = (game.get_screen_width(), game.get_screen_height())

    from doom_lane.graph_panel import (
        GraphRenderer, LiveGraphWindow, build_graph_state, compose_video_frame,
    )
    recorder = renderer = panel = None
    if record or watch:
        renderer = GraphRenderer()
    if record:
        from PIL import Image
        from doom_lane.recorder import FrameRecorder
        recorder = FrameRecorder(
            record, game_size[0] + renderer.width, max(game_size[1], renderer.height))
    if watch:
        panel = LiveGraphWindow(renderer)
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
            kills, last_seen_side = 0.0, -1
            while not game.is_episode_finished():
                state = game.get_state()
                if state is None:
                    break
                health, ammo, kills = state.game_variables
                facts = extract_state(state, game_size[0], health, ammo, kills)
                threat = facts.closest_enemy
                if threat is not None:
                    last_seen_side = 1 if threat.dx_norm > 0 else -1

                traced = score_actions_traced(facts, last_seen_side)
                evidence = facts.evidence()
                evidence["rules"] = [
                    {"rule": f.rule, "action": f.action, "delta": f.delta, "note": f.note}
                    for f in traced.firings]
                decision = head.decide(traced.scores, evidence=evidence)
                latencies.append(decision.latency_us)
                total_decisions += 1
                receipts.write(json.dumps(decision.receipt()) + "\n")

                if renderer is not None:
                    graph = build_graph_state(
                        evidence, traced.firings, decision, kills, total_decisions)
                    if panel is not None and total_decisions % 2 == 0:
                        panel.update(graph)
                    if recorder is not None and state.screen_buffer is not None:
                        recorder.add(compose_video_frame(
                            Image, state.screen_buffer.tobytes(), game_size,
                            renderer.render(graph)))

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

                game.make_action(one_hot[decision.choice], frame_skip)

            for _, confidence, kills_then in pending_attacks:
                outcomes.record(confidence, kills > kills_then)
            total_kills += kills
            print(f"episode {episode + 1}: kills={kills:.0f}")

    wall = time.perf_counter() - wall_start
    game.close()
    if panel is not None:
        panel.close()

    report = {
        "mode": "watch" if watch else "headless",
        "episodes": episodes,
        "total_kills": total_kills,
        "kills_per_episode": round(total_kills / episodes, 1),
        "decisions": total_decisions,
        "decisions_per_sec_wall": round(total_decisions / wall, 1),
        "decision_latency_us_median": round(statistics.median(latencies), 1),
        "decision_latency_us_p99": round(sorted(latencies)[int(0.99 * len(latencies))], 1),
        "attack_outcomes_recorded": len(outcomes),
        "brier_score": round(outcomes.brier_score(), 4) if len(outcomes) else None,
        "receipts": str(receipts_path),
    }
    if recorder is not None:
        recorder.close()
        report["video"] = recorder.path
        report["video_frames"] = recorder.frames
    if len(outcomes) >= 10:
        report["reliability"] = [
            {"bin": f"{b.lo:.1f}-{b.hi:.1f}", "n": b.count,
             "mean_conf": round(b.mean_confidence, 3), "accuracy": round(b.accuracy, 3)}
            for b in outcomes.reliability(bins=5)]
    print(json.dumps(report, indent=2))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("episodes", nargs="?", type=int, default=5)
    parser.add_argument("--watch", action="store_true",
                        help="visible window + live decision panel, real-time 35fps")
    parser.add_argument("--record", metavar="OUT.mp4",
                        help="record gameplay + decision panel to an mp4")
    args = parser.parse_args()
    run(args.episodes, watch=args.watch, record=args.record)
