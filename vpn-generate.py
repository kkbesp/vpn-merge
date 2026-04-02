#!/usr/bin/env python3
"""Генерирует deno-worker.ts, worker.js и shadowrocket.conf из vpn-config.json.

Запускается при каждом деплое через ./vpn → 5.
Также обновляет WARP-ключи через wgcf.
"""

import json
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

# ─── Paths ───

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "vpn-config.json"
CONF_PATH = SCRIPT_DIR / "shadowrocket.conf"
WORKER_DIR = SCRIPT_DIR / "worker"

# ─── Config ───

with open(CONFIG_PATH) as f:
    config = json.load(f)

worker_urls = config.get("worker_urls", [])
worker_url = worker_urls[0] if worker_urls else ""
subs = config["subscriptions"]
pings = config["ping_targets"]
warp_domains = config.get("warp_domains", [])

if not worker_url:
    print("✗ worker_urls не задан в vpn-config.json. Запусти ./install.sh")
    exit(1)


# ─── WARP: регенерация ключей ───

WG_KEY_MAP = {
    "PrivateKey": "private_key",
    "PublicKey": "public_key",
    "Endpoint": "endpoint",
    "MTU": "mtu",
}


def refresh_warp():
    """Регенерирует WARP-ключи через wgcf."""
    with tempfile.TemporaryDirectory() as tmpdir:
        for cmd in [["wgcf", "register", "--accept-tos"], ["wgcf", "generate"]]:
            subprocess.run(cmd, cwd=tmpdir, capture_output=True, text=True)
        profile = Path(tmpdir) / "wgcf-profile.conf"
        return parse_wg_profile(profile.read_text()) if profile.exists() else None


def parse_wg_profile(text):
    """Парсит wgcf-profile.conf → dict с ключами для WireGuard."""
    result = {}
    for line in text.strip().splitlines():
        line = line.strip()
        if "=" not in line or line.startswith("["):
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()
        if key == "Address":
            for part in (p.strip() for p in val.split(",")):
                result["ipv6" if ":" in part else "ipv4"] = part
        elif key in WG_KEY_MAP:
            result[WG_KEY_MAP[key]] = val
    return result


print("⠋ Обновляю WARP-ключи...", end="", flush=True)
warp = refresh_warp()
if warp:
    print(f"\r✓ WARP-ключи обновлены (IP: {warp['ipv4']})")
else:
    print("\r⚠ Не удалось обновить WARP, используются старые ключи")
    warp = config.get("warp_keys")

if warp:
    config["warp_keys"] = warp
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


# ─── Proxy rules (data-driven) ───

PROXY_DOMAINS = {
    "AI": [
        "claude.ai", "anthropic.com", "api.anthropic.com",
        "gemini.google.com", "generativelanguage.googleapis.com",
        "makersuite.google.com", "aistudio.google.com", "deepmind.google.com",
        "copilot.github.com", "githubcopilot.com",
        "perplexity.ai", "midjourney.com",
    ],
    "Мессенджеры": [
        "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
        "whatsapp.com", "whatsapp.net", "signal.org",
    ],
    "Видеозвонки": [
        "meet.google.com", "meet.googleapis.com",
        "zoom.us", "zoom.com",
    ],
    "Соцсети": [
        "instagram.com", "cdninstagram.com", "ig.me",
        "facebook.com", "fbcdn.net", "fb.com",
        "twitter.com", "x.com", "twimg.com", "t.co",
        "linkedin.com", "licdn.com",
        "threads.net",
        "reddit.com", "redd.it", "redditmedia.com",
    ],
    "Стриминг": [
        "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "youtube-nocookie.com",
        "spotify.com", "scdn.co", "twitch.tv", "soundcloud.com",
    ],
    "Разработка": [
        "github.com", "github.io", "githubusercontent.com", "githubassets.com",
        "npmjs.com", "docker.com", "docker.io", "notion.so", "figma.com",
    ],
    "Google": [
        ("google.com", "PROXY"),
        ("googleapis.com", "PROXY"),
        ("googlesyndication.com", "REJECT"),
        ("googleadservices.com", "REJECT"),
        ("doubleclick.net", "REJECT"),
        ("gstatic.com", "PROXY"),
        ("googleusercontent.com", "PROXY"),
    ],
    "Прочее": [
        "medium.com", "archive.org", "workers.dev", "pages.dev",
    ],
}

