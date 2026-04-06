---
name: Memory sync to repo
description: После каждого обновления памяти — синхронизировать в CarmiBanxe/vibe-coding репозиторий
type: feedback
---

После каждого сохранения/обновления памяти Claude Code — копировать файлы в репозиторий проекта и пушить.

**Why:** Марк хочет чтобы память была не только локально на Legion, но и в GitHub репозитории проекта для резервирования и доступности.

**How to apply:**
```bash
scp -P 2222 /home/mmber/.claude/projects/-home-mmber-banxe/memory/*.md root@192.168.0.72:/data/vibe-coding/docs/claude-memory/
ssh -p 2222 root@192.168.0.72 "cd /data/vibe-coding && git add docs/claude-memory/ && git commit -m 'memory: update' && git push origin main"
```

Репозиторий: `CarmiBanxe/vibe-coding` (git@github.com:CarmiBanxe/vibe-coding.git)
Путь на сервере: `/data/vibe-coding/docs/claude-memory/`
