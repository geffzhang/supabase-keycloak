#!/usr/bin/env bash
# 方案 B 专用：把 Keycloak 的签名公钥 与 Supabase 原有的 legacy 对称密钥
# 合并成一个 JWKS，写进 .env 的 KEYCLOAK_JWKS。
#
# ── 为什么必须"合并"而不是"替换" ────────────────────────────────
# supabase-js 每个请求都带两个头：
#   apikey: <ANON_KEY>            ← HS256 JWT，用 JWT_SECRET 签的
#   Authorization: Bearer <token> ← 用户 token
# 如果把 PGRST_JWT_SECRET 整个换成 Keycloak 的 JWKS，PostgREST / Storage /
# Realtime 就再也验不过 anon / service_role 这两把 HS256 密钥了 ——
# 未登录请求 401、Dashboard 打不开、后端 service_role 全废。
# 表现出来很像"Keycloak 配错了"，实际是把自家的后门钥匙丢了。
#
# 正确做法（Supabase 官方切非对称密钥时也是这么做的）：JWKS 里同时放
#   - Keycloak 的 RS256/ES256 公钥（验用户 token）
#   - JWT_SECRET 转成的 oct JWK（验 anon / service_role）
#
# 用法:
#   ./sync-jwks.sh                     # JWT_SECRET 从 .env 读
#   JWKS_URL=http://127.0.0.1:8080/realms/supabase/protocol/openid-connect/certs ./sync-jwks.sh
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
REALM="${KEYCLOAK_REALM:-supabase}"

if [ -n "${JWKS_URL:-}" ]; then
  :
else
  : "${KEYCLOAK_HOST:?set KEYCLOAK_HOST 或直接给 JWKS_URL}"
  JWKS_URL="https://${KEYCLOAK_HOST}/realms/${REALM}/protocol/openid-connect/certs"
fi

echo "fetching ${JWKS_URL}"
RAW=$(curl -fsS --max-time 10 "$JWKS_URL")

# 先校验 Keycloak 侧满足 Supabase 第三方认证的硬要求
printf '%s' "$RAW" | python -c '
import json, sys
keys = json.load(sys.stdin).get("keys") or []
if not keys:
    sys.exit("JWKS 为空：检查 realm 名是否正确，以及 JWKS_URL 是否可达")
bad = [k for k in keys if k.get("alg") == "HS256" or not k.get("kid")]
if bad:
    sys.exit("存在 HS256 或缺 kid 的密钥，Supabase 第三方认证不支持（在 Keycloak realm keys 里换 RS256/ES256）")
print("keycloak kid: " + ", ".join(k["kid"][:8] + "/" + k.get("alg", "?") for k in keys))
'

# JWT_SECRET 缺了不许继续：没有它 anon / service_role 会全部 401
if [ -z "${JWT_SECRET:-}" ]; then
  JWT_SECRET=$(python - "$ENV_FILE" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    sys.exit(0)
m = re.search(r"^JWT_SECRET=(.*)$", text, re.M)
if not m:
    sys.exit(0)
v = m.group(1).strip()
if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
    v = v[1:-1]
print(v)
PY
)
fi

if [ -z "${JWT_SECRET:-}" ]; then
  echo "错误：取不到 JWT_SECRET（.env 里没有或为空）。" >&2
  echo "   没有它就无法把 anon/service_role 的对称密钥并入 JWKS，" >&2
  echo "   强行替换会让未登录请求和 Dashboard 全部 401。" >&2
  exit 1
fi

RAW="$RAW" JWT_SECRET="$JWT_SECRET" ENV_FILE="$ENV_FILE" python - <<'PY'
import base64, json, os, re, sys

env_file = os.environ["ENV_FILE"]
kc = json.loads(os.environ["RAW"])
secret = os.environ["JWT_SECRET"]

# RFC 7517 oct 密钥：k 是原始密钥字节的 base64url（无填充）
k = base64.urlsafe_b64encode(secret.encode("utf-8")).decode().rstrip("=")
legacy = {"kty": "oct", "k": k, "alg": "HS256"}

# 幂等：重跑时不能把上次写的 oct 密钥重复堆进去
merged = [key for key in (kc.get("keys") or []) if key.get("kty") != "oct"]
merged.append(legacy)

jwks = json.dumps({"keys": merged}, separators=(",", ":"))
if "'" in jwks:
    sys.exit("JWKS 里含单引号，无法安全写入 .env")

line = "KEYCLOAK_JWKS='" + jwks + "'"
try:
    with open(env_file, encoding="utf-8") as f:
        content = f.read()
except FileNotFoundError:
    content = ""

pattern = re.compile(r"^KEYCLOAK_JWKS=.*$", re.M)
if pattern.search(content):
    content = pattern.sub(lambda _: line, content)
else:
    if content and not content.endswith("\n"):
        content += "\n"
    content += line + "\n"

tmp = env_file + ".tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as f:
    f.write(content)
os.replace(tmp, env_file)

print("merged: %d 个 Keycloak 公钥 + 1 个 legacy HS256" % (len(merged) - 1))
print("kty: " + ", ".join(key.get("kty", "?") for key in merged))
PY

echo "现在必须重建三个服务才能生效（restart 不重读环境变量）:"
echo "  docker compose -f docker-compose.yml -f docker-compose.supabase-thirdparty.yml up -d --force-recreate rest storage realtime"
