"""Map deliberate bio-mcp rejections onto the MCP error channel.

The mcpserver SDK only propagates `ToolError` messages to the caller; every
other exception is wrapped as a bare "Error executing tool X" and the detail
stays server-side. Validation rejections (ValueError) and upstream API
failures (BioAPIError) are deliberate, informative, and safe to surface —
convert them at the tool boundary so callers see WHY a call was refused.
"""

from __future__ import annotations

import functools
import inspect

from mcp.server.mcpserver.exceptions import ToolError

from .http import BioAPIError

_SURFACED = (ValueError, BioAPIError)


def surface_rejections(fn):
    """Decorator (stacked under @mcp.tool): re-raise deliberate rejections as ToolError."""
    if inspect.iscoroutinefunction(fn):

        @functools.wraps(fn)
        async def async_wrapper(*args, **kwargs):
            try:
                return await fn(*args, **kwargs)
            except _SURFACED as e:
                raise ToolError(str(e)) from e

        return async_wrapper

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except _SURFACED as e:
            raise ToolError(str(e)) from e

    return wrapper
