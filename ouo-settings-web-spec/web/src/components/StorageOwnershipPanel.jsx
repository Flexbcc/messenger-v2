import React from "react";
import { STORAGE_FACTS } from "../services/systemState.js";
import { useI18n } from "../i18n/I18nContext.jsx";

/**
 * Раздел «Хранение и владение данными» (требование 13).
 * Показывает фактическое состояние данных: физическое размещение,
 * зашифрованные копии, устройства с ключами, ноды, TTL, реплики,
 * последнюю синхронизацию и бэкап. Разделяет хранение и доступ.
 */
export function StorageOwnershipPanel({ values }) {
  const { t, tenum } = useI18n();
  const f = STORAGE_FACTS;
  const messageLocation = values["storage.message_location"];
  const mediaLocation = values["storage.media_location"];
  const keyLocation = values["storage.key_location"];
  const replicas = values["storage.replication_factor"] ?? f.replicas;
  const ttl = values["storage.media_ttl_enabled"]
    ? tenum(values["storage.media_ttl"])
    : t("own.noTtl");

  return (
    <div className="ownership-panel">
      <div className="ownership-note">{t("own.note")}</div>

      <div className="ownership-grid">
        <div className="fact-card">
          <h4>{t("own.physical")}</h4>
          <ul className="fact-list">
            <li><span>{t("own.messages")}</span><b>{tenum(messageLocation)}</b></li>
            <li><span>{t("own.mediaLabel")}</span><b>{tenum(mediaLocation)}</b></li>
            <li><span>{t("own.keys")}</span><b>{tenum(keyLocation)}</b></li>
          </ul>
        </div>

        <div className="fact-card">
          <h4>{t("own.copies")}</h4>
          <ul className="fact-list">
            <li><span>{t("own.encCopies")}</span><b>{f.encrypted_copies ? t("own.yes") : t("own.no")}</b></li>
            <li><span>{t("own.replicas")}</span><b>{replicas}</b></li>
            <li><span>{t("own.ttl")}</span><b>{ttl}</b></li>
            <li><span>{t("own.lastSync")}</span><b>{f.last_sync}</b></li>
            <li><span>{t("own.lastBackup")}</span><b>{f.last_backup}</b></li>
          </ul>
        </div>

        <div className="fact-card">
          <h4>{t("own.devicesKeys")}</h4>
          <ul className="entity-list">
            {f.devices_with_keys.map((d) => (
              <li key={d.id}>
                <strong>{d.name}</strong>
                <small>{d.platform}{d.has_keys ? ` · ${t("own.hasKeys")}` : ""}</small>
              </li>
            ))}
          </ul>
        </div>

        <div className="fact-card">
          <h4>{t("own.storageNodes")}</h4>
          <ul className="entity-list">
            {f.storage_nodes.map((n) => (
              <li key={n.id}>
                <strong>{n.address}</strong>
                <small>{n.region}{n.encrypted_only ? ` · ${t("own.encOnly")}` : ""}</small>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}
