// LiveEngine — непрерывная симуляция сети OUO (§20 ТЗ + масштаб до 30-40
// пользователей). Архитектура tick: clock → generator → decision → mutation →
// aggregation. Использует общие сущности (objects/kinds) и события той же
// модели, что и пошаговые сценарии; воспроизводима при одном seed.
//
// Скриптуемость: addUser/addNode/revokeDevice/blockPair/killNode и т.д. —
// публичные методы движка, вызываемые как из UI-кнопок, так и из текстовой
// консоли команд (LiveSim.jsx), т.е. сеть управляется как единым «скриптом».

import { buildWorld, PRESETS, DEFAULT_SCALE, NAME_POOL } from "./presets.js";
import { makeRng } from "./rng.js";
import { decideRoute } from "./routing.js";
import { estimateLatency } from "./latency.js";

const MAX_VISIBLE = 14;         // ограничение одновременно рисуемых передач (§22–23)
const LOG_CAP = 1000;

const KIND_SPEED = { text: 0.5, ack: 0.6, photo: 0.28, video: 0.14, file: 0.18, sync: 0.34, call: 0.5, attack: 0.6 };
const D = (ru, en) => ({ ru, en });

function stateFromCpu(cpu) {
  if (cpu >= 95) return "critical";
  if (cpu >= 85) return "overloaded";
  if (cpu >= 60) return "busy";
  return "normal";
}

function pairKey(a, b) { return [a, b].sort().join("|"); }

export class LiveEngine {
  constructor(seed, presetId, scale) { this.reset(seed, presetId, scale); }

  reset(seed, presetId, scale = DEFAULT_SCALE) {
    this.rng = makeRng(seed);
    const { objects, topo, users, relayIds, s3Ids } = buildWorld(this.rng, scale);
    this.objects = objects;
    this.topo = topo;
    this.users = users;
    this.relayIds = relayIds;
    this.s3Ids = s3Ids;
    this.scale = scale;
    this.seed = seed;
    this.presetId = presetId;
    this.preset = PRESETS[presetId] || PRESETS.normal;
    this.time = 0;
    this.tickCount = 0;
    this.transfers = [];
    this.tid = 0;
    this.log = [];
    this.lid = 0;
    this.uidCounter = users.length;
    this.nodeCounter = { relay: relayIds.length, s3: s3Ids.length };
    this.aggregated = 0;          // свёрнутые (не рисуемые) передачи
    this.directOk = true;
    this.directCooldown = 0;
    this.offlineTimers = {};      // id → тиков до возврата online
    this.blockedPairs = new Set();
    this.stats = {
      created: 0, delivered: 0, waiting: 0, failed: 0,
      mediaUp: 0, mediaDown: 0, replicated: 0, expired: 0, calls: 0,
      routes: { DIRECT: 0, RELAY: 0, S3_FALLBACK: 0, HOME_STORAGE: 0, LOCAL_QUEUE: 0, WAITING: 0 },
      security: { scans: 0, replays: 0, revocations: 0 },
      // Накопленная теоретическая задержка доставки (§ latency.js), по маршруту и по типу.
      latencyByRoute: {}, latencyByKind: {}
    };
  }

  _recordLatency(route, kind, ms) {
    const br = this.stats.latencyByRoute[route] || (this.stats.latencyByRoute[route] = { count: 0, sumMs: 0 });
    br.count += 1; br.sumMs += ms;
    const bk = this.stats.latencyByKind[kind] || (this.stats.latencyByKind[kind] = { count: 0, sumMs: 0 });
    bk.count += 1; bk.sumMs += ms;
  }

  _emit(type, ru, en, meta) {
    this.log.push({ id: `L${++this.lid}`, t: this.time, type, text: D(ru, en), meta: meta || null });
    if (this.log.length > LOG_CAP) this.log.splice(0, this.log.length - LOG_CAP);
  }

  _onlineUsers() {
    return this.users.filter((u) => u.devices.some((d) => this.objects[d]?.online));
  }
  _senderDevice(u) {
    return u.devices.find((d) => this.objects[d]?.online);
  }
  get O() { return this.objects; }

  isBlocked(a, b) {
    return this.blockedPairs.has(pairKey(a, b));
  }

  /* ── один симуляционный tick ── */
  tick() {
    this.tickCount += 1;
    this.time += 1;
    this._progress();
    this._generate();
    this._changes();
    this._resources();
  }

