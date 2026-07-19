// Пять базовых сценариев OUO Network (раздел 19 ТЗ).
// Каждый сценарий — детерминированная последовательность событий, которая
// строит мир и доставляет одно текстовое сообщение. Структура данных и
// порядок событий соответствуют будущей реальной архитектуре.

import { EVENT_TYPE as ET, NET_MODE, NODE_STATE as NS, EDGE_KIND as EK } from "./types.js";

const D = (ru, en) => ({ ru, en });

/* ─────────── builder ─────────── */
function scenario(id, titleRu, titleEn) {
  const s = { id, title: D(titleRu, titleEn), viewBox: "0 0 980 580", events: [] };
  let t = 0;
  let seq = 0;
  s.push = (type, source, target, desc, why, mut) => {
    s.events.push({ id: `ev${++seq}`, time: t, type, source, target, desc, why: why || null, mut: mut || [] });
    t += 1;
  };
  return s;
}

/* ─────────── object helpers ─────────── */
function infra(s, { bootstrap, discovery, witness, relays = [] }) {
  if (bootstrap) s.push(ET.NODE_STARTED, bootstrap.id, null, D("Bootstrap-нода в сети", "Bootstrap node online"), null,
    [{ op: "add", obj: { id: bootstrap.id, kind: "bootstrap", status: NS.ONLINE, x: bootstrap.x, y: bootstrap.y } }]);
  if (discovery) s.push(ET.NODE_STARTED, discovery.id, null, D("Discovery-нода в сети", "Discovery node online"), null,
    [{ op: "add", obj: { id: discovery.id, kind: "discovery", status: NS.ONLINE, x: discovery.x, y: discovery.y } }]);
  if (witness) s.push(ET.NODE_STARTED, witness.id, null, D("Witness-нода в сети", "Witness node online"), null,
    [{ op: "add", obj: { id: witness.id, kind: "witness", status: NS.ONLINE, x: witness.x, y: witness.y } }]);
  for (const r of relays) s.push(ET.NODE_STARTED, r.id, null, D("Relay-нода в сети", "Relay node online"), null,
    [{ op: "add", obj: { id: r.id, kind: "relay", status: NS.ONLINE, x: r.x, y: r.y } }]);
}

function addNode(s, node) {
  s.push(ET.NODE_CREATED, node.id, null, D(`Нода ${node.id} создана`, `Node ${node.id} created`), null,
    [{ op: "add", obj: {
      id: node.id, kind: node.kind, ownerUserId: node.ownerUserId || null,
      networkMode: node.networkMode, publicAddress: node.publicAddress || null,
      natType: node.natType || null, registered: false,
      storageEnabled: node.storageEnabled ?? true, relayEnabled: node.relayEnabled ?? false,
      status: NS.CREATED, x: node.x, y: node.y
    } }]);
}

function addUser(s, u) {
  s.push(ET.USER_CREATED, u.id, null, D(`Пользователь ${u.name} создан`, `User ${u.name} created`), null,
    [{ op: "add", obj: { id: u.id, kind: "user", name: u.name, publicId: u.publicId, trustLevel: u.trustLevel || "verified", homeNodeId: u.homeNodeId, status: NS.ONLINE, x: u.x, y: u.y } }]);
}

function addDevice(s, d) {
  s.push(ET.DEVICE_CREATED, d.id, null, D(`Устройство ${d.id} создано`, `Device ${d.id} created`), null,
    [{ op: "add", obj: { id: d.id, kind: "device", userId: d.userId, type: d.type || "mobile", network: d.network || "wifi", connectedNodeId: null, status: NS.ONLINE, x: d.x, y: d.y } }]);
}

/* ─────────── lifecycle helpers ─────────── */
function registerPublic(s, nodeId, { bootstrap, discovery }) {
  s.push(ET.NODE_STARTED, nodeId, null, D(`${nodeId}: запуск`, `${nodeId}: starting`), null, [{ op: "status", id: nodeId, status: NS.STARTING }]);
  s.push(ET.BOOTSTRAP_REQUEST, nodeId, bootstrap, D(`${nodeId} обращается к bootstrap`, `${nodeId} contacts bootstrap`),
    D("Новая нода не знает адресов сети. Bootstrap выдаёт список discovery, relay и witness — но не хранит список всех пользователей.",
      "A new node knows no network addresses. Bootstrap returns the list of discovery, relay and witness endpoints — it does not store a list of all users."),
    [{ op: "status", id: nodeId, status: NS.CONTACTING_BOOTSTRAP }, { op: "addEdge", id: `${nodeId}-boot`, from: nodeId, to: bootstrap, kind: EK.SERVICE }]);
  s.push(ET.BOOTSTRAP_RESPONSE, bootstrap, nodeId, D("Bootstrap вернул конфигурацию сети", "Bootstrap returned network config"), null,
    [{ op: "delEdge", id: `${nodeId}-boot` }]);
  s.push(ET.NODE_REGISTER_REQUEST, nodeId, discovery, D(`${nodeId} регистрируется в discovery`, `${nodeId} registers in discovery`),
    D("Discovery проверяет подпись, версию протокола, сертификат и capabilities. Discovery не хранит сообщения.",
      "Discovery verifies the signature, protocol version, certificate and capabilities. Discovery does not store messages."),
    [{ op: "status", id: nodeId, status: NS.REGISTERING }, { op: "addEdge", id: `${nodeId}-disc`, from: nodeId, to: discovery, kind: EK.SERVICE }]);
  s.push(ET.NODE_REGISTERED, discovery, nodeId, D(`${nodeId} зарегистрирована`, `${nodeId} registered`), null,
    [{ op: "patch", id: nodeId, props: { registered: true } }]);
  s.push(ET.ROUTE_RECORD_PUBLISHED, nodeId, discovery, D(`${nodeId} публикует route-record (direct)`, `${nodeId} publishes route-record (direct)`),
    D("route-record говорит другим нодам, как достучаться до этой ноды. Для публичной ноды — напрямую по адресу.",
      "The route-record tells other nodes how to reach this node. For a public node — directly by address."),
    [{ op: "delEdge", id: `${nodeId}-disc` }]);
  s.push(ET.HEARTBEAT_SENT, nodeId, discovery, D(`${nodeId} отправляет heartbeat`, `${nodeId} sends heartbeat`), null,
    [{ op: "status", id: nodeId, status: NS.ONLINE }]);
}

