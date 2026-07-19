// Сценарии раздела «OUO Home: безопасность и устойчивость сети» (разделы 24–29 ТЗ).
// Используют тот же event-sourcing движок (buildState) и мутации, что и network-
// сценарии — ничего в существующей реализации не меняется.
//
// Главная мысль: распределённость не устраняет уязвимости, а ограничивает радиус
// поражения; отдельные роли отключаются, ноды обновляются, личная работа
// продолжается даже при проблемах общественной сети.

import { EVENT_TYPE as ET, SEC_STATE as SS, CAPABILITY as CAP, EDGE_KIND as EK } from "./types.js";

const D = (ru, en) => ({ ru, en });

function scenario(id, ru, en) {
  const s = { id, title: D(ru, en), viewBox: "0 0 980 600", events: [], focus: "ouo-home" };
  let t = 0, seq = 0;
  s.push = (type, source, target, desc, why, mut) =>
    s.events.push({ id: `ev${++seq}`, time: t++, type, source, target, desc, why: why || null, mut: mut || [] });
  return s;
}

function addObj(s, obj, type, desc, why) {
  s.push(type || ET.NODE_STARTED, obj.id, null, desc, why || null, [{ op: "add", obj }]);
}
const E = (id, from, to, kind, status) => ({ op: "addEdge", id, from, to, kind, status: status || "active" });

// Базовый узел OUO Home с ролями, метриками и хранилищем.
function home(x = 300, y = 300, over = {}) {
  return {
    id: "ouo-home", kind: "home", label: "OUO Home", secState: SS.NORMAL,
    version: "2.3.1", supportState: "supported", knownCriticalVulnerability: false,
    capabilities: [CAP.MESSAGING, CAP.PERSONAL_STORAGE, CAP.SYNC, CAP.RELAY, CAP.UPDATE],
    metrics: { cpu: 12, ram: 30, disk: 40, connections: 4, transfers: 0, egress: 2, personal: 8, community: 40 },
    storage: { secureGb: 86, libraryGb: 412, freeGb: 1300 },
    x, y, ...over
  };
}

// Общие объекты сцены.
const PHONE = { id: "owner-phone", kind: "device", userId: "owner", type: "mobile", network: "wifi", connectedNodeId: "ouo-home", status: "online", x: 120, y: 470 };
const FRIEND = { id: "friend", kind: "friend", label: "Friend", status: "online", x: 820, y: 200 };
const RELAY = (over = {}) => ({ id: "relay-1", kind: "relay", secState: SS.NORMAL, capabilities: [CAP.RELAY], status: "online", x: 560, y: 150, ...over });
const S3 = { id: "s3", kind: "storage", ownerNodeId: "ouo-home", encrypted: true, status: "online", x: 560, y: 470 };
const NET = { id: "net", kind: "public", label: "OUO network", networkMode: "public", status: "online", x: 820, y: 420 };

