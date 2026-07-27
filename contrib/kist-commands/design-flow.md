Start the DesignFlow headless autonomous design→code loop. DesignFlow ships inside
kist as the `designflow` binary (same SPM package), with a fail-closed trust spine:
every stage's artifact must exist, be fresh, land in the committed merge-set
(ClaimReconciler), and get a ForgeSeal-sealed signoff before the loop advances.

Do this now:

1. Locate the binary. Prefer `designflow` on PATH; else build it from the kist
   checkout: `swift build --product designflow` and use `.build/debug/designflow`.
2. Run ONE cycle and report honestly:
   `designflow run --once $ARGUMENTS`
   - If the user has no OpenAI key set (OPENAI_API_KEY / config.json), append
     `--dry-run` — it exercises the real loop mechanics with a deterministic stub
     and never spends. Say clearly that it was a dry run.
3. Report back: the workspace path, the artifacts produced
   (design/analysis.md → spec/features.md → Sources/App/Generated.swift → BUILD.md),
   the sealed-signoff chain status (intact?), and the Build Architect's REAL
   `swiftc -parse` verdict. Never round a FAIL up to a pass.

Other modes, only if the user asks:
- Continuous founder loop (BOUNDED — never drop the caps):
  `designflow run --interval 300 --max-cycles <n> --max-llm-calls <n>`
- One pipeline on a specific brief:
  `designflow pipeline --input "<brief>" [--dry-run]`
- Dry promotion check (consults the Ed25519 deploy gate, writes nothing, NEVER arms):
  `designflow promote --workspace <project dir>`

Non-negotiable safety:
- Never remove `--max-cycles` / `--max-llm-calls` from an unattended `run`.
- Never arm or auto-promote. The promotion gate is dry-consult only.
- DesignFlow is labeled PROTOTYPE: it proves loop mechanics + trust gates, not that
  the generated app is production-quality. Say so.
