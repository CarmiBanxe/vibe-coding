# docs/MIROFISH-SCENARIOS.md — Banxe AI Bank (vibe-coding)

**Project:** vibe-coding  
**Type:** Banking/FCA Compliance  
**MiroFish Role:** Pre-implementation validation & stress-testing  
**Auto-trigger:** Banking keywords (HITL, FCA, fraud, KYC, sandbox)

---

## Scenario Library

### 1. HITL Handoff Simulation (`hitl-handoff.yml`)

**Purpose:** Validate human-in-the-loop trust thresholds for payment approvals

**Triggers:** `HITL`, `handoff`, `дублёр`, `trust threshold`

**Agents:**
- **User:** Initiates high-value payment (£50k+)
- **Compliance Bot:** Automated AML/KYC check
- **Human Approver (дублёр):** Manual review trigger
- **Fraud Detector:** Pattern analysis

**Flow:**
```
User → Payment Request (£75k)
     → Compliance Check (automated)
     → Risk Score: 0.73 (above 0.7 threshold)
     → HITL Trigger: Human approver notification
     → Дублёр Decision: Approve/Reject/Request Info
     → Audit Trail: ClickHouse logging
```

**Validation Metrics:**
- False positive rate < 5%
- Average handoff time < 2 minutes
- User drop-off rate < 15% at HITL stage

**Source of Truth:** `~/developer/compliance/api.py` (threshold constants)

---

### 2. FCA Sandbox Pre-Check (`pre-fca-sandbox.yml`)

**Purpose:** Test compliance policies before FCA sandbox submission

**Triggers:** `FCA`, `compliance`, `sandbox`, `regulatory approval`

**Agents:**
- **Product Owner:** Describes new feature
- **Compliance Officer:** Maps to FCA requirements
- **Risk Assessor:** Identifies gaps
- **Mock Auditor:** Simulates FCA questions

**Scenario Steps:**
1. Product demo: "Crypto-to-Fiat on-ramp via Moov"
2. Compliance mapping: FCA Policy Statement PS21/3
3. Gap analysis: Missing transaction monitoring?
4. Mock audit: 10 FCA-style questions
5. Recommendation: Go/No-Go decision

**Deliverables:**
- Compliance checklist (✓/✗ per requirement)
- Risk register (top 5 concerns)
- Mitigation plan (actions before sandbox)

---

### 3. Fraud Pattern Detection (`fraud-social-eng.yml`)

**Purpose:** Identify social engineering vulnerabilities in banking flows

**Triggers:** `fraud pattern`, `social engineering`, `phishing`, `account takeover`

**Attack Vectors Simulated:**
- **SIM Swap Attack:** Fraudster requests SIM replacement
- **Authorized Push Payment (APP):** User tricked into sending money
- **Credential Stuffing:** Brute-force login attempts
- **Deepfake Voice ID:** Synthetic voice bypass attempt

**Defense Validation:**
- Velocity checks (Redis): >3 requests/hour = flag
- Device fingerprinting: New device + high value = block
- Behavioral biometrics: Typing pattern mismatch
- Watchlist cross-check: Moov sanctions screening

**Success Criteria:**
- Detect 9/10 attack vectors
- False positive rate < 2%
- Time-to-detect < 30 seconds

---

### 4. Market Reaction Modeling (`gtm-reaction.yml`)

**Purpose:** Simulate market response to Banxe launch features

**Triggers:** `market reaction`, `launch`, `go-to-market`, `adoption`

**Agents:**
- **Early Adopter:** Tech-savvy, risk-tolerant
- **Traditional Bank Customer:** Conservative, branch-dependent
- **Fintech Competitor:** Monzo/Revolut power user
- **FCA Observer:** Regulatory perspective
- **Investor:** ROI-focused

**Scenarios:**
1. **Feature:** "Instant crypto-to-fiat conversion"
   - Early Adopter: "Finally! When?"
   - Traditional: "Is this safe?"
   - FCA: "EMI license covers this?"

2. **Pricing:** "£10/month + 0.5% FX markup"
   - Fintech User: "Revolut is cheaper"
   - Investor: "Margin too thin"

