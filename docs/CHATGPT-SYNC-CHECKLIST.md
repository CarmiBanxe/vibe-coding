# ChatGPT Custom GPT — Sync Checklist

Use this checklist when updating the Banxe ChatGPT Custom GPT after code changes.

---

## When to sync

- After changes to `src/compliance/api.py` (new endpoints, changed request/response)
- After changes to `docs/SOUL.md` (agent personality/instructions)
- After changes to `src/compliance/COMPLIANCE_ARCH.md` (compliance rules)
- After changes to `docs/MEMORY.md` (project context)

---

## Sync steps

### 1. Export OpenAPI schema

```bash
# On GMKtec (or via SSH from Legion):
bash /data/vibe-coding/scripts/export-openapi-schema.sh
git add docs/openapi-schema.json docs/CHATGPT-ACTIONS-SPEC.md
git commit -m "docs: refresh OpenAPI schema export"
git push
```

### 2. Update ChatGPT Actions schema

- [ ] Open [ChatGPT](https://chat.openai.com) → your Banxe GPT → **Edit** → **Configure** → **Actions**
- [ ] Click existing action → **Edit** → paste updated `docs/openapi-schema.json`
- [ ] Or: **Import from URL** if API is publicly accessible via ngrok/Cloudflare

### 3. Update System Prompt

- [ ] Open GPT **Configure** → **Instructions**
- [ ] Copy content from `docs/SOUL.md` (or `workspace-moa/SOUL.md`)
- [ ] Paste and save

### 4. Update Knowledge files

- [ ] In **Configure** → **Knowledge** → upload updated files:
  - [ ] `src/compliance/COMPLIANCE_ARCH.md` — full AML stack architecture
  - [ ] `docs/MEMORY.md` — project context and decisions
  - [ ] `docs/SANCTIONS_POLICY.md` — jurisdiction lists

### 5. Verify Actions endpoint

- [ ] In **Configure** → **Actions** → click **Test** on `/api/v1/health`
- [ ] Expected response: `{"status": "ok", ...}`
- [ ] If fails: check ngrok tunnel is running on GMKtec port 8090

### 6. End-to-end test

- [ ] Send: "Screen 'Vladimir Putin' for sanctions"
  - Expected: REJECT or HOLD with sanctions signals
- [ ] Send: "Check a £12,000 transfer from GB to DE"
  - Expected: HOLD (MLR reporting threshold)
- [ ] Send: "Is Syria high-risk?"
  - Expected: Category B (EDD/HOLD), not REJECT

---

## Notes

- ChatGPT Actions timeout: 30 seconds — ensure API responds within 25s
- Schema must be valid OpenAPI 3.1 — use `mkdocs build --strict` to validate docs
- Knowledge files: max 20 files, 512MB total
- System Prompt: max 8,000 characters — truncate SOUL.md if needed
