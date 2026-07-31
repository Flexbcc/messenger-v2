import os
from typing import Optional

from app.backends.base import BlobBackend


class LocalDiskBackend:
    name = "local"

    def __init__(self, root: str):
        self.root = root
        os.makedirs(self.root, exist_ok=True)

    def _path(self, key: str) -> str:
        return os.path.join(self.root, key)

    def put(self, key: str, data: bytes) -> None:
        path = self._path(key)
        os.makedirs(os.path.dirname(path) or self.root, exist_ok=True)
        if not os.path.exists(path):
            with open(path, "wb") as f:
                f.write(data)

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
