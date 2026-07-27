#!/usr/bin/env python3
"""
Minimal local transcription server.

POST /transcribe with raw audio bytes (e.g., WAV/PCM) and it returns JSON: {"text": "..."}.

Prefers MLX Whisper if available, falls back to OpenAI Whisper.

Install one of:
  pip install mlx-whisper flask soundfile
or
  pip install openai-whisper flask soundfile

Run:
  python Tools/mlx_whisper_server.py --port 8081 --model small
"""

import argparse
import io
import json
import os
import tempfile
from flask import Flask, request, jsonify

app = Flask(__name__)

ARGS = None

def transcribe_bytes(data: bytes, model_name: str):
    # Write to a temp file to support various backends easily
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(data)
        path = f.name

    # Try MLX Whisper first
    try:
        import importlib
        mw = importlib.import_module("mlx_whisper")
        # Heuristic API attempt (subject to the installed package version)
        # Most forks expose load_model() and transcribe()
        if hasattr(mw, "load_model") and hasattr(mw, "transcribe"):
            model = mw.load_model(model_name)
            result = mw.transcribe(model, path)
            # result may be a dict or object; try common forms
            if isinstance(result, dict) and "text" in result:
                return result["text"].strip()
            if hasattr(result, "text"):
                return str(result.text).strip()
        # Fallback: if there's a CLI module
        import subprocess, sys
        cmd = [sys.executable, "-m", "mlx_whisper", "transcribe", "--model", model_name, path]
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        return out.strip()
    except Exception:
        pass

    # Fallback: OpenAI Whisper
    try:
        import whisper
        model = whisper.load_model(model_name)
        result = model.transcribe(path, fp16=False)
        return result.get("text", "").strip()
    except Exception as e:
        return f"ERROR: No transcription backend available ({e})"
    finally:
        try:
            os.remove(path)
        except Exception:
            pass


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"ok": True}), 200


@app.route("/transcribe", methods=["POST"])
def transcribe_endpoint():
    data = request.get_data()
    if not data:
        return jsonify({"error": "empty body"}), 400
    text = transcribe_bytes(data, ARGS.model)
    return jsonify({"text": text})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--host", type=str, default="127.0.0.1")
    parser.add_argument("--model", type=str, default="small")
    global ARGS
    ARGS = parser.parse_args()
    app.run(host=ARGS.host, port=ARGS.port)


if __name__ == "__main__":
    main()

