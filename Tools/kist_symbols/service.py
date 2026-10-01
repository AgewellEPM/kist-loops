"""Bounded orchestration of runtime observations, Liberate and the symbolic floor."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import floor
from runtime import Observer, csv_bytes, flatten, page, pointer
from store import CAP, checked, decode, digest, encoded, name, need, publish, read, verify


class Service:
    def __init__(self, config):
        self.config = config
        self.root = checked(config["root"])
        self.observer = Observer(config.get("targets", {}))

    def artifact(self, kind, identifier):
        return checked(self.root / kind / name(identifier))

    def capabilities(self, grammar=False):
        out = {"schema": "kist-symbols-capabilities-v1", "model_calls": 0,
               "workflow": ["runtime_read → runtime_capture", "recover → dataset_schema",
                            "symbols_check → symbols_build → symbols_run"],
               "root": str(self.root), "sources": sorted(self.config.get("sources", {})),
               "targets": self.config.get("targets", {}),
               "datasets": "capture:<id> or recovery:<id>; inline data_json is also supported",
               "runtime_limits": "Only registered adapters and fields they expose. Up to five samples per capture, at most 1 Hz. No universal memory hook or continuous capture. A fresh HTTP read may contain an old or paused sample.",
               "legacy": "Use the configured Perslis/GhostBridge tools for VM identity, lifecycle, native state and acquisition. Recover an explicitly enrolled restored source with Liberate; no VM is started here.",
               "floor": "Closed tabular DSL: filters, joins, grouping, exact decimal reducers. Drafts run locally, labelled unapproved. Production signed tools still require the existing human-review/signing flow.",
               "cost": "No embedded model calls. Compact results; full evidence remains on disk. Request grammar=true only when composing a new spec."}
        if grammar:
            out["grammar"] = floor.guide()
        out["systems"] = []
        parent = checked(self.root / "systems")
        if parent.exists():
            for p in sorted(parent.iterdir()):
                if not p.name.startswith(".") and not p.is_symlink() and (p / "receipt.json").is_file():
                    out["systems"].append(p.name)
                    if len(out["systems"]) == 100:
                        out["systems_truncated"] = True
                        break
        return out

    def runtime_read(self, target, path="", offset=0, limit=30):
        _, value, meta = self.observer.fetch(target)
        return {**meta, "path": path, **page(pointer(value, path), offset, limit)}

    def runtime_capture(self, target, identifier, path="", samples=1, interval_seconds=1):
        # Check collision before contacting a running application.
        need(not self.artifact("captures", identifier).exists(), "Capture already exists; use a new identifier.")
        need(type(samples) is int and 1 <= samples <= 5 and type(interval_seconds) is int
             and 1 <= interval_seconds <= 5, "Use 1–5 samples, spaced 1–5 seconds apart.")
        import time
        rows, states, observations, files = [], [], [], {}
        for index in range(samples):
            if index:
                time.sleep(interval_seconds)
            raw, value, meta = self.observer.fetch(target)
            selected = flatten(pointer(value, path))
            rows.extend({**r, "sample": index} for r in selected)
            states.append({**{k: v for k, v in value.items() if v is None or type(v) in (str, int, float, bool)},
                           "_sample": index, "_observed_at": meta["observed_at"]})
            data = {"fields": rows, "state": states}
            floor.tables(data)
            files[f"snapshots/{index:03d}.json"] = raw
            observations.append(meta)
        files.update({"snapshot.json": raw, "tables.json": encoded(data), "source/fields.csv": csv_bytes(rows)})
        need(all(len(v) <= CAP for v in files.values()), "Capture exceeds the evidence budget.")
        dest, receipt = publish(self.root, "captures", identifier, files,
                                {"kind": "runtime_capture", "observation": meta, "observations": observations,
                                 "selection_pointer": path, "recorded": True})
        return {"status": "CAPTURED", "dataset": "capture:" + identifier, "artifact": str(dest),
                "observation": meta, "samples": samples, "selection_pointer": path,
                "fields": len(rows), "model_calls": 0,
                "receipt_sha256": digest(encoded(receipt)), "next": "dataset_schema or recover(source='capture:" + identifier + "')"}

    def liberate(self, *args):
        # Installed CLI owns extraction and integrity checks; never invoke its optional AI path.
        command = checked(self.config["liberate"])
        need(command.is_file() and os.access(command, os.X_OK), "Installed Liberate executable is unavailable.")
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "TMPDIR", "LANG")}
        env["LIBERATE_ALLOW_AI"] = "0"
        # File-backed bounded diagnostics: do not put a legacy dump into model context.
        import tempfile
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen([str(command), *map(str, args)], stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, env=env,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                import signal
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise ValueError("Liberate timed out; no completed job is claimed.")
            output.seek(0)
            message = output.read(16000).decode(errors="replace")
        need(code == 0, "Liberate refused or failed: " + message[:3000])
        return message

    def recover(self, source, identifier):
        if source.startswith("capture:"):
            capture = self.artifact("captures", source.split(":", 1)[1])
            receipt = verify(capture)
            src = capture / "source"
            system = receipt["observation"]["target"]
        else:
            need(source in self.config.get("sources", {}), "Unknown source. Enroll the explicitly selected restored folder in the host config.")
            src = checked(self.config["sources"][source])
            system = name(source)
        need(src.is_dir(), "The selected source folder is unavailable.")
        dest = self.artifact("recoveries", identifier)
        need(not dest.exists(), "Recovery job already exists; use a new identifier.")
        dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.liberate("recover", "--source", src, "--job", dest, "--system", system)
        self.liberate("verify-job", dest)
        job = decode(read(dest / "job.json"))
        return {"status": "RECOVERED", "dataset": "recovery:" + identifier,
                "artifact": str(dest), "result": job["result"], "model_calls": 0,
                "quality_note": "Integrity verifies the bundle; extraction_status and skipped counts describe format/data coverage."}

    def dataset(self, dataset="", data_json=""):
        need(bool(dataset) != bool(data_json), "Supply exactly one of dataset or data_json.")
        if data_json:
            need(len(data_json.encode()) <= CAP, "Inline evidence is too large.")
            # Decimal text is intentional: it preserves exact numeric evidence through JSON storage.
            data = json.loads(data_json, parse_float=str, object_pairs_hook=__import__("store").pairs,
                              parse_constant=lambda _: need(False, "Non-finite data is refused."))
            origin = {"kind": "inline", "description": "Caller-supplied evidence; not a runtime observation."}
        else:
            parts = dataset.split(":", 1)
            need(len(parts) == 2 and parts[0] in ("capture", "recovery"), "Use capture:<id> or recovery:<id>.")
            kind, identifier = parts
            if kind == "capture":
                dest = self.artifact("captures", identifier)
                receipt = verify(dest)
                data = decode(read(dest / "tables.json"))
                origin = {"kind": "recorded_runtime", "observation": receipt["observation"], "dataset": dataset,
                          "samples": len(receipt.get("observations", [receipt["observation"]])),
                          "selection_pointer": receipt.get("selection_pointer", "")}
            else:
                dest = self.artifact("recoveries", identifier)
                self.liberate("verify-job", dest)
                manifest = decode(read(dest / "bundle/manifest.json"))
                data = {}
                # Use canonical JSON exports, not formula-neutralized CSV or approximate SQLite arithmetic.
                for table in manifest["tables"]:
                    rel = "data/tables/" + table["name"] + ".json"
                    need(isinstance(rel, str) and not Path(rel).is_absolute() and ".." not in Path(rel).parts,
                         "Invalid Liberate export path.")
                    raw = read(dest / "bundle" / rel)
                    data[table["name"]] = json.loads(raw, parse_float=str)
                origin = {"kind": "liberate_recovery", "dataset": dataset,
                          "extraction_status": manifest.get("extraction_status")}
        floor.tables(data)
        return data, origin

    def dataset_schema(self, dataset="", data_json=""):
        data, origin = self.dataset(dataset, data_json)
        return {"tables": floor.schema(data), "origin": origin, "model_calls": 0}

    def symbols_check(self, spec_json, table, question, dataset="", data_json=""):
        data, origin = self.dataset(dataset, data_json)
        _, result = floor.check(decode(spec_json), data, table, question)
        return {**result, "origin": origin}

    def symbols_build(self, identifier, spec_json, table, question, dataset="", data_json=""):
        need(not self.artifact("systems", identifier).exists(), "System already exists; use a new identifier.")
        data, origin = self.dataset(dataset, data_json)
        spec, result = floor.check(decode(spec_json), data, table, question)
        if result["status"] == "REFUSED":
            return result
        dest, _ = publish(self.root, "systems", identifier,
                          {"spec.json": encoded(spec), "data.json": encoded(data), "review.json": encoded(result)},
                          {"kind": "symbolic_draft", "table": table, "origin": origin, "approved": False})
        return {**result, "system": identifier, "artifact": str(dest), "origin": origin,
                "next": "symbols_run rechecks the saved data and procedure without a model. Data is a frozen snapshot; capture and build a new revision to change evidence."}

    def symbols_run(self, identifier):
        dest = self.artifact("systems", identifier)
        receipt = verify(dest)
        spec = decode(read(dest / "spec.json"))
        data = decode(read(dest / "data.json"))
        _, result = floor.check(spec, data, receipt["table"], spec["question"])
        return {**result, "system": identifier, "origin": receipt["origin"], "recorded_evidence": True}
