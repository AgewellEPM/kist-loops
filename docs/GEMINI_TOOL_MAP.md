# Gemini Full Tool Map — every tool, status in kist, terminal access

Goal: **full access to Gemini's entire tool surface inside the kist terminal.** This is the complete
checklist. Status: ✅ wired · ⚠️ partial · ❌ missing. Verified against live Google docs (June 2026).

---

## A. Generation core
| Tool | Status | Terminal access |
|---|---|---|
| generateContent / streamGenerateContent | ✅ | every turn |
| systemInstruction | ✅ | every turn |
| temperature / topP / maxOutputTokens | ✅ | per-turn settings |
| topK / stopSequences / seed / penalties | ❌ | (add to ModelSettings) |
| thinking: disable | ✅ | `--think` off |
| thinking: budget/level + thought summaries | ⚠️ | can only DISABLE today |

## B. Function calling
| Tool | Status | Terminal access |
|---|---|---|
| functionDeclarations (our tools) | ✅ | the whole agent loop |
| parallel + compositional calls | ✅ | agent loop |
| **toolConfig (AUTO/ANY/NONE)** | ✅ | `ModelSettings.toolChoice` |

## C. Built-in server-side tools
| Tool | Status | Terminal access |
|---|---|---|
| **google_search** (grounding + citations) | ✅ | auto, any turn; `Sources:` list |
| **url_context** (reads URLs in prompt) | ✅ | auto, any turn |
| **code_execution** (Python sandbox) | ✅ | auto, any turn |
| google_maps grounding | ❌ | location-grounded answers |

## D. Structured output
| Tool | Status | Terminal access |
|---|---|---|
| responseMimeType JSON | ✅ | `jsonOutput` setting |
| **responseSchema (strict schema)** | ✅ | `jsonSchema` setting |
| enum mode | ❌ | constrained single-label |

## E. Document understanding
| Tool | Status | Terminal access |
|---|---|---|
| PDF native vision | ✅ | `view_image` |
| **translate_document** (structure-preserving) | ✅ | `translate <doc> to <lang>` |
| large PDF via Files API | ✅ | automatic |

## F. Files API
| Tool | Status | Terminal access |
|---|---|---|
| upload + poll (big media) | ✅ | automatic on >20MB |
| delete / list (cleanup) | ❌ | hygiene (files leak ~48h) |

## G. Multimodal input
| Tool | Status | Terminal access |
|---|---|---|
| images | ✅ | drop / `view_image` |
| video (file + YouTube URL) | ✅ | `analyze_media`, `watch_video` |
| audio (understand + transcribe) | ✅ | `analyze_media` |

## H. Media GENERATION
| Tool | Status | Terminal access |
|---|---|---|
| **Nano Banana** — native image gen (`gemini-2.5-flash-image`) | ✅ | `generate_image` (Gemini-preferred, OpenAI fallback) |
| **image editing** | ✅ | `edit_image` (drop image + instruction → PNG) |
| **Veo — video generation** | ✅ PROTOTYPE | `generate_video` (slow, long-running) |
| **TTS — speech generation** | ✅ | `generate_audio` → WAV (voice Kore/Puck/…) |
| Lyria — music generation | ❌ | `generate_music` |
| Imagen | ❌ (deprecated Aug 2026 — skip) | use Nano Banana instead |

## I. Embeddings & retrieval
| Tool | Status | Terminal access |
|---|---|---|
| **embeddings + durable semantic memory** (`gemini-embedding-001`) | ✅ | `remember` / `recall` (file-backed vector store) |
| semantic retrieval / AQA | ❌ | grounded answers over a corpus |

## J. Realtime + infrastructure
| Tool | Status | Terminal access (once wired) |
|---|---|---|
| **Live API** (bidi WebSocket) | ✅ PROTOTYPE | `live_ask` (text round-trip; audio = future) |
| context caching (cost) | ❌ | automatic discount |
| batch mode (50% cost) | ❌ | `--batch` bulk jobs |
| countTokens | ❌ | pre-flight token/cost estimate |

## K. Separate Google product (needs GCP service account token)
| Tool | Status | Terminal access |
|---|---|---|
| **Cloud Translation v3** `translateDocument` (true PDF→PDF/DOCX fidelity) | ✅ | `translate_document fidelity:file` (needs GOOGLE_CLOUD_ACCESS_TOKEN + GOOGLE_CLOUD_PROJECT) |

---

## Build order (full access, ranked)
1. **Nano Banana** — native image gen/edit (route `generate_image` to Gemini). HIGH, low-med effort.
2. **TTS speech** — low effort API wrapper.
3. **Embeddings + semantic memory** — foundational (council #1).
4. **toolConfig + responseSchema + enum** — provider-level, makes existing tools stronger.
5. **Veo video gen**, **Live API**, **Cloud Translation v3** — higher effort / new surface.
6. **Files API cleanup**, **countTokens/caching/batch** — hygiene + cost.

Every item ships built→tested→Codex-reviewed→committed, labeled honestly.
