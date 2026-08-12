# Сборка клиентов (Messenger + Storage)

## Быстрый старт (macOS)

```bash
./scripts/build_clients.sh
./landing/scripts/sync-downloads.sh
# превью лендинга:
cd landing && python3 -m http.server 8080
# → http://localhost:8080
```

Артефакты: `dist/clients/<дата>/`  
Лендинг: `landing/` + `landing/downloads/*.zip`

## Автообновления (beta 0.1.0+)

- **Manifest:** `releases/clients/manifest.json`
- **Gateway:** `GET /releases/clients/manifest.json`
- **Генерация:** `./scripts/generate-release-manifest.sh`
- **Клиент:** баннер «Перезагрузить» (Web) или «Скачать» (desktop)

Bump версии в `pubspec.yaml` → `generate-release-manifest.sh` → rebuild → `sync-downloads.sh`.

---



## Что уже собирается на Mac (Apple Silicon)

Основной production-канал — PWA. Нативные сборки ниже предназначены для
внутреннего тестирования и не подписаны для публикации в магазинах.


| Цель            | Команда                         | Артефакт            |
| --------------- | ------------------------------- | ------------------- |
| Messenger macOS | `flutter build macos --release` | `messenger_app.app` |
| Messenger Web   | `flutter build web --release`   | `build/web/`        |
| Messenger Android | `flutter build apk --release` | `app-release.apk`   |
| Storage macOS   | `flutter build macos --release` | `storage_app.app`   |


Скрипт `scripts/build_clients.sh` делает всё сразу и кладёт zip в `dist/clients/`.

### Dart defines (URL нод)

```bash
export HOME_NODE_URL=http://161.104.18.45:8001
export MEDIA_NODE_URL=http://161.104.18.45:8004
export DISCOVERY_NODE_URL=http://194.67.92.147:8003
export GATEWAY_NODE_URL=http://194.67.92.147:8007
```

Локально: `HOME_NODE_URL=http://localhost:8001 ./scripts/build_clients.sh`

---



## Требования по платформам



### macOS / iOS (общее)

```bash
xcode-select --install          # CLI tools
brew install cocoapods
flutter config --enable-macos-desktop
flutter doctor
```

**macOS release:** Xcode 15+, подпись ad-hoc (без notarization — Gatekeeper предупреждает).

**iOS IPA (ещё не в релизе):**

- Apple Developer Program ($99/год)
- Provisioning profile + signing cert в Xcode
- `flutter build ipa --export-options-plist=...`
- Или TestFlight через Xcode Archive



### Android APK / AAB

1. **JDK 17**
  ```bash
   brew install openjdk@17
   export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
   export PATH="$JAVA_HOME/bin:$PATH"
  ```
2. **Android SDK + cmdline-tools**
  ```bash
   # SDK обычно: ~/Library/Android/sdk
   # Скачать commandlinetools-mac с developer.android.com
   # Положить в $ANDROID_HOME/cmdline-tools/latest/
   export ANDROID_HOME="$HOME/Library/Android/sdk"
   export ANDROID_SDK_ROOT="$ANDROID_HOME"
   yes | sdkmanager --licenses
   sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"
  ```
3. **Сеть:** Gradle тянет зависимости с `repo.maven.apache.org` и `dl.google.com`.
  Если сборка падает на download — проверьте VPN/DNS/firewall.
4. **Сборка**
  ```bash
   cd frontend/app
   flutter build apk --release "${DEFINES[@]}"
   # или AAB для Play Store:
   flutter build appbundle --release "${DEFINES[@]}"
  ```



### Windows (.exe)

- **Нужна Windows 10/11** (или CI runner `windows-latest`)
- Visual Studio 2022 с workload «Desktop development with C++»
- `flutter config --enable-windows-desktop`
- `flutter build windows --release`

На Mac нативный `.exe` **не** собирается.

### Linux

- Linux host (Ubuntu 22.04+)
- `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`
- `flutter build linux --release`



### Storage App

- Desktop: `storage-app/app` — macOS / Windows / Linux
- **Android/iOS не добавлены** — при необходимости: `flutter create --platforms=android,ios .`

---



## Деплой лендинга на MAIN

На `194.67.92.147` (gateway / nginx / static):

```bash
# после sync-downloads.sh
rsync -avz landing/ root@194.67.92.147:/var/www/messenger/
```

Или смонтировать `landing/` в docker-compose gateway/nginx как `/` или `/download`.

Web-клиент можно отдавать как статику:

- `landing/downloads/messenger-web/` → `https://your-domain/app/`

---



## Чеклист перед публикацией

- [ ] `flutter doctor` без критичных ✗ на целевой платформе
- [ ] Dart defines указывают на prod-ноды (не localhost)
- [ ] `./scripts/build_clients.sh` завершился без ошибок
- [ ] `./landing/scripts/sync-downloads.sh`
- [ ] macOS: smoke-test `open dist/clients/.../Messenger.app`
- [ ] Web: `python3 -m http.server` в `messenger-web/`, логин/чат
- [ ] Android: подпись keystore (`key.properties`) перед Play Store
- [ ] iOS: notarization / App Store review
- [ ] Windows: SmartScreen — нужен code signing cert

---



## CI (рекомендация)

GitHub Actions / Gitea Actions matrix:


| Job     | Runner           | Output             |
| ------- | ---------------- | ------------------ |
| macos   | `macos-14`       | `.zip` arm64 + x64 |
| android | `ubuntu-latest`  | `.apk`             |
| windows | `windows-latest` | `.zip`             |
| web     | `ubuntu-latest`  | `web/` artifact    |


Артефакты → `dist/clients/` → `sync-downloads.sh` → deploy landing.