function registerNat(s, nodeId, { bootstrap, discovery, relayId }) {
  s.push(ET.NODE_STARTED, nodeId, null, D(`${nodeId}: запуск (за NAT)`, `${nodeId}: starting (behind NAT)`), null, [{ op: "status", id: nodeId, status: NS.STARTING }]);
  s.push(ET.BOOTSTRAP_REQUEST, nodeId, bootstrap, D(`${nodeId} обращается к bootstrap`, `${nodeId} contacts bootstrap`), null,
    [{ op: "status", id: nodeId, status: NS.CONTACTING_BOOTSTRAP }, { op: "addEdge", id: `${nodeId}-boot`, from: nodeId, to: bootstrap, kind: EK.SERVICE }]);
  s.push(ET.BOOTSTRAP_RESPONSE, bootstrap, nodeId, D("Bootstrap вернул список relay", "Bootstrap returned relay list"), null,
    [{ op: "delEdge", id: `${nodeId}-boot` }]);
  s.push(ET.RELAY_CHANNEL_OPENED, nodeId, relayId, D(`${nodeId} открывает исходящий канал к ${relayId}`, `${nodeId} opens outbound channel to ${relayId}`),
    D("Нода за NAT не принимает входящие соединения. Поэтому она заранее устанавливает исходящий постоянный канал к relay; relay использует уже открытый канал для доставки входящих пакетов.",
      "A node behind NAT cannot accept inbound connections. So it opens a persistent outbound channel to a relay in advance; the relay reuses that open channel to deliver inbound packets."),
    [{ op: "addEdge", id: `${nodeId}-${relayId}`, from: nodeId, to: relayId, kind: EK.RELAY }]);
  s.push(ET.NODE_REGISTER_REQUEST, nodeId, discovery, D(`${nodeId} регистрируется в discovery`, `${nodeId} registers in discovery`), null,
    [{ op: "status", id: nodeId, status: NS.REGISTERING }, { op: "addEdge", id: `${nodeId}-disc`, from: nodeId, to: discovery, kind: EK.SERVICE }]);
  s.push(ET.NODE_REGISTERED, discovery, nodeId, D(`${nodeId} зарегистрирована`, `${nodeId} registered`), null,
    [{ op: "patch", id: nodeId, props: { registered: true } }, { op: "delEdge", id: `${nodeId}-disc` }]);
  s.push(ET.ROUTE_RECORD_PUBLISHED, nodeId, discovery, D(`${nodeId} публикует route-record (relay)`, `${nodeId} publishes route-record (relay)`),
    D("route-record ноды за NAT указывает reachableVia: relay + channelId. Прямого входящего адреса у неё нет.",
      "The NAT node's route-record lists reachableVia: relay + channelId. It has no direct inbound address."),
    [{ op: "status", id: nodeId, status: NS.ONLINE }]);
}

function connectUser(s, { userId, deviceId, nodeId, name, lan }) {
  s.push(ET.USER_CONNECTED, deviceId, nodeId, D(`${name}: устройство подключено к ${nodeId}`, `${name}: device connected to ${nodeId}`), null,
    [{ op: "patch", id: deviceId, props: { connectedNodeId: nodeId } },
     { op: "addEdge", id: `${deviceId}-${nodeId}`, from: deviceId, to: nodeId, kind: lan ? EK.LAN : EK.DIRECT }]);
}

