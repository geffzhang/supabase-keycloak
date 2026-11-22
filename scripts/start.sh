#!/usr/bin/env bash
# 一键启动：Keycloak 先行（要拿 JWKS），再起 Supabase。
#
#   ./scripts/start.sh              # 方案 B（默认）
#   ./scripts/start.sh --plan-a     # 方案 A（GoTrue 换发 token）
#
# 顺序是硬依赖，不能并行：
#   1. Keycloak 必须健康，否则拿不到 JWKS
#   2. sync-jwks.sh 必须先把 JWKS 写进 .env，rest/storage/realtime 启动时才读到
#   3. 三个服务必须 --force-recreate，restart 不重读环境变量
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="b"
case "${1:-}" in
  --plan-a|plan-a|a) MODE="a" ;;
  --plan-b|plan-b|b|"") MODE="b" ;;
  *) echo "未知参数: $1（可用 --plan-a / --plan-b）" >&2; exit 2 ;;
esac

FILES=(-f docker-compose.yml)
if [ "$MODE" = "a" ]; then
  # 方案 A：只给 auth 加 Keycloak provider，不动 rest/storage/realtime
  FILES+=(-f docker-compose.supabase-auth.yml)
else
  # 方案 B：给三个验签方注入 JWKS
  FILES+=(-f docker-compose.supabase-thirdparty.yml)
fi
FILES+=(-f docker-compose.keycloak.yml)

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

env_get() {
  python - "$1" <<'PY'
import re, sys
try:
    text = open(".env", encoding="utf-8").read()
except FileNotFoundError:
    sys.exit(0)
m = re.search(r"^%s=(.*)$" % re.escape(sys.argv[1]), text, re.M)
if not m:
    sys.exit(0)
v = m.group(1).strip()
if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
    v = v[1:-1]
print(v)
PY
}

[ -f .env ] || die "找不到 .env，先跑 ./scripts/init-env.sh"
[ -f docker-compose.yml ] || die "找不到 docker-compose.yml（官方基线副本）"

step "1/6 校验 .env"
DUP=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env | sort | uniq -d || true)
if [ -n "$DUP" ]; then
  die "存在重复键（后者覆盖前者，可能让密钥变空）：$(echo $DUP | tr '\n' ' ')"
fi
KC_HOST=$(env_get KEYCLOAK_HOST)
[ -n "$KC_HOST" ] || die "KEYCLOAK_HOST 为空"
echo "  KEYCLOAK_HOST=$KC_HOST  MODE=方案 ${MODE^^}"

step "2/6 启动 Keycloak"
docker compose "${FILES[@]}" up -d keycloak-db keycloak

step "3/6 等待 Keycloak 就绪"
# /health/ready 在管理口 9000，不在 8080 —— 探 8080 永远 404
MGMT=$(env_get KEYCLOAK_MGMT_PORT); MGMT="${MGMT:-9000}"
./scripts/wait-keycloak.sh "http://localhost:${MGMT}/health/ready" 240 \
  || die "Keycloak 未能在 240 秒内就绪，查看: docker logs keycloak --tail 80"

if [ "$MODE" = "b" ]; then
  step "4/6 合并 JWKS 到 .env"
  ./scripts/sync-jwks.sh

  # compose 层用的是 ${KEYCLOAK_JWKS:-}（空默认值），因为 :? 会在解析阶段
  # 就报错，导致"先起 Keycloak 再取 JWKS"死锁。所以这道门必须在这里守着。
  JWKS_LEN=$(env_get KEYCLOAK_JWKS | wc -c)
  [ "$JWKS_LEN" -gt 50 ] || die "KEYCLOAK_JWKS 为空或过短（${JWKS_LEN} 字符），sync-jwks.sh 可能失败"
  echo "  KEYCLOAK_JWKS 长度 ${JWKS_LEN}，非空校验通过"
else
  step "4/6 方案 A：跳过 JWKS 合并（由 GoTrue 自行处理）"
fi

step "5/6 启动 Supabase"
# db 必须先单独起来并等健康：官方 healthcheck 是 5s×10（约 50 秒），
# 而首次初始化要跑几十个 init-script，实测 30 秒以上，慢机器会超时。
# 如果直接 `up -d` 全量，compose 会因为 depends_on 卡在 db unhealthy 上失败。
docker compose "${FILES[@]}" up -d db
printf '  waiting db '
# ⚠️ 不能一遇 unhealthy 就放弃。Postgres 首次初始化期间（跑几十个 init-script）
# healthcheck 会连续失败累积 FailingStreak，此时状态是 unhealthy，
# 但初始化完成后会自动转 healthy —— 实测这个窗口有 10~30 秒。
# 只有在"持续 unhealthy 且超过宽限"时才判定真失败。
db_ready=0; unhealthy_streak=0
for _ in $(seq 1 150); do
  cid=$(docker compose "${FILES[@]}" ps -q db 2>/dev/null | head -1)
  if [ -n "$cid" ]; then
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo none)
    case "$st" in
      healthy) echo " healthy"; db_ready=1; break ;;
      unhealthy)
        unhealthy_streak=$((unhealthy_streak+1))
        # 连续 40 次（约 80 秒）仍 unhealthy 才算真失败
        if [ "$unhealthy_streak" -ge 40 ]; then
          echo " 持续 unhealthy（${unhealthy_streak} 次）"
          die "  docker logs $cid --tail 60"
        fi
        printf '!' ;;
      *) unhealthy_streak=0; printf '.' ;;
    esac
  else
    printf '.'
  fi
  sleep 2
done
[ "$db_ready" = "1" ] || die " db 在 300 秒内未就绪"
docker compose "${FILES[@]}" up -d

step "6/6 等待关键服务健康"
for svc in rest storage realtime; do
  printf '  %-10s' "$svc"
  ok=0; streak=0
  for _ in $(seq 1 120); do
    cid=$(docker compose "${FILES[@]}" ps -q "$svc" 2>/dev/null | head -1)
    if [ -z "$cid" ]; then printf '.'; sleep 2; continue; fi
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo none)
    case "$st" in
      healthy) echo " healthy"; ok=1; break ;;
      running) echo " running"; ok=1; break ;;
      unhealthy)
        streak=$((streak+1))
        # 同上：启动期内 unhealthy 是正常的，连续 40 次（约 80 秒）才判失败
        if [ "$streak" -ge 40 ]; then
          echo " 持续 unhealthy"
          die "  docker logs $cid --tail 60"
        fi
        printf '!' ;;
      *) streak=0; printf '.' ;;
    esac
    sleep 2
  done
  [ "$ok" = "1" ] || die " $svc 在 240 秒内未就绪"
done

step "完成"
KC_URL="$(env_get KC_SCHEME)://${KC_HOST}"
cat <<EOF

  Supabase API   http://localhost:8000
  Studio         http://localhost:8000  (Basic Auth，密码见 .env 的 DASHBOARD_PASSWORD)
  Keycloak       ${KC_URL}
  realm          $(env_get KEYCLOAK_REALM)

  端到端验证:
    ./scripts/verify.sh ${MODE}

  查看日志:
    docker compose ${FILES[*]} logs -f rest
EOF
