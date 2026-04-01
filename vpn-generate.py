#!/usr/bin/env python3
"""Генерирует worker.js и shadowrocket.conf из vpn-config.json
   + обновляет WARP-ключи через wgcf при каждом деплое"""

import json
import subprocess
import tempfile
import os
from pathlib import Path

script_dir = Path(__file__).parent
config_path = script_dir / "vpn-config.json"
conf_path = script_dir / "shadowrocket.conf"
worker_path = script_dir / "worker" / "worker.js"

config = json.load(open(config_path))

worker_url = config.get("worker_url", "")
subs = config["subscriptions"]
pings = config["ping_targets"]
warp_domains = config.get("warp_domains", [])

if not worker_url:
    print("✗ worker_url не задан в vpn-config.json. Запусти ./install.sh")
    exit(1)


# ─── WARP: регенерация ключей ───

def refresh_warp():
    with tempfile.TemporaryDirectory() as tmpdir:
        subprocess.run(
            ["wgcf", "register", "--accept-tos"],
            cwd=tmpdir, capture_output=True, text=True,
        )
        subprocess.run(
            ["wgcf", "generate"],
            cwd=tmpdir, capture_output=True, text=True,
        )
        profile = Path(tmpdir) / "wgcf-profile.conf"
        if not profile.exists():
            return None
        return parse_wg_profile(profile.read_text())


def parse_wg_profile(text):
    result = {}
    for line in text.strip().splitlines():
        line = line.strip()
        if "=" not in line or line.startswith("["):
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()
        if key == "PrivateKey":
            result["private_key"] = val
        elif key == "Address":
            for p in [x.strip() for x in val.split(",")]:
                if ":" in p:
                    result["ipv6"] = p
                else:
                    result["ipv4"] = p
        elif key == "PublicKey":
            result["public_key"] = val
        elif key == "Endpoint":
            result["endpoint"] = val
        elif key == "MTU":
            result["mtu"] = val
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
    json.dump(config, open(config_path, "w"), indent=2, ensure_ascii=False)


# ─── Генерация shadowrocket.conf ───

