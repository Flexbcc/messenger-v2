# Клиент OUO — функциональный чек-лист

Этот документ — единый контракт проверки клиента. Статус `PASS` ставится
только после фактического автоматического или живого прогона. Наличие кода
само по себе не считается проверкой.

Статусы:

- `PASS` — сценарий воспроизведён, результат соответствует ожиданию;
- `FAIL` — сценарий воспроизведён и обнаружен дефект;
- `BLOCKED` — проверка требует отсутствующей среды или учётных данных;
- `NOT TESTED` — сценарий ещё не запускался после последних изменений.

## Правило каждого прогона

Для каждой функции фиксируются:

1. начальное состояние;
2. цепочка действий пользователя;
3. вариация среды или ошибки;
4. ожидаемый результат;
5. фактический результат и доказательство;
6. статус.

## Текущий срез

| Область | Вариация | Ожидаемый результат | Статус | Доказательство / примечание |
|---|---|---|---|---|
| Сборка | Flutter analyze | Нет ошибок | PASS | `flutter analyze`, 25.09.2026 |
| Сборка | Полный unit/widget suite | Все обязательные тесты проходят | PASS | `flutter test`: 131 passed, 7 live-only skipped, 0 failed; 25.09.2026 |
| Визуальная система | Каталог состояний | Все ключевые состояния читаемы, иконки и кириллица отображаются | PASS | 67/67 screenshot-сценариев; загружены Roboto и Material Icons; 25.09.2026 |
| Визуальная система | Светлая, тёмная и компактная темы | Сцены строятся без исключений и переполнений | PASS | `ui_theme_smoke_test`; входит в полный suite |
| Навигация | Телефон | Четыре основных раздела доступны снизу | PASS | существующий `NavigationBar`, проверен сборкой сцен |
| Навигация | Широкое окно / ПК | Навигация переносится в боковую панель, контент не растягивается бесконтрольно | PASS | breakpoint 840 px, `NavigationRail`, рабочая область до 1040 px |
| Состояния экранов | Чаты, звонки, контакты, устройства | Пустое состояние и ошибка имеют единый вид и понятное следующее действие | PASS | общий `AppEmptyState`; обновление пустого списка чатов остаётся доступно |
| Адаптивность | Сводка устройств на узком экране | Счётчики не выходят за границы | PASS | `Wrap` вместо непереносимой строки |
| Web | Release build | Артефакт собирается | PASS | `flutter build web` |
| macOS | Release build и запуск | Нативное окно запускается | PASS | локальный arm64 build; чистый `com.messenger.messengerApp.qa.ratchet2` запущен 24.09.2026 |
| Авторизация | Холодный старт с PIN | До PIN содержимое приложения недоступно | PASS | живой web-прогон + unit test |
| Авторизация | Неверный PIN | Доступ не предоставляется | PASS | живой web-прогон |
| Авторизация | Правильный PIN | Основной профиль открывается | PASS | живой web-прогон |
| Авторизация | Fake PIN | Открывается только decoy-контекст | PASS | живой web-прогон |
| Авторизация | Выход из decoy | Возврат на основной PIN, реальные чаты скрыты | PASS | живой web-прогон |
| Авторизация | Временный HTTP/сетевой сбой при старте | Локальная сессия сохраняется | PASS | production boot использует `SessionRestorePolicy`; 408/425/429/5xx, timeout, transport и parse failure retain; только 401/403/404 clear |
| Обновление | Идентичность release-артефакта | Bundle ID и обязательные sandbox/Keychain-связанные entitlements не меняются | PASS | `sh tool/verify_macos_release_identity.sh`: source config, built `Info.plist` и signed entitlements совпадают; bundle ID `com.messenger.messengerApp` |
| Обновление | Новая подписанная сборка поверх старой | Старая сессия и Keychain доступны после замены приложения | BLOCKED | ручная QA-переупаковка с другой подписью доказала отрицательный сценарий и зависла на старом Keychain item; положительный upgrade требует стабильного Developer ID/signing pipeline |
| E2EE | Два новых пользователя онлайн | Получатель расшифровывает, сервер plaintext не получает | PASS | `live_backend_integration_test` в предыдущем live-прогоне |
| E2EE | Перезапуск без смены подписи/контейнера | Identity, device-key и ratchet-сессия сохраняются | PASS | `crypto_persistence_restart_test`: отправитель и получатель реконструированы из persistence; обмен продолжился в обе стороны |
| E2EE | Переподпись с другим sandbox-контейнером | Обновление должно быть запрещено процедурой выпуска | BLOCKED | контейнеры действительно различаются; отдельный migration-тест впереди |
| E2EE | Одновременные text/read-receipt операции | Все мутации одной ratchet-сессии выполняются последовательно | PASS | общий `CryptoSerialQueue`, 20 concurrent jobs + 12 ciphertext roundtrip |
| E2EE | Сообщения, накопленные после потери ratchet state | Клиент честно показывает ошибку, не подделывает plaintext | PASS | macOS показал `не удалось расшифровать` |
| Сообщения | Быстрая серия из 10 сообщений | Ничего не теряется, порядок сохраняется | PASS | живой web-прогон |
| Сообщения | 100+ сообщений | Доставка и ratchet-порядок стабильны | PASS | live: 100 text + 5 read receipts через Home, 105/105 расшифрованы |
| Сообщения | Закрытие/повторное открытие чата | История сохраняется | PASS | живой web-прогон |
| Черновики | Выход и возврат в чат | Текст восстанавливается ровно один раз | PASS | контрольный живой прогон |
| Черновики | Черновики отключены | Старый черновик удаляется и не возвращается | PASS | `settings_runtime_contract_test` |
| Offline | Получатель выключен | Зашифрованные сообщения накапливаются и доставляются после возврата | PASS | 3 сообщения доставлены, unread=3 |
| Offline E2EE | Получатель читает накопленную серверную историю с тем же ratchet state | Все накопленные сообщения расшифровываются | PASS | чистый live-прогон: получатель без WS, 105/105 из истории расшифрованы |
| Offline E2EE | Полный restart crypto/application state перед следующим пакетом | Ratchet загружается с диска и следующий пакет расшифровывается | PASS | два restart-теста: cache ключа очищен, `CryptoService.loadOrCreate()` создан заново, следующий пакет и ответ расшифрованы |
| Realtime | Оба клиента постоянно онлайн | Доставка через persistent WebSocket без mailbox polling | PASS | live Docker: новый recipient держал WS, получил targeted envelope как `new_message`, расшифровал; повторный замер REST send → WS receive = **27 мс** |
| Блокировка | Заблокировать контакт | Входящие сообщения/звонки не принимаются; исходящие из старого экрана запрещены | PASS | единый `ContactInteractionPolicy`: blocked peer отклонён для initiate/message/call; контроллер использует policy во всех трёх путях |
| Блокировка | Разблокировать контакт | Общение снова разрешено с учётом обычной privacy-policy | PASS | policy tests: established peer разрешён после block check, новый peer всё ещё подчиняется incoming-policy |
| Блокировка | Перезапуск приложения и разные локальные аккаунты | Блок-лист сохраняется и не протекает между аккаунтами | PASS | runtime reconstruction test: Bob→Alice и Alice→Bob сохраняются независимо |
| Secret room | Верный дополнительный пароль | Комната открывается | PASS | живой web-прогон |
| Secret room | Слабый, но допустимый пароль | Предупреждение не блокирует сохранение | PASS | unit + живой прогон |
| Secret room | Пароль введён как команда | Пароль не отправляется сообщением | PASS | живой web-прогон |
| Secret room | Выход из комнаты | Секретный текст скрывается | PASS | живой web-прогон |
| Secret room | Повторная активация | Секретный текст снова доступен | PASS | живой web-прогон |
| Disappearing | Истечение TTL при открытом чате | Сообщение исчезает в заданный момент | PASS | deterministic clock test + ChatScreen планирует rebuild на ближайший фактический expiry, не ждёт 20-секундный background tick |
| Disappearing | Приложение было закрыто во время TTL | Просроченное сообщение не появляется после старта | PASS | reopen test: просроченное скрыто, постоянное остаётся |
| Multi-device | Второе устройство того же пользователя | Одноразовое enrollment, отдельный envelope и независимый ключ | PASS | live Docker: primary approved linked web-device; Home вернул 2 trusted device; ciphertext различался; оба устройства получили свой envelope и расшифровали |
| Recovery | Backup/restore на новом устройстве | Auth identity, Signal identity, local key и ratchet восстанавливаются без сервера | PASS | strengthened backup roundtrip: ключи удалены, импортированы, существующая E2EE-сессия продолжила decrypt/encrypt в обе стороны |
| Звонки | Web ↔ macOS audio | Signaling и media E2EE работают | NOT TESTED | E2EE signaling PASS; реальный media-path требует выданного browser/macOS microphone permission и двух интерактивных клиентов |
| Звонки | Логика reconnect | Disconnect запускает один ICE restart; recovery снимает ожидание; failure завершает звонок | PASS | `call_recovery_policy_test`: исчерпывающая матрица connected/disconnected/failed/connecting/closed; контроллер использует тот же policy |
| Звонки | Отказ/занято/reconnect на реальном media-path | UI и состояние возвращаются в норму | NOT TESTED | signaling encode/decode, recovery-policy и UI scenes PASS; реальный ICE disconnect/reconnect с двумя media-клиентами не запускался |
| Перезапуск | Web reload | Сессия, PIN, история и ключи сохраняются | FAIL | живой reload существующей QA-вкладки: до reload открывались чаты и черновик, после reload показана регистрация. Browser probe подтвердил, что `localStorage` сам по себе сохраняется (`previous=1` после reload); `session_store_restart_test` подтверждает current-format save/load и сохранение identity locator при отсутствии legacy-token. Для окончательного различения legacy-случая и текущего дефекта подготовлена регистрация чистого current-build аккаунта |
| Перезапуск | macOS restart без переподписи | Сессия и ratchet сохраняются | NOT TESTED | persistence reconstruction и чистый native launch PASS; пользовательская live-сессия в стабильном production-signed bundle не создана |
| Ошибки | Home временно недоступна | Клиент остаётся авторизованным; сетевой runtime может перейти offline | PASS | decision-matrix test подтверждает сохранение session/identity для HTTP 503 и transport timeout; offline-индикатор отдельно покрыт UI scenes |
| Ошибки | Повреждённый ciphertext | Fail closed, plaintext не показывается | PASS | crypto tests/UI state |

