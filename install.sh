#!/bin/bash
# Установка VPN Manager

set -e

G='\033[32m' R='\033[31m' Y='\033[33m' C='\033[36m'
B='\033[1m' D='\033[2m' N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/worker"
CONFIG="$SCRIPT_DIR/vpn-config.json"

echo ""
echo -e "  ${B}${C}⚡ VPN Manager — Установка${N}"
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""

# ─── 1. Зависимости ───

check() {
  if command -v "$1" &>/dev/null; then
    echo -e "  ${G}✓${N} $1"
    return 0
  else
    echo -e "  ${Y}✗${N} $1 — не найден"
    return 1
  fi
}

echo -e "  ${B}Проверяю зависимости...${N}"

check python3 || { echo -e "  ${R}Установи python3${N}"; exit 1; }
check curl || { echo -e "  ${R}Установи curl${N}"; exit 1; }

if ! check wgcf; then
  echo -e "  ${Y}→${N} Устанавливаю wgcf..."
  brew install wgcf
  echo -e "  ${G}✓${N} wgcf установлен"
fi

if ! check wrangler && ! npx wrangler --version &>/dev/null 2>&1; then
  echo -e "  ${Y}→${N} Устанавливаю wrangler..."
  mkdir -p "$WORKER_DIR"
  cd "$WORKER_DIR" && npm install wrangler --save-dev
  echo -e "  ${G}✓${N} wrangler установлен"
fi

echo ""

# ─── 2. Worker directory ───

mkdir -p "$WORKER_DIR"

if [[ ! -f "$WORKER_DIR/wrangler.toml" ]]; then
  cat > "$WORKER_DIR/wrangler.toml" << 'EOF'
name = "sub-merger"
main = "worker.js"
compatibility_date = "2024-01-01"
EOF
fi

if [[ ! -f "$WORKER_DIR/package.json" ]]; then
  cd "$WORKER_DIR" && npm install wrangler --save-dev 2>/dev/null
fi

# ─── 3. Cloudflare авторизация ───

echo -e "  ${B}Авторизация в Cloudflare${N}"

if ! cd "$WORKER_DIR" && npx wrangler whoami 2>&1 | grep -q "logged in"; then
  echo -e "  ${Y}→${N} Откроется браузер — нажми Allow"
  echo ""
  cd "$WORKER_DIR" && npx wrangler login
fi

echo -e "  ${G}✓${N} Авторизован"
echo ""

# ─── 4. Конфиг ───

if [[ -f "$CONFIG" ]]; then
  echo -e "  ${G}✓${N} vpn-config.json уже существует"
else
  cp "$SCRIPT_DIR/vpn-config.example.json" "$CONFIG"
  echo -e "  ${G}✓${N} Создан vpn-config.json из шаблона"
fi

echo ""
echo -e "  ${B}Добавь свои VPN-подписки${N}"
echo -e "  ${D}Вставляй ссылки по одной, пустая строка = готово${N}"
echo ""

subs=()
while true; do
  read -rp "  URL подписки (Enter = готово): " url
  [[ -z "$url" ]] && break
  subs+=("$url")
  echo -e "  ${G}✓${N} Добавлено"
done

if [[ ${#subs[@]} -gt 0 ]]; then
  python3 -c "
import json,sys
d=json.load(open('$CONFIG'))
d['subscriptions'] = $(printf '%s\n' "${subs[@]}" | python3 -c "import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"
  echo -e "\n  ${G}✓${N} ${#subs[@]} подписок сохранено"
fi

echo ""

# ─── 5. Первый деплой ───

echo -e "  ${B}Первый деплой...${N}"
echo ""

# Генерируем worker.js
python3 "$SCRIPT_DIR/vpn-generate.py" 2>&1 | sed 's/^/  /'

# Деплоим
cd "$WORKER_DIR"
deploy_output=$(npx wrangler deploy 2>&1)

if echo "$deploy_output" | grep -q "Deployed"; then
  # Извлекаем URL
  worker_url=$(echo "$deploy_output" | grep "https://" | head -1 | grep -o 'https://[^ ]*')
  echo -e "  ${G}✓${N} Задеплоено: ${worker_url}"

  # Сохраняем URL в конфиг
  python3 -c "
import json
d=json.load(open('$CONFIG'))
d['worker_url']='${worker_url}'
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"

  # Перегенерируем с правильным URL
  python3 "$SCRIPT_DIR/vpn-generate.py" > /dev/null 2>&1
  cd "$WORKER_DIR" && npx wrangler deploy > /dev/null 2>&1

  echo -e "  ${G}✓${N} Конфиг обновлён с URL"
else
  echo -e "  ${R}✗${N} Ошибка деплоя:"
  echo "$deploy_output" | tail -5
  exit 1
fi

echo ""
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""
echo -e "  ${G}${B}Установка завершена!${N} 🎉"
echo ""
echo -e "  ${B}Твои ссылки для Shadowrocket:${N}"
echo -e "  Конфиг     ${C}${worker_url}/conf${N}"
echo -e "  Подписка   ${C}${worker_url}/sub${N}"
echo -e "  Тест       ${C}${worker_url}/ping${N}"
echo ""
echo -e "  ${B}Что дальше:${N}"
echo -e "  1. Добавь конфиг в Shadowrocket (Настройка → + → URL)"
echo -e "  2. Добавь подписку (Главная → + → Subscribe → URL)"
echo -e "  3. Запускай ${C}./vpn${N} для управления"
echo ""