/* ─────────── 1. Normal operation ─────────── */
function sec1() {
  const s = scenario("normal", "Нормальная работа", "Normal operation");
  addObj(s, home(), ET.NODE_STARTED, D("OUO Home запущен (личное хранилище + помощь сети)", "OUO Home started (personal storage + network assistance)"),
    D("OUO Home объединяет мессенджер, личную ноду, хранилище и синхронизацию в одном установочном приложении. Сложность (bootstrap, relay, NAT) скрыта внутри.",
      "OUO Home combines the messenger, personal node, storage and sync in one installable app. The complexity (bootstrap, relay, NAT) is hidden inside."));
  addObj(s, PHONE, ET.DEVICE_CREATED, D("Телефон владельца связан с OUO Home", "Owner phone paired with OUO Home"),
    D("Телефон связывается с домом одноразовым QR: взаимная крипто-проверка, подтверждение fingerprint, pairing-token уничтожается. Долгий секрет в QR не передаётся.",
      "The phone pairs via a one-time QR: mutual crypto check, fingerprint confirmation, the pairing token is destroyed. No long-lived secret is carried in the QR."));
  s.push(ET.USER_CONNECTED, "owner-phone", "ouo-home", D("Доверенный зашифрованный канал Phone ↔ Home", "Trusted encrypted link Phone ↔ Home"), null,
    [{ op: "addEdge", id: "phone-home", from: "owner-phone", to: "ouo-home", kind: EK.TRUSTED }]);
  addObj(s, FRIEND, ET.NODE_STARTED, D("Друг онлайн", "Friend is online"));
  addObj(s, RELAY(), ET.NODE_STARTED, D("Relay-нода сети", "Network relay node"));
  addObj(s, NET, ET.NODE_STARTED, D("Общая сеть OUO", "General OUO network"));
  s.push(ET.MESSAGE_SENT, "ouo-home", "friend", D("Сообщение другу по прямому зашифрованному каналу", "Message to friend over a direct encrypted channel"), null,
    [{ op: "addEdge", id: "home-friend", from: "ouo-home", to: "friend", kind: EK.DELIVERED }]);
  s.push(ET.MEDIA_UPLOADED, "owner-phone", "ouo-home", D("Файл сохранён в Secure Objects дома", "File saved to home Secure Objects"),
    D("Входящие файлы — отдельные зашифрованные объекты в Secure Objects. Компрометация файлового каталога не раскрывает переписку: S3-креды ≠ ключ чата ≠ ключ файла.",
      "Incoming files are separate encrypted objects in Secure Objects. Compromising the file catalog does not reveal chats: S3 creds ≠ chat key ≠ file key."),
    [{ op: "addEdge", id: "phone-home-media", from: "owner-phone", to: "ouo-home", kind: EK.MEDIA }]);
  s.push(ET.CAPACITY_ADVERTISED, "ouo-home", "net", D("Свободные ресурсы помогают сети (relay)", "Spare resources assist the network (relay)"),
    D("Частная нода добровольно помогает сети только свободными ресурсами и только явно включёнными ролями. Личные задачи всегда в приоритете.",
      "A private node assists the network only with spare resources and only via explicitly enabled roles. Personal tasks always take priority."),
    [{ op: "addEdge", id: "home-net", from: "ouo-home", to: "net", kind: EK.RELAY }, { op: "patch", id: "ouo-home", props: { metrics: { cpu: 18, ram: 34, disk: 40, connections: 16, transfers: 2, egress: 12, personal: 8, community: 60 } } }]);
  s.push(ET.HEALTH_CHECK, "ouo-home", null, D("Состояние: NORMAL — всё здорово", "State: NORMAL — everything healthy"), null, []);
  return s;
}

/* ─────────── 2. Home offline → fallback ─────────── */
function sec2() {
  const s = scenario("home-offline", "Домашний ПК выключен — fallback", "Home offline — fallback");
  addObj(s, home(), ET.NODE_STARTED, D("OUO Home в сети", "OUO Home online"));
  addObj(s, PHONE, ET.DEVICE_CREATED, D("Телефон владельца", "Owner phone"));
  s.push(ET.USER_CONNECTED, "owner-phone", "ouo-home", D("Доверенный канал Phone ↔ Home", "Trusted link Phone ↔ Home"), null, [{ op: "addEdge", id: "phone-home", from: "owner-phone", to: "ouo-home", kind: EK.TRUSTED }]);
  addObj(s, S3, ET.NODE_STARTED, D("Настроен S3 (резерв)", "S3 configured (fallback)"));
  addObj(s, FRIEND, ET.NODE_STARTED, D("Друг онлайн", "Friend online"));
  s.push(ET.NODE_OFFLINE, "ouo-home", null, D("Домашний ПК выключен — Home Node offline", "Home PC powered off — Home Node offline"),
    D("Когда дом выключен, часть функций личного облака временно недоступна. Система не падает — она переключается на резервные пути.",
      "When home is off, some personal-cloud functions are temporarily unavailable. The system does not fail — it switches to fallback paths."),
    [{ op: "status", id: "ouo-home", status: "offline" }, { op: "patch", id: "ouo-home", props: { secState: SS.OFFLINE } }, { op: "setEdge", id: "phone-home", kind: EK.ERROR }]);
  s.push(ET.MEDIA_UPLOADED, "owner-phone", "ouo-home", D("Загрузка на Home не удалась", "Upload to Home failed"), null,
    [{ op: "addEdge", id: "phone-home-fail", from: "owner-phone", to: "ouo-home", kind: EK.ERROR }]);
  s.push(ET.FALLBACK_USED, "owner-phone", "s3", D("Fallback: временная загрузка в S3", "Fallback: temporary upload to S3"),
    D("Порядок резерва: Home Node online → Home; иначе S3, если настроен; иначе прямая передача получателю; иначе локальная очередь на телефоне.",
      "Fallback order: Home Node online → Home; else S3 if configured; else direct transfer to recipient; else a local pending queue on the phone."),
    [{ op: "delEdge", id: "phone-home-fail" }, { op: "addEdge", id: "phone-s3", from: "owner-phone", to: "s3", kind: EK.MEDIA }]);
  s.push(ET.MESSAGE_SENT, "owner-phone", "friend", D("Прямая доставка другу (он онлайн)", "Direct delivery to friend (online)"), null,
    [{ op: "addEdge", id: "phone-friend", from: "owner-phone", to: "friend", kind: EK.DELIVERED }]);
  s.push(ET.NODE_ONLINE, "ouo-home", null, D("Дом снова включён — синхронизация догоняет", "Home back online — sync catches up"), null,
    [{ op: "status", id: "ouo-home", status: "online" }, { op: "patch", id: "ouo-home", props: { secState: SS.NORMAL } }, { op: "setEdge", id: "phone-home", kind: EK.TRUSTED }, { op: "delEdge", id: "phone-s3" }]);
  return s;
}

