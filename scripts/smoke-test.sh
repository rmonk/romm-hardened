#!/usr/bin/env bash
# Start the image with MariaDB and check that:
#   * migrations run and the app, nginx (with mod_zip and njs) and valkey come up
#   * the first admin can be created (CSRF flow, email validation via dnspython)
#   * OAuth2 password login works and the token reads /api/users/me
#   * the raised Python packages are in place, pip is gone, deps are consistent
#   * upstream's ScreenScraper developer credentials are still set (not printed)
#   * a restart with the same volumes keeps the user
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs curl + jq)
set -euo pipefail

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
name="romm-smoke-$$"
db="$name-db"
net="$name-net"
port="${SMOKE_PORT:-18580}"
base="http://127.0.0.1:$port"
mariadb_image="${SMOKE_MARIADB_IMAGE:-docker.io/library/mariadb:11.8}"
jar="$(mktemp)"
dbpass="smoke-$RANDOM$RANDOM"
secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
user=smokeadmin
pass="Smoke-pass-$RANDOM-$RANDOM"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then echo "--- romm logs ---"; $docker logs --tail 80 "$name" 2>&1 || true; fi
  $docker rm -f "$name" "$db" >/dev/null 2>&1 || true
  $docker volume rm -f "$name-db" "$name-romm" "$name-redis" >/dev/null 2>&1 || true
  $docker network rm "$net" >/dev/null 2>&1 || true
  rm -f "$jar"
  exit $rc
}
trap cleanup EXIT

fail() { echo "smoke: FAIL $*"; exit 1; }

$docker network create "$net" >/dev/null
$docker run -d --name "$db" --network "$net" -v "$name-db:/var/lib/mysql" \
  -e MARIADB_ROOT_PASSWORD="$dbpass" -e MARIADB_DATABASE=romm \
  -e MARIADB_USER=romm-user -e MARIADB_PASSWORD="$dbpass" "$mariadb_image" >/dev/null
echo "smoke: waiting for MariaDB"
for _ in $(seq 60); do
  $docker exec "$db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
  sleep 2
done
$docker exec "$db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 || fail "MariaDB not ready"

start() {
  $docker run -d --name "$name" --network "$net" -p "127.0.0.1:$port:8080" \
    -v "$name-romm:/romm" -v "$name-redis:/redis-data" \
    -e DB_HOST="$db" -e DB_NAME=romm -e DB_USER=romm-user -e DB_PASSWD="$dbpass" \
    -e ROMM_AUTH_SECRET_KEY="$secret" "$image" >/dev/null
  echo "smoke: waiting for romm"
  for _ in $(seq 90); do
    curl -sf -o /dev/null "$base/api/heartbeat" && return 0
    [ "$($docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "container exited"
    sleep 2
  done
  fail "romm not answering on /api/heartbeat"
}

token() {
  curl -sS -X POST "$base/api/token" \
    --data-urlencode grant_type=password --data-urlencode "username=$user" \
    --data-urlencode "password=$pass" --data-urlencode scope=me.read \
    | jq -r '.access_token // empty'
}

start
hb="$(curl -sS -c "$jar" "$base/api/heartbeat")"
version="$(jq -r .SYSTEM.VERSION <<<"$hb")"
[ "$(jq -r .SYSTEM.SHOW_SETUP_WIZARD <<<"$hb")" = true ] || fail "fresh database but no setup wizard"
curl -sf -o /dev/null "$base/" || fail "frontend not served by nginx"
echo "smoke: romm $version up, frontend served"

csrf="$(awk '$6=="romm_csrftoken"{print $7}' "$jar")"
[ -n "$csrf" ] || fail "no CSRF cookie from heartbeat"
code="$(curl -sS -o /tmp/smoke-user-$$.json -w '%{http_code}' -b "$jar" -H "x-csrftoken: $csrf" \
  -H 'Content-Type: application/json' -X POST "$base/api/users" \
  -d "$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p,email:"smoke@example.com",role:"admin"}')")"
[ "$code" = 201 ] || { cat /tmp/smoke-user-$$.json; rm -f /tmp/smoke-user-$$.json; fail "creating admin returned HTTP $code"; }
rm -f /tmp/smoke-user-$$.json
tok="$(token)"; [ -n "$tok" ] || fail "password login returned no token"
me="$(curl -sS -H "Authorization: Bearer $tok" "$base/api/users/me" | jq -r .username)"
[ "$me" = "$user" ] || fail "/api/users/me returned '$me'"
echo "smoke: admin created, token login OK"

$docker exec "$name" sh -eu -c '
  nginx -t 2>&1 | grep -q "test is successful"
  nginx -T 2>/dev/null | grep -qE "^load_module modules/ngx_http_zip_module.so;"
  valkey-cli ping | grep -q PONG
  if command -v pip >/dev/null 2>&1 || python3 -m pip --version >/dev/null 2>&1; then echo "pip still present"; exit 1; fi
  for b in RAHasher rom-converto 7z node bsdtar; do command -v "$b" >/dev/null; done
  test -n "${SCREENSCRAPER_DEV_ID:-}" && test -n "${SCREENSCRAPER_DEV_PASSWORD:-}"
  python - <<EOF
from importlib.metadata import version
import authlib.integrations.starlette_client, authlib.oidc.discovery, dns.resolver, oauthlib, requests_oauthlib, apprise, email_validator
print("; ".join(f"{p} {version(p)}" for p in ("authlib", "dnspython", "oauthlib")))
EOF
  nginx -v 2>&1
'
logs="$($docker logs "$name" 2>&1)"
grep -q 'Traceback' <<<"$logs" && fail "traceback in logs"
echo "smoke: nginx + mod_zip, valkey, tools, packages OK; pip gone; ScreenScraper dev creds present"

$docker rm -f "$name" >/dev/null
start
tok="$(token)"; [ -n "$tok" ] || fail "login after restart"
grep -q 'Traceback' <<<"$($docker logs "$name" 2>&1)" && fail "traceback after restart"
echo "smoke: restart with same volumes OK"
# The image's HEALTHCHECK must exist and pass. (podman keeps it only in Docker-format images:
# build with `--format docker`; CI pushes Docker v2 manifests for the same reason.)
hc="$($docker image inspect --format '{{json .Config.Healthcheck}}' "$image" \
  | jq -r '.Test // empty | if .[0] == "CMD-SHELL" then ["sh", "-c", .[1]] else .[1:] end | @sh')"
[ -n "$hc" ] || { echo "smoke: FAIL the image has no health check"; exit 1; }
eval "$docker exec \"$name\" $hc" >/dev/null || { echo "smoke: FAIL the image's health check fails"; exit 1; }
echo "smoke: image health check passes"
echo "smoke: PASS"