// Пометить рёбра пути как «маршрут доставки», прогнать конверт и вернуть ACK.
function runMessage(s, { msgId, senderDevice, recipientDevice, path, mode }) {
  // path — массив id объектов от senderDevice до recipientDevice включительно.
  s.push(ET.MESSAGE_CREATED, senderDevice, recipientDevice, D("Сообщение создано (device видит plaintext)", "Message created (device sees plaintext)"),
    D("Открытый текст существует только на устройствах отправителя и получателя. Ноды видят лишь зашифрованный envelope.",
      "Plaintext exists only on the sender and recipient devices. Nodes only ever see the encrypted envelope."), []);
  s.push(ET.MESSAGE_ENCRYPTED, senderDevice, null, D("Сообщение зашифровано (E2EE envelope)", "Message encrypted (E2EE envelope)"), null, []);

  for (let i = 0; i < path.length - 1; i += 1) {
    const from = path[i];
    const to = path[i + 1];
    const edgeId = `${from}-${to}`;
    const rev = `${to}-${from}`;
    const type = i === 0 ? ET.MESSAGE_SENT : (i === path.length - 2 ? ET.MESSAGE_RECEIVED : ET.MESSAGE_RELAYED);
    const desc = i === 0
      ? D("Устройство отправляет envelope на свою ноду", "Device sends the envelope to its node")
      : (i === path.length - 2
          ? D("Нода доставляет envelope устройству получателя", "Node delivers the envelope to the recipient device")
          : D("Пакет ретранслируется дальше по маршруту", "Packet is relayed further along the route"));
    s.push(type, from, to, desc, null,
      [{ op: "addEdge", id: edgeId, from, to, kind: EK.DELIVERED },
       { op: "setEdge", id: rev, kind: EK.DELIVERED },
       { op: "msg", msg: { id: msgId, edgeId, kind: "message", label: mode } }]);
  }

  s.push(ET.MESSAGE_DECRYPTED, recipientDevice, null, D("Получатель расшифровал сообщение", "Recipient decrypted the message"), null, [{ op: "clearMsg" }]);

  // ACK обратно по тому же пути.
  const back = [...path].reverse();
  s.push(ET.ACK_SENT, recipientDevice, senderDevice, D("Получатель отправляет ACK", "Recipient sends ACK"), null,
    [{ op: "msg", msg: { id: `${msgId}-ack`, edgeId: `${back[0]}-${back[1]}`, kind: "ack", label: "ACK" } }]);
  s.push(ET.ACK_RECEIVED, senderDevice, null, D("ACK получен отправителем — доставка подтверждена", "ACK received by sender — delivery confirmed"), null, [{ op: "clearMsg" }]);
}

