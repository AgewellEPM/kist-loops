"""URL path-segment hygiene for client-built endpoint URLs.

Every client interpolates caller-supplied identifiers into URL *paths*
(f"{BASE}/{ident}"). httpx does not encode path segments, and it normalizes
dot-segments client-side — so a crafted value containing '../', '?', '#', or
'/' can reroute the request to a different API operation, and a non-printable
character crashes URL parsing with an exception the error layer can't surface.
Route every such interpolation through path_segment().
"""

from __future__ import annotations

from urllib.parse import quote


def path_segment(value: str, *, what: str, safe: str = "") -> str:
    """Validate + percent-encode one caller-supplied URL path segment.

    - empty/whitespace-only → ValueError naming `what`
    - non-printable characters (\\n, \\t, NUL, ...) → ValueError
    - everything else percent-encoded so '/', '..', '?', '#' can never change
      the route. `safe` lists characters the target API requires literal
      (e.g. ':' for KEGG 'path:map00010' or HGVS notations) — keep it minimal.
    """
    v = (value or "").strip()
    if not v:
        raise ValueError(f"empty {what}")
    if not v.isprintable():
        raise ValueError(f"{what} contains non-printable characters: {value!r}")
    return quote(v, safe=safe)
