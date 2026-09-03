#!/usr/bin/env bash
# 讀取 demo.ini 並匯出成環境變數，供 README 指令與各 script 使用。
#   用法：source scripts/env.sh          （在 repo 任何位置都可以）
#   指定別的參數檔：DEMO_INI=/path/other.ini source scripts/env.sh
#   載入後可執行 demo_config 查看目前生效的參數
#
# ini 規則：[section] 只是分組、會被略過；KEY = value；; 或 # 開頭為註解；
#           行尾「 ; 註解」「 # 註解」（前面要有空白）會被去掉；值可用引號包住。

_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEMO_ROOT="$(cd "$_env_dir/.." && pwd)"
export DEMO_INI="${DEMO_INI:-$DEMO_ROOT/demo.ini}"

if [ ! -f "$DEMO_INI" ]; then
  echo "✗ 找不到參數檔 $DEMO_INI" >&2
  echo "  請先：cp demo.ini.example demo.ini，填入你的網域 / zone ID / 金鑰" >&2
  return 1 2>/dev/null || exit 1
fi

_demo_keys=()
while IFS= read -r _line || [ -n "$_line" ]; do
  _line="${_line%$'\r'}"
  case "$_line" in ''|';'*|'#'*|'['*) continue ;; esac
  [[ "$_line" == *=* ]] || continue
  _key="${_line%%=*}"; _val="${_line#*=}"
  _key="${_key//[[:space:]]/}"
  _val="$(printf '%s' "$_val" | sed -E 's/[[:space:]]+[;#].*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$_val" in \"*\") _val="${_val:1:${#_val}-2}" ;; \'*\') _val="${_val:1:${#_val}-2}" ;; esac
  [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "✗ demo.ini 無法解析：$_line" >&2; continue; }
  export "$_key=$_val"
  _demo_keys+=("$_key")
done < "$DEMO_INI"

# ---- 預設值與衍生變數 ----
: "${BASE_DOMAIN:?demo.ini 缺少 BASE_DOMAIN}"
: "${HOSTED_ZONE_ID:?demo.ini 缺少 HOSTED_ZONE_ID}"
: "${APP_HOST:=app.$BASE_DOMAIN}"
: "${AWS_ENTRY_HOST:=app-aws.$BASE_DOMAIN}"
: "${GCP_ENTRY_HOST:=app-gcp.$BASE_DOMAIN}"
: "${DB_HOST:=db.$BASE_DOMAIN}"
: "${DNS_TTL:=15}"
: "${CTX_A:=ocp-a}"; : "${CTX_G:=ocp-g}"
: "${NAMESPACE:=bursting-demo}"
: "${AWS_REGION:=us-east-1}"
: "${DB_USER:=demo}"; : "${DB_PASSWORD:=demo1234}"; : "${DB_NAME:=demodb}"; : "${DISPLAY_TZ:=Asia/Taipei}"
: "${HPA_MIN_REPLICAS:=1}"; : "${HPA_MAX_REPLICAS:=10}"
: "${HPA_CPU_PERCENT:=60}"; : "${HPA_MEM_PERCENT:=80}"
: "${CPU_PRESSURE_PERCENT:=65}"; : "${CPU_PRESSURE_FOR:=2m}"
: "${BURST_MODE:=proportional}"; : "${BURST_AWS_WEIGHT:=50}"; : "${BURST_GCP_WEIGHT:=50}"
: "${BURST_GCP_MIN_PODS:=2}"; : "${BURST_RECONCILE_SECONDS:=15}"
: "${KNATIVE_MAX_SCALE:=20}"
: "${LOAD_CONCURRENCY:=150}"; : "${LOAD_DURATION:=900}"; : "${LOAD_BURN_MS:=1000}"
: "${AWS_ROUTER_HOSTNAME:=}"; : "${GCP_ROUTER_IP:=}"
: "${AWS_ACCESS_KEY_ID:=}"; : "${AWS_SECRET_ACCESS_KEY:=}"
KUBECONFIG_A="${KUBECONFIG_A:-$HOME/ocp-a/auth/kubeconfig}"; KUBECONFIG_A="${KUBECONFIG_A/#\~/$HOME}"
KUBECONFIG_G="${KUBECONFIG_G:-$HOME/ocp-g/auth/kubeconfig}"; KUBECONFIG_G="${KUBECONFIG_G/#\~/$HOME}"

# Route 53 用的 FQDN（結尾加點）與常用網址
export RECORD_NAME="${APP_HOST}."
export AWS_TARGET="${AWS_ENTRY_HOST}."
export GCP_TARGET="${GCP_ENTRY_HOST}."
export APP_URL="http://${APP_HOST}"
export GCP_ENTRY_URL="http://${GCP_ENTRY_HOST}"
export AWS_DEFAULT_REGION="$AWS_REGION"

export BASE_DOMAIN HOSTED_ZONE_ID APP_HOST AWS_ENTRY_HOST GCP_ENTRY_HOST DB_HOST DNS_TTL \
  CTX_A CTX_G KUBECONFIG_A KUBECONFIG_G NAMESPACE AWS_ROUTER_HOSTNAME GCP_ROUTER_IP \
  AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DB_USER DB_PASSWORD DB_NAME DISPLAY_TZ \
  HPA_MIN_REPLICAS HPA_MAX_REPLICAS HPA_CPU_PERCENT HPA_MEM_PERCENT \
  CPU_PRESSURE_PERCENT CPU_PRESSURE_FOR BURST_MODE BURST_AWS_WEIGHT BURST_GCP_WEIGHT BURST_GCP_MIN_PODS BURST_RECONCILE_SECONDS KNATIVE_MAX_SCALE \
  LOAD_CONCURRENCY LOAD_DURATION LOAD_BURN_MS

demo_config() {
  cat <<CFG
參數檔: $DEMO_INI
  APP_HOST=$APP_HOST  (AWS→$AWS_ENTRY_HOST, GCP→$GCP_ENTRY_HOST)
  DB_HOST=$DB_HOST   HOSTED_ZONE_ID=$HOSTED_ZONE_ID   TTL=$DNS_TTL
  CTX_A=$CTX_A  CTX_G=$CTX_G  NAMESPACE=$NAMESPACE
  AWS_ROUTER_HOSTNAME=${AWS_ROUTER_HOSTNAME:-(未填，setup-dns.sh 會自動查)}
  GCP_ROUTER_IP=${GCP_ROUTER_IP:-(未填，setup-dns.sh 會自動查)}
  AWS key: ${AWS_ACCESS_KEY_ID:+已設定}${AWS_ACCESS_KEY_ID:-(未設定)}
  HPA ${HPA_MIN_REPLICAS}→${HPA_MAX_REPLICAS} @ CPU ${HPA_CPU_PERCENT}%   叢集告警 >${CPU_PRESSURE_PERCENT}% for ${CPU_PRESSURE_FOR}
  bursting 模式 ${BURST_MODE}（起手權重 ${BURST_AWS_WEIGHT}/${BURST_GCP_WEIGHT}，ocp-g 最低 ${BURST_GCP_MIN_PODS} pod，每 ${BURST_RECONCILE_SECONDS}s）   壓測 c=${LOAD_CONCURRENCY} ${LOAD_DURATION}s burn=${LOAD_BURN_MS}ms
CFG
}

unset _env_dir _line _key _val _demo_keys
