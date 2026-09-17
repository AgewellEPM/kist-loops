# symbolic-floor — subtree contract

This directory is a **git subtree** of the symbolic floor project.

- **Canonical home (per the science-loops rule):** here, `symbolic-floor/`
  in science-loops.
- **Runtime copy:** `~/.kist/workspaces/captain/symbolic_floor` — where the
  dashboard runs and where the floor DBs live (`data/` is gitignored in
  both; DBs never travel through git).

## Sync lanes (run from the science-loops repo root)

Pull the runtime copy's new commits into science-loops:

```bash
git subtree pull --prefix=symbolic-floor \
    ~/.kist/workspaces/captain/symbolic_floor main
```

Push science-loops-side edits back to the runtime copy:

```bash
git subtree push --prefix=symbolic-floor \
    ~/.kist/workspaces/captain/symbolic_floor from-science-loops
# then in the runtime copy: merge from-science-loops into main
```

**Do not edit the same files in both trees between syncs** — pick a side per
change. If both drifted, subtree pull will surface conflicts; resolve them
in science-loops (canonical) and push back.

## Verify after any sync

```bash
# runtime is stdlib-only; pytest is the only dev dependency
cd symbolic-floor && python3 -m venv .venv \
  && .venv/bin/pip install -q pytest \
  && .venv/bin/python -m pytest tests/ -q
```
