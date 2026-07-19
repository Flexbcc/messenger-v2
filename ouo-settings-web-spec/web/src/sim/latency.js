// Модель теоретической задержки (мс) — не измерение реальной сети, а
// приблизительная оценка порядка величины для каждого типа сообщения по
// каждому маршруту. Используется и как справочная таблица (Latency tab), и
// как основа для eta живых передач в LiveEngine (routing.js подставляет её
// в decideRoute, чтобы «сколько это будет стоить по времени» не было
// оторвано от выбора маршрута).
//
// Все числа — округлённые, явно помеченные как теоретическая оценка, а не
// результат замеров реальной инфраструктуры.

// Задержка одного «хопа» транспорта, мс: { min, typ, max }.
export const HOP_LATENCY = {
  direct: { min: 15, typ: 35, max: 80 },   // установленное P2P-соединение
  relay: { min: 20, typ: 45, max: 110 },   // один прыжок через relay (+ обработка пакета)
  lan: { min: 1, typ: 3, max: 8 },         // внутри локальной сети
  queue_write: { min: 8, typ: 18, max: 40 } // запись зашифрованного объекта в очередь на ноде
};

// Клиентский оверхед на тип сообщения: шифрование/подготовка payload, мс.
export const KIND_OVERHEAD = {
  text: { min: 2, typ: 6, max: 15 },
  ack: { min: 1, typ: 2, max: 5 },
  sync: { min: 8, typ: 20, max: 45 },
  photo: { min: 35, typ: 90, max: 220 },
  video: { min: 150, typ: 420, max: 1100 },
  file: { min: 60, typ: 160, max: 500 },
  call: { min: 15, typ: 35, max: 90 } // только signalling; сам media stream не моделируется как «сообщение»
};

// Дополнительная стоимость конкретного маршрута сверх хопов транспорта.
export const ROUTE_EXTRA = {
  DIRECT: { min: 0, typ: 0, max: 0 },
  RELAY: { min: 5, typ: 12, max: 30 },          // обработка на relay
  HOME_STORAGE: { min: 0, typ: 0, max: 0 },     // сама постановка в очередь уже входит в queue_write
  S3_FALLBACK: { min: 120, typ: 320, max: 900 }, // HTTPS upload/download зашифрованного blob, зависит от размера
  LOCAL_QUEUE: { min: 0, typ: 0, max: 0 },
  WAITING: { min: 0, typ: 0, max: 0 }
};

// Число «хопов» транспорта для маршрута — используется для справочной
// таблицы (когда нет конкретного пути) и как значение по умолчанию.
export const ROUTE_HOPS = {
  DIRECT: 1, RELAY: 2, HOME_STORAGE: 1, S3_FALLBACK: 1, LOCAL_QUEUE: 0, WAITING: 0
};

function sum(...ranges) {
  return ranges.reduce((acc, r) => ({ min: acc.min + r.min, typ: acc.typ + r.typ, max: acc.max + r.max }), { min: 0, typ: 0, max: 0 });
}

/**
 * Оценивает теоретическую задержку доставки для (route, kind, hops).
 * hops — необязательное число хопов транспорта; если не задано, берётся
 * представительное значение из ROUTE_HOPS (для справочной таблицы).
 */
export function estimateLatency(route, kind, hops) {
  const kindOverhead = KIND_OVERHEAD[kind] || KIND_OVERHEAD.text;
  const routeExtra = ROUTE_EXTRA[route] || ROUTE_EXTRA.WAITING;
  const hopKind = route === "RELAY" ? "relay" : route === "DIRECT" ? "direct" : "queue_write";
  const hopCount = hops != null ? hops : (ROUTE_HOPS[route] ?? 0);
  const hopLatency = HOP_LATENCY[hopKind] || HOP_LATENCY.direct;
  const transport = { min: hopLatency.min * hopCount, typ: hopLatency.typ * hopCount, max: hopLatency.max * hopCount };
  const total = sum(kindOverhead, transport, routeExtra);
  return {
    ...total,
    breakdown: [
      { label: "kind", ...kindOverhead },
      { label: "transport", ...transport, hops: hopCount },
      { label: "route", ...routeExtra }
    ]
  };
}

export const ROUTE_IDS = ["DIRECT", "RELAY", "HOME_STORAGE", "S3_FALLBACK", "LOCAL_QUEUE"];
export const KIND_IDS = ["text", "photo", "video", "file", "sync", "call", "ack"];

/** Полная справочная таблица (kind × route) представительных задержек. */
export function buildLatencyTable() {
  const rows = [];
  for (const kind of KIND_IDS) {
    const cells = {};
    for (const route of ROUTE_IDS) {
      cells[route] = estimateLatency(route, kind);
    }
    rows.push({ kind, cells });
  }
  return rows;
}
