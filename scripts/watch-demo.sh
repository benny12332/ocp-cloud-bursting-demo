#!/usr/bin/env bash
# 演示時的觀察面板：每 5 秒顯示兩邊叢集狀態 + 流量實際落點
# 用法: ./watch-demo.sh [URL]     （URL 省略則用 demo.ini 的 APP_HOST；
#       kubeconfig 取 demo.ini 的 KUBECONFIG_A / KUBECONFIG_G）
set -uo pipefail
source "$(dirname "$0")/env.sh"
URL="${1:-$APP_URL}"

for f in "$KUBECONFIG_A" "$KUBECONFIG_G"; do
  [ -f "$f" ] || { echo "✗ 找不到 kubeconfig: $f（請檢查 demo.ini 的 [clusters]）" >&2; exit 1; }
done

while true; do
  clear
  echo "════════ $CTX_A (AWS) $(date '+%H:%M:%S') ════════"
  oc --kubeconfig "$KUBECONFIG_A" -n "$NAMESPACE" get hpa frontend 2>/dev/null
  oc --kubeconfig "$KUBECONFIG_A" -n "$NAMESPACE" get pods -l app=frontend --no-headers 2>/dev/null | awk '{print "  "$1, $3}'
  echo
  echo "════════ $CTX_G (GCP, Knative) ════════"
  pods=$(oc --kubeconfig "$KUBECONFIG_G" -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -v '^$' || true)
  if [ -n "$pods" ]; then echo "$pods" | awk '{print "  "$1, $3}'; else echo "  (scale-to-zero，無 pod)"; fi
  echo
  echo "════════ 流量落點 $URL（連續 10 個請求）════════"
  for i in $(seq 1 10); do
    curl -s -m 5 "$URL/whoami" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  →", d.get("site"))' 2>/dev/null &
  done
  wait
  sleep 5
done