/* ─────────── Scenario 1: two users on one node ─────────── */
function s1() {
  const s = scenario("one-node", "Два пользователя на одной ноде", "Two users on one node");
  const boot = { id: "bootstrap-1", x: 140, y: 70 };
  const disc = { id: "discovery-1", x: 470, y: 70 };
  infra(s, { bootstrap: boot, discovery: disc });
  addNode(s, { id: "node-x", kind: "public", networkMode: NET_MODE.PUBLIC, publicAddress: "node-x.ouo", x: 470, y: 320 });
  registerPublic(s, "node-x", { bootstrap: boot.id, discovery: disc.id });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-x", x: 250, y: 470 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 250, y: 400 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-x", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-x", x: 690, y: 470 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 690, y: 400 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-x", name: "Bob" });
  s.push(ET.ROUTE_LOOKUP_STARTED, "node-x", "node-x", D("Alice пишет Bob → node-x проверяет получателя", "Alice messages Bob → node-x checks recipient"),
    D("Оба пользователя обслуживаются node-x. Нода видит, что получатель локальный, и не отправляет пакет во внешнюю сеть.",
      "Both users are served by node-x. The node sees the recipient is local and never sends the packet to the external network."), []);
  runMessage(s, { msgId: "msg-1", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-x", "device-b1"], mode: "local node delivery" });
  return s;
}

/* ─────────── Scenario 2: two users on different public nodes ─────────── */
function s2() {
  const s = scenario("two-public", "Пользователи на разных публичных нодах", "Two users on different public nodes");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 470, y: 60 };
  const wit = { id: "witness-1", x: 800, y: 60 };
  infra(s, { bootstrap: boot, discovery: disc, witness: wit });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 230, y: 300 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.PUBLIC, publicAddress: "node-b.ouo", x: 740, y: 300 });
  registerPublic(s, "node-b", { bootstrap: boot.id, discovery: disc.id });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 230, y: 490 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 230, y: 420 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 740, y: 490 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 740, y: 420 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });
  // route resolution
  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.ROUTE_LOOKUP_STARTED, "node-a", "discovery-1", D("node-a ищет маршрут к Bob", "node-a looks up route to Bob"),
    D("Клиент знает identity Bob, но не его текущую точку присутствия. node-a спрашивает discovery, где сейчас home-нода Bob.",
      "The client knows Bob's identity but not his current point of presence. node-a asks discovery where Bob's home node is now."),
    [{ op: "status", id: "node-a", status: NS.SEARCHING }, { op: "addEdge", id: "node-a-discovery-1", from: "node-a", to: "discovery-1", kind: EK.SERVICE }]);
  s.push(ET.ROUTE_FOUND, "discovery-1", "node-a", D("Получен route-record node-b", "Received route-record for node-b"), null,
    [{ op: "delEdge", id: "node-a-discovery-1" }, { op: "addEdge", id: "node-a-witness-1", from: "node-a", to: "witness-1", kind: EK.SERVICE }]);
  s.push(ET.ROUTE_FOUND, "witness-1", "node-a", D("Witness подтвердил актуальность маршрута", "Witness confirmed the route is current"),
    D("Witness защищает от подделанных route-record: подтверждает, что запись свежая и нода действительно присутствует.",
      "Witness protects against forged route-records: it confirms the record is fresh and the node is actually present."),
    [{ op: "delEdge", id: "node-a-witness-1" }, { op: "status", id: "node-a", status: NS.ONLINE }]);
  s.push(ET.DIRECT_CONNECTION_STARTED, "node-a", "node-b", D("Пробное прямое соединение node-a → node-b", "Trial direct connection node-a → node-b"), null,
    [{ op: "addEdge", id: "node-a-node-b", from: "node-a", to: "node-b", kind: EK.POTENTIAL }]);
  s.push(ET.DIRECT_CONNECTION_ESTABLISHED, "node-a", "node-b", D("Прямое соединение установлено", "Direct connection established"), null,
    [{ op: "setEdge", id: "node-a-node-b", kind: EK.DIRECT }]);
  runMessage(s, { msgId: "msg-2", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-a", "node-b", "device-b1"], mode: "direct route" });
  return s;
}

/* ─────────── Scenario 3: public node ↔ NAT node ─────────── */
function s3() {
  const s = scenario("public-nat", "Публичная нода и нода за NAT", "Public node communicates with NAT node");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 470, y: 60 };
  const relay = { id: "relay-1", x: 780, y: 200 };
  infra(s, { bootstrap: boot, discovery: disc, relays: [relay] });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 230, y: 320 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.NAT_SYMMETRIC, natType: "symmetric", x: 740, y: 400 });
  registerNat(s, "node-b", { bootstrap: boot.id, discovery: disc.id, relayId: "relay-1" });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 230, y: 500 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 230, y: 430 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 900, y: 500 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 900, y: 430 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });
  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.ROUTE_LOOKUP_STARTED, "node-a", "discovery-1", D("node-a ищет маршрут к Bob", "node-a looks up route to Bob"), null,
    [{ op: "status", id: "node-a", status: NS.SEARCHING }, { op: "addEdge", id: "node-a-discovery-1", from: "node-a", to: "discovery-1", kind: EK.SERVICE }]);
  s.push(ET.ROUTE_FOUND, "discovery-1", "node-a", D("route-record node-b: reachableVia relay-1", "route-record node-b: reachableVia relay-1"),
    D("node-b за symmetric NAT недоступна напрямую. Её route-record указывает доставку через relay-1 по уже открытому каналу.",
      "node-b is behind symmetric NAT and not directly reachable. Its route-record specifies delivery via relay-1 over the already-open channel."),
    [{ op: "delEdge", id: "node-a-discovery-1" }, { op: "status", id: "node-a", status: NS.ONLINE }]);
  s.push(ET.DIRECT_CONNECTION_ESTABLISHED, "node-a", "relay-1", D("node-a соединяется с relay-1", "node-a connects to relay-1"), null,
    [{ op: "addEdge", id: "node-a-relay-1", from: "node-a", to: "relay-1", kind: EK.RELAY }]);
  runMessage(s, { msgId: "msg-3", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-a", "relay-1", "node-b", "device-b1"], mode: "relay route" });
  return s;
}

/* ─────────── Scenario 4: two NAT nodes via relay ─────────── */
function s4() {
  const s = scenario("nat-to-nat", "Две ноды за NAT через relay", "Two NAT nodes communicate through relay");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 470, y: 60 };
  const relay = { id: "relay-x", x: 490, y: 300 };
  infra(s, { bootstrap: boot, discovery: disc, relays: [relay] });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.NAT_SYMMETRIC, natType: "symmetric", x: 200, y: 360 });
  registerNat(s, "node-a", { bootstrap: boot.id, discovery: disc.id, relayId: "relay-x" });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.NAT_SYMMETRIC, natType: "symmetric", x: 780, y: 360 });
  registerNat(s, "node-b", { bootstrap: boot.id, discovery: disc.id, relayId: "relay-x" });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 100, y: 500 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 200, y: 470 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 880, y: 500 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 780, y: 470 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });
  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.ROUTE_LOOKUP_STARTED, "node-a", "discovery-1", D("node-a ищет маршрут к Bob", "node-a looks up route to Bob"), null,
    [{ op: "status", id: "node-a", status: NS.SEARCHING }, { op: "addEdge", id: "node-a-discovery-1", from: "node-a", to: "discovery-1", kind: EK.SERVICE }]);
  s.push(ET.ROUTE_FOUND, "discovery-1", "node-a", D("Обе ноды за NAT — общий relay-x", "Both nodes behind NAT — shared relay-x"),
    D("Прямое соединение между двумя symmetric NAT невозможно. Обе ноды держат исходящие каналы к relay-x, поэтому доставка идёт node-a → relay-x → node-b.",
      "A direct connection between two symmetric NATs is impossible. Both nodes hold outbound channels to relay-x, so delivery goes node-a → relay-x → node-b."),
    [{ op: "delEdge", id: "node-a-discovery-1" }, { op: "status", id: "node-a", status: NS.ONLINE }]);
  runMessage(s, { msgId: "msg-4", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-a", "relay-x", "node-b", "device-b1"], mode: "relay route" });
  return s;
}

/* ─────────── Scenario 5: local-only node → public ─────────── */
function s5() {
  const s = scenario("local-to-public", "Локальная нода включает внешний режим", "Local-only node switches to public mode");
  const boot = { id: "bootstrap-1", x: 160, y: 60 };
  const disc = { id: "discovery-1", x: 500, y: 60 };
  const relay = { id: "relay-1", x: 820, y: 150 };
  infra(s, { bootstrap: boot, discovery: disc, relays: [relay] });
  // LAN region
  s.push(ET.NODE_STARTED, "lan-1", null, D("Локальная сеть (LAN)", "Local network (LAN)"), null,
    [{ op: "add", obj: { id: "lan-1", kind: "lan", label: "LAN 192.168.1.0/24", x: 90, y: 260, w: 380, h: 280, status: NS.ONLINE } }]);
  addNode(s, { id: "node-local-a", kind: "local", ownerUserId: "user-a", networkMode: NET_MODE.LOCAL_ONLY, publicAddress: null, x: 280, y: 320 });
  s.push(ET.NODE_STARTED, "node-local-a", null, D("node-local-a: локальный режим (local_ready)", "node-local-a: local mode (local_ready)"),
    D("В локальном режиме нода обслуживает только устройства внутри LAN, не регистрируется в общей сети, и внешние пользователи её не находят.",
      "In local mode the node serves only devices inside the LAN, does not register in the shared network, and external users cannot find it."),
    [{ op: "status", id: "node-local-a", status: NS.LOCAL_READY }]);
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-local-a", x: 160, y: 470 });
  addDevice(s, { id: "device-a1", userId: "user-a", network: "wifi", x: 380, y: 470 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-local-a", name: "Alice", lan: true });
  // switch to public
  s.push(ET.MODE_SWITCH, "user-a", "node-local-a", D("Alice включает внешний режим", "Alice enables external mode"),
    D("При включении внешнего режима локальная нода не открывает входящий порт. Вместо этого она устанавливает исходящий канал к relay и публикует route-record — и становится доступной пользователям общей сети.",
      "When external mode is enabled the local node does not open an inbound port. Instead it opens an outbound channel to a relay and publishes a route-record — becoming reachable to the shared network."),
    [{ op: "patch", id: "node-local-a", props: { networkMode: NET_MODE.NAT_SYMMETRIC } }, { op: "status", id: "node-local-a", status: NS.STARTING }]);
  s.push(ET.RELAY_CHANNEL_OPENED, "node-local-a", "relay-1", D("node-local-a открывает исходящий канал к relay-1", "node-local-a opens outbound channel to relay-1"), null,
    [{ op: "addEdge", id: "node-local-a-relay-1", from: "node-local-a", to: "relay-1", kind: EK.RELAY }]);
  s.push(ET.NODE_REGISTER_REQUEST, "node-local-a", "discovery-1", D("node-local-a регистрируется", "node-local-a registers"), null,
    [{ op: "status", id: "node-local-a", status: NS.REGISTERING }, { op: "addEdge", id: "node-local-a-disc", from: "node-local-a", to: "discovery-1", kind: EK.SERVICE }]);
  s.push(ET.ROUTE_RECORD_PUBLISHED, "node-local-a", "discovery-1", D("Опубликован route-record (relay) — нода доступна извне", "route-record (relay) published — node reachable externally"), null,
    [{ op: "delEdge", id: "node-local-a-disc" }, { op: "patch", id: "node-local-a", props: { registered: true } }, { op: "status", id: "node-local-a", status: NS.ONLINE }]);
  // incoming message from external public node B
  addNode(s, { id: "node-b", kind: "public", ownerUserId: "user-b", networkMode: NET_MODE.PUBLIC, publicAddress: "node-b.ouo", x: 780, y: 380 });
  s.push(ET.NODE_STARTED, "node-b", null, D("Внешняя публичная node-b в сети", "External public node-b online"), null, [{ op: "status", id: "node-b", status: NS.ONLINE }, { op: "patch", id: "node-b", props: { registered: true } }]);
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 900, y: 500 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 780, y: 470 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });
  s.push(ET.ROUTE_FOUND, "discovery-1", "node-b", D("node-b находит Alice через relay-1", "node-b finds Alice via relay-1"), null,
    [{ op: "addEdge", id: "node-b-relay-1", from: "node-b", to: "relay-1", kind: EK.RELAY }]);
  runMessage(s, { msgId: "msg-5", senderDevice: "device-b1", recipientDevice: "device-a1", path: ["device-b1", "node-b", "relay-1", "node-local-a", "device-a1"], mode: "relay route" });
  return s;
}

function addStorage(s, st) {
  s.push(ET.NODE_STARTED, st.id, null, D(`Хранилище ${st.id} (S3) готово`, `Storage ${st.id} (S3) ready`), null,
    [{ op: "add", obj: { id: st.id, kind: "storage", ownerNodeId: st.ownerNodeId, encrypted: true, ttlEnabled: true, status: NS.ONLINE, x: st.x, y: st.y } }]);
}

// Проигрывает текстовый маршрут (без ACK) — используется как «несущий» поток
// для media-locator. Помечает рёбра как доставку.
function runEnvelope(s, { msgId, path, mode }) {
  for (let i = 0; i < path.length - 1; i += 1) {
    const from = path[i], to = path[i + 1];
    const edgeId = `${from}-${to}`;
    const type = i === 0 ? ET.MESSAGE_SENT : (i === path.length - 2 ? ET.MESSAGE_RECEIVED : ET.MESSAGE_RELAYED);
    const desc = i === 0
      ? D("Устройство отправляет envelope с locator+key", "Device sends envelope with locator+key")
      : (i === path.length - 2
          ? D("Нода доставляет envelope устройству получателя", "Node delivers the envelope to the recipient device")
          : D("Пакет ретранслируется дальше", "Packet is relayed further"));
    s.push(type, from, to, desc, null,
      [{ op: "addEdge", id: edgeId, from, to, kind: EK.DELIVERED },
       { op: "msg", msg: { id: msgId, edgeId, kind: "message", label: mode } }]);
  }
}

/* ─────────── Scenario 6: media delivery (two streams, S3) ─────────── */
function s6() {
  const s = scenario("media-s3", "Доставка медиа через S3 (два потока)", "Media delivery via S3 (two streams)");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 490, y: 60 };
  infra(s, { bootstrap: boot, discovery: disc });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 250, y: 300 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.PUBLIC, publicAddress: "node-b.ouo", x: 730, y: 300 });
  registerPublic(s, "node-b", { bootstrap: boot.id, discovery: disc.id });
  addStorage(s, { id: "s3-a", ownerNodeId: "node-a", x: 490, y: 200 });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 250, y: 490 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 250, y: 420 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 730, y: 490 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 730, y: 420 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });

  // Media stream: encrypt локально, upload зашифрованного blob в S3.
  s.push(ET.MEDIA_ENCRYPTED, "device-a1", null, D("Alice выбирает файл, генерирует media key, шифрует локально", "Alice picks a file, generates a media key, encrypts locally"),
    D("Медиа шифруется отдельным media key на устройстве. Ни нода, ни S3 не видят содержимое и не имеют ключа.",
      "Media is encrypted with a separate media key on the device. Neither the node nor S3 sees the content or holds the key."), []);
  s.push(ET.MEDIA_UPLOADED, "device-a1", "s3-a", D("Зашифрованный blob загружен в S3, получен media locator", "Encrypted blob uploaded to S3, media locator returned"), null,
    [{ op: "addEdge", id: "device-a1-s3-a", from: "device-a1", to: "s3-a", kind: EK.MEDIA },
     { op: "msg", msg: { id: "media-6", edgeId: "device-a1-s3-a", kind: "media", label: "media path" } }]);

  // Message stream: E2EE envelope с locator+key едет по нодам.
  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Envelope содержит locator + media key (E2EE)", "Envelope carries locator + media key (E2EE)"),
    D("По нодам едет только небольшой E2EE-конверт с locator и ключом. Сам файл через ноды не проходит — это разделяет message path и media path.",
      "Only a small E2EE envelope with the locator and key travels through the nodes. The file itself never passes through the nodes — this separates the message path from the media path."),
    [{ op: "clearMsg" }]);
  runEnvelope(s, { msgId: "msg-6", path: ["device-a1", "node-a", "node-b", "device-b1"], mode: "message path" });

  // Recipient извлекает locator+key, качает blob напрямую из S3, расшифровывает.
  s.push(ET.MEDIA_DOWNLOADED, "s3-a", "device-b1", D("Bob извлекает locator+key и качает blob из S3", "Bob extracts locator+key and downloads the blob from S3"), null,
    [{ op: "clearMsg" }, { op: "addEdge", id: "s3-a-device-b1", from: "s3-a", to: "device-b1", kind: EK.MEDIA },
     { op: "msg", msg: { id: "media-6b", edgeId: "s3-a-device-b1", kind: "media", label: "media path" } }]);
  s.push(ET.MEDIA_DECRYPTED, "device-b1", null, D("Bob расшифровывает медиа локально", "Bob decrypts the media locally"),
    D("Расшифровка происходит на устройстве получателя. S3 хранил только зашифрованный объект и никогда не имел ключа.",
      "Decryption happens on the recipient device. S3 only stored an encrypted object and never held the key."),
    [{ op: "clearMsg" }]);
  return s;
}

