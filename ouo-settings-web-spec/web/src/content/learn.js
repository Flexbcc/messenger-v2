// База знаний для панели «Как это работает?».
// Двуязычные объяснения ключевых настроек. Для остальных используется
// генеративный fallback на основе спеки и графа зависимостей.
//
// Компоненты системы (для схемы «что затрагивается»):
//   client · node · relay · s3 · discovery · secure_enclave · backup

const B = (ru, en) => ({ ru, en });

export const LEARN = {
  "security.pin_enabled": {
    components: ["client", "secure_enclave"],
    what: B(
      "Включает локальную блокировку клиента PIN-кодом. PIN проверяется только на устройстве и никогда не уходит на ноду или сервер.",
      "Enables a local client lock with a PIN. The PIN is checked on-device only and never leaves for a node or server."
    ),
    pros: [
      B("Защищает данные при краже разблокированного телефона", "Protects data if an unlocked phone is stolen"),
      B("Работает офлайн, не зависит от сети", "Works offline, independent of the network")
    ],
    cons: [
      B("Забытый PIN невозможно восстановить без Recovery Key", "A forgotten PIN cannot be recovered without a Recovery Key"),
      B("Слабый PIN снижает защиту", "A weak PIN reduces protection")
    ],
    scenarios: [
      B("Телефон потерян в разблокированном состоянии — приложение всё равно закрыто PIN-ом", "Phone lost while unlocked — the app is still gated behind the PIN"),
      B("Пограничный контроль просит показать телефон — включается фейковый профиль", "A border check asks to see the phone — the fake profile kicks in")
    ],
    diagram: "pin"
  },
  "security.fake_pin_enabled": {
    components: ["client", "secure_enclave"],
    what: B(
      "Включает второй PIN, внешне неотличимый от основного, который открывает безопасный или подставной профиль вместо настоящего.",
      "Enables a second PIN, indistinguishable from the primary one, that opens a safe or decoy profile instead of the real one."
    ),
    pros: [
      B("Правдоподобное отрицание под принуждением", "Plausible deniability under coercion"),
      B("Нельзя доказать существование скрытых данных", "Existence of hidden data cannot be proven")
    ],
    cons: [
      B("Требует заранее подготовленного правдоподобного профиля", "Requires a pre-prepared, believable profile"),
      B("Ошибочный ввод фейкового PIN сбивает с толку самого владельца", "Accidentally entering the fake PIN confuses the owner too")
    ],
    scenarios: [
      B("Под давлением вводится фейковый PIN — открывается безопасный профиль", "Under pressure the fake PIN is entered — a safe profile opens")
    ],
    diagram: "pin"
  },
  "notifications.enabled": {
    components: ["client", "node"],
    what: B(
      "Главный переключатель уведомлений. Определяет, дойдёт ли push до устройства и покажет ли клиент баннер.",
      "Master notification switch. Determines whether a push reaches the device and whether the client shows a banner."
    ),
    pros: [B("Мгновенная осведомлённость о новых сообщениях", "Instant awareness of new messages")],
    cons: [B("Метаданные уведомлений могут раскрывать активность", "Notification metadata can reveal activity")],
    scenarios: [B("Нажатие «Тест уведомлений» показывает реальный вид баннера", "Pressing “Test notifications” shows the real banner appearance")],
    diagram: "notif"
  },
  "notifications.preview": {
    components: ["client"],
    what: B(
      "Управляет тем, сколько содержимого видно на экране блокировки: полный текст, только отправитель или скрыто.",
      "Controls how much content shows on the lock screen: full text, sender only, or hidden."
    ),
    pros: [B("Скрытие превью защищает от подглядывания", "Hiding previews protects against shoulder-surfing")],
    cons: [B("Полное превью удобнее, но менее приватно", "Full preview is convenient but less private")],
    scenarios: [B("В метро включают «Только отправитель», дома — «Полное»", "On the subway use “Sender only”, at home “Full”")],
    diagram: "notif"
  },
  "storage.message_location": {
    components: ["client", "node", "s3"],
    what: B(
      "Определяет физическое место хранения зашифрованных сообщений: только устройство, личная нода или реплицированные ноды.",
      "Determines the physical storage location of encrypted messages: device only, personal node, or replicated nodes."
    ),
    pros: [
      B("«Только устройство» — максимум приватности", "“Device only” — maximum privacy"),
      B("Ноды дают доступ с нескольких устройств", "Nodes enable access from multiple devices")
    ],
    cons: [
      B("«Только устройство» — потеря телефона = потеря истории", "“Device only” — losing the phone loses history"),
      B("Хранение на нодах увеличивает поверхность метаданных", "Node storage increases the metadata surface")
    ],
    scenarios: [B("Смена значения перестраивает маршрут в разделе Data ownership", "Changing the value re-routes the flow in the Data ownership panel")],
    diagram: "route"
  },
  "storage.replication_factor": {
    components: ["client", "node"],
    what: B(
      "Сколько зашифрованных копий сообщения хранится на разных нодах. Больше копий — выше устойчивость, больше следов.",
      "How many encrypted copies of a message are kept on different nodes. More copies mean more durability but more footprint."
    ),
    pros: [B("Устойчивость к отказу отдельной ноды", "Resilience to a single node failure")],
    cons: [B("Каждая копия — дополнительная точка хранения", "Each copy is another storage point")],
    scenarios: [B("Выбор 3 реплик показывает схему Node A/B/C", "Choosing 3 replicas shows the Node A/B/C diagram")],
    diagram: "replication"
  },
  "privacy.qr_mode": {
    components: ["client", "discovery"],
    what: B(
      "Тип QR-доступа: постоянный, временный (с TTL) или одноразовый. Управляет тем, как долго QR можно использовать.",
      "QR access type: permanent, temporary (with TTL) or single-use. Controls how long a QR can be used."
    ),
    pros: [B("Временный QR снижает риск утечки идентификатора", "A temporary QR reduces the risk of identifier leaks")],
    cons: [B("Постоянный QR удобен, но живёт вечно", "A permanent QR is convenient but lives forever")],
    scenarios: [B("«Показать QR» с типом Temporary отсчитывает TTL", "“Show QR” with Temporary counts down the TTL")],
    diagram: "qr"
  },
  "backup.enabled": {
    components: ["client", "backup", "s3"],
    what: B(
      "Включает резервное копирование. Копия шифруется отдельным паролем; без него восстановление невозможно.",
      "Enables backups. The copy is encrypted with a separate password; without it recovery is impossible."
    ),
    pros: [B("Восстановление после потери устройства", "Recovery after device loss")],
    cons: [B("Потеря пароля копии = потеря копии", "Losing the backup password loses the backup")],
    scenarios: [B("«Создать резервную копию» показывает состав и контрольную сумму", "“Create backup” shows contents and checksum")],
    diagram: "backup"
  },
  "hidden.enabled": {
    components: ["client", "secure_enclave"],
    what: B(
      "Включает скрытые чаты, доступ к которым открывается отдельным методом (PIN, жест или секретная команда).",
      "Enables hidden chats accessed via a separate method (PIN, gesture or secret command)."
    ),
    pros: [B("Отдельный слой защиты для чувствительных диалогов", "A separate protection layer for sensitive conversations")],
    cons: [B("Забытый метод открытия = потеря доступа", "A forgotten open method loses access")],
    scenarios: [B("«Открыть скрытые чаты» проверяет выбранный метод", "“Open hidden chats” checks the selected method")],
    diagram: "notif"
  },
  "node.mode": {
    components: ["client", "node", "relay", "discovery"],
    what: B(
      "Режим подключения к сети OUO: авто, личная нода или ручной выбор. Влияет на маршрут всех данных.",
      "Connection mode to the OUO network: auto, personal node, or manual. Affects the route of all data."
    ),
    pros: [B("Личная нода — полный контроль над хранением", "A personal node gives full storage control")],
    cons: [B("Ручной режим требует поддержки инфраструктуры", "Manual mode requires maintaining infrastructure")],
    scenarios: [B("Переключение ноды перестраивает маршрут доставки", "Switching the node re-routes delivery")],
    diagram: "route"
  }
};

// Компоненты и их подписи для схемы «что затрагивается».
export const COMPONENTS = {
  client:         { ru: "Клиент", en: "Client" },
  node:           { ru: "Нода", en: "Node" },
  relay:          { ru: "Relay", en: "Relay" },
  s3:             { ru: "S3-хранилище", en: "S3 storage" },
  discovery:      { ru: "Discovery", en: "Discovery" },
  secure_enclave: { ru: "Secure Enclave", en: "Secure Enclave" },
  backup:         { ru: "Backup", en: "Backup" }
};

export function learnFor(id) {
  return LEARN[id] || null;
}
