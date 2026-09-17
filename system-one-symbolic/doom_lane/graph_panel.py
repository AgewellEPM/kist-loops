"""The tiles traversing: live dataflow graph of every symbolic decision.

Same shape as TypeSafe's Jev demo graph — fact tiles on the left, rule nodes,
a typed-decision oval, action nodes on the right, with the traversed path
lighting up green each tic — except every node here is a REAL symbolic
object: fact tiles come from the labels buffer, rule nodes are the named
rules in policy.py, and the lit path is exactly what receipts.jsonl records.
Path = justification, drawn at 35fps. Cost ticker included ($0.0000, always).

One PIL renderer feeds both the live Tk window and the recorded mp4, so the
video and the on-screen view can never drift apart.
"""
from __future__ import annotations

from dataclasses import dataclass

PANEL_W = 800
PANEL_H = 480
MAX_ENEMY_TILES = 4

BG = (5, 8, 5)
AMBER = (217, 119, 6)
AMBER_BRIGHT = (245, 158, 11)
GREEN = (34, 197, 94)
GREEN_DIM = (20, 83, 45)
TEXT = (229, 231, 235)
TEXT_DIM = (110, 120, 110)

RULES = ("scan-memory", "opportunistic-fire", "track-the-threat",
         "ammo-discipline", "dry-gun")
# Static wiring: which fact tiles feed which rules (the graph's edge set).
RULE_INPUTS = {
    "scan-memory": ("enemies",),
    "opportunistic-fire": ("enemies", "ammo"),
    "track-the-threat": ("enemies",),
    "ammo-discipline": ("ammo",),
    "dry-gun": ("ammo",),
}


@dataclass(frozen=True)
class GraphState:
    """Everything the renderer needs — pure data, unit-testable without PIL."""
    fact_tiles: tuple[tuple[str, str], ...]   # (tile_key, tile_text)
    fired_rules: tuple[str, ...]
    actions: tuple[tuple[str, float, float], ...]  # (name, score, probability)
    choice: str
    confidence: float
    latency_us: float
    kills: float
    decisions_so_far: int


def build_graph_state(evidence: dict, firings, decision, kills: float,
                      decisions_so_far: int) -> GraphState:
    """Map one decision's receipt material onto graph nodes."""
    tiles = [
        ("health", f"health {evidence.get('health', 0):.0f}"),
        ("ammo", f"ammo {evidence.get('ammo', 0):.0f}"),
        ("kills", f"kills {kills:.0f}"),
    ]
    enemy_count = int(evidence.get("enemy_count") or 0)
    if enemy_count == 0:
        tiles.append(("enemies", "enemies: none"))
    else:
        nearest = evidence.get("nearest_name") or "enemy"
        dx = evidence.get("nearest_dx")
        tiles.append(("enemies",
                      f"{nearest} dx={dx:+.2f}" if dx is not None else nearest))
        if enemy_count > 1:
            tiles.append(("enemies+", f"+{enemy_count - 1} more visible"))
    actions = tuple(
        (name, decision.scores[name], decision.probabilities[name])
        for name in decision.probabilities)
    return GraphState(
        fact_tiles=tuple(tiles[:3 + MAX_ENEMY_TILES]),
        fired_rules=tuple(f.rule for f in firings),
        actions=actions,
        choice=decision.choice,
        confidence=decision.confidence,
        latency_us=decision.latency_us,
        kills=kills,
        decisions_so_far=decisions_so_far,
    )


