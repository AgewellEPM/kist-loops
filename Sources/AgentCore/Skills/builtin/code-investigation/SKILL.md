---
name: code-investigation
description: Use when you need to understand an unfamiliar codebase or subsystem before changing it — locating where a feature lives, tracing a call path, or building a mental model of how files fit together. Read this before editing code you have not already read in this session.
user-invocable: true
license: MIT
---

# Code investigation procedure

Goal: understand enough of the real code to change it safely — never edit a file you have not
read, never assume an API exists without seeing it.

## Procedure

1. **Orient first.** Read the applicable root instructions (`AGENTS.md`, `README.md`, and
   `CLAUDE.md` when present) and the named task specification. When paths are already known,
   batch their independent windows with the relevant source files in `read_files`. Use a
   directory listing only when you need to discover the layout or confirm which files exist.
2. **Discover what is missing.** Use `glob_files` for unknown paths and `search_code` for
   unknown symbols or relevant callers. A known path or a complete observation does not need
   another discovery call. Search for the *callee* when finding affected call sites and the
   *type name* when its definition or uses are still unknown.
3. **Read the real thing.** Use `read_files` for independent source windows when available,
   otherwise `read_file`. Keep skill reads separate with `read_file`. Confirm signatures and
   behavior from source. Follow each reported continuation or omission; do not claim clipped
   contents were read. Reuse already observed paths, ranges and digests until an edit, changed
   snapshot or specific unanswered question makes another read necessary.
4. **Trace the path end to end.** For a behavior, follow it from entry point → the function
   that implements it → its callers and callees. Note every site that shares the pattern you
   intend to change; a fix usually touches more than one.
5. **State your model before editing.** Summarize what you found — which files own what, where
   the change must land, and which sibling sites need the same change — then make the edit.

## Anti-patterns

- Editing a file you only grepped and never read.
- Assuming a helper/method exists because the name "should" be there — verify in source.
- Fixing the one site that failed while leaving identical sibling sites unchanged.
- Repeating a directory listing, search or completed read merely to follow a ritual sequence.
- Losing observed ranges and pending continuations when recording progress or compacting context.
