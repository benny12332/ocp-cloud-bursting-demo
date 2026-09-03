#!/usr/bin/env bash
# 手動調整 Route 53 加權（demo 備援 / 手動回縮用）；參數來自 demo.ini
# 用法: ./set-weights.sh <aws權重> <gcp權重>
#   ./set-weights.sh 100 0    # 全部回 ocp-a
#   ./set-weights.sh 50 50    # 分流
set -euo pipefail
source "$(dirname "$0")/env.sh"

AWS_W="${1:?用法: $0 <aws權重> <gcp權重>}"
GCP_W="${2:?用法: $0 <aws權重> <gcp權重>}"

change() {
  cat <<JSON
    {"Action":"UPSERT","ResourceRecordSet":{
      "Name":"$RECORD_NAME","Type":"CNAME","TTL":$DNS_TTL,
      "SetIdentifier":"$1","Weight":$2,
      "ResourceRecords":[{"Value":"$3"}]}}
JSON
}

aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{\"Changes\":[$(change ocp-a "$AWS_W" "$AWS_TARGET"),$(change ocp-g "$GCP_W" "$GCP_TARGET")]}" >/dev/null

echo "✓ $APP_HOST 權重：ocp-a=$AWS_W  ocp-g=$GCP_W"
