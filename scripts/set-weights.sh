#!/usr/bin/env bash
# 手動調整 Route 53 加權（demo 備援 / 手動回縮用）
# 用法: ./set-weights.sh <aws權重> <gcp權重>
#   ./set-weights.sh 100 0    # 全部回 ocp-a
#   ./set-weights.sh 50 50    # 分流
# 需先設定環境變數或修改下方預設值，且本機 aws cli 已設定好認證。

set -euo pipefail

AWS_W="${1:?用法: $0 <aws權重> <gcp權重>}"
GCP_W="${2:?用法: $0 <aws權重> <gcp權重>}"

ZONE_ID="${ZONE_ID:-ZXXXXXXXXXXXXX}"                            # ← 改
RECORD="${RECORD:-app.bursting.demo.example.com.}"               # ← 改
AWS_TARGET="${AWS_TARGET:-app-aws.bursting.demo.example.com.}"   # ← 改
GCP_TARGET="${GCP_TARGET:-app-gcp.bursting.demo.example.com.}"   # ← 改
TTL="${TTL:-15}"

change() {
  cat <<EOF
    {"Action":"UPSERT","ResourceRecordSet":{
      "Name":"$RECORD","Type":"CNAME","TTL":$TTL,
      "SetIdentifier":"$1","Weight":$2,
      "ResourceRecords":[{"Value":"$3"}]}}
EOF
}

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Changes\":[$(change ocp-a "$AWS_W" "$AWS_TARGET"),$(change ocp-g "$GCP_W" "$GCP_TARGET")]}"

echo "已設定: ocp-a=$AWS_W ocp-g=$GCP_W"