  /* ── прогресс активных передач ── */
  _progress() {
    const keep = [];
    for (const tr of this.transfers) {
      if (tr.status === "queued" || tr.status === "delivered" || tr.status === "failed") continue;
      const from = this.objects[tr.path[tr.hop]];
      const to = this.objects[tr.path[tr.hop + 1]];
      // Потеря узла на пути → resumable rerouting (продолжаем с текущего %, не с нуля).
      if (!from || !to || from.online === false || to.online === false) {
        const rec = this.users.find((u) => u.id === tr.recipientUserId);
        const dec = rec ? decideRoute(this, tr.path[tr.hop], rec, tr.kind) : null;
        if (dec && dec.route !== "WAITING") {
          this._emit("ROUTE_CHANGED", `Маршрут потерян → продолжение через ${dec.route} с ${Math.round(tr.progress * 100)}%`,
            `Route lost → resumed via ${dec.route} at ${Math.round(tr.progress * 100)}%`);
          tr.path = dec.path; tr.hop = 0; tr.route = dec.route; tr.terminal = dec.terminal;
        } else {
          tr.status = "queued"; this.stats.waiting += 1;
          keep.push(tr); continue;
        }
      }
      tr.progress += (KIND_SPEED[tr.kind] || 0.4);
      while (tr.progress >= 1 && tr.hop < tr.path.length - 2) { tr.progress -= 1; tr.hop += 1; }
      if (tr.progress >= 1 && tr.hop >= tr.path.length - 2) {
        this._finalize(tr);
      } else {
        keep.push(tr);
      }
    }
    this.transfers = keep;
  }

  _finalize(tr) {
    if (tr.kind === "attack") { return; }
    if (tr.etaMs != null) this._recordLatency(tr.route, tr.kind, tr.etaMs);
    const meta = { transferId: tr.id, kind: tr.kind, route: tr.route, etaMs: tr.etaMs, path: tr.path };
    if (tr.terminal === "queued") {
      this.stats.waiting += 1;
      this._emit(tr.route === "S3_FALLBACK" ? "MEDIA_UPLOADED" : "MESSAGE_QUEUED",
        `${tr.label.ru}: в очереди (${tr.route})`, `${tr.label.en}: queued (${tr.route})`, { ...meta, status: "queued" });
      if (tr.route === "S3_FALLBACK") this.stats.mediaUp += 1;
      return;
    }
    // delivered
    this.stats.delivered += 1;
    if (tr.kind === "photo" || tr.kind === "video" || tr.kind === "file") {
      this.stats.mediaDown += 1;
      this.stats.replicated += 1; // копия в Secure Objects дома получателя
    }
    if (tr.kind === "call") this.stats.calls += 1;
    if (tr.kind !== "ack" && tr.kind !== "sync" && tr.kind !== "call") {
      this._emit("DELIVERED", `${tr.label.ru} доставлено (${tr.route}, ~${tr.etaMs} мс)`, `${tr.label.en} delivered (${tr.route}, ~${tr.etaMs} ms)`,
        { ...meta, status: "delivered" });
    } else if (tr.kind === "sync") {
      this._emit("SYNC_DONE", "Синхронизация: сохранено", "Sync: saved", { ...meta, status: "delivered" });
    } else if (tr.kind === "call") {
      this._emit("CALL_END", "Звонок завершён", "Call ended", { ...meta, status: "delivered" });
    }
  }

  _spawn(kind, senderDev, recipientUserId, path, route, terminal, label, etaMs) {
    if (this.transfers.length >= MAX_VISIBLE) { this.aggregated += 1; return null; }
    const tr = {
      id: `T${++this.tid}`, kind, senderDev, recipientUserId,
      path, hop: 0, progress: 0, route, terminal, label, etaMs
    };
    this.transfers.push(tr);
    return tr;
  }

