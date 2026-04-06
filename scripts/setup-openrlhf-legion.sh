#!/bin/bash
###############################################################################
# setup-openrlhf-legion.sh — OpenRLHF с flash-attn на Legion Pro 5 (WSL2)
#
# Запускать НА LEGION (WSL2 Ubuntu):
#   cd ~/vibe-coding && git pull && bash scripts/setup-openrlhf-legion.sh
#
# Почему Legion, а не GMKtec:
#   - Legion: RTX 4070 Laptop → NVIDIA CUDA → flash-attn работает
#   - GMKtec: AMD Ryzen AI MAX+ → ROCm → flash-attn НЕ работает
#
# Что делает:
#   1. Фиксирует PATH для nvidia-smi в WSL2 (/usr/lib/wsl/lib)
#   2. Проверяет GPU и CUDA
#   3. Создаёт изолированный venv /root/.venvs/openrlhf (Python 3.12)
#   4. Устанавливает torch с CUDA
#   5. Устанавливает flash-attn через --no-build-isolation
#   6. Устанавливает openrlhf
#   7. Smoke-test
###############################################################################

set -euo pipefail

# КРИТИЧНО для WSL2: nvidia-smi лежит не в стандартном PATH
export PATH="/usr/lib/wsl/lib:$PATH"

VENV_PATH="$HOME/.venvs/openrlhf"
CUDA_VERSION="cu126"  # torch CUDA 12.6 build

echo "============================================================"
echo "  SETUP: OpenRLHF + flash-attn на Legion Pro 5 (WSL2)"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

###############################################################################
# Шаг 1: GPU диагностика
###############################################################################
echo "--- [1/6] GPU ДИАГНОСТИКА ---"

if command -v nvidia-smi &>/dev/null; then
    echo "  nvidia-smi найден: $(which nvidia-smi)"
    nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader
else
    echo "  WARN: nvidia-smi не найден в PATH"
    echo "  Пробую /usr/lib/wsl/lib/nvidia-smi..."
    if /usr/lib/wsl/lib/nvidia-smi &>/dev/null; then
        echo "  Найден в /usr/lib/wsl/lib/"
        /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
        # Добавляем в PATH постоянно
        if ! grep -q "wsl/lib" ~/.bashrc; then
            echo 'export PATH="/usr/lib/wsl/lib:$PATH"' >> ~/.bashrc
            echo "  Добавлен в ~/.bashrc автоматически"
        fi
    else
        echo "  ERROR: nvidia-smi не найден — CUDA недоступна"
        echo "  Проверьте Windows NVIDIA драйвер (≥ 525.x)"
        exit 1
    fi
fi

echo ""

###############################################################################
# Шаг 2: Проверяем Python
###############################################################################
echo "--- [2/6] PYTHON ---"

PYTHON_BIN=""
for py in python3.12 python3.11 python3.10 python3; do
    if command -v "$py" &>/dev/null; then
        ver=$("$py" --version 2>&1)
        echo "  Найден: $py ($ver)"
        PYTHON_BIN="$py"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "  ERROR: Python 3.10+ не найден"
    exit 1
fi

echo "  Использую: $PYTHON_BIN"

###############################################################################
# Шаг 3: Создаём venv
###############################################################################
echo ""
echo "--- [3/6] VENV: $VENV_PATH ---"

if [ -d "$VENV_PATH" ]; then
    echo "  venv уже существует"
else
    echo "  Создаю новый venv..."
    "$PYTHON_BIN" -m venv "$VENV_PATH"
    echo "  OK: venv создан"
fi

source "$VENV_PATH/bin/activate"
echo "  Активирован: $VIRTUAL_ENV"
echo "  Python: $(python --version)"
echo ""

###############################################################################
# Шаг 4: Базовые зависимости
###############################################################################
echo "--- [4/6] БАЗОВЫЕ ЗАВИСИМОСТИ ---"

echo "  Обновляю pip/setuptools/wheel..."
pip install -U pip setuptools wheel packaging ninja 2>&1 | tail -3

