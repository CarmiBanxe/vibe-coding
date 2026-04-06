-- decision_events.sql — G-01 Decision Event Log migration
--
-- Создаёт append-only таблицу compliance-решений в PostgreSQL.
-- Enforces I-24 (no UPDATE/DELETE) at the database level.
--
-- Run:
--   psql postgresql://banxe:banxe_secure_2026@127.0.0.1:5432/banxe_compliance \
--        -f decision_events.sql
--
-- Or via deploy script: bash scripts/deploy-decision-event-log.sh
--
-- Invariant I-24: Decision Event Log = append-only, без UPDATE/DELETE
-- Authority: DORA Art. 14(2), FCA MLR 2017 record-keeping (5-year TTL)
-- ---------------------------------------------------------------------------

-- NOTE: banxe_app_role must be created before running this script.
-- Run as postgres superuser (one-time): see scripts/deploy-decision-event-log.sh
-- The role creation requires CREATEROLE privilege (superuser only in most setups).

BEGIN;

-- ── Schema ──────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS banxe_compliance;

-- Grant schema usage to app role (role must already exist)
GRANT USAGE ON SCHEMA banxe_compliance TO banxe_app_role;

-- ── Table ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS banxe_compliance.decision_events (

  -- Identity
  event_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type        VARCHAR(50) NOT NULL DEFAULT 'AML_DECISION',
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Core decision (I-05: thresholds determine these values)
  case_id           UUID        NOT NULL,
  decision          VARCHAR(10) NOT NULL CHECK (decision IN ('APPROVE','HOLD','REJECT','SAR')),
  composite_score   SMALLINT    NOT NULL CHECK (composite_score BETWEEN 0 AND 100),
  decision_reason   VARCHAR(30) NOT NULL,   -- threshold | hard_override | high_risk_floor

  -- Transaction context (correlation IDs for replay — G-01 + G-20)
  tx_id             VARCHAR(200),
  channel           VARCHAR(50),
  customer_id       VARCHAR(200),

  -- Routing flags (immutable once written)
  requires_edd          BOOLEAN NOT NULL DEFAULT FALSE,
  requires_mlro_review  BOOLEAN NOT NULL DEFAULT FALSE,
  hard_block_hit        BOOLEAN NOT NULL DEFAULT FALSE,  -- Cat A jurisdiction / OFAC
  sanctions_hit         BOOLEAN NOT NULL DEFAULT FALSE,
  crypto_risk           BOOLEAN NOT NULL DEFAULT FALSE,

  -- Policy provenance (FCA audit: which policy was in effect)
  policy_version        VARCHAR(100) NOT NULL DEFAULT '',
  policy_jurisdiction   VARCHAR(10)  NOT NULL DEFAULT 'UK',
  policy_regulator      VARCHAR(20)  NOT NULL DEFAULT 'FCA',
  policy_framework      VARCHAR(50)  NOT NULL DEFAULT 'MLR 2017',

  -- Signals summary
  signals_count     SMALLINT    NOT NULL DEFAULT 0,
  rules_triggered   TEXT[]      NOT NULL DEFAULT '{}',
  signals_json      JSONB       NOT NULL DEFAULT '[]',

  -- Full audit payload (raw, immutable)
  audit_payload     JSONB       NOT NULL DEFAULT '{}'

);

-- Prevent column additions that bypass immutability (documentation constraint)
COMMENT ON TABLE banxe_compliance.decision_events IS
  'Append-only compliance decision log. I-24: no UPDATE/DELETE. FCA MLR 2017 retention: 5 years.';

-- ── Indexes (read performance for replay_decision.py) ──────────────────────
CREATE INDEX IF NOT EXISTS idx_de_case_id
  ON banxe_compliance.decision_events (case_id);

CREATE INDEX IF NOT EXISTS idx_de_customer_id
  ON banxe_compliance.decision_events (customer_id)
  WHERE customer_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_de_occurred_at
  ON banxe_compliance.decision_events (occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_de_tx_id
  ON banxe_compliance.decision_events (tx_id)
  WHERE tx_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_de_decision
  ON banxe_compliance.decision_events (decision, occurred_at DESC);

-- ── Row-Level Security (optional, defence-in-depth) ───────────────────────
-- ALTER TABLE banxe_compliance.decision_events ENABLE ROW LEVEL SECURITY;

-- ── Privileges: GRANT INSERT + SELECT, REVOKE UPDATE + DELETE ─────────────
--
-- This is the database-level enforcement of I-24 (append-only):
-- the application role can INSERT and SELECT, but NEVER UPDATE or DELETE.
--
GRANT SELECT, INSERT ON banxe_compliance.decision_events TO banxe_app_role;
REVOKE UPDATE, DELETE ON banxe_compliance.decision_events FROM banxe_app_role;

-- Also revoke from PUBLIC to prevent accidental privilege escalation
REVOKE UPDATE, DELETE ON banxe_compliance.decision_events FROM PUBLIC;

-- Sequence access (needed for gen_random_uuid() on older PG versions)
-- gen_random_uuid() uses pgcrypto; no sequence needed for UUID PK.

-- ── Grant role to application user (banxe OS user) ────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'banxe') THEN
    GRANT banxe_app_role TO banxe;
  END IF;
END
$$;

-- ── Verify: show table permissions ────────────────────────────────────────
-- Run this after migration to confirm:
-- SELECT grantee, privilege_type, is_grantable
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'banxe_compliance' AND table_name = 'decision_events'
-- ORDER BY grantee, privilege_type;

COMMIT;

-- ── Expected permissions after migration: ────────────────────────────────
--   banxe_app_role  | INSERT  | NO
--   banxe_app_role  | SELECT  | NO
--   (no UPDATE)
--   (no DELETE)