TELEGRAM_CIDRS = [
    "IP-CIDR,91.108.0.0/16,WARP-CHAIN,no-resolve",
    "IP-CIDR,149.154.160.0/20,WARP-CHAIN,no-resolve",
    "IP-CIDR,185.76.151.0/24,WARP-CHAIN,no-resolve",
    "IP-CIDR6,2001:67c:4e8::/48,WARP-CHAIN,no-resolve",
    "IP-CIDR6,2001:b28:f23d::/48,WARP-CHAIN,no-resolve",
    "IP-CIDR6,2001:b28:f23f::/48,WARP-CHAIN,no-resolve",
    "IP-CIDR6,2a0a:f280::/32,WARP-CHAIN,no-resolve",
]


def build_proxy_rules():
    """Генерирует блок DOMAIN-SUFFIX правил из PROXY_DOMAINS."""
    sections = []
    for category, domains in PROXY_DOMAINS.items():
        lines = [f"# ═══ {category} ═══"]
        for d in domains:
            if isinstance(d, tuple):
                lines.append(f"DOMAIN-SUFFIX,{d[0]},{d[1]}")
            else:
                lines.append(f"DOMAIN-SUFFIX,{d},PROXY")
        sections.append("\n".join(lines))
    return "\n\n".join(sections)


# ─── Shadowrocket conf ───

def generate_conf(warp_params):
    """Генерирует shadowrocket.conf из WARP-ключей и правил маршрутизации."""
    warp_line = ""
    if warp_params:
        w = warp_params
        warp_line = (
            f'⚠️ WARP (не трогать) = wireguard, '
            f'self-ip={w["ipv4"].split("/")[0]}, '
            f'self-ip-v6={w["ipv6"].split("/")[0]}, '
            f'private-key={w["private_key"]}, '
            f'mtu={w.get("mtu", "1280")}, dns=1.1.1.1, '
            f'peer=(public-key={w["public_key"]}, '
            f'allowed-ips="0.0.0.0/0, ::/0", '
            f'endpoint={w["endpoint"]}, keepalive=45)'
        )

    warp_rules = ""
    if warp_domains and warp_params:
        warp_rules = "\n".join(f"DOMAIN-SUFFIX,{d},WARP-CHAIN" for d in warp_domains)

    proxy_rules = build_proxy_rules()
    telegram_cidrs = "\n".join(TELEGRAM_CIDRS)
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    return f"""\
# Shadowrocket VPN Config — auto-select, split routing, ad block, WARP
# Auto-generated — правь vpn-config.json + ./vpn
# Updated: {now}

[General]
bypass-system = true
ipv6 = false
prefer-ipv6 = false
private-ip-answer = true
dns-direct-system = false
dns-fallback-system = false
dns-direct-fallback-proxy = true
dns-server = https://dns.adguard-dns.com/dns-query, https://1.1.1.1/dns-query, https://dns.google/dns-query
fallback-dns-server = system
hijack-dns = :53
skip-proxy = 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local, captive.apple.com
tun-excluded-routes = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 255.255.255.255/32, 239.255.255.250/32
always-real-ip = *
icmp-auto-reply = false
always-reject-url-rewrite = false
udp-policy-not-supported-behaviour = REJECT
update-url = {worker_url}/conf

[Proxy]
{warp_line}

[Proxy Group]
AUTO = url-test, interval=300, timeout=3, url={worker_url}/ping, policy-regex-filter=^(?!.*WARP).*
WARP-CHAIN = select, policy-path={worker_url}/sub, underlying-proxy=⚠️ WARP (не трогать)

[Rule]
RULE-SET,https://anti-ad.net/surge2.txt,REJECT

# ═══ WARP-домены (гео-блоки, Telegram, Instagram) ═══
{warp_rules}
{telegram_cidrs}

{proxy_rules}

# ═══ РФ — напрямую ═══
RULE-SET,https://raw.githubusercontent.com/misha-tgshv/shadowrocket-configuration-file/main/list/domain-list-ru.txt,DIRECT
GEOIP,RU,DIRECT

FINAL,PROXY

[URL Rewrite]
^https://pagead2\\.googlesyndication\\.com - reject
^https://googleads\\.g\\.doubleclick\\.net - reject

[MITM]
enable = false
"""


# ─── Worker code generation ───
# Template uses %% placeholders — no double-brace escaping needed

CF_ENTRY = """\
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/sub' || url.pathname === '/') return handleMerge();
    if (url.pathname === '/ping') return handlePing();
    if (url.pathname === '/conf') return handleConf();
    return new Response('Not found', { status: 404 });
  },
};"""

