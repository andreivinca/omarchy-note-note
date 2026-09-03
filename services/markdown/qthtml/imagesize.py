"""An image file's pixel width, from its header, without decoding it.

The editor displays images through Qt's rich text, which renders them at
natural size and clips at the pane — so the writer caps the *display* width
with a `width` attribute, and needs the natural width to know when. Reading
the header is enough; anything unreadable simply reports 0 and gets no cap.
"""
import os
import struct
import urllib.parse


def local_path(url, base=""):
    """The file an `<img src>` names: a file:// URL, or a relative src
    resolved against the document's base directory (the note's own folder,
    for local notebooks). Anything else — remote, data:, a bare absolute
    path — is not a file this module can measure, and answers ""."""
    if url.startswith("file://"):
        return urllib.parse.unquote(url[len("file://"):])
    if base and "://" not in url and not url.startswith(("/", "data:")):
        # `../../x.png`, and `%2Fetc%2Fpasswd`, which unquotes to an absolute
        # path after the test above has already let it through. Both are held
        # off by normalising the relative half and refusing one that climbs
        # out or was never relative. This keeps a property rather than closing
        # a hole: the src was typed by the user into their own note, names a
        # file they can already read as themselves, and all that leaves here
        # is a width — but "an image reference cannot escape the note's
        # directory" is cheaper to keep than to re-establish later, once
        # something else has started trusting the answer.
        rel = os.path.normpath(urllib.parse.unquote(url))
        if not os.path.isabs(rel) and rel != os.pardir \
                and not rel.startswith(os.pardir + os.sep):
            return os.path.join(base, rel)
    return ""


def width_of(path):
    """Pixel width of a PNG/JPEG/GIF/BMP file, or 0 when unknown."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(32)
            if head.startswith(b"\x89PNG\r\n\x1a\n") and len(head) >= 24:
                return struct.unpack(">I", head[16:20])[0]
            if head.startswith((b"GIF87a", b"GIF89a")) and len(head) >= 10:
                return struct.unpack("<H", head[6:8])[0]
            if head.startswith(b"BM") and len(head) >= 22:
                return struct.unpack("<i", head[18:22])[0]
            if head.startswith(b"\xff\xd8"):
                return _jpeg_width(handle, head)
    except (OSError, struct.error):
        pass
    return 0


def _jpeg_width(handle, head):
    """Walk the JPEG segments to the start-of-frame, bounded."""
    handle.seek(2)
    for _ in range(64):                          # a sane header has far fewer
        marker = handle.read(2)
        if len(marker) < 2 or marker[0] != 0xFF:
            return 0
        kind = marker[1]
        if 0xC0 <= kind <= 0xCF and kind not in (0xC4, 0xC8, 0xCC):
            seg = handle.read(7)
            return struct.unpack(">H", seg[5:7])[0] if len(seg) == 7 else 0
        length = handle.read(2)
        if len(length) < 2:
            return 0
        handle.seek(struct.unpack(">H", length)[0] - 2, 1)
    return 0