/* ─────────── 3. Personal load rises → community preempted ─────────── */
function sec3() {
  const s = scenario("personal-load", "Рост личной нагрузки", "Personal load rises");
  addObj(s, home(300, 300, { metrics: { cpu: 15, ram: 32, disk: 45, connections: 14, transfers: 2, egress: 12, personal: 10, community: 55 } }), ET.NODE_STARTED,
    D("OUO Home: мало личной нагрузки, много помощи сети", "OUO Home: low personal load, high network assistance"),
    D("Модель — не «40/60», а гарантированный приоритет: личная нагрузка может занять до 100%; общественная использует только свободное и вытесняема.",
      "The model is not a fixed 40/60 split but guaranteed priority: personal load may use up to 100%; community uses only spare capacity and is preemptible."));
  addObj(s, NET, ET.NODE_STARTED, D("Общая сеть", "General network"));
  s.push(ET.CAPACITY_ADVERTISED, "ouo-home", "net", D("Помощь сети: relay активен", "Network assistance: relay active"), null, [{ op: "addEdge", id: "home-net", from: "ouo-home", to: "net", kind: EK.RELAY }]);
  s.push(ET.STATE_CHANGED, "ouo-home", null, D("Началась личная синхронизация — нагрузка растёт", "Personal sync starts — load rises"), null,
    [{ op: "patch", id: "ouo-home", props: { secState: SS.BUSY, metrics: { cpu: 62, ram: 58, disk: 60, connections: 16, transfers: 5, egress: 10, personal: 60, community: 30 } } }]);
  s.push(ET.TASK_REJECTED, "ouo-home", "net", D("Новые relay-задачи сети отклоняются", "New relay tasks from the network are rejected"),
    D("Admission controller не ждёт полного отказа: при росте личной нагрузки он перестаёт принимать новые тяжёлые общественные задания, но завершает уже начатые короткие.",
      "The admission controller does not wait for total failure: as personal load rises it stops accepting new heavy community tasks while finishing short in-flight ones."),
    [{ op: "setEdge", id: "home-net", kind: EK.RETRY }]);
  s.push(ET.RESOURCE_PREEMPTED, "ouo-home", null, D("Личная нагрузка получает приоритет (до 100%)", "Personal workload gets priority (up to 100%)"), null,
    [{ op: "patch", id: "ouo-home", props: { metrics: { cpu: 95, ram: 72, disk: 70, connections: 8, transfers: 6, egress: 3, personal: 95, community: 3 } } }, { op: "setEdge", id: "home-net", kind: EK.BLOCKED }]);
  s.push(ET.HEALTH_CHECK, "ouo-home", null, D("Личные сервисы не деградируют", "Personal services do not degrade"), null, []);
  return s;
}

