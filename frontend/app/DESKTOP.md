# Desktop (macOS) — локальное тестирование

Клиент можно запускать на Mac без телефона. Бэкенд должен быть поднят локально (Home / Media / Discovery nodes).

## Требования

- Flutter SDK с поддержкой macOS (`flutter config --enable-macos-desktop`)
- CocoaPods (`brew install cocoapods`)
- Xcode Command Line Tools

## Быстрый старт

```bash
cd project/client/messenger_app
chmod +x scripts/run-desktop-macos.sh
./scripts/run-desktop-macos.sh
```

По умолчанию клиент ходит на:

| Сервис | URL |
|--------|-----|
| Home Node | `http://localhost:8001` |
| Media Node | `http://localhost:8004` |
| Discovery Node | `http://localhost:8003` |

Переопределение через переменные окружения:

```bash
HOME_NODE_URL=http://127.0.0.1:8001 ./scripts/run-desktop-macos.sh
```

## Сборка .app

```bash
/Users/apple/flutter/bin/flutter build macos \
  --dart-define=HOME_NODE_URL=http://localhost:8001 \
  --dart-define=MEDIA_NODE_URL=http://localhost:8004 \
  --dart-define=DISCOVERY_NODE_URL=http://localhost:8003
```

Артефакт: `build/macos/Build/Products/Release/messenger_app.app`

## Что работает на десктопе

- Чаты, звонки (WebRTC), настройки
- **OS-уведомления** — `flutter_local_notifications` (системный баннер macOS)
- **Блокировка приложения** — PIN при возврате из фона (тот же PIN, что в Private Mode)
- **Private Mode** — скрытые чаты в AES-GCM vault на диске

## Разрешения macOS

При первом запуске macOS может запросить:

- Уведомления
- Микрофон / камера (для звонков)

В `Info.plist` включён `NSAllowsLocalNetworking` для HTTP к localhost.

## Linux / Windows

Платформы уже добавлены (`linux/`, `windows/`). Запуск:

```bash
flutter run -d linux   # или windows
```

Те же `--dart-define` для URL бэкенда.
