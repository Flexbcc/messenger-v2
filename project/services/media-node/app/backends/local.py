import os
from pathlib import Path
from typing import Optional

from app.backends.base import BlobBackend


class LocalDiskBackend:
    name = "local"

    def __init__(self, root: str):
        self.root = str(Path(root).resolve())
        os.makedirs(self.root, mode=0o700, exist_ok=True)

    def _path(self, key: str) -> str:
        if (
            not isinstance(key, str)
            or not key
            or len(key) > 1024
            or "\x00" in key
            or Path(key).is_absolute()
        ):
            raise ValueError("invalid local blob key")
        candidate = str((Path(self.root) / key).resolve())
        if os.path.commonpath((self.root, candidate)) != self.root:
            raise ValueError("local blob key escapes storage root")
        return candidate

    def put(self, key: str, data: bytes) -> None:
        path = self._path(key)
        os.makedirs(os.path.dirname(path) or self.root, mode=0o700, exist_ok=True)
        try:
            with open(path, "xb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
        except FileExistsError:
            # Blob keys are immutable. Content-addressed callers verify the
            # existing value when reading it.
            return

    def get(self, key: str) -> Optional[bytes]:
        path = self._path(key)
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as f:
            return f.read()

    def delete(self, key: str) -> None:
        path = self._path(key)
        if os.path.isfile(path):
            os.remove(path)

    def exists(self, key: str) -> bool:
        return os.path.isfile(self._path(key))