## Обязательные следующие прогоны

1. Войти двумя UI-клиентами в стабильных Web и production-signed macOS
   сборках, перезапустить их без пересборки и повторить E2EE-обмен.
2. Установить штатное обновление macOS с теми же Bundle ID, entitlements и
   Developer ID, затем подтвердить доступ к прежним Keychain/ratchet records.
3. Выдать локальному Web и macOS клиентам доступ к микрофону и выполнить
   audio call в обе стороны: answer, reject, busy, network disconnect/reconnect.

## План нормализации интерфейса

Работа ведётся по пользовательским потокам, а не механической заменой всех
виджетов сразу:

1. **Основа — выполнено:** шрифты, иконки, общая тема, адаптивная основная
   навигация, одинаковые состояния основных списков.
2. **Ключевые потоки — в работе:** регистрация/вход, создание контакта,
   создание чата, отправка сообщения, устройства и приватный режим. Для каждого
   проверяются обычное, пустое, загрузочное и ошибочное состояния.
3. **Сложные экраны:** чат, звонок и настройки безопасности — проверка
   приоритетов действий, опасных подтверждений, длинного текста и узких экранов.
4. **Финальный visual QA:** телефон, планшет/узкое окно и ПК; светлая, тёмная и
   компактная темы; затем ручной проход по фактической Web/macOS сборке.

