// SimulationEngine — воспроизводимое сворачивание событий в состояние мира.
// Состояние на момент события i получается фолдингом events[0..i] поверх
// пустого мира. Одинаковый сценарий → одинаковая последовательность.
//
// Событие несёт человекочитаемое описание (desc), пояснение (why) и список
// мутаций (mut), которые reducer применяет к состоянию.

function emptyState() {
  return { objects: {}, edges: [], message: null };
}

function findEdge(state, id) {
  return state.edges.find((e) => e.id === id);
}

function applyMutation(state, m) {
  switch (m.op) {
    case "add":
      state.objects[m.obj.id] = { ...m.obj };
      break;
    case "status":
      if (state.objects[m.id]) state.objects[m.id] = { ...state.objects[m.id], status: m.status };
      break;
    case "patch":
      if (state.objects[m.id]) state.objects[m.id] = { ...state.objects[m.id], ...m.props };
      break;
    case "move":
      if (state.objects[m.id]) state.objects[m.id] = { ...state.objects[m.id], x: m.x, y: m.y };
      break;
    case "remove": {
      const next = { ...state.objects };
      delete next[m.id];
      state.objects = next;
      state.edges = state.edges.filter((e) => e.from !== m.id && e.to !== m.id);
      break;
    }
    case "addEdge": {
      const existing = findEdge(state, m.id);
      if (existing) Object.assign(existing, { from: m.from, to: m.to, kind: m.kind, status: m.status || "active" });
      else state.edges.push({ id: m.id, from: m.from, to: m.to, kind: m.kind, status: m.status || "active" });
      break;
    }
    case "setEdge": {
      const e = findEdge(state, m.id);
      if (e) {
        if (m.kind != null) e.kind = m.kind;
        if (m.status != null) e.status = m.status;
      }
      break;
    }
    case "delEdge":
      state.edges = state.edges.filter((e) => e.id !== m.id);
      break;
    case "msg":
      state.message = { ...m.msg };
      break;
    case "clearMsg":
      state.message = null;
      break;
    default:
      break;
  }
}

// Экспортируется, чтобы Live Mode переиспользовал ту же модель мутаций
// (общие сущности и события для пошагового и живого режимов).
export function applyEvent(state, ev) {
  for (const m of ev.mut || []) applyMutation(state, m);
}
export { applyMutation };

/**
 * Возвращает снимок мира после применения events[0..upto] (включительно).
 * upto = -1 → пустой мир.
 */
export function buildState(events, upto) {
  const state = emptyState();
  const end = Math.min(upto, events.length - 1);
  for (let i = 0; i <= end; i += 1) {
    // Клонируем edges массив, чтобы мутации setEdge не текли между снимками.
    state.edges = state.edges.map((e) => ({ ...e }));
    applyEvent(state, events[i]);
  }
  return state;
}

/** Форматирует время события в mm:ss. */
export function formatTime(sec) {
  const m = String(Math.floor(sec / 60)).padStart(2, "0");
  const s = String(sec % 60).padStart(2, "0");
  return `${m}:${s}`;
}
