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

# ─── 8. Определяем org и деплоим ───
step "Определяю аккаунт и деплою..."

deno_dir="$SCRIPT_DIR/deno-worker"
mkdir -p "$deno_dir"
cp "$SCRIPT_DIR/worker/deno-worker.ts" "$deno_dir/main.ts"
cd "$deno_dir"

# Определяем org и деплоим одним Python-скриптом
deno_url=$(python3 << PYEOF
import urllib.request, json, subprocess, sys, time, random, string

token = "${deno_token}"
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

# Пробуем разные API endpoints чтобы найти org
org = ""
for url in [
    "https://api.deno.com/v2/organizations",
    "https://api.deno.com/v1/organizations",
]:
    try:
        req = urllib.request.Request(url, headers=headers)
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read())
        if isinstance(data, list) and data:
            org = data[0].get("slug") or data[0].get("id") or ""
        elif isinstance(data, dict):
            items = data.get("items") or data.get("organizations") or []
            if items:
                org = items[0].get("slug") or items[0].get("id") or ""
        if org:
            break
    except:
        continue

if not org:
    # Пробуем через user endpoint
    try:
        req = urllib.request.Request("https://api.deno.com/v2/user", headers=headers)
        resp = urllib.request.urlopen(req, timeout=15)
        user = json.loads(resp.read())
        org = user.get("login") or user.get("slug") or user.get("name","").lower().replace(" ","-")
    except:
        pass

if not org:
    print("FAIL:org", file=sys.stderr)
    sys.exit(1)

# Генерируем имя приложения
app = f"vpn-{''.join(random.choices(string.ascii_lowercase, k=6))}"

# Деплоим через CLI
cmd = [
    "deno", "deploy", "create",
    "--org", org, "--app", app,
    "--source", "local",
    "--do-not-use-detected-build-config",
    "--install-command", "echo ok",
    "--runtime-mode", "dynamic",
    "--entrypoint", "main.ts",
    "--region", "global",
]

env = dict(__import__("os").environ)
env["DENO_DEPLOY_TOKEN"] = token

result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
output = result.stdout + result.stderr

# Ищем URL
for line in output.split("\n"):
    for word in line.split():
        if ".deno.net" in word or ".deno.dev" in word:
            url = word.strip()
            if url.startswith("https://") and "console." not in url and "jsr." not in url:
                print(url)
                sys.exit(0)

# Не нашли URL — выводим всё для дебага
print(output, file=sys.stderr)
sys.exit(1)
PYEOF
)

if [[ -z "$deno_url" || "$deno_url" == "FAIL:"* ]]; then
  echo ""
  fail "Не удалось задеплоить. Проверь токен и попробуй снова: ./install.sh"
fi

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
