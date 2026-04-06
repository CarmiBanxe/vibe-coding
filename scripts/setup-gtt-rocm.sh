#!/bin/bash
# setup-gtt-rocm.sh — Фаза 1
# GTT memory unlock (amdgpu.gttsize=59392) + ROCm установка на GMKtec
# После завершения GMKtec перезагрузится (~2 мин)
# Затем запустить: bash scripts/setup-qwen3-model.sh
#
# Запускать на Legion: bash scripts/setup-gtt-rocm.sh

set -e
echo "============================================"
echo "  GMKtec — Phase 1: GTT Unlock + ROCm"
echo "============================================"
echo ""

# ─────────────────────────────────────────────────────────
# ШАГ 1: Проверяем текущее состояние
# ─────────────────────────────────────────────────────────
echo "[1/4] Текущее состояние памяти и GPU..."
ssh gmktec "
echo 'RAM:' && free -h | grep Mem
echo ''
echo 'GTT сейчас:' && sudo dmesg | grep -i 'gtt memory' | tail -3 || echo '  (GTT не настроен)'
echo ''
echo 'GPU (pci):' && lspci | grep -i 'VGA\|Display\|Radeon' | head -3
echo ''
echo 'ROCm установлен:' && rocm-smi 2>/dev/null && echo YES || echo NO
"

# ─────────────────────────────────────────────────────────
# ШАГ 2: GTT unlock в GRUB
# ─────────────────────────────────────────────────────────
echo ""
echo "[2/4] Настройка GTT (amdgpu.gttsize=59392) в GRUB..."

ssh gmktec '
GRUB_FILE="/etc/default/grub"

# Бэкап
sudo cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Читаем текущую строку
CURRENT=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE")
echo "  Текущая: $CURRENT"

# Проверяем — уже есть gttsize?
if echo "$CURRENT" | grep -q "gttsize"; then
    echo "  GTT уже настроен, пропускаем"
else
    # Добавляем параметры перед последней кавычкой
    sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 amd_iommu=off amdgpu.gttsize=59392 ttm.pages_limit=15204352\"/" "$GRUB_FILE"
    echo "  Новая: $(grep "^GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE")"
fi

sudo update-grub 2>&1 | tail -5
echo "  GRUB обновлён ✓"
'

# ─────────────────────────────────────────────────────────
# ШАГ 3: Установка ROCm
# ─────────────────────────────────────────────────────────
echo ""
echo "[3/4] Установка ROCm (AMD GPU drivers + compute)..."
echo "  Это может занять 3-10 минут..."

ssh gmktec '
# Проверяем — уже установлен?
if command -v rocm-smi &>/dev/null; then
    echo "  ROCm уже установлен:"
    rocm-smi --showid 2>/dev/null | head -5
    exit 0
fi

# Добавляем AMD ROCm репозиторий (официальный, последняя версия)
echo "  Добавляем AMD ROCm репозиторий..."
wget -q -O /tmp/amdgpu-install.deb https://repo.radeon.com/amdgpu-install/6.3/ubuntu/noble/amdgpu-install_6.3.60300-1_all.deb 2>&1 || {
    echo "  Прямая загрузка не удалась, пробуем через apt..."
    sudo apt install -y rocm 2>&1 | tail -10
    exit 0
}

sudo apt install -y /tmp/amdgpu-install.deb 2>&1 | tail -5
sudo amdgpu-install -y --usecase=rocm --no-dkms 2>&1 | tail -20
sudo usermod -a -G render,video $USER
sudo usermod -a -G render,video root
echo "  ROCm установлен ✓"
' || {
    echo "  [WARN] ROCm установка не удалась — продолжаем без ROCm"
    echo "  CPU-инференс будет работать, но медленнее"
}

# ─────────────────────────────────────────────────────────
# ШАГ 4: Перезагрузка
# ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] Перезагрузка GMKtec..."
echo "  Ожидайте ~2 минуты, затем запустите:"
echo "  bash scripts/setup-qwen3-model.sh"
echo ""

ssh gmktec "sudo reboot" || true

echo "  GMKtec перезагружается..."
echo ""
echo "============================================"
echo "  Фаза 1 завершена. Ждите 2 минуты."
echo "  Затем: bash scripts/setup-qwen3-model.sh"
echo "============================================"
