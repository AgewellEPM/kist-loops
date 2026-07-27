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

1. **Orient first.** Read `AGENTS.md`, `README.md`, and any `CLAUDE.md` at the root before
   diving in — they often name the entry points and the conventions you must follow.
2. **Find by name, then by content.** Use `glob_files` to locate files by path pattern, then
   `search_code` to find the symbols/strings that matter. Search for the *callee* to find all
   call sites; search for the *type name* to find its definition and uses.
3. **Read the real thing.** Open the actual files with `read_file`. Page through large files
   with explicit line ranges. Confirm a function's signature and behavior from source — do not
   infer it from its name.
4. **Trace the path end to end.** For a behavior, follow it from entry point → the function
   that implements it → its callers and callees. Note every site that shares the pattern you
   intend to change; a fix usually touches more than one.
5. **State your model before editing.** Summarize what you found — which files own what, where
   the change must land, and which sibling sites need the same change — then make the edit.

## Anti-patterns

- Editing a file you only grepped and never read.
- Assuming a helper/method exists because the name "should" be there — verify in source.
- Fixing the one site that failed while leaving identical sibling sites unchanged.
