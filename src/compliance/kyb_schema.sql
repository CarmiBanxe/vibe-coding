-- Unified KYB Storage — Banxe Compliance
-- PostgreSQL DDL
-- Run in: banxe_compliance database

SET search_path = banxe_compliance;

-- ── 1. Canonical entities ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_entities (
    entity_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_name      TEXT NOT NULL,
    country_code        CHAR(2),                        -- ISO 3166-1 alpha-2
    jurisdiction_code   VARCHAR(10),                    -- e.g. 'gb', 'us_de', 'fr'
    registration_number TEXT,
    status              VARCHAR(30),                    -- active|dissolved|liquidation|insolvency|unknown
    raw_status          TEXT,
    incorporation_date  DATE,
    dissolution_date    DATE,
    company_type        TEXT,
    is_branch           BOOLEAN DEFAULT FALSE,
    is_inactive         BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (jurisdiction_code, registration_number)
);
CREATE INDEX IF NOT EXISTS kyb_entities_name_idx      ON kyb_entities USING gin(to_tsvector('english', canonical_name));
CREATE INDEX IF NOT EXISTS kyb_entities_country_idx   ON kyb_entities (country_code);
CREATE INDEX IF NOT EXISTS kyb_entities_status_idx    ON kyb_entities (status);

-- ── 2. Aliases (previous names, trade names) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_entity_aliases (
    alias_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id   UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    alias_name  TEXT NOT NULL,
    alias_type  VARCHAR(30),          -- previous_name|trade_name|abbreviation|transliteration
    valid_from  DATE,
    valid_to    DATE,
    source      TEXT,
    UNIQUE (entity_id, alias_name)
);
CREATE INDEX IF NOT EXISTS kyb_aliases_name_idx ON kyb_entity_aliases USING gin(to_tsvector('english', alias_name));

-- ── 3. Source provenance ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_entity_sources (
    source_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id         UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    source_system     VARCHAR(50) NOT NULL,             -- companies_house|opencorporates|wikidata
    source_entity_key TEXT NOT NULL,                    -- e.g. CH company_number or OC jurisdiction/number
    source_url        TEXT,
    retrieved_at      TIMESTAMPTZ DEFAULT NOW(),
    confidence        NUMERIC(4,3) DEFAULT 1.000,       -- 0.000–1.000
    etag              TEXT,
    raw_json          JSONB,
    UNIQUE (source_system, source_entity_key)
);
CREATE INDEX IF NOT EXISTS kyb_sources_entity_idx ON kyb_entity_sources (entity_id);
CREATE INDEX IF NOT EXISTS kyb_sources_system_idx ON kyb_entity_sources (source_system);

-- ── 4. Addresses ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_addresses (
    address_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id       UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    address_type    VARCHAR(20),                        -- registered|trading|correspondence
    line1           TEXT,
    line2           TEXT,
    locality        TEXT,
    region          TEXT,
    postal_code     TEXT,
    country_code    CHAR(2),
    full_address    TEXT,
    from_source     VARCHAR(50),
    valid_from      DATE,
    valid_to        DATE
);
CREATE INDEX IF NOT EXISTS kyb_addresses_entity_idx ON kyb_addresses (entity_id);

-- ── 5. Officers (directors, secretaries) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_officers (
    officer_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    full_name           TEXT NOT NULL,
    position            TEXT,                           -- director|secretary|llp_member|etc
    appointed_on        DATE,
    resigned_on         DATE,
    nationality         TEXT,
    date_of_birth_month INT,
    date_of_birth_year  INT,
    address             TEXT,
    source_system       VARCHAR(50),
    source_officer_key  TEXT,
    sanctions_checked   BOOLEAN DEFAULT FALSE,
    pep_checked         BOOLEAN DEFAULT FALSE,
    sanctions_hit       BOOLEAN,
    pep_hit             BOOLEAN,
    raw_json            JSONB
);
CREATE INDEX IF NOT EXISTS kyb_officers_entity_idx  ON kyb_officers (entity_id);
CREATE INDEX IF NOT EXISTS kyb_officers_name_idx    ON kyb_officers USING gin(to_tsvector('english', full_name));
CREATE INDEX IF NOT EXISTS kyb_officers_active_idx  ON kyb_officers (entity_id, resigned_on) WHERE resigned_on IS NULL;