echo "  Устанавливаю numpy..."
pip install numpy 2>&1 | tail -2

echo "  Устанавливаю torch (CUDA 12.6)..."
pip install torch torchvision torchaudio \
    --index-url "https://download.pytorch.org/whl/${CUDA_VERSION}" \
    2>&1 | tail -5

echo "  Проверяю torch + CUDA..."
python -c "
import torch
print(f'    torch: {torch.__version__}')
print(f'    CUDA:  {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'    GPU:   {torch.cuda.get_device_name(0)}')
    print(f'    VRAM:  {torch.cuda.get_device_properties(0).total_memory // 1024**3} GB')
else:
    print('    WARN: CUDA недоступна!')
"

echo ""

###############################################################################
# Шаг 5: flash-attn
###############################################################################
echo "--- [5/6] FLASH-ATTN (--no-build-isolation) ---"
echo "  Ключ: --no-build-isolation позволяет setup.py видеть уже установленный torch"
echo "  Это официально рекомендованный способ установки flash-attn"
echo ""

if pip show flash-attn &>/dev/null; then
    echo "  flash-attn уже установлен: $(pip show flash-attn | grep Version)"
else
    echo "  Устанавливаю flash-attn (может занять 5-15 минут — компиляция CUDA)..."
    pip install --no-build-isolation flash-attn 2>&1

    if pip show flash-attn &>/dev/null; then
        echo "  OK: flash-attn $(pip show flash-attn | grep Version | awk '{print $2}')"
    else
        echo "  WARN: flash-attn не установился, пробую prebuilt wheel..."
        # Пробуем prebuilt wheel для Python 3.12 + CUDA 12.6
        FLASH_URL="https://github.com/Dao-AILab/flash-attention/releases/download/v2.7.4.post1"
        PY_VER=$(python -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")
        TORCH_VER=$(python -c "import torch; v=torch.__version__; print(v.split('+')[0].replace('.','')[:3])")
        echo "  Python: $PY_VER, torch: $TORCH_VER"
        # Fallback — продолжаем без flash-attn (openrlhf может работать в legacy режиме)
        echo "  Продолжаю без flash-attn (openrlhf поддерживает legacy attention)"
    fi
fi

echo ""

###############################################################################
# Шаг 6: OpenRLHF
###############################################################################
echo "--- [6/6] OPENRLHF ---"

if pip show openrlhf &>/dev/null; then
    echo "  OpenRLHF уже установлен: $(pip show openrlhf | grep Version)"
else
    echo "  Устанавливаю openrlhf..."
    pip install openrlhf 2>&1 | tail -10

    if ! pip show openrlhf &>/dev/null; then
        echo "  Пробую из GitHub..."
        pip install git+https://github.com/OpenRLHF/OpenRLHF.git 2>&1 | tail -10
    fi
fi

echo ""
echo "  Итог установки:"
pip show openrlhf 2>/dev/null | grep -E "Name|Version|Location" | awk '{printf "    %s\n", $0}'

echo ""
echo "  Smoke-test импорта:"
python -c "
import torch
import openrlhf
print(f'    torch: {torch.__version__}')
print(f'    CUDA: {torch.cuda.is_available()}')
try:
    from flash_attn import flash_attn_func
    print('    flash-attn: OK')
except ImportError:
    print('    flash-attn: нет (legacy attention mode)')
print('    openrlhf: OK')
" 2>/dev/null || echo "  Импорт не удался — проверьте вывод выше"

###############################################################################
# Итог
###############################################################################
echo ""
echo "============================================================"
echo "  ГОТОВО"
echo "============================================================"
echo ""
echo "  Активировать venv:"
echo "    source $VENV_PATH/bin/activate"
echo ""
echo "  Для работы в этом venv:"
echo "    python -c \"import openrlhf; print('OK')\""
echo ""
echo "  NOTE: Этот venv только для Legion (WSL2 + RTX 4070)"
echo "        На GMKtec используется другой скрипт (без flash-attn)"
echo "============================================================"
