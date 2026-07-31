from typing import Optional

from botocore.exceptions import ClientError

import boto3
from botocore.client import Config

from app.config_loader import S3Settings


class S3Backend:
    name = "s3"

    def __init__(self, cfg: S3Settings):
        self.cfg = cfg
        self._client = boto3.client(
            "s3",
            endpoint_url=cfg.endpoint_url or None,
            aws_access_key_id=cfg.access_key or None,
            aws_secret_access_key=cfg.secret_key or None,
            region_name=cfg.region or None,
            config=Config(signature_version="s3v4"),
        )

    def _object_key(self, key: str) -> str:
        prefix = (self.cfg.prefix or "").strip("/")
        if prefix:
            return f"{prefix}/{key}"
        return key

    def put(self, key: str, data: bytes) -> None:
        self._client.put_object(Bucket=self.cfg.bucket, Key=self._object_key(key), Body=data)

    def get(self, key: str) -> Optional[bytes]:
        try:
            resp = self._client.get_object(Bucket=self.cfg.bucket, Key=self._object_key(key))
            return resp["Body"].read()
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
                return None
            raise

    def delete(self, key: str) -> None:
        self._client.delete_object(Bucket=self.cfg.bucket, Key=self._object_key(key))

    def exists(self, key: str) -> bool:
        try:
            self._client.head_object(Bucket=self.cfg.bucket, Key=self._object_key(key))
            return True
        except ClientError:
            return False
