// Сценарии «Жизненный цикл пользователя и его устройств» (§26 A/G/H/I ТЗ).
// Используют тот же event-sourcing движок (buildState) и мутации, что и
// network/security-сценарии — ничего в существующей реализации не меняется.
//
// Главная мысль: identity и device keys — независимые сущности. Устройства не
// делят общий приватный ключ; отзыв устройства останавливает новое шифрование
// для него, но не стирает данные, которые уже на нём есть.

import { EVENT_TYPE as ET, EDGE_KIND as EK } from "./types.js";

const D = (ru, en) => ({ ru, en });

function scenario(id, ru, en) {
  const s = { id, title: D(ru, en), viewBox: "0 0 980 600", events: [], focus: "home-a" };
  let t = 0, seq = 0;
  s.push = (type, source, target, desc, why, mut) =>
    s.events.push({ id: `ev${++seq}`, time: t++, type, source, target, desc, why: why || null, mut: mut || [] });
  return s;
}
function addObj(s, obj, type, desc, why) {
  s.push(type || ET.NODE_STARTED, obj.id, null, desc, why || null, [{ op: "add", obj }]);
}

const IDENTITY = (x, y) => ({ id: "identity-a", kind: "identity", ownerUserId: "user-a", x, y });
const HOME = (over = {}) => ({
  id: "home-a", kind: "home", label: "OUO Home", secState: "normal", version: "2.3.1", supportState: "supported",
  registered: false, storageEnabled: false, capabilities: ["messaging", "personal_storage", "sync"],
  metrics: { cpu: 10, ram: 22, disk: 0, connections: 0, transfers: 0, egress: 0, personal: 4, community: 0 },
  storage: { secureGb: 0, libraryGb: 0, freeGb: 0 }, x: 460, y: 260, ...over
});
const PHONE = (over = {}) => ({ id: "phone-a", kind: "device", userId: "user-a", type: "mobile", network: "wifi", online: false, connectedNodeId: null, x: 220, y: 460, ...over });
const LAPTOP = (over = {}) => ({ id: "laptop-a", kind: "device", userId: "user-a", type: "laptop", network: "wifi", online: false, connectedNodeId: null, x: 460, y: 500, ...over });
const FRIEND = (over = {}) => ({ id: "friend", kind: "friend", label: "Friend", status: "online", x: 830, y: 300, ...over });

