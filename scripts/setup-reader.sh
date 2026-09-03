#!/usr/bin/env bash
# proportional 模式前置：在 ocp-g 建唯讀 SA，把 token / CA / API URL 放進 ocp-a 的 secret ocp-g-reader
set -euo pipefail
source "$(dirname "$0")/env.sh"
"$DEMO_ROOT/scripts/render.sh" >/dev/null

oc --context "$CTX_G" apply -f "$DEMO_ROOT/rendered/ocp-g/05-burst-reader-rbac.yaml"

token=""
for _ in $(seq 1 30); do
  token=$(oc --context "$CTX_G" -n "$NAMESPACE" get secret burst-reader-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$token" ] && break
  sleep 1
done
[ -n "$token" ] || { echo "✗ burst-reader-token 沒有產生 token" >&2; exit 1; }
ca=$(oc --context "$CTX_G" -n "$NAMESPACE" get secret burst-reader-token -o jsonpath='{.data.ca\.crt}' | base64 -d)
api=$(oc --context "$CTX_G" whoami --show-server)

oc --context "$CTX_A" -n "$NAMESPACE" create secret generic ocp-g-reader \
  --from-literal=OCP_G_API="$api" \
  --from-literal=OCP_G_TOKEN="$token" \
  --from-literal=OCP_G_CA="$ca" \
  --dry-run=client -o yaml | oc --context "$CTX_A" apply -f -
echo "✓ ocp-a secret ocp-g-reader 已建立（API: $api）"

if oc --context "$CTX_A" -n "$NAMESPACE" get deploy burst-controller >/dev/null 2>&1; then
  oc --context "$CTX_A" -n "$NAMESPACE" rollout restart deploy/burst-controller
  echo "✓ burst-controller 已重啟以載入 secret"
fi
