#!/bin/bash
set -euo pipefail

G='\033[32m' R='\033[31m' Y='\033[33m' C='\033[36m'
B='\033[1m' D='\033[2m' N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/worker"
CONFIG="$SCRIPT_DIR/vpn-config.json"

echo ""
echo -e "  ${B}${C}⚡ VPN Manager — Установка${N}"
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""

# ─── Утилиты ───

ok()   { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}⚠${N} $1"; }
fail() { echo -e "  ${R}✗${N} $1"; exit 1; }
step() { echo -e "  ${Y}→${N} $1"; }

has() { command -v "$1" &>/dev/null; }

# ─── 1. Homebrew ───

# Подхватываем brew если установлен но не в PATH
[[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
[[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true

if ! has brew; then
  step "Устанавливаю Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fail "Не удалось установить Homebrew"
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [[ -f /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"
fi
has brew && ok "Homebrew" || fail "Homebrew не установлен"

# ─── 2. Зависимости через brew ───

for pkg in python3 node deno wgcf; do
  if ! has "$pkg"; then
    step "Устанавливаю ${pkg}..."
    case "$pkg" in
      python3) brew install python ;;
      node)    brew install node ;;
      deno)    brew install deno ;;
      wgcf)    brew install wgcf ;;
    esac
  fi
  has "$pkg" && ok "$pkg" || fail "$pkg не установлен"
done

has curl && ok "curl" || fail "curl не установлен"

# ─── 3. Wrangler ───

mkdir -p "$WORKER_DIR"

if [[ ! -f "$WORKER_DIR/wrangler.toml" ]]; then
  cp "$SCRIPT_DIR/wrangler.toml" "$WORKER_DIR/wrangler.toml"
fi

if ! (cd "$WORKER_DIR" && npx wrangler --version &>/dev/null 2>&1); then
  step "Устанавливаю wrangler..."
  (cd "$WORKER_DIR" && npm install wrangler --save-dev 2>&1) || fail "Не удалось установить wrangler"
fi
ok "wrangler"

# ─── 4. Авторизация Cloudflare ───

echo ""
if ! (cd "$WORKER_DIR" && npx wrangler whoami 2>&1 | grep -q "logged in"); then
  step "Нужна авторизация в Cloudflare — откроется браузер"
  (cd "$WORKER_DIR" && npx wrangler login) || fail "Не удалось авторизоваться"
fi
ok "Cloudflare авторизован"

# ─── 5. Конфиг ───

echo ""
if [[ ! -f "$CONFIG" ]]; then
  cp "$SCRIPT_DIR/vpn-config.example.json" "$CONFIG"
  ok "vpn-config.json создан"
else
  ok "vpn-config.json уже есть"
fi

# ─── 6. Подписки ───

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

# ─── 7. Workers.dev поддомен ───

echo ""
step "Проверяю workers.dev поддомен..."

# Пробуем деплой минимального воркера
cat > "$WORKER_DIR/worker.js" << 'BOOTSTRAP'
export default {
  async fetch() {
    return new Response('Setting up...', { status: 200 });
  },
};
BOOTSTRAP

cd "$WORKER_DIR"
deploy_log="/tmp/vpn-merge-deploy-$$.log"

# Первый деплой — может попросить зарегистрировать workers.dev
npx wrangler deploy 2>&1 | tee "$deploy_log"
deploy_output=$(cat "$deploy_log")

# Если нужна регистрация workers.dev — создаём dummy через wrangler
if echo "$deploy_output" | grep -qi "workers.dev subdomain\|register.*workers.dev\|onboarding\|deploy your worker to one or more routes"; then
  step "Регистрирую workers.dev поддомен автоматически..."

  # Получаем account_id
  account_id=$(echo "$deploy_output" | grep -o '[a-f0-9]\{32\}' | head -1)
  [[ -z "$account_id" ]] && account_id=$(npx wrangler whoami 2>&1 | grep -o '[a-f0-9]\{32\}' | head -1)

  # Регистрируем поддомен через Cloudflare API
  subdomain_name=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 15)

  # Получаем OAuth токен из wrangler config
  cf_token=""
  wrangler_config="$HOME/.wrangler/config/default.toml"
  [[ -f "$wrangler_config" ]] && cf_token=$(grep -o 'oauth_token = "[^"]*"' "$wrangler_config" | sed 's/oauth_token = "//;s/"//' || true)

  # Альтернативный путь к конфигу
  if [[ -z "$cf_token" ]]; then
    for f in "$HOME"/.wrangler/config/*.toml "$HOME"/Library/Preferences/.wrangler/config/*.toml; do
      [[ -f "$f" ]] && cf_token=$(grep -o 'oauth_token = "[^"]*"' "$f" 2>/dev/null | sed 's/oauth_token = "//;s/"//' || true)
      [[ -n "$cf_token" ]] && break
    done
  fi

  if [[ -n "$cf_token" && -n "$account_id" ]]; then
    # Регистрируем поддомен через API
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/subdomain" \
      -H "Authorization: Bearer ${cf_token}" \
      -H "Content-Type: application/json" \
      -d "{\"subdomain\":\"${subdomain_name}\"}" > /dev/null 2>&1

    sleep 3
    step "Повторяю деплой..."
    npx wrangler deploy 2>&1 | tee "$deploy_log"
    deploy_output=$(cat "$deploy_log")
  fi

  # Если API не сработал — пробуем через wrangler init + deploy трюк
  if ! echo "$deploy_output" | grep -q "https://"; then
    step "Альтернативный способ регистрации..."
    tmp_worker=$(mktemp -d)
    cat > "$tmp_worker/wrangler.toml" << TMPTOML
name = "init-subdomain"
main = "index.js"
compatibility_date = "2024-01-01"
workers_dev = true
TMPTOML
    echo 'export default{async fetch(){return new Response("ok")}}' > "$tmp_worker/index.js"
    (cd "$tmp_worker" && npx wrangler deploy 2>&1) || true
    (cd "$tmp_worker" && npx wrangler delete --name init-subdomain -f 2>&1) || true
    rm -rf "$tmp_worker"

    sleep 3
    step "Повторяю деплой..."
    npx wrangler deploy 2>&1 | tee "$deploy_log"
    deploy_output=$(cat "$deploy_log")
  fi

  # Последняя попытка
  if ! echo "$deploy_output" | grep -q "https://"; then
    sleep 5
    npx wrangler deploy 2>&1 | tee "$deploy_log"
    deploy_output=$(cat "$deploy_log")
  fi
fi

# Извлекаем URL
worker_url=$(echo "$deploy_output" | grep -o 'https://[^ ]*workers.dev' | head -1)

if [[ -z "$worker_url" ]]; then
  fail "Не удалось задеплоить воркер. Смотри вывод выше."
fi

ok "Cloudflare Worker: ${worker_url}"

# ─── 8. Сохраняем URL и генерируем конфиг ───

python3 -c "
import json
d=json.load(open('$CONFIG'))
d['worker_urls']=['${worker_url}']
json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"
ok "URL сохранён"

step "Генерирую конфиг и WARP-ключи..."
cd "$SCRIPT_DIR"
python3 "$SCRIPT_DIR/vpn-generate.py" 2>&1 | sed 's/^/  /'

# ─── 9. Финальный деплой ───

step "Финальный деплой на Cloudflare..."
cd "$WORKER_DIR"
npx wrangler deploy 2>&1 | tee "$deploy_log"

if grep -q "Deployed" "$deploy_log"; then
  ok "Cloudflare задеплоен"
else
  warn "Cloudflare деплой мог не пройти — проверь вывод выше"
fi

# ─── 10. Deno Deploy (зеркало для РФ) ───

echo ""
step "Настраиваю зеркало на Deno Deploy (работает без VPN из РФ)..."

deno_dir="$SCRIPT_DIR/deno-worker"
mkdir -p "$deno_dir"
cp "$WORKER_DIR/deno-worker.ts" "$deno_dir/main.ts" 2>/dev/null || true

if [[ -f "$deno_dir/main.ts" ]]; then
  # Генерируем уникальное имя проекта
  cf_name=$(echo "$worker_url" | sed 's|https://||' | sed 's|\..*||')
  deno_app="${cf_name}-deno"

  cat > "$deno_dir/deno.json" << DENOJSON
{"deploy":{"org":"$(whoami)","app":"${deno_app}","entrypoint":"main.ts","installCommand":"echo ok"}}
DENOJSON

  # Пробуем создать и задеплоить
  deno_log="/tmp/vpn-merge-deno-$$.log"

  if DENO_DEPLOY_TOKEN="" deno deploy create \
    --org "$(whoami)" --app "$deno_app" \
    --source local --do-not-use-detected-build-config \
    --install-command "echo ok" \
    --runtime-mode dynamic --entrypoint main.ts \
    --region global 2>&1 | tee "$deno_log"; then

    deno_url=$(grep -o 'https://[^ ]*deno[^ ]*' "$deno_log" | grep -v "console\." | head -1)

    if [[ -n "$deno_url" ]]; then
      # Добавляем Deno URL в конфиг
      python3 -c "
import json
d=json.load(open('$CONFIG'))
urls=d.get('worker_urls',[])
if '${deno_url}' not in [u for u in urls]:
  urls.append('${deno_url}')
  d['worker_urls']=urls
  json.dump(d,open('$CONFIG','w'),indent=2,ensure_ascii=False)
"
      ok "Deno Deploy: ${deno_url}"
    else
      warn "Deno Deploy не настроился — можно настроить позже через ./vpn"
    fi
  else
    warn "Deno Deploy пропущен (нужна авторизация — настрой позже)"
  fi
else
  warn "deno-worker.ts не найден — Deno Deploy пропущен"
fi

# ─── 11. Итог ───

echo ""
echo -e "  ${D}──────────────────────────────────────────${N}"
echo ""
echo -e "  ${G}${B}Установка завершена!${N} 🎉"
echo ""

# Читаем все URL
echo -e "  ${B}Твои ссылки для Shadowrocket:${N}"
python3 -c "
import json
d=json.load(open('$CONFIG'))
for i,u in enumerate(d.get('worker_urls',[])):
  domain=u.replace('https://','').split('/')[0]
  print(f'  Зеркало {i+1}: \033[36m{u}\033[0m ({domain})')
  print(f'    /sub  — подписка')
  print(f'    /conf — конфигурация')
  print(f'    /ping — тест')
" 2>/dev/null

echo ""
echo -e "  ${B}Порядок настройки Shadowrocket:${N}"
echo -e "  1. Настройка → + → вставь ссылку /conf"
echo -e "  2. Главная → + → Subscribe → вставь ссылку /sub"
echo -e "  3. Настройки → Тестирование URL → вставь ссылку /ping"
echo -e "  4. Запускай ${C}./vpn${N} для управления"
echo ""

rm -f "$deploy_log" "$deno_log" 2>/dev/null