/* ─────────── 1. Первый запуск: identity → устройство → Home → pairing → сообщение ─────────── */
function lc1() {
  const s = scenario("first-run", "Первый запуск: от установки до первого сообщения", "First run: from install to first message");

  addObj(s, PHONE(), ET.CLIENT_INSTALLED, D("Клиент установлен на телефон", "Client installed on the phone"),
    D("Установка обычным способом (App Store / установщик). Никакого git, конфигов или контейнеров.",
      "Installed the normal way (App Store / installer). No git, config files, or containers."));

  addObj(s, IDENTITY(220, 330), ET.IDENTITY_CREATED, D("Создана локальная identity", "Local identity created"),
    D("Identity-ключ генерируется на устройстве и никуда не отправляется в открытом виде. Identity, device и node — три разные сущности.",
      "The identity key is generated on-device and never leaves in the open. Identity, device and node are three distinct entities."));

  s.push(ET.DEVICE_KEY_GENERATED, "phone-a", null, D("Сгенерирован ключ устройства (device key)", "Device key generated"), null,
    [{ op: "patch", id: "phone-a", props: { online: true, keyId: "dk_9f2a" } },
     { op: "addEdge", id: "id-phone", from: "identity-a", to: "phone-a", kind: EK.TRUSTED }]);

  s.push(ET.NETWORK_MODE_CHOSEN, "phone-a", null, D("Выбор: общая сеть или собственная нода", "Choice: shared network or own node"),
    D("Пользователь решает, подключаться ли к чужим нодам сети или поднять OUO Home на своём устройстве. Здесь выбрана собственная нода.",
      "The user decides whether to rely on other nodes in the network or run OUO Home on their own device. Here, own node is chosen."), []);

  addObj(s, HOME(), ET.NODE_CREATED, D("OUO Home установлен (обычным установщиком)", "OUO Home installed (regular installer)"));

  s.push(ET.DISK_SELECTED, "home-a", null, D("Выбран диск для Secure Objects и User Library", "Disk selected for Secure Objects and User Library"),
    D("Мастер настройки просит выбрать том и лимит места — без ручного редактирования конфигов.",
      "The setup wizard asks for a volume and a space limit — no manual config editing."),
    [{ op: "patch", id: "home-a", props: { storage: { secureGb: 0, libraryGb: 0, freeGb: 900 }, storageEnabled: true } }]);

  s.push(ET.LIMIT_SET, "home-a", null, D("Лимит помощи сети установлен: 30%", "Network assistance limit set: 30%"), null,
    [{ op: "patch", id: "home-a", props: { assistanceEnabled: true, assistanceLimit: 30 } }]);

  addObj(s, { id: "discovery", kind: "discovery", status: "online", x: 700, y: 90 }, ET.NODE_STARTED, D("Discovery-нода в сети", "Discovery node online"));
  s.push(ET.NODE_REGISTER_REQUEST, "home-a", "discovery", D("Home регистрируется в discovery", "Home registers in discovery"), null,
    [{ op: "addEdge", id: "home-disc", from: "home-a", to: "discovery", kind: EK.SERVICE }]);
  s.push(ET.NODE_REGISTERED, "discovery", "home-a", D("Home зарегистрирован", "Home registered"), null,
    [{ op: "patch", id: "home-a", props: { registered: true } }, { op: "delEdge", id: "home-disc" }]);

  addObj(s, { id: "qr-1", kind: "qr", ownerUserId: "user-a", expiresIn: 90, x: 460, y: 400 }, ET.QR_GENERATED,
    D("Home показывает одноразовый QR для привязки телефона", "Home shows a one-time QR to pair the phone"),
    D("QR несёт node_id, публичный ключ устройства, короткоживущий pairing-token и версию протокола — никакого постоянного пароля.",
      "The QR carries node_id, the device public key, a short-lived pairing token and protocol version — no standing password."));
  s.push(ET.QR_SCANNED, "phone-a", "qr-1", D("Телефон сканирует QR", "Phone scans the QR"), null,
    [{ op: "addEdge", id: "phone-qr", from: "phone-a", to: "qr-1", kind: EK.SERVICE }]);
  s.push(ET.PAIRING_CONFIRMED, "phone-a", "home-a", D("Взаимная проверка пройдена, fingerprint подтверждён", "Mutual check passed, fingerprint confirmed"),
    D("Устройства выполняют взаимную криптографическую проверку и показывают короткий код/fingerprint для ручного сравнения — это защищает от подмены QR.",
      "Devices perform mutual cryptographic verification and show a short code/fingerprint for manual comparison — this protects against a swapped QR."),
    [{ op: "delEdge", id: "phone-qr" }, { op: "patch", id: "phone-a", props: { connectedNodeId: "home-a" } },
     { op: "addEdge", id: "phone-home", from: "phone-a", to: "home-a", kind: EK.TRUSTED }]);
  s.push(ET.PAIRING_TOKEN_DESTROYED, "qr-1", null, D("Одноразовый pairing-token уничтожен", "One-time pairing token destroyed"), null,
    [{ op: "remove", id: "qr-1" }]);

  addObj(s, { id: "qr-2", kind: "qr", ownerUserId: "friend", expiresIn: 90, x: 830, y: 420 }, ET.QR_GENERATED,
    D("Друг показывает свой QR контакта", "Friend shows their contact QR"),
    D("Контактный QR несёт публичную identity и route hint — этого достаточно, чтобы найти актуальную точку присутствия без глобального реестра пользователей.",
      "A contact QR carries the public identity and a route hint — enough to find the current point of presence without a global user registry."));
  addObj(s, FRIEND(), null, D("Друг добавлен в контакты", "Friend added to contacts"));
  s.push(ET.CONTACT_ADDED, "phone-a", "friend", D("Контакт добавлен по QR", "Contact added via QR"), null,
    [{ op: "remove", id: "qr-2" }, { op: "addEdge", id: "phone-friend-pot", from: "phone-a", to: "friend", kind: EK.POTENTIAL }]);

  s.push(ET.FIRST_MESSAGE_SENT, "phone-a", "friend", D("Отправлено первое сообщение", "First message sent"), null,
    [{ op: "delEdge", id: "phone-friend-pot" },
     { op: "addEdge", id: "phone-home-msg", from: "phone-a", to: "home-a", kind: EK.DELIVERED },
     { op: "addEdge", id: "home-friend-msg", from: "home-a", to: "friend", kind: EK.DELIVERED },
     { op: "msg", msg: { id: "msg-first", edgeId: "home-friend-msg", kind: "message", label: "first message" } }]);
  s.push(ET.ACK_RECEIVED, "friend", "phone-a", D("ACK получен — доставка подтверждена", "ACK received — delivery confirmed"), null, [{ op: "clearMsg" }]);
  return s;
}

