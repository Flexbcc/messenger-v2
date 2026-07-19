import React, { useState } from "react";
import { Modal } from "./Modal.jsx";
import { useI18n } from "../i18n/I18nContext.jsx";
import {
  schemaForItemType,
  newItem,
  itemTitle,
  itemSubtitle
} from "../services/itemSchemas.js";

/**
 * Универсальный редактор одного элемента списка.
 * Форма строится из ITEM_SCHEMAS по item_type (user/chat/device/node/
 * time_range/user_or_chat).
 */
function ItemForm({ itemType, draft, setDraft }) {
  const { lang } = useI18n();
  const schema = schemaForItemType(itemType);
  if (!schema) return <p>{itemType}</p>;

  function set(key, value) {
    setDraft({ ...draft, [key]: value });
  }

  return (
    <div className="item-form">
      {schema.fields.map((f) => {
        const value = draft[f.key];
        return (
          <label className="field" key={f.key}>
            <span className="field-label">
              {f.label[lang] ?? f.label.ru}
              {f.required && <em className="req">*</em>}
            </span>

            {f.type === "text" && (
              <input
                type="text"
                value={value ?? ""}
                onChange={(e) => set(f.key, e.target.value)}
              />
            )}

            {f.type === "time" && (
              <input
                type="time"
                value={value ?? ""}
                onChange={(e) => set(f.key, e.target.value)}
              />
            )}

            {f.type === "boolean" && (
              <input
                type="checkbox"
                checked={Boolean(value)}
                onChange={(e) => set(f.key, e.target.checked)}
              />
            )}

            {f.type === "select" && (
              <select value={value ?? ""} onChange={(e) => set(f.key, e.target.value)}>
                <option value="">—</option>
                {f.options.map((o) => (
                  <option key={o} value={o}>
                    {o}
                  </option>
                ))}
              </select>
            )}

            {f.type === "multiselect" && (
              <div className="chips">
                {f.options.map((o) => {
                  const arr = Array.isArray(value) ? value : [];
                  const active = arr.includes(o);
                  return (
                    <button
                      type="button"
                      key={o}
                      className={active ? "chip active" : "chip"}
                      onClick={() =>
                        set(
                          f.key,
                          active ? arr.filter((x) => x !== o) : [...arr, o]
                        )
                      }
                    >
                      {o}
                    </button>
                  );
                })}
              </div>
            )}
          </label>
        );
      })}
    </div>
  );
}

function itemIsValid(itemType, draft) {
  const schema = schemaForItemType(itemType);
  if (!schema) return false;
  return schema.fields.every((f) => {
    if (!f.required) return true;
    const v = draft[f.key];
    return v !== undefined && v !== null && String(v).length > 0;
  });
}

/**
 * Модальный редактор всего списка: добавление / редактирование / удаление
 * элементов. Один компонент обслуживает все item_type через ITEM_SCHEMAS.
 */
export function ListEditorModal({ setting, value, onSave, onClose }) {
  const { lang, t, tset } = useI18n();
  const itemType = setting.item_type;
  const schema = schemaForItemType(itemType);
  const itemLabel = schema ? (schema.label[lang] ?? schema.label.ru) : itemType;
  const [items, setItems] = useState(Array.isArray(value) ? value.map((x) => ({ ...x })) : []);
  const [editing, setEditing] = useState(null); // { index, draft } | null

  function startAdd() {
    setEditing({ index: -1, draft: newItem(itemType) });
  }
  function startEdit(index) {
    setEditing({ index, draft: { ...items[index] } });
  }
  function commitEdit() {
    if (!itemIsValid(itemType, editing.draft)) return;
    if (editing.index === -1) {
      setItems([...items, editing.draft]);
    } else {
      const next = items.slice();
      next[editing.index] = editing.draft;
      setItems(next);
    }
    setEditing(null);
  }
  function removeItem(index) {
    setItems(items.filter((_, i) => i !== index));
  }

  const maxItems = setting.data?.maxItems;
  const atMax = maxItems != null && items.length >= maxItems;

  const footer = (
    <>
      <span className="muted">
        {items.length}
        {maxItems != null ? ` / ${maxItems}` : ""} {t("control.items")}
      </span>
      <div className="spacer" />
      <button className="btn ghost" onClick={onClose}>
        {t("modal.cancel")}
      </button>
      <button className="btn primary" onClick={() => onSave(items)}>
        {t("modal.saveList")}
      </button>
    </>
  );

  return (
    <Modal
      title={`${tset(setting.id)} · ${itemLabel}`}
      onClose={onClose}
      footer={footer}
      wide
    >
      {editing ? (
        <div>
          <h4 className="sub">
            {editing.index === -1 ? t("modal.newItem") : t("modal.editItem")}
          </h4>
          <ItemForm
            itemType={itemType}
            draft={editing.draft}
            setDraft={(d) => setEditing({ ...editing, draft: d })}
          />
          <div className="row-end">
            <button className="btn ghost" onClick={() => setEditing(null)}>
              {t("modal.back")}
            </button>
            <button
              className="btn primary"
              disabled={!itemIsValid(itemType, editing.draft)}
              onClick={commitEdit}
            >
              {editing.index === -1 ? t("modal.add") : t("modal.save")}
            </button>
          </div>
        </div>
      ) : (
        <div>
          <div className="row-end">
            <button className="btn primary" disabled={atMax} onClick={startAdd}>
              + {t("modal.add")} · {itemLabel}
            </button>
          </div>
          {items.length === 0 ? (
            <p className="muted empty-list">{t("modal.emptyList")}</p>
          ) : (
            <ul className="item-list">
              {items.map((item, index) => (
                <li key={item.id || index} className="item-row">
                  <div className="item-main">
                    <strong>{itemTitle(itemType, item)}</strong>
                    <small>{itemSubtitle(itemType, item)}</small>
                  </div>
                  <div className="item-actions">
                    <button className="btn ghost sm" onClick={() => startEdit(index)}>
                      {t("modal.edit")}
                    </button>
                    <button className="btn danger sm" onClick={() => removeItem(index)}>
                      {t("modal.remove")}
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Modal>
  );
}