/* ─────────── 4. Overload progression ─────────── */
function sec4() {
  const s = scenario("overload", "Перегрузка: NORMAL → CRITICAL", "Overload: NORMAL → CRITICAL");
  addObj(s, home(), ET.NODE_STARTED, D("OUO Home: состояние NORMAL", "OUO Home: state NORMAL"),
    D("Admission controller оценивает CPU/RAM/диск/сеть/очереди/latency и переводит ноду между состояниями заранее, не дожидаясь отказа.",
      "The admission controller evaluates CPU/RAM/disk/network/queues/latency and transitions the node in advance, without waiting for failure."));
  addObj(s, NET, ET.NODE_STARTED, D("Общая сеть", "General network"));
  s.push(ET.CAPACITY_ADVERTISED, "ouo-home", "net", D("Публикация capacity: relay + temp storage", "Capacity advertised: relay + temp storage"), null, [{ op: "addEdge", id: "home-net", from: "ouo-home", to: "net", kind: EK.RELAY }]);
  s.push(ET.STATE_CHANGED, "ouo-home", null, D("BUSY: ограничивает новые тяжёлые задания", "BUSY: limits new heavy tasks"),
    D("BUSY — нода продолжает текущие задачи, но ограничивает приём новых тяжёлых заданий сети.", "BUSY — the node keeps current tasks but limits accepting new heavy network jobs."),
    [{ op: "patch", id: "ouo-home", props: { secState: SS.BUSY, metrics: { cpu: 66, ram: 60, disk: 55, connections: 40, transfers: 8, egress: 20, personal: 30, community: 36 } } }, { op: "setEdge", id: "home-net", kind: EK.RETRY }]);
  s.push(ET.STATE_CHANGED, "ouo-home", null, D("OVERLOADED: новые задания сети не принимаются", "OVERLOADED: new network jobs rejected"),
    D("OVERLOADED — нода перестаёт принимать новые задания общей сети; маршрутизаторы выбирают другие ноды.", "OVERLOADED — the node stops accepting new network jobs; routers pick other nodes."),
    [{ op: "patch", id: "ouo-home", props: { secState: SS.OVERLOADED, metrics: { cpu: 88, ram: 82, disk: 70, connections: 60, transfers: 12, egress: 25, personal: 40, community: 48 } } }, { op: "setEdge", id: "home-net", kind: EK.BLOCKED }]);
  s.push(ET.STATE_CHANGED, "ouo-home", null, D("CRITICAL: общественные функции отключены", "CRITICAL: community functions disabled"),
    D("CRITICAL — нода отключает общественные функции и оставляет только: управление, критические личные сообщения, завершение безопасных операций, восстановление и обновление.",
      "CRITICAL — the node disables community functions, keeping only: management, critical personal messages, finishing safe operations, recovery and updates."),
    [{ op: "patch", id: "ouo-home", props: { secState: SS.CRITICAL, capabilities: [CAP.MESSAGING, CAP.UPDATE], metrics: { cpu: 97, ram: 90, disk: 78, connections: 6, transfers: 1, egress: 2, personal: 95, community: 0 } } }, { op: "delEdge", id: "home-net" }]);
  s.push(ET.STATE_CHANGED, "ouo-home", null, D("Нагрузка спала → возврат к NORMAL", "Load subsides → back to NORMAL"), null,
    [{ op: "patch", id: "ouo-home", props: { secState: SS.NORMAL, capabilities: [CAP.MESSAGING, CAP.PERSONAL_STORAGE, CAP.SYNC, CAP.RELAY, CAP.UPDATE], metrics: { cpu: 20, ram: 35, disk: 60, connections: 12, transfers: 2, egress: 10, personal: 12, community: 40 } } }]);
  return s;
}

