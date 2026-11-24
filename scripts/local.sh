#!/usr/bin/env bash
# Runs the whole local stack from the workspace root (see LOCAL.md for what each part does and for the
# manual steps): Postgres + Redis + schema (docker), identity, gatekeeper, dictionary, optionally courier, and the
# web apps. Processes run in the background; pid files and logs live in .local/run.
#
#   scripts/local.sh up [backend|web]   start (default: everything), idempotent
#   scripts/local.sh down [web|backend|all]   stop all processes (default), only the web apps, only the
#                                       backend processes, or everything including the containers
#   scripts/local.sh status             what runs, with the URLs
#   scripts/local.sh logs [name]        follow a log (identity, gatekeeper, dictionary, courier, courier-worker, dict, bill, admin)
#   scripts/local.sh setup              (re)run identity-setup: first admin and the gateway client
#   scripts/local.sh reset              wipe Postgres/Redis volumes (asks first), the local keys and the card images
#
# Variables: SETUP_ADMIN_PASSWORD (default below), WITH_COURIER=1 to start courier and its worker,
# WITH_DICTIONARY=0 to skip the dictionary service (it is on by default). The card images of the dictionary
# are files in .local/images; DICTIONARY_IMAGE_MAX_BYTES, _MAX_DIM, _MAX_PIXELS and _USER_QUOTA exported before
# `up` reach the service (the defaults apply otherwise).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCAL=$ROOT/.local
RUN=$LOCAL/run
BIN=$LOCAL/bin
mkdir -p "$RUN" "$BIN"

ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
ADMIN_PASSWORD=${SETUP_ADMIN_PASSWORD:-Correct-Horse-Battery-9}
CLIENT_ID=gatekeeper-dev

# the variables every Go service reads (LOCAL.md step 1)
export ENV=local POSTGRES_HOST=localhost POSTGRES_DB=app POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres \
       POSTGRES_SSLMODE=disable REDIS_HOST=localhost

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

compose() { (cd "$ROOT/db-migration" && docker compose "$@"); }

