// Routing decision engine для живой модели (§9 ТЗ).
// Маршрут НЕ захардкожен: выбирается из текущего состояния сети (динамическое
// число relay/S3 — генерируется presets.js, не завязано на конкретные id).
// Результат: DIRECT | RELAY | HOME_STORAGE | S3_FALLBACK | LOCAL_QUEUE | WAITING | FAILED
// + путь (список id объектов) + объяснение выбора (ru/en) + etaMs — теоретическая
// задержка доставки (см. latency.js), с небольшим детерминированным джиттером.

import { estimateLatency } from "./latency.js";

const D = (ru, en) => ({ ru, en });

function usableRelays(o, world, excludeIds = []) {
  return Object.values(o)
    .filter((r) => r.kind === "relay" && r.online && r.secState !== "compromised" && r.secState !== "overloaded"
      && !excludeIds.some((id) => world.isBlocked?.(id, r.id)))
    .sort((a, b) => (a.metrics?.streams ?? 0) - (b.metrics?.streams ?? 0));
}

function usableStorage(o) {
  return Object.values(o).find((r) => r.kind === "storage" && r.online) || null;
}

export function decideRoute(world, senderDevId, recipientUser, kind) {
  const dec = decideRouteBase(world, senderDevId, recipientUser, kind);
  const hops = Math.max(0, dec.path.length - 1);
  const est = estimateLatency(dec.route, kind, hops);
  const jitter = world.rng ? 0.85 + world.rng.next() * 0.3 : 1;
  const etaMs = Math.round(est.typ * jitter);
  return { ...dec, etaMs, etaRange: { min: est.min, max: est.max } };
}

function decideRouteBase(world, senderDevId, recipientUser, kind) {
  const o = world.objects;
  const sDev = o[senderDevId];
  const sHome = sDev?.connectedNodeId ? o[sDev.connectedNodeId] : null;
  const sHomeUp = sHome && sHome.online && sHome.secState !== "critical";
  const rHome = recipientUser.homeNodeId ? o[recipientUser.homeNodeId] : null;
  const rHomeUp = rHome && rHome.online && rHome.secState !== "critical";
  const rDev = recipientUser.devices.map((id) => o[id]).find((d) => d && d.online);
  const s3 = usableStorage(o);

  const head = sHomeUp ? [sDev.id, sHome.id] : [sDev.id];
  const anchorS = sHomeUp ? sHome.id : sDev.id;

  // Получатель полностью недоступен (нет онлайн-устройства и дом офлайн).
  if (!rDev && !rHomeUp) {
    if (kind !== "text" && s3) {
      return { route: "S3_FALLBACK", path: [sDev.id, s3.id], terminal: "queued",
        why: D("Получатель офлайн, его дом недоступен → зашифрованный объект во временный S3.",
               "Recipient offline, home unavailable → encrypted object to temporary S3.") };
    }
    return { route: "LOCAL_QUEUE", path: [sDev.id], terminal: "queued",
      why: D("Ни устройства, ни дома получателя, ни S3 — сообщение в локальной очереди отправителя.",
             "No recipient device, home or S3 — message held in the sender's local queue.") };
  }

  // Терминал: онлайн-устройство получателя, иначе очередь на его доме.
  const tail = rDev ? (rHomeUp ? [rHome.id, rDev.id] : [rDev.id]) : [rHome.id];
  const terminal = rDev ? "delivered" : "queued";
  const anchorR = rHomeUp ? rHome.id : (rDev ? rDev.id : rHome.id);

  const directBlocked = world.isBlocked?.(anchorS, anchorR);
  const relays = usableRelays(o, world, [anchorS, anchorR]);

  // Транспорт между отправителем и домом/устройством получателя.
  if (sHomeUp && rHomeUp) {
    // Обе стороны с домами: сначала прямой маршрут, иначе relay.
    if (world.directOk !== false && !directBlocked) {
      return { route: "DIRECT", path: [...head, ...tail], terminal,
        why: D("Обе ноды с домами онлайн, прямой маршрут доступен и не перегружен.",
               "Both homes online, a direct route is available and not overloaded.") };
    }
    if (relays.length) {
      const r = relays[0];
      return { route: "RELAY", path: [...head, r.id, ...tail], terminal,
        why: D(`Прямой маршрут недоступен → ${r.id} (наименьшая нагрузка, capability relay).`,
               `Direct route unavailable → ${r.id} (lowest load, relay capability).`) };
    }
    return { route: "HOME_STORAGE", path: [...head, rHome.id], terminal: "queued",
      why: D("Нет прямого маршрута и доступного relay → очередь на доме получателя.",
             "No direct route and no usable relay → queued at the recipient's home.") };
  }

  // У отправителя нет дома (например, только телефон) — через relay.
  if (relays.length && rHomeUp) {
    const r = relays[0];
    return { route: "RELAY", path: [sDev.id, r.id, ...tail], terminal,
      why: D(`У отправителя нет своей ноды → доставка через ${r.id}.`,
             `Sender has no home node → delivery via ${r.id}.`) };
  }
  if (relays.length && rDev) {
    const r = relays[0];
    return { route: "RELAY", path: [sDev.id, r.id, rDev.id], terminal,
      why: D(`Прямой маршрут недоступен → relay ${r.id}.`, `Direct route unavailable → relay ${r.id}.`) };
  }
  if (rHomeUp) {
    return { route: "HOME_STORAGE", path: [...head, rHome.id], terminal: "queued",
      why: D("Relay недоступен → очередь на доме получателя.", "No relay available → queued at the recipient's home.") };
  }
  return { route: "WAITING", path: [sDev.id], terminal: "queued",
    why: D("Нет доступного маршрута прямо сейчас — ожидание.", "No route available right now — waiting.") };
}
