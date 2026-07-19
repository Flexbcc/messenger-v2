// Живая сеть: генератор масштабируемой топологии (10–40+ пользователей, §2/§21
// ТЗ + запрос «полноценная сеть, не 2-3 пользователя») и presets нагрузки (§17).
// Объекты используют ту же форму, что и в сценариях (kind/x/y/metrics…),
// поэтому рендерятся тем же NetworkCanvas.

import { SEC_STATE as SS, CAPABILITY as CAP } from "./types.js";

export const NAME_POOL = [
  "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi", "Ivan", "Judy",
  "Karl", "Liam", "Mia", "Noah", "Olga", "Paul", "Quinn", "Ruth", "Sam", "Tara",
  "Uma", "Vik", "Wendy", "Xander", "Yara", "Zack", "Anna", "Boris", "Cleo", "Diego",
  "Erik", "Faye", "Gina", "Hugo", "Ines", "Jack", "Kira", "Leo", "Mona", "Nina",
  "Omar", "Petra", "Ravi", "Sara", "Theo", "Vera", "Will", "Zoe"
];

const homeMetrics = () => ({ cpu: 12, ram: 26, disk: 30, connections: 3, transfers: 0, egress: 2, personal: 8, community: 25 });

export const DEFAULT_SCALE = { userCount: 22, homeRatio: 0.42, laptopRatio: 0.3, relayCount: 4, s3Count: 2 };

/**
 * Строит масштабируемый мир: N пользователей на кольце вокруг инфраструктуры.
 * У части пользователей есть собственный OUO Home (своё хранилище), у
 * остальных — только устройство, полагающееся на relay/S3 fallback.
 * rng — seeded генератор (детерминизм сохраняется).
 */
export function buildWorld(rng, scale = DEFAULT_SCALE) {
  const { userCount, homeRatio, laptopRatio, relayCount, s3Count } = { ...DEFAULT_SCALE, ...scale };
  const objects = {};
  const users = [];
  const topo = [];
  const add = (o) => { objects[o.id] = o; };
  const edge = (from, to) => topo.push({ id: `t-${from}-${to}`, from, to });

  const cx = 620, cy = 480;

  // ── инфраструктура ──
  add({ id: "discovery", kind: "discovery", online: true, status: "online", x: cx - 60, y: 50 });
  add({ id: "witness", kind: "witness", online: true, status: "online", x: cx + 60, y: 50 });
  add({ id: "net", kind: "public", label: "OUO network", networkMode: "public", online: true, status: "online", x: cx, y: cy });

  const relayIds = [];
  for (let i = 0; i < relayCount; i += 1) {
    const a = (i / relayCount) * Math.PI * 2 - Math.PI / 2;
    const id = `relay-${i + 1}`;
    relayIds.push(id);
    add({ id, kind: "relay", secState: SS.NORMAL, online: true, status: "online",
      x: cx + Math.cos(a) * 140, y: cy + Math.sin(a) * 140,
      capabilities: [CAP.RELAY], metrics: { streams: 0, egress: 20 } });
    edge(id, "net");
    edge(id, "discovery");
  }

  const s3Ids = [];
  for (let i = 0; i < s3Count; i += 1) {
    const id = `s3-${i + 1}`;
    s3Ids.push(id);
    add({ id, kind: "storage", ownerNodeId: null, encrypted: true, online: true, status: "online",
      x: cx + (i === 0 ? -70 : 70), y: cy + 60 });
  }

  // ── пользователи по кольцу ──
  const R = Math.min(440, 260 + userCount * 4.5);
  for (let i = 0; i < userCount; i += 1) {
    const angle = (i / userCount) * Math.PI * 2;
    const x = Math.round(cx + Math.cos(angle) * R);
    const y = Math.round(cy + Math.sin(angle) * R);
    const name = NAME_POOL[i % NAME_POOL.length] + (i >= NAME_POOL.length ? String(Math.floor(i / NAME_POOL.length) + 1) : "");
    const hasHome = rng.chance(homeRatio);
    const nearestRelay = relayIds[i % relayIds.length];
    const phoneId = `phone-${i}`;
    const laptopId = `laptop-${i}`;

    if (hasHome) {
      const homeId = `home-${i}`;
      add({ id: homeId, kind: "home", label: `Home ${name}`, secState: SS.NORMAL, version: "2.3.1", supportState: "supported",
        online: true, registered: true, storageEnabled: true, assistanceEnabled: rng.chance(0.6),
        capabilities: [CAP.MESSAGING, CAP.PERSONAL_STORAGE, CAP.SYNC, ...(rng.chance(0.6) ? [CAP.RELAY] : []), CAP.UPDATE],
        metrics: homeMetrics(), storage: { secureGb: rng.int(4, 90), libraryGb: rng.int(20, 400), freeGb: rng.int(200, 1500) },
        x, y });
      add({ id: phoneId, kind: "device", userId: `user-${i}`, type: "mobile", network: rng.chance(0.8) ? "wifi" : "mobile",
        online: true, connectedNodeId: homeId, keyId: `dk_${i}p`, x: x + 14, y: y + 14 });
      edge(phoneId, homeId);
      const devices = [phoneId];
      if (rng.chance(laptopRatio)) {
        add({ id: laptopId, kind: "device", userId: `user-${i}`, type: "laptop", network: "wifi",
          online: true, connectedNodeId: homeId, keyId: `dk_${i}l`, x: x - 14, y: y - 14 });
        edge(laptopId, homeId);
        devices.push(laptopId);
      }
      edge(homeId, nearestRelay);
      edge(homeId, "net");
      users.push({ id: `user-${i}`, name, devices, homeNodeId: homeId });
    } else {
      add({ id: phoneId, kind: "device", userId: `user-${i}`, type: "mobile", network: rng.chance(0.7) ? "wifi" : "mobile",
        online: true, connectedNodeId: null, keyId: `dk_${i}p`, x, y });
      edge(phoneId, nearestRelay);
      users.push({ id: `user-${i}`, name, devices: [phoneId], homeNodeId: null });
    }
  }

  return { objects, topo, users, relayIds, s3Ids };
}

