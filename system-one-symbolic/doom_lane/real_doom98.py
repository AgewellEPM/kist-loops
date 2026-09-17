#!/usr/bin/env python3
"""REAL DOOM (shareware 1.9, C:\\DOOMS in the win98 guest) under symbolic
control — the Perslis real-software lane, traced end to end.

The GhostBridge session owns the VM; this loop only observes frames and
taps keys via the perslis CLI. Per decision it writes a receipt with the
full justification graph, updates the live traversal-graph window, and
appends a composed (game + graph) frame to the evidence mp4.

This is the same architecture TypeSafe demoed against a Doom port fed
structured text state — except here the software is the actual 1993 binary
in a real Windows 98 guest, perception is arithmetic over the framebuffer,
and every decision is replayable from its receipt. Cost: $0.

Usage:
  .venv/bin/python -m doom_lane.real_doom98 --cycles 40 \
      [--start-game] [--live] [--record out.mp4]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from decision_head import DecisionHead, DecisionSpace
from doom_lane.graph_panel import GraphRenderer, GraphState, LiveGraphWindow
from doom_lane.qmp_client import PersistentQmp
from doom_lane.real_perception import perceive_images
from doom_lane.real_policy import REAL_ACTIONS, score_real_actions

QMP_DEFAULT = "/Users/lukekist/.perslis/qmp/win98/qmp.sock"
CAPTURE_DIR = "/Users/lukekist/.perslis/retroshell-v1-production-dos-qualified/captures"
ACTION_KEYS = {"TURN_LEFT": "left", "TURN_RIGHT": "right",
               "FORWARD": "up", "ATTACK": "ctrl", "OBSERVE": None}
CAMERA_MOVERS = {"TURN_LEFT", "TURN_RIGHT", "FORWARD", "ATTACK"}

REAL_RULES = ("look-before-acting", "fire-on-motion", "face-the-motion",
              "dry-gun", "stop-and-look", "scan-sweep", "explore-forward",
              "explore-look-bias")
REAL_RULE_INPUTS = {
    "look-before-acting": ("observed",),
    "fire-on-motion": ("blobs", "ammo"),
    "face-the-motion": ("blobs",),
    "dry-gun": ("ammo",),
    "stop-and-look": ("observed",),
    "scan-sweep": ("blobs",),
    "explore-forward": ("blobs",),
    "explore-look-bias": ("observed",),
}


def build_real_graph_state(state, firings, decision, cycle: int) -> GraphState:
    primary = state.primary_blob
    tiles = [
        ("observed", f"observed={'yes' if state.observed else 'NO (moved)'}"),
        ("blobs", f"motion blob dx={primary.dx_norm:+.2f}" if primary
                  else "motion blobs: none"),
        ("ammo", f"ammo red-mass {state.ammo_mass:.3f}"),
        ("health", f"health red-mass {state.health_mass:.3f}"),
    ]
    return GraphState(
        fact_tiles=tuple(tiles),
        fired_rules=tuple(f.rule for f in firings),
        actions=tuple((name, decision.scores[name], decision.probabilities[name])
                      for name in decision.probabilities),
        choice=decision.choice,
        confidence=decision.confidence,
        latency_us=decision.latency_us,
        kills=0.0,
        decisions_so_far=cycle,
    )


def start_new_game(guest: PersistentQmp) -> None:
    """Escape out of the attract demo and start E1M1 (default skill)."""
    print("starting new game: esc > new game > episode > skill")
    guest.send_keys(["esc", "ret", "ret", "ret"], gap_s=0.9)
    time.sleep(3.0)


def run(cycles: int, qmp: str, start_game: bool, live: bool,
        record: str | None) -> dict:
    guest = PersistentQmp(qmp, CAPTURE_DIR)
    head = DecisionHead(DecisionSpace("doom98.real", REAL_ACTIONS), temperature=0.6)
    renderer = GraphRenderer(rules=REAL_RULES, rule_inputs=REAL_RULE_INPUTS,
                             title="REAL DOOM (win98) — symbolic traversal")
    panel = LiveGraphWindow(renderer, title="Real DOOM — Symbolic Traversal") if live else None
    recorder = None
    if record:
        from PIL import Image
        from doom_lane.recorder import FrameRecorder
        recorder = FrameRecorder(record, 640 + renderer.width,
                                 max(480, renderer.height), fps=1)

    if start_game:
        start_new_game(guest)

    receipts_path = pathlib.Path(__file__).parent / "real_receipts.jsonl"
    latencies, cycle_walls = [], []
    action_counts = {action: 0 for action in REAL_ACTIONS}
    previous_image, _ = guest.capture()
    last_action = "OBSERVE"
    ticks_since_observe = 0
    explore_steps = 0

    with receipts_path.open("w") as receipts:
        for cycle in range(1, cycles + 1):
            wall0 = time.perf_counter()
            frame_image, frame_path = guest.capture()
            state = perceive_images(previous_image, frame_image,
                                    camera_moved=last_action in CAMERA_MOVERS)

            traced = score_real_actions(state, ticks_since_observe, explore_steps)
            evidence = state.evidence()
            evidence["rules"] = [
                {"rule": f.rule, "action": f.action, "delta": f.delta, "note": f.note}
                for f in traced.firings]
            evidence["frame"] = frame_path.name
            decision = head.decide(traced.scores, evidence=evidence)
            latencies.append(decision.latency_us)
            action_counts[decision.choice] += 1
            receipts.write(json.dumps(decision.receipt()) + "\n")

            graph = build_real_graph_state(state, traced.firings, decision, cycle)
            if panel is not None:
                panel.update(graph)
            if recorder is not None:
                from PIL import Image
                composed = Image.new("RGB", (recorder_width(renderer), 480), (5, 8, 5))
                composed.paste(frame_image, (0, 0))
                composed.paste(renderer.render(graph), (640, 0))
                recorder.add(composed.tobytes())

            key = ACTION_KEYS[decision.choice]
            if key is not None:
                guest.send_key(key)
            else:
                time.sleep(0.35)  # hold still so the next diff pair is clean

            ticks_since_observe = 0 if decision.choice == "OBSERVE" else ticks_since_observe + 1
            explore_steps = explore_steps + 1 if decision.choice in ("FORWARD", "TURN_RIGHT") and not state.blobs else 0
            last_action = decision.choice
            previous_image = frame_image
            cycle_walls.append(time.perf_counter() - wall0)
            print(f"cycle {cycle:3d}: {decision.choice:<10} "
                  f"conf={decision.confidence:.2f} "
                  f"obs={'y' if state.observed else 'n'} blobs={len(state.blobs)} "
                  f"({cycle_walls[-1]:.2f}s)")

    if panel is not None:
        panel.close()
    guest.close()
    report = {
        "lane": "real-doom98",
        "cycles": cycles,
        "decisions_per_sec_wall": round(1 / statistics.median(cycle_walls), 2),
        "cycle_wall_s_median": round(statistics.median(cycle_walls), 2),
        "decision_latency_us_median": round(statistics.median(latencies), 1),
        "action_counts": action_counts,
        "receipts": str(receipts_path),
    }
    if recorder is not None:
        recorder.close()
        report["video"] = recorder.path
        report["video_frames"] = recorder.frames
    print(json.dumps(report, indent=2))
    return report


def recorder_width(renderer) -> int:
    return 640 + renderer.width


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cycles", type=int, default=40)
    parser.add_argument("--qmp", default=QMP_DEFAULT)
    parser.add_argument("--start-game", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--record", metavar="OUT.mp4")
    args = parser.parse_args()
    run(args.cycles, args.qmp, args.start_game, args.live, args.record)
