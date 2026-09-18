# floor-proposer — training & deployment recipe

Own local model on top of the floor. The gate (contract.py + runtime.py)
makes ANY model airtight; training makes the local one *reliable*.

## The numbers rule (ripper discipline)
Never train blind. Baseline first, eval after, compare. Reports live in
`proposer/reports/`. Baseline (prompt-only llama3.2:3b, 27 held-out):
parse 0.741 · kind 0.63 · subject 0.304 · abstain-recall 0.5 — weak exactly
where it's dangerous (invented claim shapes, hallucinated accessions,
confident answers on fictional proteins). The gate rejected 100% of that.

## Dataset
Generated FROM the floor — witnessed gold only (the ripper's 71%-unwitnessed
lesson): `python -c "...proposer.dataset.write_dataset(Store(), 'data/training/proposer-v1')"`
180 pairs: claims (curated name→accession table only), extracts (accessions
the floor provably lacks), intents (params from the planner's own ranges),
abstains (fictional/off-domain/ambiguous). Every assistant turn passes
`parse_proposal` at build time — the dataset cannot teach what the gate rejects.

## Train (jeeves-ripper rig, MLX, M4)
```bash
HF_HOME=/Volumes/PRO-G40/jeeves-ripper/hf \
/Volumes/PRO-G40/jeeves-ripper/venv/bin/python -m mlx_lm lora \
  --model mlx-community/Llama-3.2-3B-Instruct-4bit --train \
  --data data/training/proposer-v1 --iters 300 --batch-size 2 \
  --adapter-path /Volumes/PRO-G40/floor-proposer/adapters
```

## Deploy to Ollama — the GGUF path that actually works
⚠️ `mlx_lm ... --export-gguf` is BROKEN (two ways; proven in the ripper
session). The working lane:
```bash
# 1. fuse adapter into bf16 weights (4-bit base can't fuse cleanly to GGUF —
#    fuse against the bf16 snapshot, also cached in the rig)
HF_HOME=/Volumes/PRO-G40/jeeves-ripper/hf \
/Volumes/PRO-G40/jeeves-ripper/venv/bin/python -m mlx_lm fuse \
  --model mlx-community/Llama-3.2-3B-Instruct-bf16 \
  --adapter-path /Volumes/PRO-G40/floor-proposer/adapters \
  --save-path /Volumes/PRO-G40/floor-proposer/fused
# 2. convert with llama.cpp (NOT mlx)
/Volumes/PRO-G40/jeeves-ripper/venv/bin/python \
  /Volumes/PRO-G40/jeeves-ripper/llama.cpp/convert_hf_to_gguf.py \
  /Volumes/PRO-G40/floor-proposer/fused \
  --outfile /Volumes/PRO-G40/floor-proposer/floor-proposer.gguf \
  --outtype q8_0
# 3. Modelfile + create
ollama create floor-proposer -f proposer/Modelfile
```

## Evaluate
```bash
.venv/bin/python -c "from symbolic_floor.store import Store; from proposer.evaluate import evaluate; import json; s=Store(); print(json.dumps(evaluate(s, 'data/training/proposer-v1/eval.jsonl', model='floor-proposer'), indent=2))"
```
Ship only if it beats baseline on parse AND abstain-recall without new false
abstains. The 4-bit-trained adapter fused onto bf16 is a mild mismatch —
acceptable for a format-teaching LoRA; retrain on bf16 if numbers disagree.

Weights live on PRO-G40 (never in git). The floor stays the only author of
facts regardless of which model proposes.