/* ─────────── Scenario 7: message retry after delivery failure ─────────── */
function s7() {
  const s = scenario("retry", "Ретрай после сбоя доставки", "Message retry after delivery failure");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 490, y: 60 };
  infra(s, { bootstrap: boot, discovery: disc });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 250, y: 300 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.PUBLIC, publicAddress: "node-b.ouo", x: 730, y: 300 });
  registerPublic(s, "node-b", { bootstrap: boot.id, discovery: disc.id });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 250, y: 490 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 250, y: 420 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 730, y: 490 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 730, y: 420 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });

  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.MESSAGE_ENCRYPTED, "device-a1", null, D("Сообщение зашифровано (E2EE envelope)", "Message encrypted (E2EE envelope)"), null, []);
  s.push(ET.MESSAGE_SENT, "device-a1", "node-a", D("Устройство отправляет envelope на node-a", "Device sends envelope to node-a"), null,
    [{ op: "addEdge", id: "device-a1-node-a", from: "device-a1", to: "node-a", kind: EK.DELIVERED }]);
  s.push(ET.NODE_OFFLINE, "node-b", null, D("node-b временно недоступна", "node-b is temporarily unavailable"), null,
    [{ op: "status", id: "node-b", status: NS.OFFLINE }]);
  s.push(ET.DELIVERY_FAILED, "node-a", "node-b", D("Доставка node-a → node-b не удалась", "Delivery node-a → node-b failed"),
    D("node-b не отвечает. Envelope остаётся в очереди на node-a (deliveryPolicy.maxRetries = 5); открытый текст никуда не утекает.",
      "node-b does not respond. The envelope stays queued on node-a (deliveryPolicy.maxRetries = 5); no plaintext leaks anywhere."),
    [{ op: "addEdge", id: "node-a-node-b", from: "node-a", to: "node-b", kind: EK.ERROR }, { op: "status", id: "node-a", status: NS.DELIVERING }]);
  s.push(ET.RETRY_SCHEDULED, "node-a", null, D("Запланирован повтор (backoff)", "Retry scheduled (backoff)"), null,
    [{ op: "setEdge", id: "node-a-node-b", kind: EK.RETRY }]);
  s.push(ET.NODE_ONLINE, "node-b", null, D("node-b снова в сети", "node-b is back online"), null,
    [{ op: "status", id: "node-b", status: NS.ONLINE }, { op: "delEdge", id: "node-a-node-b" }]);
  runMessage(s, { msgId: "msg-7", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-a", "node-b", "device-b1"], mode: "retry ok" });
  return s;
}

/* ─────────── Scenario 8: relay failure → backup route ─────────── */
function s8() {
  const s = scenario("failover", "Отказ relay → резервный маршрут", "Relay failure → backup route");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 470, y: 60 };
  const relay1 = { id: "relay-1", x: 520, y: 180 };
  const relay2 = { id: "relay-2", x: 520, y: 430 };
  infra(s, { bootstrap: boot, discovery: disc, relays: [relay1, relay2] });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 190, y: 300 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.NAT_SYMMETRIC, natType: "symmetric", x: 830, y: 300 });
  registerNat(s, "node-b", { bootstrap: boot.id, discovery: disc.id, relayId: "relay-1" });
  s.push(ET.RELAY_CHANNEL_OPENED, "node-b", "relay-2", D("node-b открывает резервный канал к relay-2", "node-b opens a backup channel to relay-2"),
    D("Нода за NAT держит каналы сразу к нескольким relay и публикует их все в route-record (reachableVia). Это даёт резервный маршрут.",
      "The NAT node holds channels to several relays at once and publishes them all in its route-record (reachableVia). This provides a backup route."),
    [{ op: "addEdge", id: "node-b-relay-2", from: "node-b", to: "relay-2", kind: EK.RELAY }]);
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 190, y: 490 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 190, y: 420 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 900, y: 490 });
  addDevice(s, { id: "device-b1", userId: "user-b", x: 900, y: 420 });
  connectUser(s, { userId: "user-b", deviceId: "device-b1", nodeId: "node-b", name: "Bob" });

  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.ROUTE_FOUND, "discovery-1", "node-a", D("route-record node-b: reachableVia [relay-1, relay-2]", "route-record node-b: reachableVia [relay-1, relay-2]"), null, []);
  s.push(ET.DIRECT_CONNECTION_ESTABLISHED, "node-a", "relay-1", D("node-a выбирает relay-1 (основной)", "node-a selects relay-1 (primary)"), null,
    [{ op: "addEdge", id: "node-a-relay-1", from: "node-a", to: "relay-1", kind: EK.RELAY }]);
  s.push(ET.MESSAGE_SENT, "device-a1", "node-a", D("Envelope отправлен на node-a", "Envelope sent to node-a"), null,
    [{ op: "addEdge", id: "device-a1-node-a", from: "device-a1", to: "node-a", kind: EK.DELIVERED }]);
  s.push(ET.NODE_OFFLINE, "relay-1", null, D("relay-1 выходит из строя", "relay-1 goes down"), null,
    [{ op: "status", id: "relay-1", status: NS.OFFLINE }, { op: "setEdge", id: "node-a-relay-1", kind: EK.ERROR }, { op: "setEdge", id: "node-b-relay-1", kind: EK.ERROR }]);
  s.push(ET.DELIVERY_FAILED, "node-a", "relay-1", D("Доставка через relay-1 не удалась", "Delivery via relay-1 failed"), null,
    [{ op: "status", id: "node-a", status: NS.SEARCHING }]);
  s.push(ET.ROUTE_FOUND, "node-a", "relay-2", D("Переключение на резервный relay-2 (без нового lookup)", "Failover to backup relay-2 (no new lookup)"),
    D("route-record уже содержал relay-2. Отправитель берёт следующую запись reachableVia и переотправляет — новый запрос к discovery не нужен.",
      "The route-record already contained relay-2. The sender takes the next reachableVia entry and resends — no new discovery lookup is needed."),
    [{ op: "delEdge", id: "node-a-relay-1" }, { op: "delEdge", id: "node-b-relay-1" }, { op: "addEdge", id: "node-a-relay-2", from: "node-a", to: "relay-2", kind: EK.RELAY }, { op: "status", id: "node-a", status: NS.ONLINE }]);
  runMessage(s, { msgId: "msg-8", senderDevice: "device-a1", recipientDevice: "device-b1", path: ["device-a1", "node-a", "relay-2", "node-b", "device-b1"], mode: "backup route" });
  return s;
}

