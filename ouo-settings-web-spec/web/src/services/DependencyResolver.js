// DependencyResolver
// Оценивает условия visible_if (equals / in) и строит карту видимости настроек.
//
// Правила (см. SETTINGS-SPEC.md):
//  1. Скрытая настройка НЕ удаляется автоматически из состояния.
//  2. При отключении родителя интерфейс скрывает дочерние поля.
//  3. Сброс дочерних значений выполняется только по явному правилу reset_when_hidden.

/**
 * Проверяет одно условие visible_if относительно текущих значений.
 * Поддерживает две формы:
 *   { setting, equals: <value> }
 *   { setting, in: [<value>, ...] }
 */
export function conditionMatches(condition, values) {
  if (!condition) return true;

  const actual = values[condition.setting];

  if (Object.prototype.hasOwnProperty.call(condition, "equals")) {
    return actual === condition.equals;
  }

  if (Object.prototype.hasOwnProperty.call(condition, "in")) {
    return Array.isArray(condition.in) && condition.in.includes(actual);
  }

  // Неизвестная форма условия — по умолчанию показываем.
  return true;
}

/**
 * Видима ли настройка при текущих значениях.
 * Учитывает цепочку зависимостей: если родитель сам скрыт,
 * дочерняя настройка тоже считается скрытой.
 */
export function isVisible(setting, values, index) {
  const cond = setting.visible_if;
  if (!cond) return true;

  if (!conditionMatches(cond, values)) return false;

  // Каскад: родитель условия должен быть видим сам.
  if (index) {
    const parent = index[cond.setting];
    if (parent && !isVisible(parent, values, index)) return false;
  }

  return true;
}

/**
 * Строит индекс id -> setting по всей спецификации.
 */
export function buildIndex(spec) {
  const index = {};
  for (const section of spec.sections) {
    for (const setting of section.settings) {
      index[setting.id] = setting;
    }
  }
  return index;
}

/**
 * Возвращает карту { id: boolean } видимости всех настроек.
 */
export function computeVisibility(spec, values, index = buildIndex(spec)) {
  const map = {};
  for (const section of spec.sections) {
    for (const setting of section.settings) {
      map[setting.id] = isVisible(setting, values, index);
    }
  }
  return map;
}

/**
 * Применяет reset_when_hidden: если настройка стала скрытой и в её спеке
 * указан флаг reset_when_hidden, значение сбрасывается к default.
 * Ничего не удаляет — только опционально сбрасывает по явному правилу.
 * Возвращает НОВЫЙ объект значений (или исходный, если изменений нет).
 */
export function applyResetWhenHidden(spec, values, index = buildIndex(spec)) {
  let next = values;
  for (const section of spec.sections) {
    for (const setting of section.settings) {
      if (!setting.reset_when_hidden) continue;
      const visible = isVisible(setting, values, index);
      if (!visible && "default" in setting && next[setting.id] !== setting.default) {
        if (next === values) next = { ...values };
        next[setting.id] = setting.default;
      }
    }
  }
  return next;
}