/* ─────────── 2. Второе устройство: независимые device keys ─────────── */
function lc2() {
  const s = scenario("second-device", "Второе устройство: независимые ключи", "Second device: independent keys");

  addObj(s, IDENTITY(220, 200), null, D("Identity пользователя уже существует", "User identity already exists"));
  addObj(s, HOME({ registered: true, storageEnabled: true, storage: { secureGb: 12, libraryGb: 40, freeGb: 860 }, assistanceEnabled: true }),
    null, D("OUO Home уже работает", "OUO Home already running"));
  addObj(s, PHONE({ online: true, connectedNodeId: "home-a", keyId: "dk_9f2a" }), null, D("Телефон уже привязан", "Phone already paired"),
    null);
  s.push(ET.DEVICE_LIST_UPDATED, "phone-a", "home-a", D("Телефон уже доверенно связан с identity и Home", "Phone already trusted-linked to identity and Home"), null, [
    { op: "addEdge", id: "id-phone", from: "identity-a", to: "phone-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "phone-home", from: "phone-a", to: "home-a", kind: EK.TRUSTED }
  ]);
  addObj(s, FRIEND(), null, D("Друг онлайн", "Friend online"));

  addObj(s, { id: "qr-3", kind: "qr", ownerUserId: "user-a", expiresIn: 90, x: 460, y: 420 }, ET.QR_GENERATED,
    D("Home показывает QR для второго устройства (ноутбук)", "Home shows a QR for the second device (laptop)"), null);
  addObj(s, LAPTOP(), ET.CLIENT_INSTALLED, D("Клиент установлен на ноутбук", "Client installed on the laptop"));
  s.push(ET.QR_SCANNED, "laptop-a", "qr-3", D("Ноутбук сканирует QR", "Laptop scans the QR"), null,
    [{ op: "addEdge", id: "laptop-qr", from: "laptop-a", to: "qr-3", kind: EK.SERVICE }]);
  s.push(ET.DEVICE_KEY_GENERATED, "laptop-a", null, D("Ноутбук получает СВОЙ device key (dk_71cd)", "Laptop gets its OWN device key (dk_71cd)"),
    D("Каждое устройство генерирует собственную пару ключей локально. Общий приватный ключ между устройствами не передаётся — история синхронизируется, ключ нет.",
      "Each device generates its own key pair locally. No shared private key is transferred between devices — history syncs, the key does not."),
    [{ op: "patch", id: "laptop-a", props: { keyId: "dk_71cd", online: true } }]);
  s.push(ET.PAIRING_CONFIRMED, "laptop-a", "home-a", D("Fingerprint подтверждён", "Fingerprint confirmed"), null,
    [{ op: "delEdge", id: "laptop-qr" }, { op: "patch", id: "laptop-a", props: { connectedNodeId: "home-a" } },
     { op: "addEdge", id: "id-laptop", from: "identity-a", to: "laptop-a", kind: EK.TRUSTED },
     { op: "addEdge", id: "laptop-home", from: "laptop-a", to: "home-a", kind: EK.TRUSTED }]);
  s.push(ET.PAIRING_TOKEN_DESTROYED, "qr-3", null, D("QR уничтожен", "QR destroyed"), null, [{ op: "remove", id: "qr-3" }]);
  s.push(ET.DEVICE_LIST_UPDATED, "identity-a", null, D("Список устройств: phone-a, laptop-a", "Device list: phone-a, laptop-a"), null, []);

  s.push(ET.MESSAGE_CREATED, "friend", "user-a", D("Друг пишет пользователю", "Friend messages the user"), null,
    [{ op: "addEdge", id: "friend-home", from: "friend", to: "home-a", kind: EK.DELIVERED }]);
  s.push(ET.MESSAGE_RECEIVED, "home-a", "phone-a", D("Доставлено на телефон, расшифровано dk_9f2a", "Delivered to phone, decrypted with dk_9f2a"),
    D("Home рассылает сообщение каждому онлайн-устройству независимо — каждое расшифровывает своим ключом.",
      "Home fans the message out to every online device independently — each decrypts with its own key."),
    [{ op: "addEdge", id: "home-phone-msg", from: "home-a", to: "phone-a", kind: EK.DELIVERED }]);
  s.push(ET.MESSAGE_RECEIVED, "home-a", "laptop-a", D("Доставлено на ноутбук, расшифровано dk_71cd", "Delivered to laptop, decrypted with dk_71cd"), null,
    [{ op: "addEdge", id: "home-laptop-msg", from: "home-a", to: "laptop-a", kind: EK.DELIVERED }]);
  return s;
}

/* ─────────── 3. Потеря и отзыв устройства ─────────── */
function lc3() {
  const s = scenario("device-revoke", "Потеря и отзыв устройства", "Device loss and revocation");

  addObj(s, IDENTITY(220, 200), null, D("Identity пользователя", "User identity"));
  addObj(s, HOME({ registered: true, storageEnabled: true, storage: { secureGb: 18, libraryGb: 60, freeGb: 840 } }), null, D("OUO Home", "OUO Home"));
  addObj(s, PHONE({ online: true, connectedNodeId: "home-a", keyId: "dk_9f2a" }), null, D("Телефон", "Phone"));
  addObj(s, LAPTOP({ online: true, connectedNodeId: "home-a", keyId: "dk_71cd" }), null, D("Ноутбук", "Laptop"));
  addObj(s, FRIEND(), null, D("Друг", "Friend"));
  s.push(ET.DEVICE_LIST_UPDATED, "identity-a", null, D("Оба устройства уже доверенно связаны", "Both devices already trusted-linked"), null, [
    { op: "addEdge", id: "id-phone", from: "identity-a", to: "phone-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "id-laptop", from: "identity-a", to: "laptop-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "phone-home", from: "phone-a", to: "home-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "laptop-home", from: "laptop-a", to: "home-a", kind: EK.TRUSTED }
  ]);

  s.push(ET.DEVICE_LOST, "laptop-a", null, D("Ноутбук потерян", "Laptop is lost"), null,
    [{ op: "patch", id: "laptop-a", props: { lost: true } }, { op: "setEdge", id: "laptop-home", kind: EK.ERROR }]);

  s.push(ET.DEVICE_REVOKED, "phone-a", "laptop-a", D("С телефона отозван ключ ноутбука", "Laptop key revoked from the phone"),
    D("Отзыв делается с доверенного устройства (или через Home) и распространяется по сети как обновлённый список устройств. Скомпрометировать identity через одно устройство нельзя.",
      "Revocation is issued from a trusted device (or via Home) and propagates as an updated device list. A single device cannot compromise the whole identity."),
    [{ op: "patch", id: "laptop-a", props: { revoked: true, online: false, connectedNodeId: null } },
     { op: "delEdge", id: "id-laptop" }, { op: "delEdge", id: "laptop-home" }]);

  s.push(ET.DEVICE_LIST_UPDATED, "identity-a", null, D("Список устройств обновлён: только phone-a", "Device list updated: phone-a only"), null, []);
  s.push(ET.RECIPIENT_SET_UPDATED, "home-a", null, D("Home больше не шифрует новые сообщения для laptop-a", "Home stops encrypting new messages for laptop-a"), null, []);

  s.push(ET.MESSAGE_CREATED, "friend", "user-a", D("Друг пишет снова", "Friend messages again"), null,
    [{ op: "addEdge", id: "friend-home", from: "friend", to: "home-a", kind: EK.DELIVERED }]);
  s.push(ET.MESSAGE_RECEIVED, "home-a", "phone-a", D("Доставлено только на phone-a", "Delivered only to phone-a"), null,
    [{ op: "addEdge", id: "home-phone-msg", from: "home-a", to: "phone-a", kind: EK.DELIVERED }]);

  s.push(ET.DATA_NOT_REMOTELY_ERASABLE, "laptop-a", null, D("Данные на потерянном ноутбуке НЕ стёрты удалённо", "Data on the lost laptop is NOT wiped remotely"),
    D("Отзыв ключа останавливает НОВОЕ шифрование для устройства — он не стирает то, что уже было расшифровано и сохранено на нём. Это честное ограничение E2EE, а не баг.",
      "Revoking the key stops NEW encryption for the device — it does not erase what was already decrypted and stored there. This is an honest E2EE limitation, not a bug."), []);
  return s;
}

/* ─────────── 4. Ротация ключей ─────────── */
function lc4() {
  const s = scenario("key-rotation", "Ротация ключей", "Key rotation");

  addObj(s, IDENTITY(220, 200), null, D("Identity пользователя", "User identity"));
  addObj(s, HOME({ registered: true, storageEnabled: true, storage: { secureGb: 20, libraryGb: 70, freeGb: 820 } }), null, D("OUO Home", "OUO Home"));
  addObj(s, PHONE({ online: true, connectedNodeId: "home-a", keyId: "dk_9f2a" }), null, D("Телефон", "Phone"));
  addObj(s, FRIEND({ trustLevel: "verified" }), null, D("Друг (уровень доверия: verified)", "Friend (trust level: verified)"));
  s.push(ET.DEVICE_LIST_UPDATED, "identity-a", null, D("Телефон доверенно связан, друг известен по route hint", "Phone trusted-linked, friend known via route hint"), null, [
    { op: "addEdge", id: "id-phone", from: "identity-a", to: "phone-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "phone-home", from: "phone-a", to: "home-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "home-friend", from: "home-a", to: "friend", kind: EK.POTENTIAL }
  ]);

  s.push(ET.IDENTITY_KEY_ROTATED, "identity-a", null, D("Плановая ротация identity-ключа", "Scheduled identity key rotation"),
    D("Ключи не живут вечно: плановая ротация или ротация после инцидента снижает ценность украденного ключа во времени.",
      "Keys do not live forever: scheduled or incident-driven rotation reduces the value of a stolen key over time."),
    [{ op: "patch", id: "identity-a", props: { keyId: "idk_2" } }]);

  s.push(ET.NODE_KEY_ROTATED, "home-a", null, D("Ключ ноды Home ротирован", "Home node key rotated"), null,
    [{ op: "patch", id: "home-a", props: { nodeKeyId: "nk_2" } }]);

  s.push(ET.DEVICE_KEY_GENERATED, "phone-a", null, D("Device key телефона обновлён", "Phone device key refreshed"), null,
    [{ op: "patch", id: "phone-a", props: { keyId: "dk_9f2a_r2" } }]);

  s.push(ET.CONTACT_WARNED, "home-a", "friend", D("Друг предупреждён об изменении ключей", "Friend is warned about the key change"),
    D("Контакты видят предупреждение при смене ключа собеседника — это защита от тихой подмены identity (например, MITM через скомпрометированную ноду).",
      "Contacts see a warning when a peer's key changes — this guards against a silent identity swap (e.g. MITM via a compromised node)."),
    [{ op: "setEdge", id: "home-friend", kind: EK.SERVICE }, { op: "patch", id: "friend", props: { trustLevel: "unverified" } }]);

  s.push(ET.REVERIFICATION_REQUIRED, "friend", null, D("Требуется повторная верификация", "Re-verification required"), null, []);
  s.push(ET.REVERIFIED, "friend", "home-a", D("Fingerprint сверен, доверие восстановлено", "Fingerprint compared, trust restored"), null,
    [{ op: "setEdge", id: "home-friend", kind: EK.POTENTIAL }, { op: "patch", id: "friend", props: { trustLevel: "verified" } }]);
  return s;
}

/* ─────────── 5. Восстановление Home Node и миграция на NAS ─────────── */
function lc5() {
  const s = scenario("home-recovery", "Восстановление Home Node и миграция на NAS", "Home Node recovery and NAS migration");

  addObj(s, IDENTITY(160, 160), null, D("Identity пользователя", "User identity"));
  addObj(s, HOME({ registered: true, storageEnabled: true, storage: { secureGb: 64, libraryGb: 300, freeGb: 500 }, x: 400, y: 220 }),
    null, D("OUO Home работает уже давно", "OUO Home has been running for a while"));
  addObj(s, PHONE({ online: true, connectedNodeId: "home-a", keyId: "dk_9f2a", x: 160, y: 420 }), null, D("Телефон", "Phone"));
  addObj(s, LAPTOP({ online: true, connectedNodeId: "home-a", keyId: "dk_71cd", x: 400, y: 470 }), null, D("Ноутбук", "Laptop"));
  addObj(s, FRIEND({ x: 830, y: 220 }), null, D("Друг (у него своя копия переписки)", "Friend (holds their own copy of the chat)"));
  addObj(s, { id: "s3-backup", kind: "storage", ownerNodeId: "home-a", encrypted: true, ttlEnabled: false, online: true, x: 780, y: 420 },
    null, D("Зашифрованная резервная копия (S3)", "Encrypted backup (S3)"));
  s.push(ET.DEVICE_LIST_UPDATED, "identity-a", null, D("Всё уже настроено и синхронизировано", "Everything already set up and synced"), null, [
    { op: "addEdge", id: "id-phone", from: "identity-a", to: "phone-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "id-laptop", from: "identity-a", to: "laptop-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "phone-home", from: "phone-a", to: "home-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "laptop-home", from: "laptop-a", to: "home-a", kind: EK.TRUSTED },
    { op: "addEdge", id: "home-friend", from: "home-a", to: "friend", kind: EK.POTENTIAL },
    { op: "addEdge", id: "home-s3", from: "home-a", to: "s3-backup", kind: EK.MEDIA }
  ]);

  s.push(ET.DISK_FAILED, "home-a", null, D("Диск домашнего ПК вышел из строя", "The home PC's disk has failed"),
    D("Физический отказ диска — самый частый повод восстановления. Secure Objects на нём были зашифрованы, но сейчас недоступны физически.",
      "Physical disk failure is the most common recovery trigger. Secure Objects on it were encrypted, but are now physically unreachable."),
    [{ op: "patch", id: "home-a", props: { secState: "critical", storageEnabled: false } }]);
  s.push(ET.NODE_OFFLINE, "home-a", null, D("Home Node недоступна", "Home Node is unreachable"), null,
    [{ op: "status", id: "home-a", status: "offline" }, { op: "setEdge", id: "phone-home", kind: EK.ERROR }, { op: "setEdge", id: "laptop-home", kind: EK.ERROR }]);

  s.push(ET.DEVICE_DATA_PRESERVED, "phone-a", "laptop-a", D("Данные на устройствах не пострадали", "Data on the devices is unaffected"),
    D("История переписки, уже полученная устройствами, локальные черновики и ключи остаются на телефоне/ноутбуке — потеря ноды не значит потерю переписки на клиентах.",
      "Chat history already received by the devices, local drafts and keys remain on phone/laptop — losing the node does not mean losing chats on the clients."), []);

  s.push(ET.BACKUP_FOUND, "s3-backup", null, D("Найдена зашифрованная резервная копия", "An encrypted backup was found"),
    D("Если backup включён (Backups → Encrypt backup), объекты и настройки лежат зашифрованными в S3 отдельным паролем — независимо от диска Home.",
      "If backups are enabled, objects and settings sit encrypted in S3 under a separate password — independent of the Home disk."), []);

  addObj(s, HOME({ id: "home-a2", registered: false, storageEnabled: false, storage: { secureGb: 0, libraryGb: 0, freeGb: 500 }, x: 620, y: 340 }),
    ET.NEW_HOME_CREATED, D("Установлена новая OUO Home на другом ПК", "A new OUO Home is installed on another PC"), null);
  addObj(s, { id: "discovery", kind: "discovery", online: true, status: "online", x: 460, y: 60 }, null, D("Discovery-нода", "Discovery node"));
  s.push(ET.NODE_REGISTER_REQUEST, "home-a2", "discovery", D("Новая нода регистрируется", "New node registers"), null,
    [{ op: "addEdge", id: "home2-disc", from: "home-a2", to: "discovery", kind: EK.SERVICE }]);
  s.push(ET.NODE_REGISTERED, "discovery", "home-a2", D("Зарегистрирована с новым ключом ноды", "Registered with a new node key"), null,
    [{ op: "patch", id: "home-a2", props: { registered: true } }, { op: "delEdge", id: "home2-disc" }]);

  s.push(ET.BACKUP_RESTORED, "s3-backup", "home-a2", D("Резервная копия расшифрована паролем и восстановлена", "Backup decrypted with its password and restored"),
    D("Пароль backup — не то же самое, что device key или identity. Без него зашифрованная копия в S3 бесполезна даже для владельца.",
      "The backup password is not the device key or identity. Without it, the encrypted S3 copy is useless even to the owner."),
    [{ op: "patch", id: "home-a2", props: { storageEnabled: true, storage: { secureGb: 60, libraryGb: 280, freeGb: 520 } } }]);
  s.push(ET.OBJECTS_REPLICATED, "friend", "home-a2", D("Недостающие объекты дозагружены из копии у друга", "Missing objects are re-fetched from the friend's copy"),
    D("Даже без полного backup история частично восстановима: у собеседников есть собственные копии совместных сообщений на их стороне.",
      "Even without a full backup, history is partly recoverable: peers hold their own copies of shared messages on their side."),
    [{ op: "addEdge", id: "friend-home2", from: "friend", to: "home-a2", kind: EK.MEDIA }]);

  s.push(ET.REVERIFICATION_REQUIRED, "phone-a", "home-a2", D("У новой ноды другой ключ — устройства просят подтверждение", "The new node has a different key — devices ask for confirmation"),
    D("Identity и device keys не менялись, но node key новый. Устройство должно один раз подтвердить fingerprint новой ноды перед тем как ей довериться.",
      "Identity and device keys did not change, but the node key is new. The device must confirm the new node's fingerprint once before trusting it."),
    [{ op: "delEdge", id: "phone-home" }, { op: "delEdge", id: "laptop-home" }]);
  s.push(ET.REVERIFIED, "phone-a", "home-a2", D("Телефон и ноутбук доверяют новой ноде", "Phone and laptop trust the new node"), null,
    [{ op: "patch", id: "phone-a", props: { connectedNodeId: "home-a2" } }, { op: "patch", id: "laptop-a", props: { connectedNodeId: "home-a2" } },
     { op: "addEdge", id: "phone-home2", from: "phone-a", to: "home-a2", kind: EK.TRUSTED },
     { op: "addEdge", id: "laptop-home2", from: "laptop-a", to: "home-a2", kind: EK.TRUSTED }]);
  s.push(ET.OLD_STORAGE_DECOMMISSIONED, "home-a", null, D("Старая нода помечена как утеряна и выведена из реестра", "The old node is marked lost and retired from the registry"), null,
    [{ op: "patch", id: "home-a", props: { registered: false } }]);

  // ── миграция: спустя время пользователь переносит Home на собственный NAS ──
  addObj(s, { id: "nas-a", kind: "home", label: "NAS", secState: "normal", version: "2.3.1", supportState: "supported",
    registered: false, storageEnabled: false, capabilities: ["messaging", "personal_storage", "sync"],
    metrics: { cpu: 4, ram: 10, disk: 5, connections: 0, transfers: 0, egress: 0, personal: 2, community: 0 },
    storage: { secureGb: 0, libraryGb: 0, freeGb: 4000 }, x: 780, y: 220 }, ET.NAS_SELECTED,
    D("Выбран NAS для постоянного размещения Home", "A NAS is selected as the permanent home for OUO Home"),
    D("NAS даёт больше места и постоянную доступность (24/7) по сравнению с обычным ПК, который выключают на ночь.",
      "A NAS offers more space and constant (24/7) availability compared to a regular PC that gets turned off at night."));
  s.push(ET.STORE_COPIED, "home-a2", "nas-a", D("Encrypted object store копируется на NAS", "Encrypted object store copied to the NAS"), null,
    [{ op: "addEdge", id: "home2-nas", from: "home-a2", to: "nas-a", kind: EK.MEDIA }]);
  s.push(ET.HASH_VERIFIED, "nas-a", null, D("Контрольные суммы объектов сверены", "Object checksums verified"),
    D("Каждый перенесённый зашифрованный объект проверяется по hash — миграция не должна тихо повредить данные.",
      "Every migrated encrypted object is checked against its hash — migration must not silently corrupt data."), []);
  s.push(ET.ENDPOINT_SWITCHED, "phone-a", "nas-a", D("Устройства переключены на endpoint NAS", "Devices switched to the NAS endpoint"), null,
    [{ op: "delEdge", id: "phone-home2" }, { op: "delEdge", id: "laptop-home2" }, { op: "delEdge", id: "home2-nas" },
     { op: "patch", id: "phone-a", props: { connectedNodeId: "nas-a" } }, { op: "patch", id: "laptop-a", props: { connectedNodeId: "nas-a" } },
     { op: "patch", id: "nas-a", props: { registered: true, storageEnabled: true, storage: { secureGb: 60, libraryGb: 280, freeGb: 3700 } } },
     { op: "addEdge", id: "phone-nas", from: "phone-a", to: "nas-a", kind: EK.TRUSTED },
     { op: "addEdge", id: "laptop-nas", from: "laptop-a", to: "nas-a", kind: EK.TRUSTED }]);
  s.push(ET.OLD_STORAGE_DECOMMISSIONED, "home-a2", null, D("Временная нода на ноутбуке-доноре отключена", "The temporary donor-laptop node is decommissioned"), null,
    [{ op: "patch", id: "home-a2", props: { registered: false, online: false } }, { op: "status", id: "home-a2", status: "offline" }]);
  return s;
}

export const LIFECYCLE_SCENARIOS = [lc1(), lc2(), lc3(), lc4(), lc5()];
