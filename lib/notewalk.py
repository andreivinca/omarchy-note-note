"""The notebook walk shared by the local provider's scripts (list.py,
search.py): the notes root itself, then every non-hidden direct subfolder,
sorted by name. A symlinked folder is not ours and does not appear — the
same policy readfile.py applies to the files inside."""
import os


def notebook_keys(root):
    """Notebook keys, "" first for the root; [] when root is unreadable."""
    keys = [""]
    try:
        with os.scandir(root) as it:
            keys += sorted(e.name for e in it
                           if not e.name.startswith(".") and e.is_dir(follow_symlinks=False))
    except OSError:
        return []
    return keys