Нормализация не должна менять E2EE, маршрутизацию или серверные контракты. Если
проверка интерфейса обнаруживает функциональный дефект, он фиксируется отдельной
строкой этого чек-листа и исправляется отдельным коммитом.

## Воспроизводимые команды последнего среза

Запускать из `frontend/app`. Live-команды рассчитаны только на закрытый
локальный Docker-стенд и намеренно требуют явного флага.

```bash
flutter analyze
flutter test --reporter compact
sh tool/verify_macos_release_identity.sh

RUN_LIVE_BACKEND=1 flutter test test/live_ratchet_concurrency_test.dart \
  --dart-define=HOME_NODE_URL=http://127.0.0.1:8001 \
  --dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=true

RUN_LIVE_BACKEND=1 flutter test test/live_multidevice_delivery_test.dart \
  --dart-define=HOME_NODE_URL=http://127.0.0.1:8001 \
  --dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=true

RUN_LIVE_BACKEND=1 flutter test test/live_realtime_delivery_test.dart \
  --dart-define=HOME_NODE_URL=http://127.0.0.1:8001 \
  --dart-define=ALLOW_INSECURE_BOOTSTRAP_HTTP=true
```

Фактический результат 24.09.2026:

- analyze: `No issues found`;
- основной suite: `131 passed`, `7 skipped`, `0 failed`;
- macOS release identity: bundle ID и обязательные signed entitlements `PASS`;
- ratchet: `100 text + 5 read_receipt`, расшифровано `105/105`;
- multi-device: primary + linked device получили разные envelopes и оба
  расшифровали;
- realtime: `27 ms` от завершения REST send до получения WS event;
- release build: Web и macOS (`Messenger.app`, 43.1 MB) собраны успешно.

## Критерий завершения

Клиентский этап нельзя считать готовым, пока обязательные строки не имеют
`PASS`, а каждый оставшийся `BLOCKED` / `NOT TESTED` не содержит конкретную
причину и следующий воспроизводимый шаг.
