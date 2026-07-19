import React from "react";
import { useI18n } from "../i18n/I18nContext.jsx";

// Небольшая горизонтальная/вертикальная схема из подписанных узлов со стрелками.
function Chain({ nodes, vertical }) {
  return (
    <div className={`chain${vertical ? " vertical" : ""}`}>
      {nodes.map((n, i) => (
        <React.Fragment key={i}>
          <div className={`chain-node${n.accent ? " accent" : ""}`}>{n.label}</div>
          {i < nodes.length - 1 && <div className="chain-arrow">{vertical ? "↓" : "→"}</div>}
        </React.Fragment>
      ))}
    </div>
  );
}

/**
 * Схемы, реагирующие на текущее состояние настроек.
 * kind: route | replication | pin | notif | qr | backup | crypto
 */
export function FlowDiagram({ kind, values = {} }) {
  const { lang } = useI18n();
  const L = (ru, en) => (lang === "en" ? en : ru);

  if (kind === "route") {
    const loc = values["storage.message_location"] || "device_only";
    const nodes = [{ label: L("Сообщение", "Message"), accent: true }, { label: L("Ваше устройство", "Your device") }];
    if (loc !== "device_only") nodes.push({ label: L("Личная нода", "Personal node") });
    if (loc === "replicated_nodes") nodes.push({ label: L("Реплики нод", "Node replicas") });
    if (values["storage.media_location"] === "personal_node_s3") nodes.push({ label: "S3" });
    nodes.push({ label: L("Получатель", "Recipient"), accent: true });
    nodes.push({ label: L("Локальный кэш", "Local cache") });
    return <Chain nodes={nodes} />;
  }

  if (kind === "replication") {
    const factor = Number(values["storage.replication_factor"] ?? 1);
    const letters = ["A", "B", "C", "D", "E"].slice(0, Math.max(1, Math.min(5, factor)));
    return (
      <div className="replication">
        <div className="chain-node accent">{L("Клиент", "Client")}</div>
        <div className="chain-arrow">↓</div>
        <div className="replica-row">
          {letters.map((l) => <div className="chain-node" key={l}>Node {l}</div>)}
        </div>
      </div>
    );
  }

  if (kind === "crypto") {
    return <Chain vertical nodes={[
      { label: "plaintext", accent: true },
      { label: L("сжатие", "compression") },
      { label: "AES-256" },
      { label: "Double Ratchet" },
      { label: L("пакет", "packet") },
      { label: "relay" },
      { label: L("получатель", "recipient") },
      { label: L("расшифровка", "decrypt") },
      { label: "plaintext", accent: true }
    ]} />;
  }

  if (kind === "pin") {
    return <Chain nodes={[
      { label: "PIN", accent: true },
      { label: "Secure Enclave" },
      { label: L("проверка", "verify") },
      { label: L("доступ", "access"), accent: true }
    ]} />;
  }

  if (kind === "notif") {
    return <Chain nodes={[
      { label: L("Сообщение", "Message"), accent: true },
      { label: L("Нода", "Node") },
      { label: "push" },
      { label: L("Клиент", "Client") },
      { label: L("Баннер", "Banner"), accent: true }
    ]} />;
  }

  if (kind === "qr") {
    return <Chain nodes={[
      { label: "QR", accent: true },
      { label: "Discovery" },
      { label: L("ключи", "keys") },
      { label: L("контакт", "contact"), accent: true }
    ]} />;
  }

  if (kind === "backup") {
    return <Chain nodes={[
      { label: L("Данные", "Data"), accent: true },
      { label: "AES" },
      { label: L("Копия", "Backup") },
      { label: "S3" }
    ]} />;
  }

  return null;
}