def generate_conf(warp_params):
    warp_line = ""
    if warp_params:
        warp_line = (
            f'⚠️ WARP (не трогать) = wireguard, self-ip={warp_params["ipv4"].split("/")[0]}, '
            f'self-ip-v6={warp_params["ipv6"].split("/")[0]}, '
            f'private-key={warp_params["private_key"]}, '
            f'mtu={warp_params.get("mtu", "1280")}, dns=1.1.1.1, '
            f'peer=(public-key={warp_params["public_key"]}, '
            f'allowed-ips="0.0.0.0/0, ::/0", '
            f'endpoint={warp_params["endpoint"]}, keepalive=45)'
        )

    warp_rules = ""
    if warp_domains and warp_params:
        warp_rules = "\n".join(f"DOMAIN-SUFFIX,{d},WARP-CHAIN" for d in warp_domains)

    conf = f"""\
# Shadowrocket VPN Config — auto-select, split routing, ad block, WARP
# Auto-generated — правь vpn-config.json + ./vpn
# Updated: {subprocess.check_output(["date", "+%Y-%m-%d %H:%M"]).decode().strip()}

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
IP-CIDR,91.108.0.0/16,WARP-CHAIN,no-resolve
IP-CIDR,149.154.160.0/20,WARP-CHAIN,no-resolve
IP-CIDR,185.76.151.0/24,WARP-CHAIN,no-resolve
IP-CIDR6,2001:67c:4e8::/48,WARP-CHAIN,no-resolve
IP-CIDR6,2001:b28:f23d::/48,WARP-CHAIN,no-resolve
IP-CIDR6,2001:b28:f23f::/48,WARP-CHAIN,no-resolve
IP-CIDR6,2a0a:f280::/32,WARP-CHAIN,no-resolve

# ═══ AI ═══
DOMAIN-SUFFIX,claude.ai,PROXY
DOMAIN-SUFFIX,anthropic.com,PROXY
DOMAIN-SUFFIX,api.anthropic.com,PROXY
DOMAIN-SUFFIX,copilot.github.com,PROXY
DOMAIN-SUFFIX,githubcopilot.com,PROXY
DOMAIN-SUFFIX,perplexity.ai,PROXY
DOMAIN-SUFFIX,midjourney.com,PROXY

# ═══ Мессенджеры ═══
DOMAIN-SUFFIX,discord.com,PROXY
DOMAIN-SUFFIX,discord.gg,PROXY
DOMAIN-SUFFIX,discordapp.com,PROXY
DOMAIN-SUFFIX,discordapp.net,PROXY
DOMAIN-SUFFIX,discord.media,PROXY
DOMAIN-SUFFIX,whatsapp.com,PROXY
DOMAIN-SUFFIX,whatsapp.net,PROXY
DOMAIN-SUFFIX,signal.org,PROXY

# ═══ Видеозвонки ═══
DOMAIN-SUFFIX,meet.google.com,PROXY
DOMAIN-SUFFIX,meet.googleapis.com,PROXY
DOMAIN-SUFFIX,zoom.us,PROXY
DOMAIN-SUFFIX,zoom.com,PROXY

# ═══ Соцсети ═══
DOMAIN-SUFFIX,instagram.com,PROXY
DOMAIN-SUFFIX,cdninstagram.com,PROXY
DOMAIN-SUFFIX,ig.me,PROXY
DOMAIN-SUFFIX,facebook.com,PROXY
DOMAIN-SUFFIX,fbcdn.net,PROXY
DOMAIN-SUFFIX,fb.com,PROXY
DOMAIN-SUFFIX,twitter.com,PROXY
DOMAIN-SUFFIX,x.com,PROXY
DOMAIN-SUFFIX,twimg.com,PROXY
DOMAIN-SUFFIX,t.co,PROXY
DOMAIN-SUFFIX,linkedin.com,PROXY
DOMAIN-SUFFIX,licdn.com,PROXY
DOMAIN-SUFFIX,threads.net,PROXY
DOMAIN-SUFFIX,reddit.com,PROXY
DOMAIN-SUFFIX,redd.it,PROXY
DOMAIN-SUFFIX,redditmedia.com,PROXY

# ═══ Стриминг ═══
DOMAIN-SUFFIX,youtube.com,PROXY
DOMAIN-SUFFIX,youtu.be,PROXY
DOMAIN-SUFFIX,googlevideo.com,PROXY
DOMAIN-SUFFIX,ytimg.com,PROXY
DOMAIN-SUFFIX,youtube-nocookie.com,PROXY
DOMAIN-SUFFIX,spotify.com,PROXY
DOMAIN-SUFFIX,scdn.co,PROXY
DOMAIN-SUFFIX,twitch.tv,PROXY
DOMAIN-SUFFIX,soundcloud.com,PROXY

# ═══ Разработка ═══
DOMAIN-SUFFIX,github.com,PROXY
DOMAIN-SUFFIX,github.io,PROXY
DOMAIN-SUFFIX,githubusercontent.com,PROXY
DOMAIN-SUFFIX,githubassets.com,PROXY
DOMAIN-SUFFIX,npmjs.com,PROXY
DOMAIN-SUFFIX,docker.com,PROXY
DOMAIN-SUFFIX,docker.io,PROXY
DOMAIN-SUFFIX,notion.so,PROXY
DOMAIN-SUFFIX,figma.com,PROXY

# ═══ Google ═══
DOMAIN-SUFFIX,google.com,PROXY
DOMAIN-SUFFIX,googleapis.com,PROXY
DOMAIN-SUFFIX,googlesyndication.com,REJECT
DOMAIN-SUFFIX,googleadservices.com,REJECT
DOMAIN-SUFFIX,doubleclick.net,REJECT
DOMAIN-SUFFIX,gstatic.com,PROXY
DOMAIN-SUFFIX,googleusercontent.com,PROXY

# ═══ Прочее ═══
DOMAIN-SUFFIX,medium.com,PROXY
DOMAIN-SUFFIX,archive.org,PROXY
DOMAIN-SUFFIX,workers.dev,PROXY
DOMAIN-SUFFIX,pages.dev,PROXY

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
    return conf


conf = generate_conf(warp)
conf_path.write_text(conf)
print(f"✓ shadowrocket.conf ({len(warp_domains)} WARP-доменов)")


# ─── Генерация worker.js ───

subs_lines = "\n".join(f"  '{s}'," for s in subs)
pings_lines = "\n".join(f"  '{s}'," for s in pings)
conf_escaped = conf.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")

worker = f"""\
// Auto-generated by vpn manager

