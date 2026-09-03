#!/usr/bin/env bash
# README Step 3：建立 namespace 與三個 secret
#   db-credentials（兩邊）、postgres-tls（ocp-a，自簽 CN=DB_HOST）、aws-route53（ocp-a）
set -euo pipefail
source "$(dirname "$0")/env.sh"

for ctx in "$CTX_A" "$CTX_G"; do
  oc --context "$ctx" create namespace "$NAMESPACE" --dry-run=client -o yaml | oc --context "$ctx" apply -f -
  oc --context "$ctx" -n "$NAMESPACE" create secret generic db-credentials \
    --from-literal=user="$DB_USER" --from-literal=password="$DB_PASSWORD" --from-literal=database="$DB_NAME" \
    --dry-run=client -o yaml | oc --context "$ctx" apply -f -
done

tmp=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" -subj "/CN=$DB_HOST" 2>/dev/null
oc --context "$CTX_A" -n "$NAMESPACE" create secret generic postgres-tls \
  --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" \
  --dry-run=client -o yaml | oc --context "$CTX_A" apply -f -
rm -rf "$tmp"

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "⚠ demo.ini 的 [aws] 沒填 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY，略過 aws-route53 secret" >&2
else
  oc --context "$CTX_A" -n "$NAMESPACE" create secret generic aws-route53 \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | oc --context "$CTX_A" apply -f -
fi
echo "✓ secrets 建立完成（namespace: $NAMESPACE）"