/* ─────────── 5. Network scan ─────────── */
function sec5() {
  const s = scenario("scan", "Сканирование сети", "Network scan");
  addObj(s, home(360, 320), ET.NODE_STARTED, D("OUO Home с публичным интерфейсом", "OUO Home with a public interface"));
  addObj(s, { id: "scanner-1", kind: "scanner", label: "Scanner", status: "online", x: 120, y: 200 }, ET.NODE_STARTED,
    D("Внешний сканер обращается к публичному адресу", "External scanner probes the public address"),
    D("Поверхность атаки минимизирована. До аутентификации нода не отдаёт версию, список пользователей, файлов, маршрутов, admin API или понятный protocol banner.",
      "The attack surface is minimized. Before authentication the node reveals no version, user list, files, routes, admin API or a readable protocol banner."));
  s.push(ET.SCAN_ATTEMPT, "scanner-1", "ouo-home", D("Запрос к публичному endpoint", "Request to the public endpoint"), null,
    [{ op: "addEdge", id: "scan", from: "scanner-1", to: "ouo-home", kind: EK.SERVICE }]);
  s.push(ET.SCAN_REJECTED, "ouo-home", "scanner-1", D("Требуется аутентификация — запрос отклонён / rate-limited", "Authentication required — request rejected / rate-limited"),
    D("Минимальный handshake → криптографическая аутентификация → проверка роли → только затем протокольные операции. Админ-интерфейс наружу не публикуется.",
      "Minimal handshake → cryptographic authentication → role check → only then protocol operations. The admin interface is never exposed externally."),
    [{ op: "setEdge", id: "scan", kind: EK.BLOCKED }]);
  s.push(ET.HEALTH_CHECK, "ouo-home", null, D("Сканер не увидел пользователей, файлов и версии", "Scanner saw no users, files or version"), null, []);
  return s;
}

/* ─────────── 6. Compromised relay ─────────── */
function sec6() {
  const s = scenario("bad-relay", "Компрометация Relay", "Compromised relay");
  addObj(s, home(160, 320), ET.NODE_STARTED, D("OUO Home (отправитель)", "OUO Home (sender)"));
  addObj(s, FRIEND, ET.NODE_STARTED, D("Друг (получатель)", "Friend (recipient)"));
  addObj(s, RELAY({ secState: SS.NORMAL }), ET.NODE_STARTED, D("Relay на маршруте", "Relay on the route"));
  addObj(s, { id: "relay-2", kind: "relay", secState: SS.NORMAL, capabilities: [CAP.RELAY], status: "online", x: 560, y: 420 }, ET.NODE_STARTED, D("Резервный relay-2", "Backup relay-2"));
  s.push(ET.MESSAGE_SENT, "ouo-home", "relay-1", D("Зашифрованный пакет уходит через relay-1", "Encrypted packet goes via relay-1"), null,
    [{ op: "addEdge", id: "home-r1", from: "ouo-home", to: "relay-1", kind: EK.RELAY }, { op: "addEdge", id: "r1-friend", from: "relay-1", to: "friend", kind: EK.RELAY }]);
  s.push(ET.NODE_COMPROMISED, "relay-1", null, D("relay-1 под контролем атакующего", "relay-1 is attacker-controlled"),
    D("Relay видит только зашифрованные пакеты и часть метаданных: время, объём, IP соседних участников, длительность. Содержимого, ключа вложения и chat-identity ключа у него нет.",
      "The relay sees only encrypted packets and some metadata: timing, volume, adjacent IPs, duration. It has no plaintext, no attachment key and no chat-identity key."),
    [{ op: "patch", id: "relay-1", props: { secState: SS.COMPROMISED } }, { op: "setEdge", id: "home-r1", kind: EK.ERROR }, { op: "setEdge", id: "r1-friend", kind: EK.ERROR }]);
  s.push(ET.TAMPER_DETECTED, "friend", "relay-1", D("Попытка изменить пакет обнаружена (AEAD/подпись)", "Packet tampering detected (AEAD/signature)"), null, []);
  s.push(ET.REPLAY_BLOCKED, "friend", "relay-1", D("Повторная отправка заблокирована (nonce/sequence/TTL)", "Replay blocked (nonce/sequence/TTL)"),
    D("Каждый объект несёт message_id, sequence, nonce, created_at/expires_at и подпись/AEAD. Повтор и подмена отклоняются, полям клиента нода не доверяет.",
      "Each object carries message_id, sequence, nonce, created_at/expires_at and a signature/AEAD. Replay and tampering are rejected; the node does not trust client-supplied fields."),
    []);
  s.push(ET.ROUTE_REVOKED, "ouo-home", "relay-1", D("Маршрут через relay-1 отозван, репутация снижена", "Route via relay-1 revoked, reputation reduced"), null,
    [{ op: "delEdge", id: "home-r1" }, { op: "delEdge", id: "r1-friend" }]);
  s.push(ET.FALLBACK_USED, "ouo-home", "relay-2", D("Маршрут переключён на relay-2", "Route switched to relay-2"), null,
    [{ op: "addEdge", id: "home-r2", from: "ouo-home", to: "relay-2", kind: EK.RELAY }, { op: "addEdge", id: "r2-friend", from: "relay-2", to: "friend", kind: EK.DELIVERED }]);
  return s;
}

