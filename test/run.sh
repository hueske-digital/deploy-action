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
  local want=$1 name=$2 url=$3 key=$4 got=0
  INPUT_URL=$url INPUT_SECRET=$key node deploy.mjs || got=$?
  if { [ "$want" = ok ] && [ "$got" -ne 0 ]; } || { [ "$want" = fail ] && [ "$got" -eq 0 ]; }; then
    echo "FAILED: $name"
    failed=1
  else
    echo "ok: $name"
  fi
}
hook=http://localhost:9000/hooks/deploy-demo
expect ok "right secret" "$hook" "$secret"
docker exec deploy-action-test test -e /tmp/deploy-demo || { echo "FAILED: no marker"; failed=1; }
expect fail "wrong secret" "$hook" "$(openssl rand -hex 32)"
expect fail "unknown hook" http://localhost:9000/hooks/deploy-other "$secret"
expect fail "http to another host" http://example.org/hooks/deploy-demo "$secret"
expect fail "other path" http://localhost:9000/hooks/apply "$secret"
expect fail "short secret" "$hook" abc
exit "$failed"
