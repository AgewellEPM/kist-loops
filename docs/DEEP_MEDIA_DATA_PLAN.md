# Mythos · Deep Media + Data Understanding — Build Plan (Phase 5)

**Status:** PLAN (research-backed). Builds on the Phase 1–4 multimodal work (drag-in media, Gemini
Files API, multi-provider vision, TUI). Two tracks:

- **Track A — Media intelligence:** drop a video/audio clip and *interrogate* it — "what's this
  about", "give me the timestamped transcript", "what scenes do I need to watch", "at what time does
  X happen", and pull up the actual frame/clip at that moment.
- **Track B — Data intelligence:** read Excel/CSV, converse about *everything* in it (not just
  code), and "cross-compare this graph to that graph, tell me the difference" — then build project
  work from what it found.

---

## 0. What we already have after Phases 1–4
- Drag/attach image/video/audio/pdf; Gemini Files API upload+poll for big/long media.
- Multi-provider vision (image) + Gemini for video/audio; `/paste` from clipboard.
- The agent is a tool-using loop — new capabilities slot in as **AgentTools** the model calls.

**Key insight:** Gemini *already* does most of Track A. Our job is to make it **structured,
searchable, and navigable** — not to invent video understanding from scratch.

---

## 1. Research findings (June 2026)

### Video / audio
- **Gemini video understanding** natively supports: timestamped Q&A in `MM:SS` ("what happens at
  04:12?"), **timestamped transcripts** (optional speaker labels + visual descriptions),
  **scene/timeline detection**, chapter summaries, and **multi-video comparison**. Gemini 2.5 'low'
  media-res processes ~6h of video in a 2M-token context. Video is sampled at 1 fps, audio at 1Kbps.
  → "what's this about / transcript / which scenes / when does X happen" is achievable **with the
  Gemini we already wired** + structured prompting. No new vendor required for v1.
- **TwelveLabs** (specialist): Marengo (any-to-any video *search* embeddings) + Pegasus (time-based
  metadata partitioning to a user schema); beat Gemini 2.5 Pro ~30% on segmentation in early tests.
  → optional v2 upgrade for **semantic moment search across a library** of videos, not one clip.
- **Deepgram / AssemblyAI** (specialist): precise **word-level timestamps + speaker diarization**;
  Deepgram Nova-3 ~5.2% WER + <300ms streaming; AssemblyAI bundles summaries/sentiment/entities.
  → optional v2 for **broadcast-grade transcripts** when Gemini's 1Kbps audio isn't precise enough.
- **Local tooling (free, no API):** `ffmpeg` (extract keyframes/clips/thumbnails at a timestamp),
  **PySceneDetect** (content/threshold scene-cut detection). → pull the actual frame/clip at the
  moment Gemini flags, so "watch 04:12" becomes a thumbnail/clip on screen.

### Data / spreadsheets
- **DuckDB** — embedded columnar SQL engine, reads CSV/Parquet directly, **millions of rows in ms**,
  terminal-native, no server. v1.5.2 (Apr 2026) 6–18× faster min/max. → the scale path: model emits
  SQL, we execute, answer.
- **PandasAI** good for interactive <100K rows; **LangChain** for code-gen workflows. → the pattern
  is the same: LLM → SQL/Python → execute → answer.
- **Swift xlsx:** **CoreXLSX** (pure-Swift XLSX/XLSM/XLSB parser, Codable, fast, reads cells +
  styles). CSV is trivial. → read sheets without shelling out.
- **Graph compare, two ways:** (a) **vision** — screenshot/drag two chart images, Gemini compares
  (works the moment Phase 1–3 land + a compare prompt); precise enough for "what's different".
  (b) **data** — extract the chart's underlying series from the xlsx chart XML and diff numerically.
  → support both: vision for *any* graph image (even a photo), data-extraction for native xlsx charts.

---

## 2. Architecture decisions
1. **Everything new is an AgentTool.** The loop already calls tools; `analyze_media`,
   `read_spreadsheet`, `query_data`, `extract_clip`, `compare` become tools the model invokes when
   you drag a file or ask. No core-loop surgery.
2. **Gemini-first, specialist-optional.** v1 uses the Gemini we have (structured prompts → JSON).
   TwelveLabs / Deepgram are pluggable providers behind the same tool interface for v2 precision.
3. **Structured outputs, not prose.** Media analysis returns a typed `MediaIndex`
   (`summary`, `timeline[{at, label, why}]`, `transcript[{at, text, speaker?}]`, `keyMoments`).
   Cache it per file so follow-ups ("when does X happen?") search the index locally — fast + cheap.
4. **Local extraction for "show me the scene."** `ffmpeg`/PySceneDetect (system binaries, shelled
   via the existing run_command tool surface) pull the frame/clip at a timestamp. Degrade gracefully
   if not installed (report, don't crash).
5. **DuckDB for scale, CoreXLSX for structure.** Small sheets → CoreXLSX/CSV inline to the model;
   big data → load into DuckDB and let the model query by SQL. One `query_data` tool over both.
6. **Compare = vision OR data.** `compare` takes two sources (images → vision diff; xlsx chart refs
   → numeric series diff) and returns a structured difference report.

---

## 3. Phased build order (value first)

### Track A — Media intelligence
- **A1 · Structured media analysis (Gemini).** `analyze_media(path|attachment, want: summary|timeline|
  transcript|all)` → `MediaIndex` (typed JSON), cached per file hash. Renders a navigable index:
  chapters with `MM:SS`, "scenes worth watching", full timestamped transcript. SMALL — mostly a
  structured prompt + a Codable model over the Files-API path we already have.
- **A2 · Moment search.** "at what time does X happen?" → search the cached `MediaIndex`
  (transcript + timeline); fall back to a fresh Gemini timestamped query if not indexed. SMALL.
- **A3 · Pull the scene.** `extract_clip(path, at, ±window)` / `extract_frame(path, at)` via ffmpeg
  → a thumbnail/clip for the flagged moment (and PySceneDetect for auto scene cuts). MEDIUM (system
  dep: ffmpeg; graceful degrade).
- **A4 · Specialist providers (optional).** Deepgram/AssemblyAI for diarized word-level transcripts;
  TwelveLabs for semantic search across a *library*. Pluggable behind the A1/A2 tools. LARGER.

### Track B — Data intelligence
- **B1 · Read spreadsheets.** `read_spreadsheet(path)` via CoreXLSX (xlsx) + CSV → sheet list, shape,
  headers, a sampled preview, and per-column types. The model can now converse about the contents.
  MEDIUM (dep: CoreXLSX SPM package).
- **B2 · Query at scale.** `query_data(path, question|sql)` loads CSV/Parquet/xlsx-export into DuckDB
  and runs model-generated SQL (validated, read-only). Millions of rows. MEDIUM (dep: duckdb binary/lib).
- **B3 · Compare graphs.** `compare(a, b)` — two chart **images** → Gemini vision diff; two xlsx
  **chart refs** → extract series + numeric diff. Returns a structured difference report. MEDIUM.
- **B4 · Build from data.** Let the agent turn B1–B3 findings into project artifacts (reports,
  generated code, a chart) through the tools it already has. SMALL once B1–B3 exist.

---

## 4. New dependencies (call them out)
- **CoreXLSX** (SPM, pure Swift) — xlsx parsing. Low risk, pinned.
- **DuckDB** — CLI binary or C lib. Shell out to the `duckdb` CLI first (zero linkage risk); link the
  lib later if needed.
- **ffmpeg** + optional **PySceneDetect** — system binaries; detect presence, degrade gracefully.
- **Optional v2:** TwelveLabs, Deepgram/AssemblyAI API keys (new provider entries + key accounts).

## 5. Risks
- **Cost/latency on long video** (~300 tok/s; 6h at low-res = huge context). Pre-warn + confirm; cache
  the `MediaIndex` so re-asking is free.
- **System-binary availability** (ffmpeg/duckdb not installed). Detect + clear message + Gemini-only
  fallback. Never crash.
- **xlsx chart-series extraction** is fiddly (chart XML) — ship the **vision** compare first (works
  for any graph), add numeric data-compare as an enhancement.
- **SQL safety** — model-generated SQL must be read-only + sandboxed (DuckDB read-only mode, no file
  writes). Validate before execute.
- **Parallel session** — keep building in the `mythos-stage2-mm` worktree, commit each increment.

## 6. Recommendation
Two fast first wins that need **no new deps** and reuse what's built:
1. **A1+A2 (Gemini structured media index + moment search)** — "what's this about / transcript /
   which scenes / when does X" lands immediately on the Files-API path.
2. **B3 vision compare + B1 CSV read** — "compare these two graphs" works via vision now; CSV needs
   no dependency. xlsx (CoreXLSX) and DuckDB scale come next.

Then layer A3 (ffmpeg clips), B2 (DuckDB scale), and the optional specialist providers.

_Sources:_ Gemini video-understanding (ai.google.dev), TwelveLabs Marengo/Pegasus (twelvelabs.io),
Deepgram/AssemblyAI STT comparisons (deepgram.com, assemblyai.com), DuckDB CSV analysis (duckdb),
CoreXLSX (github.com/CoreOffice/CoreXLSX), ffmpeg/PySceneDetect (scenedetect.com). Links in chat.