/* ─────────── 7. Home Node compromise ─────────── */
function sec7() {
  const s = scenario("home-compromise", "Взлом Home Node (диск / процесс)", "Home Node compromise (disk / running)");
  addObj(s, home(), ET.NODE_STARTED, D("OUO Home с изоляцией компонентов", "OUO Home with component isolation"),
    D("OUO Home — не монолит: UI, Identity, Messaging, Storage, Sync, Community Worker, Update изолированы и имеют минимальные привилегии. Relay не читает библиотеку, Storage не имеет ключей чатов.",
      "OUO Home is not a monolith: UI, Identity, Messaging, Storage, Sync, Community Worker, Update are isolated with least privilege. Relay cannot read the library; Storage holds no chat keys."));
  addObj(s, S3, ET.NODE_STARTED, D("Secure Objects (зашифрованные)", "Secure Objects (encrypted)"));
  s.push(ET.DISK_STOLEN, "ouo-home", null, D("Сценарий A: украден диск", "Scenario A: disk stolen"),
    D("Атакующий получает encrypted blobs, индексы и часть метаданных — но НЕ ключи сообщений. Содержимое переписки автоматически не раскрывается.",
      "The attacker gets encrypted blobs, indexes and some metadata — but NOT the message keys. Chat contents are not automatically revealed."),
    []);
  s.push(ET.NODE_COMPROMISED, "ouo-home", null, D("Сценарий B: взломан работающий Home Node", "Scenario B: running Home Node compromised"),
    D("Риск выше: возможен доступ к активным процессам. Минимизируется время ключей в памяти, права процессов и горизонтальное перемещение между компонентами.",
      "Higher risk: access to running processes is possible. Time keys spend in memory, process privileges and lateral movement between components are minimized."),
    [{ op: "patch", id: "ouo-home", props: { secState: SS.COMPROMISED } }]);
  s.push(ET.CAPABILITY_DISABLED, "ouo-home", null, D("Community Worker отключён, изоляция удержала компоненты", "Community Worker disabled, isolation held the components"), null,
    [{ op: "patch", id: "ouo-home", props: { capabilities: [CAP.MESSAGING] } }]);
  s.push(ET.KEY_ROTATED, "ouo-home", null, D("Ключ ноды отозван, создана новая identity ноды", "Node key revoked, new node identity created"),
    D("Данные пользователя НЕ объявляются автоматически полностью защищёнными. Связанные устройства получают предупреждение; ключ ноды ротируется.",
      "User data is NOT automatically declared fully safe. Paired devices are warned; the node key is rotated."),
    [{ op: "add", obj: PHONE }, { op: "addEdge", id: "phone-home", from: "owner-phone", to: "ouo-home", kind: EK.TRUSTED }]);
  s.push(ET.PEERS_NOTIFIED, "ouo-home", "owner-phone", D("Связанные устройства предупреждены", "Paired devices notified"), null, []);
  return s;
}

