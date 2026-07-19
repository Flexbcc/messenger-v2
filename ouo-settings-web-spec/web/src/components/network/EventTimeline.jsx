import React, { useEffect, useRef } from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { formatTime } from "../../sim/engine.js";

/**
 * Журнал событий (раздел 1.3 ТЗ). Каждое событие кликабельно —
 * клик перематывает состояние сети на момент этого события.
 */
export function EventTimeline({ events, cursor, onJump }) {
  const { lang, t } = useI18n();
  const listRef = useRef(null);

  useEffect(() => {
    const el = listRef.current?.querySelector(".ev.current");
    el?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  return (
    <div className="net-timeline">
      <div className="net-timeline-head">
        <span>{t("net.timeline")}</span>
        <span className="muted">{cursor + 1} {t("net.of")} {events.length}</span>
      </div>
      <ol ref={listRef} className="net-events">
        {events.map((ev, i) => (
          <li key={ev.id}
            className={`ev${i === cursor ? " current" : ""}${i > cursor ? " future" : ""}`}
            onClick={() => onJump(i)}>
            <time>{formatTime(ev.time)}</time>
            <code className="ev-type">{ev.type}</code>
            <span className="ev-desc">{ev.desc ? (ev.desc[lang] ?? ev.desc.ru) : ""}</span>
            {ev.why && <span className="ev-why" title={t("net.why")}>ⓘ</span>}
          </li>
        ))}
      </ol>
    </div>
  );
}
