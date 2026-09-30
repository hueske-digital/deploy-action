#!/bin/bash
# Runs deploy.mjs against a real adnanh/webhook with the deploy hook of a
# stack "demo": the right secret is taken (202 and the marker), a wrong
# one, an unknown hook, plain http to another host and a short secret are
# refused. With health-url it waits for a local page that tells the
# version: ready at once, after a change, never (the timeout), and a
# mistake in the health inputs is refused before the hook is called.
# Needs docker and node.
set -euo pipefail
cd "$(dirname "$0")/.."

image=docker.io/almir/webhook:2.8.3@sha256:f77cc91c91d1527b48052280af38b50791e842ad8dd291e9b360a0c13c9ca991
work=$(mktemp -d)
chmod 0755 "$work"
secret=$(openssl rand -hex 32)
awk -v s="$secret" '{ sub(/SECRET/, s); print }' test/hooks.yaml > "$work/hooks.yaml"
chmod 0644 "$work/hooks.yaml"
docker rm -f deploy-action-test > /dev/null 2>&1 || true
docker run -d --name deploy-action-test -p 127.0.0.1:9000:9000 \
  -v "$work/hooks.yaml:/etc/webhook/hooks.yaml:ro" "$image" \
  -hooks /etc/webhook/hooks.yaml -port 9000 -verbose > /dev/null
# The stack's page: 200 with the file's content, or its status when the
# file holds a number only.
cat > "$work/health.mjs" <<'JS'
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
createServer((_, res) => {
  const body = readFileSync(process.argv[2], "utf8").trim();
  if (/^[0-9]{3}$/.test(body)) { res.writeHead(Number(body)); res.end("error page"); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(body);
}).listen(9001, "127.0.0.1");
JS
page=$work/health.json
echo '{"status":"ok","commit":"0000000"}' > "$page"
node "$work/health.mjs" "$page" & health_pid=$!
trap 'kill "$health_pid" 2> /dev/null; wait "$health_pid" 2> /dev/null || true; docker rm -f deploy-action-test > /dev/null; rm -rf "$work"' EXIT
for _ in $(seq 20); do
  curl -s -o /dev/null http://127.0.0.1:9000/ && break
  sleep 0.5
done

failed=0
expect() {
  local want=$1 name=$2 host=$3 stack=$4 key=$5 got=0
  INPUT_HOST=$host INPUT_STACK=$stack INPUT_SECRET=$key node deploy.mjs < /dev/null || got=$?
  if { [ "$want" = ok ] && [ "$got" -ne 0 ]; } || { [ "$want" = fail ] && [ "$got" -eq 0 ]; }; then
    echo "FAILED: $name"
    failed=1
  else
    echo "ok: $name"
  fi
}
host=localhost:9000
expect ok "right secret" "$host" demo "$secret"
docker exec deploy-action-test test -e /tmp/deploy-demo || { echo "FAILED: no marker"; failed=1; }
expect ok "127.0.0.1" 127.0.0.1:9000 demo "$secret"
expect fail "wrong secret" "$host" demo "$(openssl rand -hex 32)"
expect fail "host with a login" "user@$host" demo "$secret"
expect fail "port out of range" localhost:99999 demo "$secret"
expect fail "unknown stack" "$host" other "$secret"
expect fail "host with a scheme" "http://$host" demo "$secret"
expect fail "host with a path" "$host/hooks" demo "$secret"
expect fail "stack in capitals" "$host" Demo "$secret"
expect fail "stack with a path" "$host" "demo/../apply" "$secret"
expect fail "short secret" "$host" demo abc

# health-url and health-json; the run's commit is GITHUB_SHA.
export GITHUB_SHA=abcdef1234567890abcdef1234567890abcdef12
health=http://127.0.0.1:9001/api/health
json='{"status": "ok", "commit": "{commit}"}'
# Inputs with a dash reach the action as INPUT_HEALTH-URL and the like,
# which only env can set.
with_health() {
  local want=$1 name=$2 url=$3 json=$4 timeout=$5 got=0
  env "INPUT_HOST=$host" INPUT_STACK=demo "INPUT_SECRET=$secret" "INPUT_HEALTH-URL=$url" \
    "INPUT_HEALTH-JSON=$json" "INPUT_HEALTH-TIMEOUT=$timeout" node deploy.mjs < /dev/null || got=$?
  if { [ "$want" = ok ] && [ "$got" -ne 0 ]; } || { [ "$want" = fail ] && [ "$got" -eq 0 ]; }; then
    echo "FAILED: $name"
    failed=1
  else
    echo "ok: $name"
  fi
}
echo '{"status":"ok","commit":"abcdef1","builtAt":"x"}' > "$page"
with_health ok "health at once" "$health" "$json" 30
echo '{"status":"ok","commit":"abcdef1234567890abcdef1234567890abcdef12"}' > "$page"
with_health ok "health with the whole commit" "$health" "$json" 30
echo '{"status":"ok","commit":"0000000"}' > "$page"
( sleep 3; echo '{"status":"ok","commit":"abcdef1"}' > "$page" ) & starting=$!
with_health ok "health after the new version starts" "$health" "$json" 30
wait "$starting"
with_health ok "health-url alone" "$health" "" 30
echo '{"status":"ok","commit":"abcdef"}' > "$page"
with_health fail "commit shorter than 7" "$health" "$json" 6
echo '{"status":"starting","commit":"abcdef1"}' > "$page"
with_health fail "other status until the timeout" "$health" "$json" 6
echo 503 > "$page"
with_health fail "error page until the timeout" "$health" "" 6
docker exec deploy-action-test rm -f /tmp/deploy-demo
with_health fail "health-url over http elsewhere" "http://example.org/api/health" "$json" 30
with_health fail "health-json no object" "$health" '[1]' 30
with_health fail "health-json no JSON" "$health" '{status' 30
with_health fail "health-timeout no number" "$health" "$json" soon
with_health fail "health-json without health-url" "" "$json" 30
if docker exec deploy-action-test test -e /tmp/deploy-demo; then
  echo "FAILED: a mistake in the health inputs called the hook"
  failed=1
else
  echo "ok: no hook call for a mistake in the health inputs"
fi
exit "$failed"
