# Проверка desktop-клиента macOS — 24.09.2026

## Проверенный результат

- Flutter обновлён локально с 3.35.6 до 3.47.5 для поддержки Xcode 27.
- Минимальная версия приложения поднята до macOS 12.0.
- Release-сборка `Messenger.app` создана для Apple Silicon (`arm64`).
- Bundle ID: `com.messenger.messengerApp`, версия: `0.1.0+1`.
- Ad-hoc подпись и целостность вложенных frameworks прошли `codesign --verify`.
- Приложение действительно запущено; macOS видит процесс и нативное окно
  onboarding «Создать аккаунт».
- Полный Flutter-набор после клиентского аудита: 126 passed, 7 условных
  live-тестов skipped, 0 failed.
- Отдельные live-тесты E2EE ratchet (105/105 операций), multi-device и
  persistent WebSocket delivery: passed; повторный realtime замер — 27 мс.
- Chaos-тест трёх пользователей: 19 passed, 0 failed, 1 infrastructure warn.
- Flutter analyze: без ошибок.
- Обычная Web/PWA-сборка после миграции Dart JS interop: successful.

## Локальный тестовый пакет

`dist/clients/20260924/Messenger-0.1.0-macos-arm64-test.dmg`

SHA-256:

```text
c3b3522d146f992e1824fc89491fa83934c13cc51e950f32aeecbb1eaad1f577
```

Образ проверен `hdiutil verify`. Это тестовый, ad-hoc подписанный пакет для
Apple Silicon. Он не notarized и не является публичным production-релизом.

## Что остаётся до публичного macOS-релиза

1. Apple Developer ID signing и notarization.
2. Production HTTPS endpoints вместо локального HTTP-профиля.
3. Подписанный release manifest и проверка обновления.
4. Ручной UX-прогон двух независимых окон/устройств.
5. Отдельные Windows и Linux сборки на соответствующих runners.

## Инвариант локального обновления

Тестовые и release-обновления обязаны сохранять одновременно:

- `CFBundleIdentifier`;
- sandbox-entitlements;
- Keychain access policy;
- signing profile.

Нельзя проверять сохранность E2EE-сессии сборкой, которую вручную переименовали
и переподписали другим набором entitlements. macOS выдаст ей другой контейнер
данных; приложение перестанет видеть прежние Double Ratchet records, и уже
накопленные сообщения корректно завершатся ошибкой расшифрования.