**Output:** Adoption curve projection (12 months)

---

### 5. UX Validation — KYC Drop-off (`ux-validation.yml`)

**Purpose:** Identify friction points in onboarding flow

**Triggers:** `UX validation`, `drop-off`, `onboarding`, `conversion`

**User Personas:**
- **Impatient Millennial:** Expects <5 min signup
- **Non-native Speaker:** Struggles with English forms
- **Privacy-Concerned:** Hesitates on data sharing
- **Elderly User:** Needs larger fonts, clearer instructions

**Onboarding Flow:**
```
Step 1: Email signup          → 95% completion
Step 2: Password creation      → 88% completion
Step 3: Phone verification     → 82% completion
Step 4: ID document upload     → 67% completion ← DROP-OFF POINT
Step 5: Selfie verification    → 61% completion
Step 6: Address confirmation   → 58% completion
Step 7: Source of funds        → 54% completion ← CRITICAL FRICTION
```

**Recommendations:**
- Add progress bar ("Step 4 of 7")
- Explain WHY source of funds required (FCA mandate)
- Offer chat support at Step 4+
- Allow save-and-continue-later

---

### 6. BTC Crash Stress Test (`fraud-stress-test.yml`)

**Purpose:** System behavior during extreme market volatility

**Triggers:** `stress test`, `crisis`, `BTC crash`, `market collapse`

**Scenario:** Bitcoin drops 40% in 2 hours

**Cascade Effects:**
```
Hour 0:00  → BTC peaks at $85k
Hour 0:15  → Sell-off begins (-8%)
Hour 0:30  → Panic selling (-18%)
Hour 1:00  → Circuit breaker triggered (-25%)
Hour 1:30  → Liquidity crisis (-35%)
Hour 2:00  → Stabilization attempt (-40%)
```

**System Load Simulation:**
- Normal: 50 req/sec, 200 concurrent users
- Crisis: 2,500 req/sec, 15,000 concurrent users
- Expected failure points:
  - Redis velocity cache overflow
  - ClickHouse audit write latency
  - Moov API rate limits

**Validation Questions:**
- Does system gracefully degrade or catastrophically fail?
- Are critical compliance checks maintained under load?
- Can users exit positions or does system freeze?

---

## MiroFish Integration

### Auto-Trigger Keywords

When Claude detects these keywords in conversation, MiroFish activates automatically:

| Keyword | Scenario | Priority |
|---------|----------|----------|
| `HITL`, `handoff`, `дублёр` | hitl-handoff.yml | High |
| `FCA`, `sandbox`, `compliance` | pre-fca-sandbox.yml | Critical |
| `fraud`, `social engineering` | fraud-social-eng.yml | High |
| `launch`, `market reaction` | gtm-reaction.yml | Medium |
| `drop-off`, `conversion` | ux-validation.yml | Medium |
| `stress test`, `crash` | fraud-stress-test.yml | High |

### Running Simulations

**Manual trigger:**
```bash
cd ~/vibe-coding
bash ../mirofish-engine/run.sh hitl-handoff
```

**Auto-trigger (Claude-detected):**
```
User: "Need to design HITL handoff for £50k+ payments"
Claude: "Запускаю MiroFish симуляцию hitl-handoff.yml для валидации архитектуры..."
[Simulation runs]
Claude: "Результаты показывают 12% false positive rate. Рекомендую снизить порог с 0.7 до 0.65"
```

---

## Memory Updates

After each simulation, update `docs/MEMORY.md`:

```markdown
## 2026-04-03 — HITL Handoff Simulation

**Scenario:** hitl-handoff.yml  
**Result:** PASSED with recommendations  
**Key Finding:** 0.7 threshold too aggressive (12% FP)  
**Action:** Lower to 0.65, re-test Q2 2026  
**Owner:** @bereg2022
```

---

**Source:** `~/developer/docs/MIROFISH-SCENARIOS-vibe-coding.md` (MASTER)  
**Synced:** N/A (project-specific, not synced)  
**Last Updated:** 2026-04-03