/* ─────────── 8. Vulnerability → advisory → update ─────────── */
function sec8() {
  const s = scenario("vuln", "Уязвимость Relay → обновление", "Relay vulnerability → update");
  addObj(s, home(), ET.NODE_STARTED, D("OUO Home 2.3.0, relay включён", "OUO Home 2.3.0, relay enabled"));
  addObj(s, { id: "update-src", kind: "update", label: "Update source", status: "online", x: 780, y: 160 }, ET.NODE_STARTED, D("Источник подписанных обновлений", "Signed update source"));
  addObj(s, NET, ET.NODE_STARTED, D("Общая сеть", "General network"));
  s.push(ET.CAPACITY_ADVERTISED, "ouo-home", "net", D("Relay помогает сети", "Relay assists the network"), null, [{ op: "addEdge", id: "home-net", from: "ouo-home", to: "net", kind: EK.RELAY }]);
  s.push(ET.SECURITY_ADVISORY, "update-src", "ouo-home", D("Получен подписанный security advisory", "Signed security advisory received"),
    D("Advisory проверяется по подписи. Он может пометить версию уязвимой и отключить роль — но не даёт разработчику читать/удалять файлы или выполнять произвольные команды.",
      "The advisory is signature-verified. It can flag a version and disable a role — but it cannot let the developer read/delete files or run arbitrary commands."),
    [{ op: "addEdge", id: "upd", from: "update-src", to: "ouo-home", kind: EK.SERVICE }, { op: "patch", id: "ouo-home", props: { knownCriticalVulnerability: true } }]);
  s.push(ET.CAPABILITY_DISABLED, "ouo-home", null, D("Relay отключён; сообщения и хранилище продолжают работать", "Relay disabled; messaging and storage keep working"),
    D("Реакция локальна: отключается только уязвимая capability. Личная переписка, локальное хранилище, sync, прямая передача, обновление — работают.",
      "The response is local: only the vulnerable capability is disabled. Personal messaging, local storage, sync, direct transfer and updates keep working."),
    [{ op: "patch", id: "ouo-home", props: { capabilities: [CAP.MESSAGING, CAP.PERSONAL_STORAGE, CAP.SYNC, CAP.UPDATE], secState: SS.OUTDATED } }, { op: "setEdge", id: "home-net", kind: EK.BLOCKED }]);
  s.push(ET.UPDATE_STARTED, "ouo-home", "update-src", D("Скачивание пакета, проверка hash и подписи, подготовка rollback", "Downloading package, verifying hash & signature, preparing rollback"), null, []);
  s.push(ET.UPDATE_INSTALLED, "ouo-home", null, D("Установлена 2.3.1, защита от downgrade", "2.3.1 installed, downgrade protection"), null,
    [{ op: "patch", id: "ouo-home", props: { version: "2.3.1", knownCriticalVulnerability: false } }]);
  s.push(ET.HEALTH_CHECK, "ouo-home", null, D("Health check пройден (иначе — авто-откат)", "Health check passed (else auto-rollback)"), null, []);
  s.push(ET.CAPABILITY_RESTORED, "ouo-home", null, D("Relay восстановлен, помощь сети возобновлена", "Relay restored, network assistance resumed"), null,
    [{ op: "patch", id: "ouo-home", props: { capabilities: [CAP.MESSAGING, CAP.PERSONAL_STORAGE, CAP.SYNC, CAP.RELAY, CAP.UPDATE], secState: SS.NORMAL } }, { op: "setEdge", id: "home-net", kind: EK.RELAY }, { op: "delEdge", id: "upd" }]);
  return s;
}