alive() { [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }

# start_proc name dir command...: background process in its own process group, log in .local/run/<name>.log
start_proc() {
  local name=$1 dir=$2; shift 2
  if alive "$name"; then echo "  $name already running (pid $(cat "$RUN/$name.pid"))"; return; fi
  (
    cd "$dir"
    set -m
    nohup "$@" >"$RUN/$name.log" 2>&1 &
    echo $! >"$RUN/$name.pid"
  )
  echo "  $name started (pid $(cat "$RUN/$name.pid")), log .local/run/$name.log"
}

stop_proc() {
  local name=$1 pid
  alive "$name" || { rm -f "$RUN/$name.pid"; return 0; }
  pid=$(cat "$RUN/$name.pid")
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL -- "-$pid" 2>/dev/null || true
  rm -f "$RUN/$name.pid"
  echo "  $name stopped"
}

wait_http() { # url name seconds
  local url=$1 name=$2 secs=${3:-60}
  for _ in $(seq 1 $((secs * 5))); do
    curl -fs "$url" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "--- last lines of .local/run/$name.log" >&2
  tail -15 "$RUN/$name.log" >&2 2>/dev/null || true
  die "$name did not become ready ($url)"
}

port_free() { ! lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

check_port() { # port name
  if port_free "$1"; then return 0; fi
  alive "$2" && return 0
  die "port $1 is in use by another process (needed by $2): lsof -i :$1"
}

# ---------------------------------------------------------------- pieces

keys() {
  [ -f "$LOCAL/k1.pem" ] || { need openssl; openssl ecparam -name prime256v1 -genkey -noout -out "$LOCAL/k1.pem" 2>/dev/null; }
  [ -f "$LOCAL/mfa.key" ] || echo "k1:$(openssl rand -base64 32)" >"$LOCAL/mfa.key"
  [ -f "$LOCAL/session.key" ] || echo "k1:$(openssl rand -base64 32)" >"$LOCAL/session.key"
  [ -f "$LOCAL/gatekeeper.secret" ] || openssl rand -hex 16 >"$LOCAL/gatekeeper.secret"
  [ -f "$LOCAL/dictionary.secret" ] || openssl rand -hex 16 >"$LOCAL/dictionary.secret"
}

db() {
  need docker
  say "Postgres, Redis and the schema"
  compose up --build -d
  local i
  for i in $(seq 1 120); do
    if compose exec -T postgres psql -U postgres -d app -tAc "select 1 from identity_users limit 1" >/dev/null 2>&1; then
      echo "  schema ready"; return 0
    fi
    sleep 1
  done
  die "the schema is not ready after 120s: (cd db-migration && docker compose logs flyway)"
}

build() { # name dir pkg
  echo "  building $1"
  (cd "$2" && go build -o "$BIN/$1" "$3")
}

identity_env() {
  export IDENTITY_ISSUER=http://localhost:8080
  export IDENTITY_SIGNING_KEY_FILE=$LOCAL/k1.pem IDENTITY_SIGNING_KEY_ID=k1
  IDENTITY_MFA_KEY=$(cat "$LOCAL/mfa.key"); export IDENTITY_MFA_KEY
  if [ "${WITH_COURIER:-0}" = 1 ]; then export COURIER_TARGET=localhost:9091; fi
}

setup() {
  need go
  keys
  identity_env
  say "identity-setup (first admin, gateway client, exchange policy)"
  build identity-setup "$ROOT/identity" ./cmd/identity-setup
  GATEKEEPER_CLIENT_SECRET=$(cat "$LOCAL/gatekeeper.secret") \
  DICTIONARY_CLIENT_SECRET=$(cat "$LOCAL/dictionary.secret") \
  SETUP_ADMIN_PASSWORD=$ADMIN_PASSWORD \
  SETUP_CONFIG='{"admin":{"email":"'"$ADMIN_EMAIL"'","keep_password":true},
    "clients":[{"id":"'"$CLIENT_ID"'","type":"confidential","resource":"gatekeeper","secret_env":"GATEKEEPER_CLIENT_SECRET",
      "redirect_uris":["http://localhost:8081/auth/callback"],
      "post_logout_uris":["http://localhost:3000/","http://localhost:3001/","http://localhost:3002/"],
      "grants":["authorization_code","refresh_token","client_credentials","urn:ietf:params:oauth:grant-type:token-exchange"]},
      {"id":"dictionary-dev","type":"confidential","resource":"dictionary","secret_env":"DICTIONARY_CLIENT_SECRET",
      "grants":["client_credentials","urn:ietf:params:oauth:grant-type:token-exchange"]}],
    "exchange_policies":[{"client":"'"$CLIENT_ID"'","audience":"identity","max_depth":1},
      {"client":"'"$CLIENT_ID"'","audience":"dictionary","max_depth":1},
      {"client":"dictionary-dev","audience":"identity","max_depth":2}]}' \
  "$BIN/identity-setup"
}

identity() {
  keys; identity_env
  check_port 8080 identity
  say "identity (http://localhost:8080, gRPC 9090)"
  # the sign in pages are the app web/apps/auth; identity serves its build (in the image: the auth-ui image)
  need pnpm
  echo "  building the sign in app (web/apps/auth)"
  if [ ! -d "$ROOT/web/node_modules" ]; then
    (cd "$ROOT/web" && { corepack enable >/dev/null 2>&1 || true; } && pnpm install >/dev/null)
  fi
  (cd "$ROOT/web" && pnpm --filter @huponx/auth build >/dev/null) || die "the sign in app did not build: (cd web && pnpm --filter @huponx/auth build)"
  export IDENTITY_UI_DIR="$ROOT/web/apps/auth/dist"
  # listed on /apps, where a sign in at identity itself (no application sent the user) ends
  export IDENTITY_APPS="Admin Portal=http://localhost:3002|http://localhost:3002/logo.svg,Dict=http://localhost:3000|http://localhost:3000/logo.svg,Bill=http://localhost:3001"
  build identity "$ROOT/identity" ./cmd/identity
  start_proc identity "$ROOT/identity" "$BIN/identity"
  wait_http http://localhost:8080/healthz identity
}

gatekeeper() {
  keys
  check_port 8081 gatekeeper
  say "gatekeeper (http://localhost:8081)"
  build gatekeeper "$ROOT/gatekeeper" ./cmd/gatekeeper
  "$ROOT/gatekeeper/scripts/routes.sh" localhost:9090 localhost:9092 >"$RUN/routes.yaml"
  start_proc gatekeeper "$ROOT/gatekeeper" env \
    PORT=8081 \
    GATEKEEPER_PUBLIC_URL=http://localhost:8081 \
    GATEKEEPER_UI_ORIGINS="http://localhost:3000,http://localhost:3001,http://localhost:3002" \
    GATEKEEPER_ROUTES_FILE="$RUN/routes.yaml" \
    GATEKEEPER_IDENTITY_ISSUER=http://localhost:8080 \
    GATEKEEPER_CLIENT_ID=$CLIENT_ID GATEKEEPER_CLIENT_SECRET="$(cat "$LOCAL/gatekeeper.secret")" \
    GATEKEEPER_AUDIENCE=gatekeeper \
    GATEKEEPER_SESSION_KEY="$(cat "$LOCAL/session.key")" \
    "$BIN/gatekeeper"
  wait_http http://localhost:8081/healthz gatekeeper
}

dictionary() {
  check_port 9092 dictionary
  say "dictionary (gRPC 9092)"
  build dictionary "$ROOT/dictionary" ./cmd/dictionary
  mkdir -p "$LOCAL/images"
  start_proc dictionary "$ROOT/dictionary" env PORT=9092 DICTIONARY_IMAGE_DIR="$LOCAL/images" \
    DICTIONARY_ISSUER=http://localhost:8080 DICTIONARY_JWKS_URL=http://localhost:8080/.well-known/jwks.json \
    DICTIONARY_IDENTITY_ADDR=localhost:9090 DICTIONARY_TOKEN_URL=http://localhost:8080/oauth2/token \
    DICTIONARY_CLIENT_ID=dictionary-dev DICTIONARY_CLIENT_SECRET="$(cat "$LOCAL/dictionary.secret")" \
    "$BIN/dictionary"
  local i
  for i in $(seq 1 50); do
    port_free 9092 || return 0
    alive dictionary || break
    sleep 0.2
  done
  echo "--- last lines of .local/run/dictionary.log" >&2
  tail -15 "$RUN/dictionary.log" >&2 2>/dev/null || true
  die "dictionary did not start listening on :9092"
}

courier() {
  check_port 9091 courier
  say "courier (gRPC 9091) and worker (health 8082)"
  build courier "$ROOT/courier" ./cmd/courier
  build courier-worker "$ROOT/courier" ./cmd/worker
  start_proc courier "$ROOT/courier" env PORT=9091 "$BIN/courier"
  start_proc courier-worker "$ROOT/courier" env HEALTH_ADDR=:8082 \
    SMTP_HOST="${SMTP_HOST:-localhost}" SMTP_PORT="${SMTP_PORT:-1025}" SMTP_FROM="${SMTP_FROM:-noreply@example.com}" \
    "$BIN/courier-worker"
}

web() {
  need pnpm
  say "web apps (dict :3000, bill :3001, admin :3002)"
  if [ ! -d "$ROOT/web/node_modules" ]; then
    (cd "$ROOT/web" && corepack enable >/dev/null 2>&1 || true; cd "$ROOT/web" && pnpm install)
  fi
  local app port
  for pair in dict:3000 bill:3001 admin:3002; do
    app=${pair%%:*}; port=${pair##*:}
    check_port "$port" "$app"
    start_proc "$app" "$ROOT/web" pnpm "dev:$app"
  done
  for pair in dict:3000 bill:3001 admin:3002; do
    wait_http "http://localhost:${pair##*:}/" "${pair%%:*}" 90
  done
}

# ---------------------------------------------------------------- commands

cmd_up() {
  local what=${1:-all}
  case "$what" in
    all|backend)
      need go
      keys
      db
      setup
      identity
      gatekeeper
      if [ "${WITH_DICTIONARY:-1}" = 1 ]; then dictionary; fi
      if [ "${WITH_COURIER:-0}" = 1 ]; then courier; fi
      ;;
  esac
  case "$what" in
    all|web) web ;;
    backend) ;;
    *) die "usage: up [backend|web]" ;;
  esac
  echo
  cmd_status
  echo
  echo "Open http://localhost:3002 and sign in as $ADMIN_EMAIL (password: SETUP_ADMIN_PASSWORD, default in scripts/local.sh)."
}