  /* ── генератор действий ── */
  _generate() {
    const p = this.preset;
    const online = this._onlineUsers();
    if (online.length >= 2) {
      const [a, b] = this.rng.pickPair(online);
      const sDev = this._senderDevice(a);
      // тип сообщения
      let kind = null, label = null;
      if (this.rng.chance(p.mediaRate)) {
        kind = this.rng.chance(0.5) ? "photo" : "video";
        label = kind === "photo" ? D("Фото", "Photo") : D("Видео", "Video");
      } else if (this.rng.chance(p.fileRate)) {
        kind = "file"; label = D("Файл", "File");
      } else if (this.rng.chance(p.messageRate)) {
        kind = "text"; label = D(`${a.name} → ${b.name}`, `${a.name} → ${b.name}`);
      }
      if (kind && sDev) {
        const dec = decideRoute(this, sDev, b, kind);
        this.stats.created += 1;
        this.stats.routes[dec.route] = (this.stats.routes[dec.route] || 0) + 1;
        const tr = this._spawn(kind, sDev, b.id, dec.path, dec.route, dec.terminal, label, dec.etaMs);
        this._emit(kind === "text" ? "MESSAGE_SENT" : "MEDIA_SENT",
          `${a.name} → ${b.name}: ${label.ru} (${dec.route}, ~${dec.etaMs} мс)`, `${a.name} → ${b.name}: ${label.en} (${dec.route}, ~${dec.etaMs} ms)`,
          tr && { transferId: tr.id, kind, route: dec.route, etaMs: dec.etaMs, path: dec.path, why: dec.why, status: "sent" });
      }
    }
    // синхронизация телефон → Home
    if (this.rng.chance(p.syncRate)) {
      const u = this.rng.pick(this.users.filter((x) => x.homeNodeId && this.objects[x.homeNodeId]?.online));
      if (u) {
        const dev = this._senderDevice(u);
        if (dev) {
          this.stats.created += 1;
          const eta = Math.round(estimateLatency("HOME_STORAGE", "sync", 1).typ);
          this._spawn("sync", dev, u.id, [dev, u.homeNodeId], "SYNC", "delivered", D("Синхронизация", "Sync"), eta);
        }
      }
    }
    // звонок
    if (this.rng.chance(p.callProb) && online.length >= 2) {
      const [a, b] = this.rng.pickPair(online);
      const sDev = this._senderDevice(a), rDev = this._senderDevice(b);
      if (sDev && rDev) {
        const rec = this.users.find((u) => u.id === b.id);
        const dec = decideRoute(this, sDev, rec, "call");
        this.stats.created += 1;
        const callRoute = dec.route === "DIRECT" ? "DIRECT" : "RELAY";
        const tr = this._spawn("call", sDev, b.id, dec.path, callRoute, "delivered", D("Звонок", "Call"), dec.etaMs);
        this._emit("CALL_START", `${a.name} звонит ${b.name} (${dec.route === "DIRECT" ? "direct media" : "relay media"})`,
          `${a.name} calls ${b.name} (${dec.route === "DIRECT" ? "direct media" : "relay media"})`,
          tr && { transferId: tr.id, kind: "call", route: callRoute, etaMs: dec.etaMs, path: dec.path, why: dec.why, status: "sent" });
      }
    }
    // атака (threat preset)
    if (this.rng.chance(p.attackProb)) this._attack();
  }

  _attack() {
    const roll = this.rng.next();
    if (roll < 0.4) {
      this.stats.security.scans += 1;
      const target = this.rng.pick(this.users.filter((u) => u.homeNodeId))?.homeNodeId;
      this._spawn("attack", "net", null, ["net", target || "net"], "BLOCKED", "blocked", D("Скан", "Scan"));
      this._emit("SCAN_REJECTED", "Скан публичного интерфейса отклонён (нужна аутентификация)",
        "Public scan rejected (authentication required)");
    } else if (roll < 0.7) {
      this.stats.security.replays += 1;
      this._emit("REPLAY_BLOCKED", "Повтор пакета заблокирован (nonce/TTL)", "Packet replay blocked (nonce/TTL)");
    } else if (this.relayIds.length) {
      const rid = this.rng.pick(this.relayIds);
      const r = this.objects[rid];
      if (r && r.secState !== "compromised") {
        r.secState = "compromised";
        this.stats.security.revocations += 1;
        this._emit("ROUTE_REVOKED", `${r.id} скомпрометирована → маршрут отозван, репутация снижена`,
          `${r.id} compromised → route revoked, reputation reduced`);
        this.offlineTimers[`fix-${r.id}`] = this.rng.int(6, 12);
      }
    }
  }