/* ─────────── 9. Outdated node ─────────── */
function sec9() {
  const s = scenario("outdated", "Устаревшая нода", "Outdated node");
  addObj(s, home(300, 300, { version: "1.9.0", supportState: "deprecated", secState: SS.OUTDATED }), ET.NODE_STARTED,
    D("OUO Home 1.9.0 — версия устарела", "OUO Home 1.9.0 — version is outdated"),
    D("Личная работа и участие в общей сети разделены. Устаревшая версия продолжает работать локально, но не получает новые общественные задания.",
      "Personal work and network participation are separated. An outdated version keeps working locally but receives no new community jobs."));
  addObj(s, PHONE, ET.DEVICE_CREATED, D("Телефон владельца", "Owner phone"));
  s.push(ET.USER_CONNECTED, "owner-phone", "ouo-home", D("Личный доверенный канал работает", "Personal trusted link works"), null, [{ op: "addEdge", id: "phone-home", from: "owner-phone", to: "ouo-home", kind: EK.TRUSTED }]);
  addObj(s, NET, ET.NODE_STARTED, D("Общая сеть", "General network"));
  s.push(ET.VERSION_DEPRECATED, "ouo-home", null, D("Состояние: DEPRECATED / VULNERABLE", "State: DEPRECATED / VULNERABLE"), null, []);
  s.push(ET.NETWORK_RESTRICTED, "net", "ouo-home", D("Маршрутизаторы не назначают новые задачи; исключена из relay/storage/discovery", "Routers assign no new tasks; excluded from relay/storage/discovery"),
    D("Уязвимая нода исключается из relay/storage/discovery; контакты видят предупреждение о небезопасном протоколе. Совместимость имеет ограниченное окно.",
      "A vulnerable node is excluded from relay/storage/discovery; contacts see an unsafe-protocol warning. Compatibility has a limited window."),
    [{ op: "addEdge", id: "net-home", from: "net", to: "ouo-home", kind: EK.BLOCKED }]);
  s.push(ET.CAPABILITY_RESTORED, "ouo-home", null, D("После обновления роли восстановлены", "After update, capabilities restored"), null,
    [{ op: "patch", id: "ouo-home", props: { version: "2.3.1", supportState: "supported", secState: SS.NORMAL } }, { op: "delEdge", id: "net-home" }]);
  return s;
}

/* ─────────── 10. Sybil group ─────────── */
function sec10() {
  const s = scenario("sybil", "Sybil-атака", "Sybil attack");
  addObj(s, home(160, 320), ET.NODE_STARTED, D("OUO Home выбирает надёжные ноды", "OUO Home selecting reliable nodes"),
    D("Уникальный ключ ≠ уникальный участник: атакующий создаёт миллионы ключей. Доверие контекстно (relay/storage/discovery) и не глобальный балл.",
      "A unique key ≠ a unique participant: an attacker can mint millions of keys. Trust is contextual (relay/storage/discovery), not a single global score."));
  const fakes = [{ x: 620, y: 130 }, { x: 720, y: 220 }, { x: 640, y: 330 }, { x: 760, y: 430 }, { x: 560, y: 460 }];
  fakes.forEach((p, i) => addObj(s, { id: `sybil-${i + 1}`, kind: "malicious", secState: SS.NORMAL, status: "online", x: p.x, y: p.y },
    ET.NODE_CREATED, D(`Поддельная нода sybil-${i + 1}`, `Fake node sybil-${i + 1}`)));
  s.push(ET.SYBIL_DETECTED, "ouo-home", null, D("Обнаружена группа новых нод из одной подсети", "A cluster of fresh nodes from one subnet detected"), null,
    fakes.map((_, i) => ({ op: "patch", id: `sybil-${i + 1}`, props: { secState: SS.COMPROMISED } })));
  s.push(ET.TRUST_LIMITED, "ouo-home", null, D("Низкие начальные лимиты, без критических ролей", "Low initial limits, no critical roles"),
    D("Неизвестная нода не получает сразу критическую роль. Сигналы: возраст, стабильность, независимые подтверждения, ограничение по подсетям, стоимость публичной роли, resource proof, постепенные квоты.",
      "An unknown node does not immediately get a critical role. Signals: age, stability, independent confirmations, subnet limits, cost of a public role, resource proof, gradually growing quotas."),
    []);
  s.push(ET.ROUTE_REVOKED, "ouo-home", null, D("Маршруты выбираются из независимых источников, не из Sybil-группы", "Routes chosen from independent sources, not the Sybil cluster"), null,
    fakes.map((_, i) => ({ op: "addEdge", id: `x-${i}`, from: "ouo-home", to: `sybil-${i + 1}`, kind: EK.BLOCKED })));
  return s;
}

export const SECURITY_SCENARIOS = [sec1(), sec2(), sec3(), sec4(), sec5(), sec6(), sec7(), sec8(), sec9(), sec10()];
