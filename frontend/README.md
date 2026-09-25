# frontend — канонический Flutter-клиент мессенджера

Самостоятельный проект UI-клиента. Актуальное приложение находится в
`frontend/app` и не зависит от загрузки всего репозитория.

- `app/` — Flutter-приложение. Production-канал — Web/PWA; macOS и Android
  поддерживаются как внутренние тестовые сборки.
  - `lib/` — код: `theme/`, `widgets/` (ч/б, Apple HIG), экраны, крипто.
  - E2EE 1:1 и группы реально работают; доставка шифруется отдельно для
    каждого устройства получателя.
  - WebRTC-звонки, QR-контакты, multi-device sync и Private Mode подключены
    к реальному состоянию приложения, а не являются статическими моками.
  - Тесты: `flutter test` (crypto roundtrip, group crypto, live backend, private mode).

`frontend/app` — единственный источник клиента. Старый deploy-snapshot удалён,
чтобы сборки и тесты не могли случайно использовать устаревший код.

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

- Gateway/Discovery используются для bootstrap.
- Home Node обслуживает исходящие REST-операции и одно постоянное WSS-соединение
  клиента для realtime-доставки.
- Media/TURN используются только соответствующими функциями.
- Relay/Mix ноды клиент напрямую не выбирает: межнодовый маршрут строит
  инфраструктура.
- Получив пакет, клиент сохраняет или обрабатывает его и только после этого
  отправляет semantic device ACK. Серверное `home_accepted` не подменяет этот ACK.