const SUBSCRIPTIONS = [
{subs_lines}
];

const PING_TARGETS = [
{pings_lines}
];

const SHADOWROCKET_CONF = `{conf_escaped}`;

export default {{
  async fetch(request) {{
    const url = new URL(request.url);
    if (url.pathname === '/sub' || url.pathname === '/') return handleMerge();
    if (url.pathname === '/ping') return handlePing();
    if (url.pathname === '/conf') return handleConf();
    return new Response('Not found', {{ status: 404 }});
  }},
}};

function handleConf() {{
  return new Response(SHADOWROCKET_CONF, {{
    headers: {{
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache',
    }},
  }});
}}

async function handlePing() {{
  const results = await Promise.allSettled(
    PING_TARGETS.map(async (url) => {{
      const res = await fetch(url, {{
        method: 'GET',
        redirect: 'follow',
        headers: {{ 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }},
        signal: AbortSignal.timeout(5000),
      }});
      return res.status;
    }}),
  );
  const allReachable = results.every((r) => r.status === 'fulfilled');
  if (allReachable) return new Response(null, {{ status: 204 }});
  return new Response('Service unreachable', {{ status: 502 }});
}}

async function handleMerge() {{
  const allNodes = [];
  const results = await Promise.allSettled(
    SUBSCRIPTIONS.map(async (subUrl) => {{
      const res = await fetch(subUrl, {{
        headers: {{
          'User-Agent': 'Shadowrocket/2070 CFNetwork/1568.100.1',
          'Accept-Encoding': 'identity',
        }},
        redirect: 'follow',
      }});
      if (!res.ok) return [];
      const text = await res.text();
      if (!text || text.trim().length === 0) return [];
      return decodeSubscription(text);
    }}),
  );
  for (const result of results) {{
    if (result.status === 'fulfilled') allNodes.push(...result.value);
  }}
  const unique = [...new Set(allNodes)].filter((l) => l.trim().length > 0);
  const merged = btoa(unique.join('\\n'));
  return new Response(merged, {{
    headers: {{
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache',
      'Subscription-Userinfo': `total=${{unique.length}}`,
      'Profile-Update-Interval': '6',
    }},
  }});
}}

function decodeSubscription(raw) {{
  const trimmed = raw.trim();
  try {{
    const decoded = atob(trimmed);
    if (/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\\/\\//m.test(decoded))
      return decoded.split('\\n').filter((l) => l.trim().length > 0);
  }} catch {{}}
  if (/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\\/\\//m.test(trimmed))
    return trimmed.split('\\n').filter((l) => l.trim().length > 0);
  try {{
    const json = JSON.parse(trimmed);
    if (Array.isArray(json))
      return json.map((item) =>
        typeof item === 'string' ? item : `vmess://${{btoa(JSON.stringify(item))}}`);
  }} catch {{}}
  return [];
}}
"""

worker_path.parent.mkdir(parents=True, exist_ok=True)
worker_path.write_text(worker)
print(f"✓ worker.js ({len(subs)} подписок, {len(pings)} пинг-таргетов)")
