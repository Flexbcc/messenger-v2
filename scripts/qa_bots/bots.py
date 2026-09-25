"""Bot persona wrapping HomeClient session."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from client import HomeClient, unique_label, unique_phone


@dataclass
class Bot:
    name: str
    client: HomeClient
    phone: str = ""
    password: str = "qa-bot-password-123"
    user_id: str = ""
    device_id: str = ""
    token: str = ""
    display_name: str = ""
    meta: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def create(
        cls,
        client: HomeClient,
        *,
        role: str,
        scenario: str,
        password: str = "qa-bot-password-123",
    ) -> Bot:
        label = unique_label(scenario, role)
        phone = unique_phone()
        bot = cls(
            name=role,
            client=client,
            phone=phone,
            password=password,
            display_name=label,
        )
        code, body = client.register(
            display_name=label,
            phone=phone,
            password=password,
            device_name=f"{role}-device",
        )
        if code != 200:
            raise RuntimeError(f"register {role} failed: {code} {body}")
        bot.user_id = body["user_id"]
        bot.device_id = body["device_id"]
        bot.token = body["access_token"]
        return bot

    def auth_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def get(self, path: str) -> tuple[int, Any]:
        return self.client.request("GET", path, token=self.token)

    def post(self, path: str, body: dict | None = None) -> tuple[int, Any]:
        return self.client.request("POST", path, token=self.token, json_body=body or {})

    def put(self, path: str, body: dict | None = None) -> tuple[int, Any]:
        return self.client.request("PUT", path, token=self.token, json_body=body or {})

    def login_again(self, device_name: str | None = None) -> tuple[int, dict]:
        code, body = self.client.login(
            identifier=self.phone,
            password=self.password,
            device_name=device_name or f"{self.name}-relogin",
        )
        if code == 200:
            self.user_id = body["user_id"]
            self.device_id = body["device_id"]
            self.token = body["access_token"]
        return code, body

    def create_direct(self, other_user_id: str) -> tuple[int, dict]:
        return self.post(
            "/conversations",
            {"type": "direct", "participant_user_ids": [other_user_id]},
        )

    def send_message(
        self,
        conversation_id: str,
        *,
        ciphertext: str,
        content_type: str = "text",
        client_msg_id: str | None = None,
    ) -> tuple[int, dict]:
        return self.post(
            f"/conversations/{conversation_id}/messages",
            {
                "ciphertext": ciphertext,
                "content_type": content_type,
                "crypto_version": "signal-v1",
                "client_msg_id": client_msg_id or str(uuid.uuid4()),
            },
        )

    def list_messages(self, conversation_id: str, limit: int = 50) -> tuple[int, Any]:
        return self.get(f"/conversations/{conversation_id}/messages?limit={limit}")

    def put_profile_settings(self, values: dict, lists: dict | None = None) -> tuple[int, Any]:
        return self.put(
            "/users/me/profile-settings",
            {"values": values, "lists": lists or {}},
        )

    def get_profile_settings(self) -> tuple[int, Any]:
        return self.get("/users/me/profile-settings")

    def update_profile(
        self,
        *,
        display_name: str | None = None,
        login: str | None = None,
        bio: str | None = None,
    ) -> tuple[int, Any]:
        body: dict[str, Any] = {}
        if display_name is not None:
            body["display_name"] = display_name
        if login is not None:
            body["login"] = login
        if bio is not None:
            body["bio"] = bio
        return self.put("/users/me/profile", body)

    def apply_privacy(
        self,
        values: dict[str, Any],
        lists: dict[str, list] | None = None,
        *,
        merge: bool = True,
    ) -> tuple[int, Any]:
        """Write privacy.* (+ optional lists). merge=True keeps prior blob values/lists."""
        if not merge:
            return self.put_profile_settings(values, lists or {})
        code, cur = self.get_profile_settings()
        if code != 200 or not isinstance(cur, dict):
            return self.put_profile_settings(values, lists or {})
        merged_values = {**(cur.get("values") or {}), **values}
        merged_lists = {**(cur.get("lists") or {}), **(lists or {})}
        return self.put_profile_settings(merged_values, merged_lists)

    def list_devices(self) -> tuple[int, Any]:
        return self.get("/users/me/devices")

    def security_signal(self, event: int, targets: list[str]) -> tuple[int, Any]:
        return self.post("/security-signals", {"event": event, "targets": targets})

    def ws_url(self) -> str:
        return self.client.ws_url(self.token)
