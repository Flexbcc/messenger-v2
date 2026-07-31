# Cursor handoff — Messenger

Актуально на 2026-07-31. Репозиторий: `/Users/apple/messenger`, основной remote — Gitea.

## Текущий продукт

- Классический централизованный мессенджер с одной серверной нодой.
- Production PWA: `https://app.lineage2-stok.online/app/`.
- API доступны с того же origin через `/home/`, `/media/`, `/discovery/`, `/gateway/`.
- Пользователь может вручную указать другой адрес ноды для тестов.
- Телефон и почта необязательны. Идентичность пользователя — его криптографический ключ.
- Восстановления с сервера нет. Экспорт/импорт и перенос между устройствами должны сохранять ключ локально у пользователя.
- Сервер может временно хранить только необходимые для доставки зашифрованные данные и общие состояния вроде presence. Сервер не должен получать plaintext переписки или ключ восстановления.

## Где работать

- Flutter/PWA: `frontend/app/`.
- Backend и compose: `project/`.
- Production nginx: `project/deploy/nginx-messenger-site.conf`.
- PWA build: `frontend/app/scripts/build-web-pwa.sh`.
- Release manifest: `releases/clients/manifest.json`.
- Серверный checkout: `/opt/messenger-central`, compose-проект — `/opt/messenger-central/project`.

Не считать `project/client/messenger_app` главным Flutter-источником без проверки. Актуальные изменения клиента делаются в `frontend/app`.

## Обновления PWA и кеш

Flutter offline service worker намеренно отключён (`--pwa-strategy=none`), потому что он удерживал старые сборки и мог оставлять приложение на белом экране. Отдельный worker `/push/` используется только для push-уведомлений — его нельзя удалять или привязывать к обновлению приложения.

Каждая production-сборка получает `APP_BUILD_ID`. Скрипт создаёт рядом с приложением `deploy-version.json`. Запущенный клиент проверяет этот файл каждые 5 минут с cache-busting query и показывает баннер, если build ID изменился. Обновление применяется только по нажатию пользователя: это не обрывает ввод сообщения неожиданной автоматической перезагрузкой.

Критические правила:

1. Никогда не отправлять `Clear-Site-Data` для домена приложения.
2. Никогда автоматически не очищать IndexedDB, localStorage или пользовательские Cache Storage.
3. Не удалять worker со scope `/app/push/` (или `/push/` в зависимости от базового URL).
4. HTML, bootstrap, `main.dart.js`, `deploy-version.json` и release manifest должны revalidate/no-store согласно nginx-конфигу.
5. При изменении схемы локальной БД делать миграцию вперёд, а не удаление базы.
6. Принудительное обновление допустимо только для несовместимой версии протокола и после сохранения черновиков.

Первый релиз после добавления `APP_BUILD_ID` старый клиент сам распознать не сможет: его нужно один раз обновить вручную. Все следующие релизы определяются автоматически.

## Production build и проверка

```bash
cd /Users/apple/messenger/frontend/app
HOME_NODE_URL=https://app.lineage2-stok.online/home \
MEDIA_NODE_URL=https://app.lineage2-stok.online/media \
DISCOVERY_NODE_URL=https://app.lineage2-stok.online/discovery \
GATEWAY_NODE_URL=https://app.lineage2-stok.online \
RELAY_NODE_URL=https://app.lineage2-stok.online/relay \
PWA_BASE_HREF=/app/ \
./scripts/build-web-pwa.sh
```

Перед выкладкой:

```bash
/Users/apple/flutter/bin/dart format lib test
/Users/apple/flutter/bin/flutter analyze
/Users/apple/flutter/bin/flutter test
```

После выкладки проверить:

- `/app/deploy-version.json` содержит ID новой сборки и `Cache-Control: no-store`;
- `/app/main.dart.js` отвечает с revalidation, а не immutable cache;
- в уже установленной PWA через максимум 5 минут появляется баннер обновления;
- после перезагрузки сохраняются аккаунт, ключ, чаты и настройки;
- push-разрешение и push worker не пропали;
- новая переписка находится по ID и QR, сообщения проходят в обе стороны.

## Ближайшие задачи

1. Прогнать обновление между двумя реальными production build на iOS PWA и Android/Chrome PWA.
2. Добавить в экран «О приложении» build ID и кнопку «Проверить обновления».
3. Сохранять черновик сообщения локально до ручной перезагрузки.
4. Продолжить end-to-end тесты QR: контактный QR и QR переноса аккаунта — разные типы payload.
5. Проверить push: разрешение, подписка, доставка в фоне, переход из уведомления в нужный чат.

## Последние важные изменения

- `0b38fe1` — устранены зависания загрузки чата, добавлено QR-сканирование контакта.
- `460f807` — исправлены nginx/sendfile stalls.
- `2cb2714` — устойчивый запуск Flutter PWA без offline service worker.

VPN пользователя уже был причиной сетевого зависания загрузки production bundle. Не путать это с кешем: диагностировать Network/Console и заголовки ответа до изменения серверной архитектуры.
