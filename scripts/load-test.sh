#!/usr/bin/env bash
# 壓測腳本：打前端 /burn 端點燒 CPU
# 流程：HPA 加 replica → worker 節點 CPU 飆高 → ClusterCPUPressure firing → 分流到 ocp-g
#
# 用法（全部可省略，預設取 demo.ini 的 APP_HOST 與 [loadtest]）:
#   ./load-test.sh [URL] [併發數] [持續秒數] [每請求燒CPU毫秒]
#   ./load-test.sh                       # 用 demo.ini 預設
#   ./load-test.sh http://x.y.z 100 600 800
#
# 有裝 hey (https://github.com/rakyll/hey) 就用 hey，沒有就退回純 curl 迴圈。
set -euo pipefail
source "$(dirname "$0")/env.sh"

URL="${1:-$APP_URL}"
CONCURRENCY="${2:-$LOAD_CONCURRENCY}"
DURATION="${3:-$LOAD_DURATION}"
BURN_MS="${4:-$LOAD_BURN_MS}"

TARGET="${URL%/}/burn?ms=${BURN_MS}"

echo "=== Cloud Bursting 壓測 ==="
echo "目標:   $TARGET"
echo "併發:   $CONCURRENCY"
echo "持續:   ${DURATION}s"
echo "==========================="

if command -v hey >/dev/null 2>&1; then
  echo "[使用 hey]"
  # DNS TTL 很短；hey 只解析一次 DNS，所以分段跑，每 30 秒重新解析
  # 讓分流生效後新的連線會打到 ocp-g
  END=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$END" ]; do
    hey -z 30s -c "$CONCURRENCY" -disable-keepalive "$TARGET" | grep -E "Requests/sec|responses" || true
  done
else
  echo "[未安裝 hey，使用 curl 迴圈]"
  END=$(( $(date +%s) + DURATION ))
  worker() {
    while [ "$(date +%s)" -lt "$END" ]; do
      curl -s -m 15 "$TARGET" -o /dev/null || true
    done
  }
  for i in $(seq 1 "$CONCURRENCY"); do
    worker &
  done
  echo "已啟動 $CONCURRENCY 個併發 worker，將持續 ${DURATION}s（Ctrl-C 可提前停止）"
  trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM
  wait
fi

echo "壓測結束。壓力消退後：HPA 縮回 → 告警 resolved → Route 53 權重收回 → ocp-g scale-to-zero"
