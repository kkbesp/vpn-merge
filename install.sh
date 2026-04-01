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
fail() { echo -e "  ${R}✗${N} $1"; exit 1; }
step() { echo -e "  ${Y}→${N} $1"; }
has()  { command -v "$1" &>/dev/null; }

# ─── 1. Homebrew ───
[[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
[[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

if ! has brew; then
  step "Устанавливаю Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fail "Homebrew"
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"
fi
ok "Homebrew"

# ─── 2. Зависимости ───
for pkg in python3 deno wgcf; do
  if ! has "$pkg"; then
    step "Устанавливаю ${pkg}..."
    case "$pkg" in
      python3) brew install python ;;
      *)       brew install "$pkg" ;;
    esac
  fi
  has "$pkg" && ok "$pkg" || fail "$pkg"
done

# ─── 3. Конфиг ───
echo ""
[[ ! -f "$CONFIG" ]] && cp "$SCRIPT_DIR/vpn-config.example.json" "$CONFIG"
ok "vpn-config.json"

# ─── 4. Подписки ───
sub_count=$(python3 -c "import json;print(len(json.load(open('$CONFIG')).get('subscriptions',[])))" 2>/dev/null || echo "0")
if [[ "$sub_count" == "0" ]]; then
  echo ""
  echo -e "  ${B}Добавь свои VPN-подписки${N}"
  echo -e "  ${D}Вставляй по одной, пустая строка = готово${N}"
  echo ""
  subs=()
  while true; do
    read -rp "  URL (Enter = готово): " url
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
    ok "${#subs[@]} подписок"
  fi
else
  ok "${sub_count} подписок"
fi

# ─── 5. Заглушка URL для генератора ───
python3 -c "
import json
d=json.load(open('$CONFIG'))
if not d.get('worker_urls') or d['worker_urls']==['']:
  d['worker_urls']=['https://placeholder.deno.dev']
  json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"

# ─── 6. Генерация ───
echo ""
step "Генерирую WARP-ключи и конфиг..."
cd "$SCRIPT_DIR"
python3 vpn-generate.py 2>&1 | sed 's/^/  /'

# ─── 7. Токен Deno Deploy ───
echo ""
deno_token=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('deno_token',''))" 2>/dev/null || echo "")

if [[ -z "$deno_token" ]]; then
  echo -e "  ${B}Нужен токен Deno Deploy (бесплатно, 30 секунд):${N}"
  echo ""
  echo -e "  1. Открой ${C}https://dash.deno.com/account#access-tokens${N}"
  echo -e "  2. Нажми ${B}New Access Token${N} → имя любое → ${B}Generate${N}"
  echo -e "  3. Скопируй токен и вставь сюда"
  echo ""

  # Открываем страницу автоматически
  open "https://dash.deno.com/account#access-tokens" 2>/dev/null || true

  read -rp "  Токен: " deno_token
  [[ -z "$deno_token" ]] && fail "Токен не введён"

  # Сохраняем токен в конфиг
  python3 -c "
import json
d=json.load(open('$CONFIG'))
d['deno_token']='${deno_token}'
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"
fi
ok "Токен Deno Deploy"

# ─── 8. Определяем org через API ───
step "Определяю аккаунт..."

deno_org=$(python3 -c "
import urllib.request, json
req = urllib.request.Request('https://api.deno.com/v2/organizations',
  headers={'Authorization': 'Bearer ${deno_token}'})
try:
  resp = urllib.request.urlopen(req, timeout=10)
  orgs = json.loads(resp.read())
  if orgs: print(orgs[0].get('slug') or orgs[0].get('id',''))
except: pass
" 2>/dev/null || echo "")

if [[ -z "$deno_org" ]]; then
  # Новый Deno Deploy может использовать другой API
  deno_org=$(python3 -c "
import urllib.request, json
req = urllib.request.Request('https://api.deno.com/v1/organizations',
  headers={'Authorization': 'Bearer ${deno_token}'})
try:
  resp = urllib.request.urlopen(req, timeout=10)
  orgs = json.loads(resp.read())
  if isinstance(orgs, list) and orgs: print(orgs[0].get('slug') or orgs[0].get('name','').lower().replace(' ','-'))
  elif isinstance(orgs, dict) and orgs.get('items'): print(orgs['items'][0].get('slug',''))
except: pass
" 2>/dev/null || echo "")
fi

if [[ -z "$deno_org" ]]; then
  # Последний вариант — берём из whoami
  deno_org=$(DENO_DEPLOY_TOKEN="$deno_token" deno deploy 2>&1 | grep -i "org" | head -1 | grep -o '[a-z0-9_-]*' | tail -1 || echo "")
fi

[[ -z "$deno_org" ]] && fail "Не удалось определить организацию Deno Deploy"
ok "Организация: ${deno_org}"

# ─── 9. Деплой ───
step "Деплою..."

deno_dir="$SCRIPT_DIR/deno-worker"
mkdir -p "$deno_dir"
cp "$SCRIPT_DIR/worker/deno-worker.ts" "$deno_dir/main.ts"
cd "$deno_dir"

app_name="vpn-$(echo "$deno_org" | head -c 10)-$(date +%s | tail -c 4)"

DENO_DEPLOY_TOKEN="$deno_token" deno deploy create \
  --org "$deno_org" \
  --app "$app_name" \
  --source local \
  --do-not-use-detected-build-config \
  --install-command "echo ok" \
  --runtime-mode dynamic \
  --entrypoint main.ts \
  --region global 2>&1 | tee /tmp/vpn-deploy.log

deploy_output=$(cat /tmp/vpn-deploy.log)
deno_url=$(echo "$deploy_output" | grep -o 'https://[a-z0-9._-]*\.deno\.net' | head -1)
[[ -z "$deno_url" ]] && deno_url=$(echo "$deploy_output" | grep -o 'https://[a-z0-9._-]*\.deno\.dev' | head -1)
[[ -z "$deno_url" ]] && deno_url=$(echo "$deploy_output" | grep -i "production" | grep -o 'https://[^ ]*' | head -1)

[[ -z "$deno_url" ]] && fail "Не удалось задеплоить. Смотри вывод выше."
ok "URL: ${deno_url}"

# ─── 8. Перегенерация с правильным URL ───
step "Обновляю конфиг с правильным URL..."
python3 -c "
import json
d=json.load(open('$CONFIG'))
d['worker_urls']=['${deno_url}']
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"

cd "$SCRIPT_DIR"
python3 vpn-generate.py > /dev/null 2>&1
cp "$SCRIPT_DIR/worker/deno-worker.ts" "$deno_dir/main.ts"

# Извлекаем app name из URL
deno_app=$(echo "$deno_url" | sed 's|https://||' | cut -d. -f1)

step "Финальный деплой..."
cd "$deno_dir"
deno deploy --app "$deno_app" --prod 2>&1 | tee /tmp/vpn-deploy.log

if grep -q "Successfully deployed" /tmp/vpn-deploy.log; then
  ok "Задеплоено"
else
  step "Повторяю..."
  sleep 3
  deno deploy --app "$deno_app" --prod 2>&1 | tee /tmp/vpn-deploy.log
fi

# ─── 9. Проверка ───
echo ""
step "Проверяю..."
sleep 5
ping_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${deno_url}/ping" 2>/dev/null || echo "000")
server_count=$(curl -s --max-time 10 "${deno_url}/sub" 2>/dev/null | base64 -d 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[[ "$ping_code" == "204" ]] && ok "/ping ок" || echo -e "  ${Y}⚠${N} /ping → ${ping_code}"
[[ "$server_count" -gt 0 ]] && ok "${server_count} серверов" || echo -e "  ${Y}⚠${N} серверы появятся после обновления"

# ─── 10. Готово ───
echo ""
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""
echo -e "  ${G}${B}Готово!${N} 🎉"
echo ""
echo -e "  ${B}Ссылки для Shadowrocket:${N}"
echo -e "  Подписка  ${C}${deno_url}/sub${N}"
echo -e "  Конфиг    ${C}${deno_url}/conf${N}"
echo -e "  Тест      ${C}${deno_url}/ping${N}"
echo ""
echo -e "  ${B}Настройка:${N}"
echo -e "  1. Настройка → + → ${C}${deno_url}/conf${N}"
echo -e "  2. Главная → + → Subscribe → ${C}${deno_url}/sub${N}"
echo -e "  3. Настройки → Тестирование URL → ${C}${deno_url}/ping${N}"
echo -e "  4. ${C}./vpn${N} для управления"
echo ""
rm -f /tmp/vpn-deploy.log 2>/dev/null