DENO_ENTRY = """\
async function handler(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/sub' || url.pathname === '/') return handleMerge();
    if (url.pathname === '/ping') return handlePing();
    if (url.pathname === '/conf') return handleConf();
    return new Response('Not found', { status: 404 });
}

Deno.serve(handler);"""

WORKER_TEMPLATE = """\
// Auto-generated by vpn manager

const SUBSCRIPTIONS = [
%%SUBS%%
];

const PING_TARGETS = [
%%PINGS%%
];

const SHADOWROCKET_CONF = `%%CONF%%`;

%%ENTRY%%

function handleConf() {
  return new Response(SHADOWROCKET_CONF, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache',
    },
  });
}

async function handlePing() {
  const results = await Promise.allSettled(
    PING_TARGETS.map(async (url) => {
      const res = await fetch(url, {
        method: 'GET',
        redirect: 'follow',
        headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' },
        signal: AbortSignal.timeout(5000),
      });
      return res.status;
    }),
  );
  const allReachable = results.every((r) => r.status === 'fulfilled');
  if (allReachable) return new Response(null, { status: 204 });
  return new Response('Service unreachable', { status: 502 });
}

async function handleMerge() {
  const allNodes = [];
  const results = await Promise.allSettled(
    SUBSCRIPTIONS.map(async (subUrl) => {
      const res = await fetch(subUrl, {
        headers: {
          'User-Agent': 'Happ/1.0',
          'X-HWID': 'vpn-merge',
          'Accept-Encoding': 'identity',
        },
        redirect: 'follow',
      });
      if (!res.ok) return [];
      const text = await res.text();
      if (!text || text.trim().length === 0) return [];
      return decodeSubscription(text);
    }),
  );
  for (const result of results) {
    if (result.status === 'fulfilled') allNodes.push(...result.value);
  }
  const unique = [...new Set(allNodes)].filter((l) => l.trim().length > 0);

  // base64 encode, safe for UTF-8
  const raw = unique.join('\\n');
  let merged;
  try {
    merged = btoa(raw);
  } catch {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(raw);
    let bin = '';
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    merged = btoa(bin);
  }
  return new Response(merged, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache',
      'Profile-Update-Interval': '6',
    },
  });
}

function decodeSubscription(raw%%RAW_TYPE%%) {
  const trimmed = raw.trim();
  try {
    const decoded = atob(trimmed);
    if (/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\\/\\//m.test(decoded))
      return decoded.split('\\n').filter((l%%FILTER_TYPE%%) => l.trim().length > 0);
  } catch {}
  if (/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\\/\\//m.test(trimmed))
    return trimmed.split('\\n').filter((l%%FILTER_TYPE%%) => l.trim().length > 0);
  try {
    const json = JSON.parse(trimmed);
    if (Array.isArray(json))
      return json.map((item) =>
        typeof item === 'string' ? item : `vmess://${btoa(JSON.stringify(item))}`);
  } catch {}
  return [];
}
"""


def normalize_ping(url):
    """Нормализует ping target — добавляет https:// если нет протокола."""
    url = url.strip()
    if not url.startswith("http"):
        url = f"https://{url}/"
    return url


def generate_worker(conf, *, typescript=False):
    """Генерирует worker код: JS для CF Workers, TS для Deno Deploy."""
    subs_lines = "\n".join(f"  '{s}'," for s in subs)
    pings_lines = "\n".join(f"  '{normalize_ping(p)}'," for p in pings)
    conf_escaped = conf.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")

    return (WORKER_TEMPLATE
        .replace("%%SUBS%%", subs_lines)
        .replace("%%PINGS%%", pings_lines)
        .replace("%%CONF%%", conf_escaped)
        .replace("%%ENTRY%%", DENO_ENTRY if typescript else CF_ENTRY)
        .replace("%%RAW_TYPE%%", ": string" if typescript else "")
        .replace("%%FILTER_TYPE%%", ": string" if typescript else ""))


# ─── Main ───

conf = generate_conf(warp)
CONF_PATH.write_text(conf)
print(f"✓ shadowrocket.conf ({len(warp_domains)} WARP-доменов)")

WORKER_DIR.mkdir(parents=True, exist_ok=True)

(WORKER_DIR / "worker.js").write_text(generate_worker(conf, typescript=False))
print(f"✓ worker.js ({len(subs)} подписок, {len(pings)} пинг-таргетов)")

(WORKER_DIR / "deno-worker.ts").write_text(generate_worker(conf, typescript=True))
print("✓ deno-worker.ts")
