#!/usr/bin/env python3
"""12 — Ten-user usage simulation: chats, call signals, privacy, security alerts.

Writes a human-readable play-by-play to reports/simulation_10_users.md
"""
from __future__ import annotations

import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bots import Bot
from client import unique_login
from harness import exit_code, home_url, run_scenario
from policy import calls_allowed, incoming_messages_allowed, username_search_allowed

REPORTS = Path(__file__).resolve().parents[1] / "reports"

# Distinct personas with different privacy postures
PERSONAS = [
    ("alice", "Открытая: все могут писать/звонить, username search ON"),
    ("bob", "Контакты only: звонки и сообщения от контактов"),
    ("carol", "Строгая: nobody messages, calls selected (только alice)"),
    ("dave", "Username OFF — не находится по @login"),
    ("erin", "Обычная: invites + calls contacts"),
    ("frank", "Блокирует dave"),
    ("gina", "Allowlist звонков: erin"),
    ("hank", "Невидимый online + read receipts off"),
    ("ivy", "Группы nobody, иначе открыта"),
    ("jude", "Доверенный контакт alice — ловит security_signal"),
]


@dataclass
class Story:
    lines: list[str] = field(default_factory=list)

    def add(self, text: str) -> None:
        self.lines.append(text)
        print(text)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(self.lines) + "\n", encoding="utf-8")


