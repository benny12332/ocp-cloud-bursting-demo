#!/usr/bin/env bash
# README Step 1 + 2：查兩邊 router 入口，建立 Route 53 記錄（固定入口 + 加權 100/0）
# 需本機 aws CLI 已設定認證，且 oc 已登入 CTX_A / CTX_G（或在 demo.ini 填好入口位址）
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ -z "$AWS_ROUTER_HOSTNAME" ]; then
  AWS_ROUTER_HOSTNAME=$(oc --context "$CTX_A" -n openshift-ingress get svc router-default \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi
if [ -z "$GCP_ROUTER_IP" ]; then
  GCP_ROUTER_IP=$(oc --context "$CTX_G" -n openshift-ingress get svc router-default \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
fi
[ -n "$AWS_ROUTER_HOSTNAME" ] || { echo "✗ 取不到 ocp-a router hostname" >&2; exit 1; }
[ -n "$GCP_ROUTER_IP" ]       || { echo "✗ 取不到 ocp-g router IP" >&2; exit 1; }

echo "ocp-a router: $AWS_ROUTER_HOSTNAME"
echo "ocp-g router: $GCP_ROUTER_IP"

aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
  \"Changes\": [
    {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$AWS_ENTRY_HOST\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$AWS_ROUTER_HOSTNAME\"}]}},
    {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$GCP_ENTRY_HOST\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$GCP_ROUTER_IP\"}]}},
    {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$DB_HOST\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$AWS_ROUTER_HOSTNAME\"}]}}
  ]}" >/dev/null
echo "✓ 固定入口：$AWS_ENTRY_HOST / $GCP_ENTRY_HOST / $DB_HOST"

"$DEMO_ROOT/scripts/set-weights.sh" 100 0