  /* ── динамика сети ── */
  _changes() {
    const p = this.preset;
    // возврат offline-узлов и «починка» relay
    for (const [key, ticks] of Object.entries(this.offlineTimers)) {
      this.offlineTimers[key] = ticks - 1;
      if (this.offlineTimers[key] <= 0) {
        delete this.offlineTimers[key];
        if (key.startsWith("fix-")) {
          const id = key.slice(4); if (this.objects[id]) this.objects[id].secState = "normal";
          this._emit("CAPABILITY_RESTORED", `${id}: обновлена, роль восстановлена`, `${id}: updated, role restored`);
        } else {
          const o = this.objects[key];
          if (o) { o.online = true; o.secState = o.secState === "offline" ? "normal" : o.secState;
            this._emit("NODE_ONLINE", `${o.label || o.id} снова в сети`, `${o.label || o.id} back online`); }
        }
      }
    }
    // уход в offline (случайный дом или устройство без дома)
    if (this.rng.chance(p.offlineProb)) {
      const candidates = this.users.map((u) => u.homeNodeId).filter(Boolean)
        .concat(this.users.filter((u) => !u.homeNodeId).map((u) => u.devices[0]));
      const cand = this.rng.pick(candidates);
      const o = cand && this.objects[cand];
      if (o && o.online !== false && !this.offlineTimers[cand]) {
        o.online = false; if (o.kind === "home") o.secState = "offline";
        this.offlineTimers[cand] = this.rng.int(4, 10);
        this._emit("NODE_OFFLINE", `${o.label || o.id} офлайн → авто-fallback`, `${o.label || o.id} offline → auto fallback`);
      }
    }
    // потеря/возврат прямого маршрута
    if (this.directCooldown > 0) {
      this.directCooldown -= 1;
      if (this.directCooldown === 0) { this.directOk = true; this._emit("ROUTE_CHANGED", "Прямой маршрут восстановлен", "Direct route restored"); }
    } else if (this.rng.chance(p.routeFailProb)) {
      this.directOk = false; this.directCooldown = this.rng.int(3, 7);
      this._emit("ROUTE_CHANGED", "Прямой маршрут потерян → relay", "Direct route lost → relay");
    }
    // всплеск личной нагрузки у случайного дома
    if (this.rng.chance(p.loadSpikeProb)) {
      const homeIds = this.users.map((u) => u.homeNodeId).filter(Boolean);
      const h = this.objects[this.rng.pick(homeIds)];
      if (h && h.online !== false) {
        h._syncBoost = 60;
        this._emit("LOAD_SPIKE", `${h.label}: началась личная синхронизация — нагрузка растёт`, `${h.label}: personal sync started — load rising`);
      }
    }
  }

  /* ── ресурсы и вытеснение (§10) ── */
  _resources() {
    const homeIds = this.users.map((u) => u.homeNodeId).filter(Boolean);
    for (const id of homeIds) {
      const h = this.objects[id];
      if (!h) continue;
      if (h.online === false) { h.metrics = { ...h.metrics, cpu: 0, ram: 0, personal: 0, community: 0, connections: 0, transfers: 0, egress: 0 }; continue; }
      const activePersonal = this.transfers.filter((t) => t.path.includes(id)).length;
      const boost = h._syncBoost || 0;
      if (h._syncBoost) h._syncBoost = Math.max(0, h._syncBoost - 9);
      let personal = Math.min(100, 8 + activePersonal * 18 + boost);
      const communityBase = h.assistanceEnabled ? 30 : 0;
      const preempted = personal > 70;
      const community = preempted ? Math.min(communityBase, 4) : communityBase;
      const reserve = Math.max(0, 100 - personal - community);
      const cpu = Math.min(100, Math.round(12 + personal * 0.72 + community * 0.4));
      const ram = Math.min(100, Math.round(28 + personal * 0.5 + community * 0.2));
      const prevState = h.secState;
      const next = h.secState === "compromised" ? "compromised" : stateFromCpu(cpu);
      h.secState = next;
      h.metrics = { ...h.metrics, cpu, ram, personal, community, reserve,
        connections: 3 + activePersonal * 2 + (community > 0 ? 6 : 0), transfers: activePersonal,
        egress: Math.round(community * 0.4 + activePersonal * 3) };
      if (preempted && communityBase > 0 && prevState !== next && (next === "busy" || next === "overloaded")) {
        this._emit("RESOURCE_PREEMPTED", `${h.label}: личная нагрузка вытесняет помощь сети`, `${h.label}: personal load preempts network assistance`);
      }
    }
    // relay streams колеблются с активными relay-передачами
    for (const id of this.relayIds) {
      const r = this.objects[id];
      if (r) r.metrics = { ...r.metrics, streams: this.transfers.filter((t) => t.path.includes(id)).length };
    }
  }