cmd_down() {
  local what=${1:-processes} names
  case "$what" in
    processes|all) names="admin bill dict courier-worker courier dictionary gatekeeper identity" ;;
    web)           names="admin bill dict" ;;
    backend)       names="courier-worker courier dictionary gatekeeper identity" ;;
    *) die "usage: down [web|backend|all]" ;;
  esac
  say "stopping"
  for n in $names; do stop_proc "$n"; done
  if [ "$what" = all ]; then compose down; fi
}

cmd_status() {
  printf '%-16s %-8s %s\n' NAME STATE URL
  local n url
  for e in identity:http://localhost:8080 gatekeeper:http://localhost:8081 dictionary:localhost:9092 courier:localhost:9091 \
           courier-worker:http://localhost:8082 dict:http://localhost:3000 bill:http://localhost:3001 admin:http://localhost:3002; do
    n=${e%%:*}; url=${e#*:}
    if alive "$n"; then printf '%-16s %-8s %s\n' "$n" running "$url"; else printf '%-16s %-8s\n' "$n" stopped; fi
  done
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q postgres; then echo "postgres/redis    running  (docker, db-migration)"; else echo "postgres/redis    stopped  (scripts/local.sh up)"; fi
}

cmd_logs() {
  if [ $# -eq 0 ]; then tail -n 20 -f "$RUN"/*.log; else tail -n 50 -f "$RUN/$1.log"; fi
}

cmd_reset() {
  read -r -p "Delete Postgres and Redis data, the local keys and the card images (.local/images) in .local? [y/N] " a
  [ "$a" = y ] || exit 0
  cmd_down
  compose down -v
  rm -rf "$LOCAL/images"
  rm -f "$LOCAL"/k1.pem "$LOCAL"/mfa.key "$LOCAL"/session.key "$LOCAL"/gatekeeper.secret
  echo "reset done; run: scripts/local.sh up"
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  down)   shift; cmd_down "$@" ;;
  status) cmd_status ;;
  logs)   shift; cmd_logs "$@" ;;
  setup)  db; setup ;;
  db)     db ;;
  reset)  cmd_reset ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
