# frontend — Flutter-клиент мессенджера

Самостоятельный проект UI-клиента. Не зависит от загрузки всего репозитория.

- `app/` — Flutter-приложение. Production-канал — Web/PWA; macOS и Android
  поддерживаются как внутренние тестовые сборки.
  - `lib/` — код: `theme/`, `widgets/` (ч/б, Apple HIG), экраны, крипто.
  - E2EE 1:1 и группы реально работают; доставка шифруется отдельно для
    каждого устройства получателя.
  - WebRTC-звонки, QR-контакты, multi-device sync и Private Mode подключены
    к реальному состоянию приложения, а не являются статическими моками.
  - Тесты: `flutter test` (crypto roundtrip, group crypto, live backend, private mode).

## Запуск
    cd app
    flutter pub get
    flutter test          # быстрый прогон
    flutter run -d chrome # web

Внутренние нативные сборки:

    flutter build macos --release
    flutter build apk --release

## Что НЕ входит (вырезано при копировании)
- `build/`, `.dart_tool/`, `macos|ios/Pods/`, логи — генерируются локально.

## Связи
- Ходит в бекенд: home-node (:8001), media-node (:8004), discovery (:8003).
- Источник: `../project/client/messenger_app` (оригинал не трогается).