class GraphRenderer:
    """Draws a GraphState as the Jev-style traversal graph. PIL only.

    rules/rule_inputs default to the simulator lane; the real-DOOM lane
    passes its own rule set and fact wiring at construction.
    """

    def __init__(self, width: int = PANEL_W, height: int = PANEL_H,
                 rules: tuple[str, ...] = RULES,
                 rule_inputs: dict[str, tuple[str, ...]] | None = None,
                 title: str = "SYMBOLIC TRAVERSAL — tiles > rules > typed decision"):
        from PIL import Image, ImageDraw, ImageFont
        self._image = Image
        self._imagedraw = ImageDraw
        self.width, self.height = width, height
        self._rules = rules
        self._rule_inputs = dict(RULE_INPUTS if rule_inputs is None else rule_inputs)
        self._title = title
        self._rule_spacing = min(74, max(42, (410 - 44) // max(1, len(rules))))
        try:
            self._font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 12)
            self._font_small = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 10)
            self._font_big = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 14)
        except OSError:
            default = ImageFont.load_default()
            self._font = self._font_small = self._font_big = default

    # -- node geometry ----------------------------------------------------
    def _fact_box(self, index: int) -> tuple[int, int, int, int]:
        y = 60 + index * 52
        return (18, y, 188, y + 36)

    def _rule_box(self, index: int) -> tuple[int, int, int, int]:
        y = 44 + index * self._rule_spacing
        return (250, y, 425, y + min(34, self._rule_spacing - 8))

    def _oval(self) -> tuple[int, int, int, int]:
        return (470, 190, 610, 260)

    _action_spacing = 80  # recomputed per render for larger action spaces

    def _action_box(self, index: int) -> tuple[int, int, int, int]:
        y = 120 + index * self._action_spacing
        return (650, y, 786, y + min(44, self._action_spacing - 12))

    @staticmethod
    def _mid_right(box):
        return (box[2], (box[1] + box[3]) // 2)

    @staticmethod
    def _mid_left(box):
        return (box[0], (box[1] + box[3]) // 2)

    # -- drawing ----------------------------------------------------------
    def render(self, graph: GraphState):
        self._action_spacing = min(80, max(56, (466 - 120) // max(1, len(graph.actions))))
        image = self._image.new("RGB", (self.width, self.height), BG)
        draw = self._imagedraw.Draw(image)

        draw.text((18, 12), self._title,
                  fill=GREEN, font=self._font_big)
        draw.text((18, 32), f"decision #{graph.decisions_so_far}   cost $0.0000   "
                            f"latency {graph.latency_us:.0f}us",
                  fill=TEXT_DIM, font=self._font_small)

        fact_boxes: dict[str, tuple] = {}
        fired = set(graph.fired_rules)
        # Facts consumed by any fired rule glow; wiring below mirrors RULE_INPUTS.
        consumed_keys = set()
        for rule in fired:
            consumed_keys.update(self._rule_inputs.get(rule, ()))

        # Edges first (under nodes): facts -> rules
        rule_boxes = {rule: self._rule_box(i) for i, rule in enumerate(self._rules)}
        for index, (key, _) in enumerate(graph.fact_tiles):
            fact_boxes[key] = self._fact_box(index)
        for rule, inputs in self._rule_inputs.items():
            for key in inputs:
                source = next((b for k, b in fact_boxes.items()
                               if k.rstrip("+") == key), None)
                if source is None:
                    continue
                active = rule in fired
                draw.line([self._mid_right(source), self._mid_left(rule_boxes[rule])],
                          fill=GREEN if active else GREEN_DIM,
                          width=2 if active else 1)
        # rules -> oval, oval -> actions
        oval = self._oval()
        for rule, box in rule_boxes.items():
            active = rule in fired
            draw.line([self._mid_right(box), (oval[0], (oval[1] + oval[3]) // 2)],
                      fill=GREEN if active else GREEN_DIM, width=2 if active else 1)
        action_boxes = {name: self._action_box(i)
                        for i, (name, _, _) in enumerate(graph.actions)}
        for name, box in action_boxes.items():
            chosen = name == graph.choice
            draw.line([(oval[2], (oval[1] + oval[3]) // 2), self._mid_left(box)],
                      fill=GREEN if chosen else GREEN_DIM, width=3 if chosen else 1)

        # Fact tiles
        for key, text in graph.fact_tiles:
            box = fact_boxes[key]
            hot = key.rstrip("+") in consumed_keys
            draw.rounded_rectangle(box, radius=6,
                                   outline=AMBER_BRIGHT if hot else AMBER,
                                   width=2 if hot else 1)
            draw.text((box[0] + 8, box[1] + 10), text,
                      fill=TEXT if hot else TEXT_DIM, font=self._font)
        draw.text((18, self._fact_box(len(graph.fact_tiles) - 1)[3] + 10),
                  "FACT TILES (labels buffer)", fill=TEXT_DIM, font=self._font_small)

        # Rule nodes
        for rule, box in rule_boxes.items():
            active = rule in fired
            draw.rounded_rectangle(box, radius=6,
                                   outline=GREEN if active else GREEN_DIM,
                                   width=2 if active else 1)
            draw.text((box[0] + 8, box[1] + 9), rule,
                      fill=GREEN if active else TEXT_DIM, font=self._font)

        # Decision oval
        draw.ellipse(oval, outline=GREEN, width=2)
        draw.text((oval[0] + 14, oval[1] + 14), "TYPED\nDECISION",
                  fill=GREEN, font=self._font)
        draw.text((oval[0] + 14, oval[3] - 22), f"conf {graph.confidence:.2f}",
                  fill=TEXT, font=self._font_small)

        # Action nodes with probability bars
        for name, score, probability in graph.actions:
            box = action_boxes[name]
            chosen = name == graph.choice
            draw.rounded_rectangle(box, radius=6,
                                   outline=GREEN if chosen else AMBER,
                                   width=3 if chosen else 1)
            draw.text((box[0] + 8, box[1] + 6), name,
                      fill=GREEN if chosen else TEXT_DIM, font=self._font)
            bar_w = int((box[2] - box[0] - 16) * probability)
            draw.rectangle((box[0] + 8, box[3] - 14, box[0] + 8 + bar_w, box[3] - 8),
                           fill=GREEN if chosen else GREEN_DIM)
            draw.text((box[0] + 8, box[3] - 28), f"p={probability:.2f}",
                      fill=TEXT if chosen else TEXT_DIM, font=self._font_small)

        draw.text((650, 40), "TYPED ACTIONS", fill=TEXT_DIM, font=self._font_small)
        draw.text((18, self.height - 22),
                  "every lit path == one receipt line (receipts.jsonl)",
                  fill=TEXT_DIM, font=self._font_small)
        return image


def compose_video_frame(image_mod, frame_rgb24: bytes, game_size: tuple[int, int],
                        graph_image) -> bytes:
    """Game frame left + traversal graph right -> one raw RGB24 video frame."""
    game = image_mod.frombytes("RGB", game_size, frame_rgb24)
    height = max(game_size[1], graph_image.height)
    canvas = image_mod.new("RGB", (game_size[0] + graph_image.width, height), BG)
    canvas.paste(game, (0, (height - game_size[1]) // 2))
    canvas.paste(graph_image, (game_size[0], (height - graph_image.height) // 2))
    return canvas.tobytes()


class LiveGraphWindow:
    """Tk window displaying the PIL-rendered graph, driven from the loop."""

    def __init__(self, renderer: GraphRenderer, title="Symbolic Traversal Graph"):
        import tkinter as tk
        from PIL import ImageTk
        self._imagetk = ImageTk
        self._tk = tk.Tk()
        self._tk.title(title)
        self._tk.configure(bg="black")
        self._tk.geometry(f"{renderer.width}x{renderer.height}+30+60")
        self._label = tk.Label(self._tk, bg="black")
        self._label.pack()
        self._photo = None
        self.renderer = renderer

    def update(self, graph: GraphState) -> None:
        image = self.renderer.render(graph)
        self._photo = self._imagetk.PhotoImage(image)
        self._label.config(image=self._photo)
        self._tk.update_idletasks()
        self._tk.update()

    def close(self) -> None:
        self._tk.destroy()