// Presets нагрузки (вероятности на симуляционный тик ≈ 1 секунда).
export const PRESETS = {
  calm:     { messageRate: 0.30, mediaRate: 0.05, fileRate: 0.02, syncRate: 0.06, offlineProb: 0.006, routeFailProb: 0.008, attackProb: 0.00, loadSpikeProb: 0.015, callProb: 0.01 },
  normal:   { messageRate: 0.55, mediaRate: 0.14, fileRate: 0.05, syncRate: 0.14, offlineProb: 0.015, routeFailProb: 0.020, attackProb: 0.006, loadSpikeProb: 0.03, callProb: 0.02 },
  busy:     { messageRate: 0.85, mediaRate: 0.28, fileRate: 0.14, syncRate: 0.22, offlineProb: 0.020, routeFailProb: 0.030, attackProb: 0.006, loadSpikeProb: 0.06, callProb: 0.03 },
  unstable: { messageRate: 0.55, mediaRate: 0.14, fileRate: 0.07, syncRate: 0.12, offlineProb: 0.060, routeFailProb: 0.090, attackProb: 0.012, loadSpikeProb: 0.05, callProb: 0.02 },
  threat:   { messageRate: 0.45, mediaRate: 0.09, fileRate: 0.03, syncRate: 0.09, offlineProb: 0.015, routeFailProb: 0.025, attackProb: 0.10, loadSpikeProb: 0.03, callProb: 0.01 },
  family:   { messageRate: 0.55, mediaRate: 0.34, fileRate: 0.09, syncRate: 0.32, offlineProb: 0.010, routeFailProb: 0.010, attackProb: 0.00, loadSpikeProb: 0.03, callProb: 0.03 }
};

export const PRESET_IDS = ["calm", "normal", "busy", "unstable", "threat", "family"];
