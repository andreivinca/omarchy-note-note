"""The vendored Markdown parser, one directory up.

Both directions need it — the writer to parse notes, the reader to check its
own output — and neither should care where it lives.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parse import parse, walk_text  # noqa: E402

__all__ = ["parse", "walk_text"]
