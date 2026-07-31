"""Sealed Sender для federation (Task #68).

Скрывает sender_user_id от промежуточных нод (relay, hub) при доставке сообщений.
Принимающий Home-node — единственный кто может расшифровать реального отправителя.

Механизм:
  - Отправляющий Home-node знает receiver Home-node public key (из Discovery)
  - sender_user_id шифруется NaCl Box (ephemeral X25519 ECDH)
  - В envelope идёт `sealed_sender_box` вместо открытого `sender_user_id`
  - Relay nodes видят только `sealed_sender_box` — опак блоб
  - Принимающий Home-node расшифровывает используя свой private key

Это базовая реализация без receiver certificate (как в Signal).
Полноценный sealed sender требует отдельного механизма sender certificate.
"""
from __future__ import annotations

import base64
import json
import os
from typing import Optional

import nacl.public
import nacl.utils
from nacl.public import Box, PrivateKey, PublicKey, SealedBox

from shared.security.keys import load_or_create_signing_key


def _load_or_create_curve_key(path: str) -> PrivateKey:
    """Load or create X25519 key for sealed sender encryption."""
    from pathlib import Path
    p = Path(path)
    if p.is_file():
        raw = base64.urlsafe_b64decode(p.read_text().strip())
        return PrivateKey(raw)
    key = PrivateKey.generate()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(base64.urlsafe_b64encode(bytes(key)).decode())
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    return key


# Per-process cache (loaded once per startup)
_curve_key: Optional[PrivateKey] = None
_curve_key_path: Optional[str] = None


def get_or_create_curve_key(path: str) -> PrivateKey:
    global _curve_key, _curve_key_path
    if _curve_key is None or _curve_key_path != path:
        _curve_key = _load_or_create_curve_key(path)
        _curve_key_path = path
    return _curve_key


def curve_public_key_b64(private_key: PrivateKey) -> str:
    return base64.urlsafe_b64encode(bytes(private_key.public_key)).decode()


def seal_sender(
    sender_user_id: str,
    receiver_public_key_b64: str,
) -> str:
    """Зашифровать sender_user_id для конкретного receiver Home-node.

    Использует SealedBox (anonymous sender ECIES) — никаких метаданных об
    отправителе не утекает в зашифрованный блоб.

    Returns base64-encoded sealed box.
    """
    receiver_pk = PublicKey(base64.urlsafe_b64decode(receiver_public_key_b64))
    box = SealedBox(receiver_pk)
    ciphertext = box.encrypt(sender_user_id.encode("utf-8"))
    return base64.urlsafe_b64encode(ciphertext).decode()


def unseal_sender(
    sealed_box_b64: str,
    receiver_private_key: PrivateKey,
) -> Optional[str]:
    """Расшифровать sender_user_id. Возвращает None при ошибке."""
    try:
        box = SealedBox(receiver_private_key)
        raw = base64.urlsafe_b64decode(sealed_box_b64)
        plaintext = box.decrypt(raw)
        return plaintext.decode("utf-8")
    except Exception:
        return None