-- ── 6. Beneficial owners / PSC / UBO ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_beneficial_owners (
    owner_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    owner_name          TEXT NOT NULL,
    owner_type          VARCHAR(30),                    -- individual|corporate|legal_person|super_secure
    control_nature      TEXT[],                         -- array: ownership_25, voting_25, right_to_appoint, etc
    ownership_percentage NUMERIC(6,3),
    notified_on         DATE,
    ceased_on           DATE,
    nationality         TEXT,
    country_of_residence TEXT,
    source_system       VARCHAR(50),
    sanctions_hit       BOOLEAN,
    pep_hit             BOOLEAN,
    raw_json            JSONB
);
CREATE INDEX IF NOT EXISTS kyb_bo_entity_idx  ON kyb_beneficial_owners (entity_id);
CREATE INDEX IF NOT EXISTS kyb_bo_name_idx    ON kyb_beneficial_owners USING gin(to_tsvector('english', owner_name));
CREATE INDEX IF NOT EXISTS kyb_bo_active_idx  ON kyb_beneficial_owners (entity_id) WHERE ceased_on IS NULL;

-- ── 7. Filing history ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyb_filings (
    filing_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id           UUID NOT NULL REFERENCES kyb_entities(entity_id) ON DELETE CASCADE,
    source_system       VARCHAR(50),
    source_filing_key   TEXT,
    filing_date         DATE,
    filing_code         TEXT,                           -- e.g. CS01, AA, TM01
    filing_title        TEXT,
    filing_description  TEXT,
    category            VARCHAR(30),                    -- accounts|confirmation|officers|charges|dissolution
    document_url        TEXT,
    pages               INT,
    raw_json            JSONB,
    UNIQUE (source_system, source_filing_key)
);
CREATE INDEX IF NOT EXISTS kyb_filings_entity_idx ON kyb_filings (entity_id);
CREATE INDEX IF NOT EXISTS kyb_filings_date_idx   ON kyb_filings (entity_id, filing_date DESC);

-- ── 8. Adverse / regulatory events ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS adverse_events (
    event_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_stable_hash   TEXT UNIQUE,                    -- SHA256(source_name + item_url) for dedup
    source_family       VARCHAR(20),                    -- regulator|court|news|eu_law
    source_name         VARCHAR(60),                    -- FCA|EBA|EUR-Lex|BAILII|Google-News
    source_weight       NUMERIC(4,3),                   -- 0.550–1.000 per source
    feed_url            TEXT,
    item_url            TEXT,
    title               TEXT,
    summary             TEXT,
    published_at        TIMESTAMPTZ,
    jurisdiction        VARCHAR(10),                    -- uk|eu|multi|us
    language            CHAR(2) DEFAULT 'en',
    topic_tags          TEXT[],                         -- enforcement|sanctions|aml|fraud|etc
    topic_weight        NUMERIC(4,3),
    severity_base       NUMERIC(5,3) DEFAULT 0.0,
    is_regulatory       BOOLEAN DEFAULT FALSE,
    ingested_at         TIMESTAMPTZ DEFAULT NOW(),
    raw_payload         JSONB
);
CREATE INDEX IF NOT EXISTS adverse_events_source_idx    ON adverse_events (source_name);
CREATE INDEX IF NOT EXISTS adverse_events_published_idx ON adverse_events (published_at DESC);
CREATE INDEX IF NOT EXISTS adverse_events_tags_idx      ON adverse_events USING gin(topic_tags);
CREATE INDEX IF NOT EXISTS adverse_events_title_idx     ON adverse_events USING gin(to_tsvector('english', title));

-- ── 9. Entity ↔ adverse event matches ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS adverse_event_entity_matches (
    match_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id              UUID NOT NULL REFERENCES adverse_events(event_id) ON DELETE CASCADE,
    entity_id             UUID REFERENCES kyb_entities(entity_id) ON DELETE SET NULL,
    matched_name          TEXT,                         -- the name string that matched
    entity_match_weight   NUMERIC(4,3),                 -- exact/fuzzy/director
    match_method          VARCHAR(30),                  -- exact|alias|officer|fuzzy
    final_score           NUMERIC(6,4),                 -- source*0.45 + entity*0.35 + topic*0.20
    reviewed              BOOLEAN DEFAULT FALSE,
    created_at            TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS adverse_match_entity_idx ON adverse_event_entity_matches (entity_id);
CREATE INDEX IF NOT EXISTS adverse_match_event_idx  ON adverse_event_entity_matches (event_id);
CREATE INDEX IF NOT EXISTS adverse_match_score_idx  ON adverse_event_entity_matches (final_score DESC);
