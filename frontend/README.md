# frontend — Flutter-клиент мессенджера

Самостоятельный проект UI-клиента. Не зависит от загрузки всего репозитория.

- `app/` — Flutter-приложение (web-first сейчас; mobile/desktop — позже).
  - `lib/` — код: `theme/`, `widgets/` (ч/б, Apple HIG), экраны, крипто.
  - E2EE 1:1 и группы реально работают (libsignal_protocol_dart, sender-key).
  - Тесты: `flutter test` (crypto roundtrip, group crypto, live backend, private mode).

## Запуск
    cd app
    flutter pub get
    flutter test          # быстрый прогон
    flutter run -d chrome # web

## Что НЕ входит (вырезано при копировании)
- `build/`, `.dart_tool/`, `macos|ios/Pods/`, логи — генерируются локально.

## Связи
- Ходит в бекенд: home-node (:8001), media-node (:8004), discovery (:8003).
- Источник: `../project/client/messenger_app` (оригинал не трогается).
