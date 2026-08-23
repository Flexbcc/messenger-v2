"""
Discovery Node storage.

Role per spec/0604_DISCOVERY_NODE.md: resolve UserID -> Home Node address
and publish node Capability. Control Plane trust lifecycle — ADR-0009.
Does not touch message content, does not participate in delivery.
"""
import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.environ.get("DISCOVERY_DB_PATH", "discovery.db")


def _add_column_if_missing(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
    except sqlite3.OperationalError:
        pass


def init_db():
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_records (
                user_id TEXT PRIMARY KEY,
                home_node_url TEXT NOT NULL,
                display_name TEXT,
                auth_public_key TEXT NOT NULL,
                cluster_id TEXT NOT NULL DEFAULT 'default',
                updated_at TEXT NOT NULL
            )
            """
        )
        _add_column_if_missing(conn, "user_records", "cluster_id", "TEXT NOT NULL DEFAULT 'default'")
        _add_column_if_missing(conn, "user_records", "login", "TEXT")
        _add_column_if_missing(conn, "user_records", "username_search_enabled", "INTEGER NOT NULL DEFAULT 1")
        # Post-R5 minimal "home changed" notify path (R4-routing.md gap):
        # track when home_node_url actually moved so peers/homes can detect
        # it via Discovery response instead of a full CONTROL notify.
        _add_column_if_missing(conn, "user_records", "home_updated_at", "TEXT")
        _add_column_if_missing(conn, "user_records", "previous_home_node_url", "TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_records_login ON user_records(login)"
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS bootstrap_records (
                user_id TEXT PRIMARY KEY,
                identity_version INTEGER NOT NULL,
                record_version INTEGER NOT NULL,
                record_json TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS route_descriptors (
                user_id TEXT NOT NULL,
                identity_version INTEGER NOT NULL,
                route_epoch INTEGER NOT NULL,
                descriptor_hash TEXT NOT NULL UNIQUE,
                descriptor_json TEXT NOT NULL,
                valid_from TEXT NOT NULL,
                valid_until TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                PRIMARY KEY (user_id, route_epoch)
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_route_descriptors_user_epoch
               ON route_descriptors(user_id, route_epoch DESC)"""
        )

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS node_capabilities (
                node_id TEXT PRIMARY KEY,
                node_url TEXT NOT NULL,
                capabilities TEXT NOT NULL,
                software_version TEXT NOT NULL DEFAULT 'unknown',
                last_heartbeat TEXT NOT NULL,
                cluster_id TEXT NOT NULL DEFAULT 'default',
                trust_status TEXT NOT NULL DEFAULT 'unknown',
                node_token_hash TEXT,
                enrollment_secret_hash TEXT,
                token_issued_at TEXT,
                token_claimed_at TEXT,
                approved_at TEXT,
                approved_by TEXT,
                suspended_at TEXT,
                suspension_reason TEXT,
                registered_at TEXT
            )
            """
        )
        _add_column_if_missing(conn, "node_capabilities", "cluster_id", "TEXT NOT NULL DEFAULT 'default'")
        for col, defn in (
            ("trust_status", "TEXT NOT NULL DEFAULT 'unknown'"),
            ("node_token_hash", "TEXT"),
            ("enrollment_secret_hash", "TEXT"),
            ("token_issued_at", "TEXT"),
            ("token_claimed_at", "TEXT"),
            ("approved_at", "TEXT"),
            ("approved_by", "TEXT"),
            ("suspended_at", "TEXT"),
            ("suspension_reason", "TEXT"),
            ("registered_at", "TEXT"),
            ("build_hash", "TEXT"),
            ("tls_cert_fingerprint", "TEXT"),
            ("release_signature", "TEXT"),
            ("attestation_status", "TEXT NOT NULL DEFAULT 'skipped'"),
            ("attestation_detail", "TEXT"),
            ("signing_public_key", "TEXT"),
            ("identity_node_id", "TEXT"),
            ("operational_certificate", "TEXT"),
            ("node_identity_status", "TEXT NOT NULL DEFAULT 'absent'"),
            ("node_identity_detail", "TEXT"),
            ("node_advertisement", "TEXT"),
            ("node_advertisement_status", "TEXT NOT NULL DEFAULT 'absent'"),
            ("node_advertisement_detail", "TEXT"),
            ("node_advertisement_epoch", "INTEGER"),
            ("advertised_endpoints", "TEXT"),
            ("advertised_transports", "TEXT"),
            ("advertised_protocols", "TEXT"),
            ("capability_certificate", "TEXT"),
            ("capability_certificate_status", "TEXT NOT NULL DEFAULT 'absent'"),
            ("capability_certificate_detail", "TEXT"),
            ("certified_capabilities", "TEXT"),
            ("certified_level", "INTEGER"),
            ("capability_epoch", "INTEGER"),
            ("transport_certificate", "TEXT"),
            ("transport_certificate_status", "TEXT NOT NULL DEFAULT 'absent'"),
            ("transport_certificate_detail", "TEXT"),
            # Active health-check (Node Monitor)
            ("health_status", "TEXT"),
            ("last_health_check", "TEXT"),
            # Vulnerability response / version quarantine
            ("version_status", "TEXT NOT NULL DEFAULT 'ok'"),
            ("quarantine_action", "TEXT NOT NULL DEFAULT 'off'"),
        ):
            _add_column_if_missing(conn, "node_capabilities", col, defn)

        # Trust level columns (0=local-only, 1=relay-eligible, 2=hub)
        for col, defn in (
            ("trust_level", "INTEGER NOT NULL DEFAULT 0"),
            ("trust_level_updated_at", "TEXT"),
            # Runtime metrics — updated on every heartbeat
            ("cpu_load_1m", "REAL"),
            ("cpu_cores", "INTEGER"),
            ("cpu_percent_est", "INTEGER"),
            ("ram_total_bytes", "INTEGER"),
            ("ram_used_bytes", "INTEGER"),
            ("ram_percent", "INTEGER"),
            ("disk_used_bytes", "INTEGER"),
            ("disk_total_bytes", "INTEGER"),
            ("disk_percent", "INTEGER"),
            ("uptime_sec", "INTEGER"),
            ("ws_connections", "INTEGER"),
            # Message/call counters (rolling 24h, reported by node)
            ("messages_24h", "INTEGER"),
            ("calls_24h", "INTEGER"),
            ("error_rate_pct", "REAL"),
            ("messages_total", "INTEGER NOT NULL DEFAULT 0"),
            # Network speed (ms RTT measured by discovery health-check)
            ("latency_ms", "INTEGER"),
        ):
            _add_column_if_missing(conn, "node_capabilities", col, defn)

        # Promotion history table
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_level_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL,
                from_level INTEGER NOT NULL,
                to_level INTEGER NOT NULL,
                reason TEXT,
                actor TEXT NOT NULL DEFAULT 'operator',
                changed_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tlh_node ON trust_level_history(node_id)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_degradation_candidates (
                subject_node_id TEXT PRIMARY KEY,
                legacy_node_id TEXT NOT NULL,
                previous_level INTEGER NOT NULL,
                proposed_level INTEGER NOT NULL,
                last_heartbeat TEXT NOT NULL,
                offline_seconds INTEGER NOT NULL,
                evidence_commitment TEXT NOT NULL,
                observed_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_record_proposals (
                record_id TEXT PRIMARY KEY,
                subject_node_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                action TEXT NOT NULL,
                metrics_commitment TEXT NOT NULL,
                proposal_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(subject_node_id, epoch)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_record_votes (
                record_id TEXT NOT NULL,
                validator_id TEXT NOT NULL,
                signature TEXT NOT NULL,
                received_at TEXT NOT NULL,
                PRIMARY KEY(record_id, validator_id),
                FOREIGN KEY(record_id) REFERENCES trust_record_proposals(record_id)
            )
            """
        )

        # Vulnerability response: blocked (vulnerable) software versions.
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS blocked_versions (
                version TEXT PRIMARY KEY,
                reason TEXT,
                blocked_at TEXT NOT NULL
            )
            """
        )
        # Network-level policy KV (quarantine_mode, force_upgrade, ...).
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS discovery_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_node_trust_status ON node_capabilities(trust_status)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_observations (
                observation_id TEXT PRIMARY KEY,
                observer_node_id TEXT NOT NULL,
                subject_node_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                challenge_type TEXT NOT NULL,
                challenge_commitment TEXT NOT NULL,
                result TEXT NOT NULL,
                latency_bucket TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                observation_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                UNIQUE(observer_node_id, challenge_commitment)
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_trust_observations_subject ON trust_observations(subject_node_id, epoch)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS trust_observation_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                observation_id TEXT NOT NULL UNIQUE,
                assignment_id TEXT NOT NULL,
                observer_node_id TEXT NOT NULL,
                observation_hash TEXT NOT NULL UNIQUE,
                observation_json TEXT NOT NULL,
                operational_certificate_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                UNIQUE(assignment_id, observer_node_id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS challenge_assignments (
                assignment_id TEXT PRIMARY KEY,
                subject_node_id TEXT NOT NULL,
                challenge_type TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                not_before TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                assignment_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                UNIQUE(subject_node_id, challenge_type, epoch)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS challenge_assignment_proposals (
                assignment_id TEXT PRIMARY KEY,
                subject_node_id TEXT NOT NULL,
                challenge_type TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                proposal_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(subject_node_id, challenge_type, epoch)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS randomness_checkpoints (
                challenge_epoch INTEGER PRIMARY KEY,
                authority_epoch INTEGER NOT NULL,
                checkpoint_hash TEXT NOT NULL UNIQUE,
                previous_hash TEXT NOT NULL,
                checkpoint_json TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operational_credential_states (
                node_id TEXT NOT NULL,
                credential_epoch INTEGER NOT NULL,
                state_hash TEXT NOT NULL UNIQUE,
                previous_state_hash TEXT NOT NULL,
                certificate_serial TEXT NOT NULL,
                certificate_issued_at TEXT NOT NULL,
                state_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                PRIMARY KEY (node_id, credential_epoch),
                UNIQUE (node_id, certificate_serial)
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_operational_credential_head
               ON operational_credential_states(node_id, credential_epoch DESC)"""
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operational_credential_state_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                state_hash TEXT NOT NULL UNIQUE,
                FOREIGN KEY (state_hash) REFERENCES operational_credential_states(state_hash)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operational_credential_revocations (
                node_id TEXT NOT NULL,
                revocation_epoch INTEGER NOT NULL,
                revocation_hash TEXT NOT NULL UNIQUE,
                previous_hash TEXT NOT NULL,
                credential_epoch INTEGER NOT NULL,
                certificate_serial TEXT NOT NULL,
                certificate_hash TEXT NOT NULL,
                operational_public_key TEXT NOT NULL,
                authority_epoch INTEGER NOT NULL,
                effective_at TEXT NOT NULL,
                revocation_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                PRIMARY KEY (node_id, revocation_epoch),
                UNIQUE (node_id, certificate_serial)
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_operational_credential_revoked_serial
               ON operational_credential_revocations(node_id, certificate_serial)"""
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operational_credential_revocation_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                revocation_hash TEXT NOT NULL UNIQUE,
                FOREIGN KEY (revocation_hash)
                    REFERENCES operational_credential_revocations(revocation_hash)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS operational_credential_revocation_conflicts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL,
                revocation_epoch INTEGER NOT NULL,
                existing_hash TEXT NOT NULL,
                conflicting_hash TEXT NOT NULL,
                conflicting_json TEXT NOT NULL,
                detected_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS challenge_assignment_observers (
                assignment_id TEXT NOT NULL,
                observer_node_id TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                ack_json TEXT,
                acknowledged_at TEXT,
                completed_observation_id TEXT,
                completed_at TEXT,
                PRIMARY KEY (assignment_id, observer_node_id),
                FOREIGN KEY (assignment_id) REFERENCES challenge_assignments(assignment_id)
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_challenge_assignment_observer_state
               ON challenge_assignment_observers(observer_node_id, state)"""
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS observer_request_nonces (
                request_nonce TEXT PRIMARY KEY,
                observer_node_id TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                consumed_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS challenge_assignment_ack_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                assignment_id TEXT NOT NULL,
                observer_node_id TEXT NOT NULL,
                ack_hash TEXT NOT NULL UNIQUE,
                ack_json TEXT NOT NULL,
                operational_certificate_json TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                UNIQUE(assignment_id, observer_node_id),
                FOREIGN KEY (assignment_id) REFERENCES challenge_assignments(assignment_id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS authority_checkpoints (
                authority_epoch INTEGER PRIMARY KEY,
                checkpoint_hash TEXT NOT NULL UNIQUE,
                previous_hash TEXT NOT NULL,
                checkpoint_json TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS authority_checkpoint_announcements (
                announcement_id TEXT PRIMARY KEY,
                source_node_id TEXT NOT NULL,
                authority_epoch INTEGER NOT NULL,
                checkpoint_hash TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                announcement_json TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_authority_announcement_source_epoch
               ON authority_checkpoint_announcements(source_node_id, authority_epoch)"""
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS node_advertisement_observations (
                observation_id TEXT NOT NULL UNIQUE,
                source_node_id TEXT NOT NULL,
                subject_node_id TEXT NOT NULL,
                advertisement_epoch INTEGER NOT NULL,
                advertisement_hash TEXT NOT NULL,
                advertisement_json TEXT NOT NULL,
                capability_certificate_json TEXT NOT NULL,
                observation_json TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                stored_at TEXT NOT NULL,
                PRIMARY KEY (source_node_id, subject_node_id, advertisement_epoch)
            )
            """
        )
        conn.execute(
            """CREATE INDEX IF NOT EXISTS idx_node_advertisement_observation_subject
               ON node_advertisement_observations(subject_node_id, advertisement_epoch DESC)"""
        )
        _add_column_if_missing(
            conn,
            "node_advertisement_observations",
            "transport_certificate_json",
            "TEXT",
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS capability_certificate_heads (
                subject_node_id TEXT PRIMARY KEY,
                capability_epoch INTEGER NOT NULL,
                certificate_hash TEXT NOT NULL UNIQUE,
                certificate_json TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS capability_certificate_conflicts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                subject_node_id TEXT NOT NULL,
                capability_epoch INTEGER NOT NULL,
                existing_hash TEXT NOT NULL,
                conflicting_hash TEXT NOT NULL,
                conflicting_json TEXT NOT NULL,
                detected_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS authority_recoveries (
                authority_epoch INTEGER PRIMARY KEY,
                recovery_hash TEXT NOT NULL UNIQUE,
                replacement_checkpoint_hash TEXT NOT NULL UNIQUE,
                compromised_authority_epoch INTEGER NOT NULL,
                recovery_json TEXT NOT NULL,
                replacement_checkpoint_json TEXT NOT NULL,
                stored_at TEXT NOT NULL
            )
            """
        )
        # Seed policy defaults from env (idempotent — INSERT OR IGNORE).
        from app.policy import _seed_settings
        _seed_settings(conn)
        from app.config import ENROLLMENT_MODE
        from app.audit import ensure_audit_table
        ensure_audit_table(conn)
        # Grandfather only in legacy — strict/hybrid keep pending until operator approve.
        if ENROLLMENT_MODE == "legacy":
            conn.execute(
                """
                UPDATE node_capabilities
                SET trust_status = 'trusted',
                    registered_at = COALESCE(registered_at, last_heartbeat)
                WHERE trust_status = 'unknown' OR trust_status IS NULL OR trust_status = ''
                """
            )
        else:
            conn.execute(
                """
                UPDATE node_capabilities
                SET registered_at = COALESCE(registered_at, last_heartbeat)
                WHERE registered_at IS NULL OR registered_at = ''
                """
            )
        conn.commit()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()
