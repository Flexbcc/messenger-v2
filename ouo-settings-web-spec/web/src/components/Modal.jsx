import React, { useEffect } from "react";
import { useI18n } from "../i18n/I18nContext.jsx";

/** Базовое модальное окно. Закрывается по Esc и по клику на подложку. */
export function Modal({ title, onClose, children, footer, wide, danger }) {
  useEffect(() => {
    function onKey(e) {
      if (e.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div
        className={`modal${wide ? " wide" : ""}${danger ? " danger" : ""}`}
        onMouseDown={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
      >
        <header className="modal-head">
          <h3>{title}</h3>
          <button className="icon-btn" onClick={onClose} aria-label="Закрыть">
            ✕
          </button>
        </header>
        <div className="modal-body">{children}</div>
        {footer && <footer className="modal-foot">{footer}</footer>}
      </div>
    </div>
  );
}

/** Диалог подтверждения для действий (requires_confirmation / danger). */
export function ConfirmDialog({ title, message, danger, confirmLabel, onConfirm, onCancel }) {
  const { t } = useI18n();
  return (
    <Modal title={title} onClose={onCancel} danger={danger}>
      <p className="confirm-message">{message}</p>
      {danger && <p className="confirm-warning">{t("modal.dangerWarn")}</p>}
      <footer className="modal-foot">
        <button className="btn ghost" onClick={onCancel}>
          {t("modal.cancel")}
        </button>
        <button className={`btn ${danger ? "danger" : "primary"}`} onClick={onConfirm}>
          {confirmLabel || t("modal.confirm")}
        </button>
      </footer>
    </Modal>
  );
}
