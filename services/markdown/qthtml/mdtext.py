"""Compatibility import for the shared Markdown text serializer."""
from . import _vendor  # noqa: F401
from mdtext import escape_inline, escape_line_start, escape_table_cell, code_span, code_fence  # noqa: F401
