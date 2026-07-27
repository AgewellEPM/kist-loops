# Gemini Full Tool-Surface Integration Plan (kist)

Status: **PLAN / research-backed.** Verified against live Google docs (June 2026) + a full audit of
kist's current `GeminiProvider`, tools, and Files API. Build is phased; nothing here is shipped yet
except where noted.

---

## 1. What kist already has (audited)

- **Transport:** `v1beta` `streamGenerateContent` (SSE), key in `?key=` query param. Streaming only.
- **Request:** `contents`, `systemInstruction`, `generationConfig` (maxTokens; temp/topP except gemini-3;
  `thinkingBudget:0` to DISABLE thinking only), `tools.functionDeclarations` (lossy OpenAPI subset),
  media parts (`inline_data` ≤20MB, `file_data` via Files API).
- **Files API:** resumable upload + poll. No delete/list (files leak to ~48h TTL).
- **Tools backed by Gemini/vision today:** `analyze_media` (native timestamped video/audio),
  `view_image` (image + PDF as a *picture*, 12MB cap, no large-file path), `watch_video` (local ffmpeg
  frames), `live_screen_watch`, `visual_verify`. `generate_image` exists but uses **OpenAI, not Gemini**.
- **Capability flags TRUE for Gemini:** nativeTools, vision, video, audio, structuredOutput.

## 2. Gaps — Gemini features we DON'T use yet

| # | Capability | State in kist | Value |
|---|---|---|---|
| G1 | **Document understanding** (PDF native vision, 50MB/1000pg) | only `view_image` as a flat picture, 12MB, no Files-API path | HIGH |
| G2 | **Translation (style-preserving)** | none | HIGH (your headline) |
| G3 | **Google Search grounding** (`google_search`) | not wired; flag false | HIGH |
| G4 | **Code execution** (`code_execution`, Python sandbox) | not wired | HIGH |
| G5 | **URL context** (`url_context`, ≤20 URLs/req) | not wired | HIGH |
| G6 | **Structured output** (`responseSchema`/`responseMimeType`) | flag TRUE but **not actually wired** | HIGH |
| G7 | **Native image gen/edit** ("Nano Banana" `gemini-*-image`) | image-gen is OpenAI-only | MED |
| G8 | **`toolConfig`** (force/forbid calls, allowedFunctionNames, VALIDATED) | not sent (API default AUTO) | MED |
| G9 | **Thinking budget/level + thought summaries** | can only DISABLE thinking | MED |
| G10 | **Grounding/citation metadata parsing** | ignored | MED (ToS: must render Search suggestions) |
| G11 | **Embeddings** (`gemini-embedding-2`, multimodal) | none | MED (semantic memory/RAG) |
| G12 | **Veo video gen / TTS speech / Lyria music** | none | LOW–MED |
| G13 | **Live API** (realtime speech-to-speech translate, 70+ langs) | none | LOW–MED |
| G14 | **Context caching / batch / countTokens** | none | LOW (cost) |
| G15 | Files API cleanup (delete/list); richer tool schema (enums/nested) | missing | LOW (hygiene) |

## 3. THE translation fork (decides G2 — read before building)

Your ask: *"drop a document, translate it, **keep its original styles**."* There are two real paths and
they are NOT the same product:

- **A. Cloud Translation API v3 `translateDocument`** — the ONLY path that returns a **re-rendered file
  with original layout** (PDF→PDF/DOCX, DOCX→DOCX, PPTX, XLSX). Verbatim "preserves the original
  formatting and layout." Limits: native PDF ≤20MB/300 pages (scanned ≤20 pages). **Requires a Google
  Cloud project + service-account credentials** — NOT the AI Studio Gemini key kist uses today.
- **B. Gemini document understanding (existing key)** — translate + transcribe-to-HTML/Markdown
  preserving *structure* (headings/lists/tables/emphasis). Output is **text/HTML/Markdown, not the
  original file format.** Zero new auth; ships today. Also gives summarize/extract/Q&A on the same doc.

"Keep its original styles" in the strict sense = **A**. If you mean "keep the structure, readable, fast,
no new setup" = **B**. Many teams ship **B now**, add **A** when a true file-fidelity export is needed.

## 4. Phased build plan

**Phase 1 — Document + translation (your headline).**
- `translate_document` / `read_document` tool (Gemini, existing key): drop a PDF/image/text doc →
  translate to target language preserving structure → save Markdown/HTML + return summary. Large files
  via Files API (closes G1's 12MB limit). Closes G1 + G2(B).
- (If you pick path A) `Cloud Translation v3` client + service-account auth + `translate_document --fidelity=file`
  returning a re-rendered PDF/DOCX. Closes G2(A).

**Phase 2 — Gemini built-in superpowers (makes EVERY agent smarter, existing key).**
- Wire `google_search` grounding (G3) + parse `groundingMetadata`/citations and render Search
  suggestions per ToS (G10). Wire `url_context` (G5) + `code_execution` (G4). Add `toolConfig` (G8).
- Wire **structured output** for real (G6): `responseMimeType`/`responseSchema` so agent sub-calls can
  demand validated JSON.
- Flip the capability flags TRUE only as each is actually wired (honesty).

**Phase 3 — Generation + retrieval.**
- Native Gemini image gen/edit "Nano Banana" (G7) as a first-class alt to the OpenAI path.
- Embeddings (G11) → semantic memory/RAG over the project + past runs.
- Thinking budget/level + thought summaries (G9).

**Phase 4 — Realtime + media gen + hygiene.**
- Veo video / TTS speech / Lyria (G12). Live API speech-to-speech translation (G13).
- Context caching + batch + countTokens for cost (G14). Files API delete/list cleanup (G15).

## 5. How each piece plugs in (the seam)

- New tools follow the `view_image`/`analyze_media` pattern: implement `AgentTool`, take
  `registry: ProviderRegistry` + a vision `ProviderBinding` (or `geminiKey` for Files API), call
  `registry.complete(...)`. Register in `KistRunner.extraTools` (key/capability-gated) and add to
  `CapabilityRegistry.domains` so it's auto-advertised to every agent.
- Provider-level features (grounding, code-exec, url-context, structured output, toolConfig) are
  request-body additions in `GeminiProvider.makeBodyTools` + new SSE parsing for
  `groundingMetadata`/`executableCode`/`urlContextMetadata`. One provider change lights them up for
  ALL agents at once.

## 6. Caveats to honor (from the research)

- **Classic `generateContent` vs new Interactions API** — field names differ; we stay on classic v1beta
  (what kist + SDKs use) until a deliberate migration.
- **Imagen is EOL Aug 17 2026** — use Nano Banana, not Imagen, for G7.
- **Search-suggestion HTML must be rendered unmodified** (ToS) when grounding is on.
- Model IDs jumped to 3.x — confirm IDs on the Models page before hardcoding new media/live models.

Labels: every phase ships built→tested→Codex-reviewed→committed to its own branch, labeled honestly.
