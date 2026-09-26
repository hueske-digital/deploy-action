#!/bin/bash
# Runs deploy.mjs against a real adnanh/webhook with the deploy hook of a
# stack "demo": the right secret is taken (202 and the marker), a wrong
# one, an unknown hook, plain http to another host and a short secret are
# refused. Needs docker and node.
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
trap 'docker rm -f deploy-action-test > /dev/null; rm -rf "$work"' EXIT
for _ in $(seq 20); do
  curl -s -o /dev/null http://127.0.0.1:9000/ && break
  sleep 0.5
done

failed=0
expect() {
  local want=$1 name=$2 host=$3 stack=$4 key=$5 got=0
  INPUT_HOST=$host INPUT_STACK=$stack INPUT_SECRET=$key node deploy.mjs || got=$?
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
exit "$failed"
