#!/usr/bin/env bash
# 把 ocp-a/ 與 ocp-g/ 裡的 ${參數} 用 demo.ini 的值代換、app/*.py 塞進 ConfigMap，輸出到 rendered/
# 之後 oc apply -f rendered/ocp-a/xx.yaml 即可，原始 yaml 不動。
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="$DEMO_ROOT/rendered"
rm -rf "$OUT"
mkdir -p "$OUT/ocp-a" "$OUT/ocp-g"

if [[ "$HOSTED_ZONE_ID" == Z*X* && "$HOSTED_ZONE_ID" == *XXXX* ]]; then
  echo "⚠ HOSTED_ZONE_ID 還是範例值 ($HOSTED_ZONE_ID)，請確認 demo.ini" >&2
fi

# app/ 底下的程式碼縮排 4 格後塞進 ConfigMap 的 block scalar（單一來源，兩個叢集共用）
indent4() { sed 's/^/    /' "$1"; }
export APP_CODE="$(indent4 "$DEMO_ROOT/app/app.py")"
export CONTROLLER_CODE="$(indent4 "$DEMO_ROOT/app/controller.py")"

n=0
for f in "$DEMO_ROOT"/ocp-a/*.yaml "$DEMO_ROOT"/ocp-g/*.yaml; do
  rel="${f#"$DEMO_ROOT"/}"
  # 只代換 ${大寫變數}，app.py / JS 裡的 $ 不受影響；遇到未定義變數直接失敗
  perl -pe 's/\$\{([A-Z][A-Z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : die "未定義的參數 \${$1} (在 $ARGV)\n"/ge' \
    "$f" > "$OUT/$rel"
  n=$((n+1))
done
echo "✓ 已用 $DEMO_INI 產生 $n 個檔案到 rendered/ocp-a/ 與 rendered/ocp-g/"