  /* ═══════════ Скриптуемое управление сетью ═══════════ */

  /** Добавляет нового пользователя (телефон, с шансом свой Home). */
  addUser(withHome = null) {
    const i = this.uidCounter++;
    const name = NAME_POOL[i % NAME_POOL.length] + (i >= NAME_POOL.length ? String(Math.floor(i / NAME_POOL.length) + 1) : "");
    const cx = 620, cy = 480;
    const angle = this.rng.next() * Math.PI * 2;
    const R = 260 + this.rng.next() * 200;
    const x = Math.round(cx + Math.cos(angle) * R), y = Math.round(cy + Math.sin(angle) * R);
    const hasHome = withHome != null ? withHome : this.rng.chance(this.scale.homeRatio ?? 0.4);
    const phoneId = `phone-x${i}`;
    let homeNodeId = null;
    const mut = [];
    if (hasHome) {
      const homeId = `home-x${i}`;
      const home = { id: homeId, kind: "home", label: `Home ${name}`, secState: "normal", version: "2.3.1", supportState: "supported",
        online: true, registered: true, storageEnabled: true, assistanceEnabled: this.rng.chance(0.6),
        capabilities: ["messaging", "personal_storage", "sync", "update"],
        metrics: { cpu: 10, ram: 22, disk: 20, connections: 0, transfers: 0, egress: 0, personal: 6, community: 0 },
        storage: { secureGb: this.rng.int(2, 40), libraryGb: this.rng.int(10, 200), freeGb: this.rng.int(200, 1200) }, x, y };
      this.objects[homeId] = home;
      homeNodeId = homeId;
      const nearestRelay = this.relayIds[i % Math.max(1, this.relayIds.length)];
      if (nearestRelay) this.topo.push({ id: `t-${phoneId}-${homeId}`, from: phoneId, to: homeId });
      this.objects[phoneId] = { id: phoneId, kind: "device", userId: `user-x${i}`, type: "mobile", network: "wifi",
        online: true, connectedNodeId: homeId, keyId: `dk_x${i}`, x: x + 14, y: y + 14 };
      if (nearestRelay) this.topo.push({ id: `t-${homeId}-${nearestRelay}`, from: homeId, to: nearestRelay });
    } else {
      this.objects[phoneId] = { id: phoneId, kind: "device", userId: `user-x${i}`, type: "mobile", network: "mobile",
        online: true, connectedNodeId: null, keyId: `dk_x${i}`, x, y };
      const nearestRelay = this.relayIds[i % Math.max(1, this.relayIds.length)];
      if (nearestRelay) this.topo.push({ id: `t-${phoneId}-${nearestRelay}`, from: phoneId, to: nearestRelay });
    }
    const user = { id: `user-x${i}`, name, devices: [phoneId], homeNodeId };
    this.users.push(user);
    this._emit("USER_ADDED", `Добавлен пользователь ${name}${hasHome ? " (со своим Home)" : " (только телефон)"}`,
      `Added user ${name}${hasHome ? " (with own Home)" : " (phone only)"}`);
    return user;
  }

  /** Добавляет инфраструктурную ноду: relay | s3. */
  addNode(kind = "relay") {
    const cx = 620, cy = 480;
    const angle = this.rng.next() * Math.PI * 2;
    const x = Math.round(cx + Math.cos(angle) * 150), y = Math.round(cy + Math.sin(angle) * 150);
    if (kind === "relay") {
      const n = ++this.nodeCounter.relay;
      const id = `relay-x${n}`;
      this.objects[id] = { id, kind: "relay", secState: "normal", online: true, status: "online",
        x, y, capabilities: ["relay"], metrics: { streams: 0, egress: 20 } };
      this.relayIds.push(id);
      this.topo.push({ id: `t-${id}-net`, from: id, to: "net" });
      this._emit("NODE_ADDED", `Добавлена relay-нода ${id}`, `Relay node ${id} added`);
      return id;
    }
    const n = ++this.nodeCounter.s3;
    const id = `s3-x${n}`;
    this.objects[id] = { id, kind: "storage", ownerNodeId: null, encrypted: true, online: true, status: "online", x, y };
    this.s3Ids.push(id);
    this._emit("NODE_ADDED", `Добавлено хранилище ${id}`, `Storage ${id} added`);
    return id;
  }