def scenario(client, report) -> None:
    story = Story()
    story.add("# Симуляция: 10 пользователей")
    story.add("")
    story.add(f"- home: `{home_url()}`")
    story.add(f"- ts: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    story.add("")
    story.add("## Персоны")
    story.add("")

    bots: dict[str, Bot] = {}
    for role, blurb in PERSONAS:
        bot = Bot.create(client, role=role, scenario="sim10")
        bots[role] = bot
        story.add(f"- **{role}** (`{bot.user_id[:8]}…`) — {blurb}")

    report.expect(len(bots) == 10, title="registered 10 users", expected="10", observed=str(len(bots)))

    # ── Settings postures ──────────────────────────────────────────────────
    story.add("")
    story.add("## Настройки")
    story.add("")

    alice, bob, carol, dave = bots["alice"], bots["bob"], bots["carol"], bots["dave"]
    erin, frank, gina, hank = bots["erin"], bots["frank"], bots["gina"], bots["hank"]
    ivy, jude = bots["ivy"], bots["jude"]

    login_alice = unique_login("alice")
    login_dave = unique_login("dave")
    alice.update_profile(login=login_alice, display_name="Alice Open")
    dave.update_profile(login=login_dave, display_name="Dave Hidden")

    alice.apply_privacy(
        {
            "privacy.username_search": True,
            "privacy.incoming_messages": "everyone",
            "privacy.calls_from": "everyone",
            "privacy.phone_search": "everyone",
        },
        {"security.trusted_contacts": [jude.user_id]},
    )
    bob.apply_privacy(
        {
            "privacy.incoming_messages": "contacts",
            "privacy.calls_from": "contacts",
            "privacy.username_search": True,
        }
    )
    carol.apply_privacy(
        {
            "privacy.incoming_messages": "nobody",
            "privacy.calls_from": "selected",
        },
        {"privacy.calls_allowlist": [alice.user_id]},
    )
    dave.apply_privacy({"privacy.username_search": False})
    frank.apply_privacy({}, {"contacts.blocked_list": [dave.user_id]})
    gina.apply_privacy(
        {"privacy.calls_from": "selected"},
        {"privacy.calls_allowlist": [erin.user_id]},
    )
    hank.apply_privacy(
        {
            "privacy.online_status": False,
            "privacy.read_receipts": False,
            "privacy.invisible_mode": True,
        }
    )
    ivy.apply_privacy({"privacy.group_invites": "nobody", "privacy.incoming_messages": "everyone"})
    jude.apply_privacy({"notifications.security_alerts": True})

    _, alice_blob = alice.get_profile_settings()
    _, carol_blob = carol.get_profile_settings()
    _, dave_blob = dave.get_profile_settings()

    story.add(f"- alice username_search={username_search_allowed(alice_blob)}, login=`@{login_alice}`")
    story.add(
        f"- carol calls(alice)={calls_allowed(carol_blob, alice.user_id, is_contact=False)}, "
        f"calls(bob)={calls_allowed(carol_blob, bob.user_id, is_contact=False)}"
    )
    story.add(
        f"- carol incoming(bob)={incoming_messages_allowed(carol_blob, bob.user_id, is_contact=False)} "
        f"(клиент бы отклонил; сервер принимает)"
    )
    story.add(f"- dave username_search={username_search_allowed(dave_blob)} login=`@{login_dave}`")
    story.add(f"- frank blocked=[dave], gina allowlist=[erin], hank invisible+no receipts")
    story.add(f"- ivy group_invites=nobody; jude — trusted у alice")

    report.expect(
        calls_allowed(carol_blob, alice.user_id, is_contact=False)
        and not calls_allowed(carol_blob, bob.user_id, is_contact=False),
        title="carol allowlist: alice yes bob no",
        expected="alice True bob False",
        observed="ok",
    )

    # Discovery search
    time.sleep(0.5)
    sc_a, _ = client.discovery_search_login(login_alice)
    sc_d, body_d = client.discovery_search_login(login_dave)
    story.add("")
    story.add("## Поиск")
    story.add(f"- поиск `@{login_alice}` → HTTP **{sc_a}** (ожидаем 200)")
    story.add(f"- поиск `@{login_dave}` → HTTP **{sc_d}** (ожидаем 403, username OFF) body={body_d}")
    report.expect(sc_a == 200, title="find alice by username", expected="200", observed=str(sc_a))
    report.expect(sc_d == 403, title="dave hidden from username search", expected="403", observed=str(sc_d))

    # ── Social graph: conversations ────────────────────────────────────────
    story.add("")
    story.add("## Чаты и сообщения")
    story.add("")

    pairs = [
        (alice, bob, "Привет, Bob — это Alice"),
        (bob, erin, "Erin, ты на связи?"),
        (erin, frank, "Frank, план на вечер"),
        (frank, gina, "Gina, кинь файл позже"),
        (gina, hank, "Hank, ты онлайн? (он invisible)"),
        (hank, ivy, "Ivy, без групп ок?"),
        (ivy, jude, "Jude, alice тебя в trusted"),
        (alice, jude, "Jude — ты мой trusted contact"),
        (dave, frank, "Dave→Frank (frank блокирует dave на клиенте)"),
        (carol, alice, "Carol→Alice (carol никого не пускает первой — но пишет сама)"),
    ]

    conv_ids: dict[tuple[str, str], str] = {}
    for a, b, text in pairs:
        code, conv = a.create_direct(b.user_id)
        if code != 200:
            report.expect(False, title=f"conv {a.name}→{b.name}", expected="200", observed=f"{code} {conv}")
            continue
        cid = conv["id"]
        conv_ids[(a.name, b.name)] = cid
        c2, msg = a.send_message(cid, ciphertext=f"[sim] {text}")
        ok = c2 == 200
        report.expect(ok, title=f"msg {a.name}→{b.name}", expected="200", observed=str(c2), bot=a.name)
        # peer history
        c3, hist = b.list_messages(cid)
        seen = c3 == 200 and any(
            isinstance(m, dict) and m.get("ciphertext", "").startswith("[sim]") for m in (hist or [])
        )
        story.add(
            f"- **{a.name} → {b.name}**: «{text}» "
            f"{'✓ доставлено' if seen else '✗ не видно в истории'}"
        )
        report.expect(seen, title=f"history {b.name} sees {a.name}", expected="message in history", observed=str(seen))

    # Round of replies on alice↔bob
    cid_ab = conv_ids.get(("alice", "bob"))
    if cid_ab:
        bob.send_message(cid_ab, ciphertext="[sim] Bob: да, на связи")
        alice.send_message(cid_ab, ciphertext="[sim] Alice: супер, звоню")
        story.add("- **bob → alice**: «да, на связи»")
        story.add("- **alice → bob**: «супер, звоню»")

    # ── Call signaling ─────────────────────────────────────────────────────
    story.add("")
    story.add("## Звонки (signaling, без медиа)")
    story.add("")

    def call_flow(caller: Bot, callee: Bot, note: str) -> None:
        code, conv = caller.create_direct(callee.user_id)
        if code != 200:
            # may already exist — try list and skip
            story.add(f"- {caller.name}→{callee.name}: не удалось создать conv ({code})")
            return
        cid = conv["id"]
        caller.send_message(cid, ciphertext="sdp-offer", content_type="call_offer")
        callee.send_message(cid, ciphertext="sdp-answer", content_type="call_answer")
        caller.send_message(cid, ciphertext="ice", content_type="call_ice_candidate")
        callee.send_message(cid, ciphertext="bye", content_type="call_end")
        _, hist = callee.list_messages(cid)
        types = [m.get("content_type") for m in (hist or []) if isinstance(m, dict)]
        ok = all(t in types for t in ("call_offer", "call_answer", "call_end"))
        story.add(f"- **{caller.name} ⇄ {callee.name}**: {note} — signaling {'✓' if ok else '✗'} {types[-4:]}")
        report.expect(ok, title=f"call {caller.name}⇄{callee.name}", expected="offer/answer/end", observed=str(types))

    call_flow(alice, bob, "обычный звонок (оба открыты)")
    call_flow(alice, carol, "alice в allowlist carol — клиент пустит")
    call_flow(bob, carol, "bob НЕ в allowlist — сервер всё равно примет offer (клиент бы сбросил)")
    call_flow(erin, gina, "erin в allowlist gina")

    # ── Security signal to trusted ─────────────────────────────────────────
    story.add("")
    story.add("## Security signal (доверенный контакт)")
    story.add("")

    from client import collect_ws_events

    def trigger() -> None:
        alice.security_signal(11, [jude.user_id])

    events = collect_ws_events(jude.ws_url(), trigger=trigger, timeout=5.0)
    hit = any(e.get("type") == "security_signal" and e.get("from_user_id") == alice.user_id for e in events)
    story.add(
        f"- alice шлёт event=11 → jude (trusted): "
        f"{'✓ WS доставил' if hit else '✗ не дошло'} ({len(events)} events)"
    )
    report.expect(hit, title="jude got security_signal", expected="WS event", observed=repr(events[:3]))

    # ── Snapshot table ─────────────────────────────────────────────────────
    story.add("")
    story.add("## Сводка пользователей")
    story.add("")
    story.add("| User | user_id (short) | phone | posture |")
    story.add("|------|-----------------|-------|---------|")
    for role, blurb in PERSONAS:
        b = bots[role]
        story.add(f"| {role} | `{b.user_id[:8]}` | `{b.phone}` | {blurb.split(':')[0]} |")

    story.add("")
    story.add("## Важно")
    story.add("")
    story.add(
        "- Сообщения — opaque ciphertext (не настоящий E2EE decrypt).\n"
        "- Звонки — только signaling envelopes, без WebRTC/аудио.\n"
        "- Блокировки / incoming / calls_from частично **клиентские**: "
        "сервер может принять то, что UI отклонил бы.\n"
        "- Полный отчёт assertions — в выводе сценария / bugs.jsonl при fail."
    )

    out = REPORTS / "simulation_10_users.md"
    story.save(out)
    story.add("")
    story.add(f"Saved `{out}`")
    report.expect(out.exists(), title="wrote simulation report", expected="file exists", observed=str(out.exists()))


if __name__ == "__main__":
    sys.exit(exit_code(run_scenario("12_ten_users_simulation", scenario)))
