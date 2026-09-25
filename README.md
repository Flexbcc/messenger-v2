# OUO Messenger

Clean source repository for the OUO distributed end-to-end encrypted
messenger and node network.

## Repository layout

- `frontend/app/` — canonical Flutter client for Web, Android, iOS and desktop.
- `project/` — Home, Discovery, Relay, Storage, Media and Gateway nodes,
  administration UI, installers and protocol tests.
- `storage-app/app/` — optional personal desktop storage client.
- `landing/` — public product and installation pages.
- `scripts/` — QA and smoke-test tools.

There is no second copy of the Flutter client. Generated builds, local data,
secrets, release archives and historical project notes are intentionally not
stored here.

## Local node network

Requirements: Docker Desktop or Docker Engine with Compose.

```bash
cd project
./scripts/dev-up.sh
```

The script creates a local `.env`, generates independent development secrets,
validates the configuration and starts the stack. Signed or production nodes
must be provisioned through `project/scripts/bootstrap-node.py`; the local
profile is not a production security profile.

## Flutter client

Requirements: Flutter stable.

```bash
cd frontend/app
flutter pub get
flutter test
flutter run -d chrome \
  --dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=true \
  --dart-define=HOME_NODE_URL=http://127.0.0.1:8001
```

## Backend tests

Requirements: Python 3.11 or newer.

```bash
cd project
python3.11 -m venv .venv
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m pytest
```

Some integration tests are still being aligned with the current strict
security policies. A test failure must not be interpreted as an instruction
to weaken runtime validation.