  /** Отзывает ключ устройства (перестаёт быть доверенным получателем). */
  revokeDevice(deviceId) {
    const d = this.objects[deviceId];
    if (!d || d.kind !== "device") return false;
    d.revoked = true; d.online = false; d.connectedNodeId = null;
    this._emit("DEVICE_KEY_REVOKED", `Ключ устройства ${deviceId} отозван`, `Device key ${deviceId} revoked`);
    return true;
  }

  /** Блокирует прямое соединение/relay-путь между двумя узлами (id, обычно home/relay). */
  blockPair(a, b) {
    if (!this.objects[a] || !this.objects[b]) return false;
    this.blockedPairs.add(pairKey(a, b));
    this._emit("CONNECTION_BLOCKED", `Соединение ${a} ↔ ${b} заблокировано`, `Connection ${a} ↔ ${b} blocked`);
    return true;
  }
  unblockPair(key) {
    if (!this.blockedPairs.has(key)) return false;
    this.blockedPairs.delete(key);
    this._emit("CONNECTION_UNBLOCKED", `Блокировка ${key} снята`, `Block ${key} removed`);
    return true;
  }

  /** «Убивает» ноду (relay/home) — уходит offline немедленно, без авто-восстановления. */
  killNode(id) {
    const o = this.objects[id];
    if (!o) return false;
    o.online = false;
    if (o.kind === "home") o.secState = "offline"; else o.secState = "offline";
    delete this.offlineTimers[id];
    this._emit("NODE_KILLED", `${o.label || id} отключена вручную`, `${o.label || id} manually taken down`);
    return true;
  }
  reviveNode(id) {
    const o = this.objects[id];
    if (!o) return false;
    o.online = true;
    if (o.kind === "home") o.secState = "normal"; else o.secState = "normal";
    this._emit("NODE_REVIVED", `${o.label || id} снова в сети`, `${o.label || id} back online`);
    return true;
  }

  /* ── снимок для рендеринга ── */
  snapshot() {
    const o = this.objects;
    // рёбра: топология (потенциальные) + активные сегменты передач + community-помощь
    const liveEdges = this.topo
      .filter((e) => o[e.from] && o[e.to])
      .map((e) => ({ id: e.id, from: e.from, to: e.to, kind: this.isBlocked(e.from, e.to) ? "blocked" : "potential" }));
    const homeIds = this.users.map((u) => u.homeNodeId).filter(Boolean);
    for (const id of homeIds) {
      const h = o[id];
      if (h && h.online !== false && h.assistanceEnabled && (h.metrics?.community ?? 0) > 0) {
        const preempted = (h.metrics?.personal ?? 0) > 70;
        liveEdges.push({ id: `assist-${id}`, from: id, to: "net", kind: preempted ? "blocked" : "relay" });
      }
    }
    const markers = [];
    for (const tr of this.transfers) {
      const a = o[tr.path[tr.hop]], b = o[tr.path[tr.hop + 1]];
      if (!a || !b) continue;
      const kindEdge = tr.kind === "attack" ? "blocked" : (tr.kind === "photo" || tr.kind === "video" || tr.kind === "file") ? "media" : "delivered";
      liveEdges.push({ id: `tr-${tr.id}`, from: tr.path[tr.hop], to: tr.path[tr.hop + 1], kind: kindEdge });
      markers.push({
        id: tr.id, kind: tr.kind,
        x: a.x + (b.x - a.x) * tr.progress, y: a.y + (b.y - a.y) * tr.progress,
        label: tr.kind === "video" || tr.kind === "file" ? `${Math.round((tr.hop + tr.progress) / (tr.path.length - 1) * 100)}%` : null,
        route: tr.route, etaMs: tr.etaMs, path: tr.path, hop: tr.hop,
        progressPct: Math.round((tr.hop + tr.progress) / (tr.path.length - 1) * 100),
        msgLabel: tr.label
      });
    }
    return {
      objects: o, edges: liveEdges, markers, users: this.users,
      time: this.time, tickCount: this.tickCount, seed: this.seed, presetId: this.presetId,
      transfers: this.transfers.length, aggregated: this.aggregated,
      blockedPairs: [...this.blockedPairs],
      stats: this.stats, log: this.log
    };
  }
}