/* ─────────── Scenario 9: offline recipient → queued at node ─────────── */
function s9() {
  const s = scenario("offline-queue", "Получатель офлайн — очередь на ноде", "Offline recipient — queued at node");
  const boot = { id: "bootstrap-1", x: 140, y: 60 };
  const disc = { id: "discovery-1", x: 490, y: 60 };
  infra(s, { bootstrap: boot, discovery: disc });
  addNode(s, { id: "node-a", kind: "personal", ownerUserId: "user-a", networkMode: NET_MODE.PUBLIC, publicAddress: "node-a.ouo", x: 250, y: 300 });
  registerPublic(s, "node-a", { bootstrap: boot.id, discovery: disc.id });
  addNode(s, { id: "node-b", kind: "personal", ownerUserId: "user-b", networkMode: NET_MODE.PUBLIC, publicAddress: "node-b.ouo", x: 730, y: 300 });
  registerPublic(s, "node-b", { bootstrap: boot.id, discovery: disc.id });
  addUser(s, { id: "user-a", name: "Alice", publicId: "OUO-ALICE", homeNodeId: "node-a", x: 250, y: 490 });
  addDevice(s, { id: "device-a1", userId: "user-a", x: 250, y: 420 });
  connectUser(s, { userId: "user-a", deviceId: "device-a1", nodeId: "node-a", name: "Alice" });
  addUser(s, { id: "user-b", name: "Bob", publicId: "OUO-BOB", homeNodeId: "node-b", x: 730, y: 490 });
  // Устройство Bob офлайн, не подключено к node-b.
  s.push(ET.DEVICE_CREATED, "device-b1", null, D("Устройство Bob офлайн", "Bob's device is offline"), null,
    [{ op: "add", obj: { id: "device-b1", kind: "device", userId: "user-b", type: "mobile", network: "none", connectedNodeId: null, status: NS.OFFLINE, x: 730, y: 420 } }]);

  s.push(ET.MESSAGE_CREATED, "device-a1", "device-b1", D("Alice пишет Bob", "Alice messages Bob"), null, []);
  s.push(ET.MESSAGE_ENCRYPTED, "device-a1", null, D("Сообщение зашифровано (E2EE envelope)", "Message encrypted (E2EE envelope)"), null, []);
  s.push(ET.MESSAGE_SENT, "device-a1", "node-a", D("Envelope отправлен на node-a", "Envelope sent to node-a"), null,
    [{ op: "addEdge", id: "device-a1-node-a", from: "device-a1", to: "node-a", kind: EK.DELIVERED }, { op: "msg", msg: { id: "msg-9", edgeId: "device-a1-node-a", kind: "message", label: "queued delivery" } }]);
  s.push(ET.MESSAGE_RELAYED, "node-a", "node-b", D("Envelope доставлен на home-ноду Bob", "Envelope delivered to Bob's home node"), null,
    [{ op: "addEdge", id: "node-a-node-b", from: "node-a", to: "node-b", kind: EK.DELIVERED }, { op: "msg", msg: { id: "msg-9", edgeId: "node-a-node-b", kind: "message", label: "queued delivery" } }]);
  s.push(ET.MESSAGE_QUEUED, "node-b", null, D("Активного устройства нет — envelope в очереди на node-b", "No active device — envelope queued on node-b"),
    D("home-нода — постоянная точка присутствия. Она держит зашифрованный envelope во временной очереди, пока не подключится устройство. Открытого текста нода не видит.",
      "The home node is the persistent point of presence. It holds the encrypted envelope in a temporary queue until a device connects. The node never sees plaintext."),
    [{ op: "status", id: "node-b", status: NS.DELIVERING }, { op: "clearMsg" }]);
  s.push(ET.NODE_ONLINE, "device-b1", null, D("Устройство Bob выходит в сеть", "Bob's device comes online"), null,
    [{ op: "patch", id: "device-b1", props: { network: "wifi", connectedNodeId: "node-b" } }, { op: "status", id: "device-b1", status: NS.ONLINE },
     { op: "addEdge", id: "device-b1-node-b", from: "device-b1", to: "node-b", kind: EK.DIRECT }]);
  s.push(ET.MESSAGE_RECEIVED, "node-b", "device-b1", D("node-b доставляет envelope из очереди", "node-b delivers the queued envelope"), null,
    [{ op: "setEdge", id: "device-b1-node-b", kind: EK.DELIVERED }, { op: "addEdge", id: "node-b-device-b1", from: "node-b", to: "device-b1", kind: EK.DELIVERED },
     { op: "msg", msg: { id: "msg-9", edgeId: "node-b-device-b1", kind: "message", label: "queued delivery" } }, { op: "status", id: "node-b", status: NS.ONLINE }]);
  s.push(ET.MESSAGE_DECRYPTED, "device-b1", null, D("Bob расшифровал сообщение", "Bob decrypted the message"), null, [{ op: "clearMsg" }]);
  s.push(ET.ACK_SENT, "device-b1", "device-a1", D("Bob отправляет ACK", "Bob sends ACK"), null,
    [{ op: "msg", msg: { id: "msg-9-ack", edgeId: "node-b-device-b1", kind: "ack", label: "ACK" } }]);
  s.push(ET.ACK_RECEIVED, "device-a1", null, D("ACK получен — доставка подтверждена", "ACK received — delivery confirmed"), null, [{ op: "clearMsg" }]);
  return s;
}

export const SCENARIOS = [s1(), s2(), s3(), s4(), s5(), s6(), s7(), s8(), s9()];
