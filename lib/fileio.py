"""Confirmed atomic UTF-8 writes shared by local notes and host settings."""
import json
import os
import stat
import sys
import tempfile

MAX_PAYLOAD = 8 * 1024 * 1024


def write_atomic(path, text, exclusive=False, mode=0o600):
    """Commit a complete file; preserve an existing regular file's permissions."""
    try:
        current = os.lstat(path)
    except FileNotFoundError:
        current = None
    if current is not None:
        if not stat.S_ISREG(current.st_mode):
            raise OSError("destination is not a regular file")
        mode = stat.S_IMODE(current.st_mode)
    directory = os.path.dirname(os.path.abspath(path))
    fd, temporary = tempfile.mkstemp(prefix='.', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(text.encode('utf-8'))
            handle.flush()
            os.fsync(handle.fileno())
        if exclusive:
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
        return str(os.stat(path, follow_symlinks=False).st_mtime_ns)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    try:
        raw = sys.stdin.buffer.read(MAX_PAYLOAD + 1)
        if len(raw) > MAX_PAYLOAD:
            raise ValueError('file payload is too large')
        payload = json.loads(raw)
        path = payload['path']
        if payload.get('parents'):
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        version = write_atomic(path, payload['text'])
        result = {'ok': True, 'version': version}
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {'error': str(error)}
    json.dump(result, sys.stdout)
    return 1 if result.get('error') else 0


if __name__ == '__main__':
    sys.exit(main())
