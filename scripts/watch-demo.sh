#!/usr/bin/env bash
# 演示時的觀察面板：每 5 秒顯示兩邊叢集狀態 + 流量實際落點
# 用法: KUBECONFIG_A=~/ocp-a/auth/kubeconfig KUBECONFIG_G=~/ocp-g/auth/kubeconfig \
#       ./watch-demo.sh http://app.bursting.demo.example.com

set -uo pipefail
URL="${1:-}"
: "${KUBECONFIG_A:?請設定 KUBECONFIG_A}"
: "${KUBECONFIG_G:?請設定 KUBECONFIG_G}"

while true; do
  clear
  echo "════════ ocp-a (AWS) $(date '+%H:%M:%S') ════════"
  oc --kubeconfig "$KUBECONFIG_A" -n bursting-demo get hpa frontend 2>/dev/null
  oc --kubeconfig "$KUBECONFIG_A" -n bursting-demo get pods -l app=frontend --no-headers 2>/dev/null | awk '{print "  "$1, $3}'
  echo
  echo "════════ ocp-g (GCP, Knative) ════════"
  oc --kubeconfig "$KUBECONFIG_G" -n bursting-demo get pods --no-headers 2>/dev/null | grep -v '^$' | awk '{print "  "$1, $3}' \
    || echo "  (scale-to-zero，無 pod)"
  echo
  if [ -n "$URL" ]; then
    echo "════════ 流量落點（連續 10 個請求）════════"
    for i in $(seq 1 10); do
      curl -s -m 5 "$URL/" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  →", d.get("site"))' 2>/dev/null &
    done
    wait
  fi
  sleep 5
done
