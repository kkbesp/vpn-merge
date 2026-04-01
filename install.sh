#!/bin/bash
set -euo pipefail

G='\033[32m' R='\033[31m' Y='\033[33m' C='\033[36m'
B='\033[1m' D='\033[2m' N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/vpn-config.json"

echo ""
echo -e "  ${B}${C}⚡ VPN Manager — Установка${N}"
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""

ok()   { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}⚠${N} $1"; }
fail() { echo -e "  ${R}✗${N} $1"; exit 1; }
step() { echo -e "  ${Y}→${N} $1"; }
has()  { command -v "$1" &>/dev/null; }

# ─── 1. Homebrew ───

[[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
[[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

if ! has brew; then
  step "Устанавливаю Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fail "Не удалось установить Homebrew"
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"
fi
has brew && ok "Homebrew" || fail "Homebrew не установлен"

# ─── 2. Зависимости ───

for pkg in python3 deno wgcf; do
  if ! has "$pkg"; then
    step "Устанавливаю ${pkg}..."
    case "$pkg" in
      python3) brew install python ;;
      deno)    brew install deno ;;
      wgcf)    brew install wgcf ;;
    esac
  fi
  has "$pkg" && ok "$pkg" || fail "$pkg не установлен"
done

has curl && ok "curl" || fail "curl не установлен"

# ─── 3. Конфиг ───

echo ""
if [[ ! -f "$CONFIG" ]]; then
  cp "$SCRIPT_DIR/vpn-config.example.json" "$CONFIG"
  ok "vpn-config.json создан"
else
  ok "vpn-config.json уже есть"
fi

# ─── 4. Подписки ───

sub_count=$(python3 -c "import json;print(len(json.load(open('$CONFIG')).get('subscriptions',[])))" 2>/dev/null || echo "0")

if [[ "$sub_count" == "0" ]]; then
  echo ""
  echo -e "  ${B}Добавь свои VPN-подписки${N}"
  echo -e "  ${D}Вставляй ссылки по одной, пустая строка = готово${N}"
  echo ""

  subs=()
  while true; do
    read -rp "  URL подписки (Enter = готово): " url
    [[ -z "$url" ]] && break
    subs+=("$url")
    ok "Добавлено"
  done

  if [[ ${#subs[@]} -gt 0 ]]; then
    python3 -c "
import json,sys
d=json.load(open('$CONFIG'))
d['subscriptions'] = $(printf '%s\n' "${subs[@]}" | python3 -c "import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"
    ok "${#subs[@]} подписок сохранено"
  fi
else
  ok "${sub_count} подписок уже в конфиге"
fi

# ─── 5. Деплой на Deno Deploy ───

echo ""
step "Деплою на Deno Deploy..."

# Генерируем имя проекта
app_name="vpn-$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 10)-$(date +%s | tail -c 5)"

# Временно ставим заглушку в worker_urls чтобы генератор не ругался
python3 -c "
import json
d=json.load(open('$CONFIG'))
d['worker_urls']=['https://placeholder.deno.dev']
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"

# Генерируем WARP-ключи и deno-worker
step "Генерирую WARP-ключи и конфиг..."
python3 "$SCRIPT_DIR/vpn-generate.py" 2>&1 | sed 's/^/  /'

# Готовим директорию для деплоя
deno_dir="$SCRIPT_DIR/deno-worker"
mkdir -p "$deno_dir"
cp "$SCRIPT_DIR/worker/deno-worker.ts" "$deno_dir/main.ts"

# Деплой
deploy_log="/tmp/vpn-merge-deploy-$$.log"

# Просто запускаем create интерактивно — Deno сам всё спросит
step "Создаю приложение на Deno Deploy..."
step "Если откроется браузер — авторизуйся и вернись сюда"
cd "$deno_dir"

deno deploy create \
  --source local \
  --do-not-use-detected-build-config \
  --install-command "echo ok" \
  --runtime-mode dynamic \
  --entrypoint main.ts \
  --region global 2>&1 | tee "$deploy_log"

deploy_output=$(cat "$deploy_log")

# Извлекаем URL
deno_url=$(echo "$deploy_output" | grep -o 'https://[^ ]*deno[^ ]*' | grep -v "console\.\|jsr\.\|registry" | head -1)

if [[ -z "$deno_url" ]]; then
  # Пробуем найти URL по паттерну Production
  deno_url=$(echo "$deploy_output" | grep -i "production" | grep -o 'https://[^ ]*' | head -1)
fi

if [[ -z "$deno_url" ]]; then
  echo ""
  fail "Не удалось задеплоить. Смотри вывод выше."
fi

ok "Задеплоено: ${deno_url}"

# ─── 6. Сохраняем URL и перегенерируем ───

python3 -c "
import json
d=json.load(open('$CONFIG'))
d['worker_urls']=['${deno_url}']
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"

# Перегенерируем с правильным URL
cd "$SCRIPT_DIR"
python3 "$SCRIPT_DIR/vpn-generate.py" > /dev/null 2>&1
cp "$SCRIPT_DIR/worker/deno-worker.ts" "$deno_dir/main.ts"

# Финальный деплой с правильным URL в конфиге
step "Финальный деплой..."
cd "$deno_dir"
deno deploy --app "$app_name" --prod 2>&1 | tee "$deploy_log"

if grep -q "Successfully deployed" "$deploy_log"; then
  ok "Финальный деплой завершён"
else
  warn "Повторяю деплой..."
  sleep 3
  deno deploy --app "$app_name" --prod 2>&1 | tee "$deploy_log"
fi

# ─── 7. Проверка ───

echo ""
step "Проверяю..."
sleep 5

ping_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${deno_url}/ping" 2>/dev/null || echo "000")
sub_count=$(curl -s --max-time 10 "${deno_url}/sub" | base64 -d 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [[ "$ping_status" == "204" ]]; then
  ok "/ping → 204"
else
  warn "/ping → ${ping_status}"
fi

if [[ "$sub_count" -gt 0 ]]; then
  ok "/sub → ${sub_count} серверов"
else
  warn "/sub → пусто (серверы появятся после обновления подписки)"
fi

# ─── 8. Итог ───

echo ""
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""
echo -e "  ${G}${B}Установка завершена!${N} 🎉"
echo ""
echo -e "  ${B}Твои ссылки для Shadowrocket:${N}"
echo -e "  Подписка  ${C}${deno_url}/sub${N}"
echo -e "  Конфиг    ${C}${deno_url}/conf${N}"
echo -e "  Тест      ${C}${deno_url}/ping${N}"
echo ""
echo -e "  ${B}Порядок настройки Shadowrocket:${N}"
echo -e "  1. ${B}Настройка${N} → + → вставь ${C}${deno_url}/conf${N}"
echo -e "  2. ${B}Главная${N} → + → Subscribe → вставь ${C}${deno_url}/sub${N}"
echo -e "  3. ${B}Настройки${N} → Тестирование URL → вставь ${C}${deno_url}/ping${N}"
echo -e "  4. Запускай ${C}./vpn${N} для управления"
echo ""

rm -f "$deploy_log" 2>/dev/null
