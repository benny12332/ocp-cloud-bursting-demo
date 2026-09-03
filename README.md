# OpenShift 跨雲 Cloud Bursting Demo（AWS → GCP）

## 架構總覽

```
                         ┌─────────── Route 53 (加權 DNS = GLB) ───────────┐
                         │  app.<domain>                                   │
                         │   ├─ ocp-a 權重 100→依pod數   ├─ ocp-g 0→依pod數│
                         └────────┬────────────────────────┬───────────────┘
                                  ▼                        ▼
        ┌──────────── ocp-a (AWS) ────────────┐   ┌──── ocp-g (GCP) ─────┐
        │  frontend (Deployment + HPA 1→10)   │   │  frontend            │
        │  postgres ◄── TLS passthrough Route─┼───┼── (Knative Service,  │
        │  Prometheus → ClusterCPUPressure    │   │   scale-to-zero)     │
        │  Alertmanager ──webhook──┐          │   │  burst-reader SA ◄───┼─┐
        │  burst-controller ◄──────┘          │   └──────────────────────┘ │
        │     ├── 讀兩邊 ready pod 數 ────────┼─────────────────────────────┘
        │     └── Route53 API 依比例改權重 ───┘
        └─────────────────────────────────────┘
```

**兩層擴展：**
1. **HPA**（Pod 層）：frontend CPU > 60% → 加 replica，最多 10 個
2. **Cloud Bursting**（叢集層）：worker 節點平均 CPU > 65% 持續 2 分鐘 → `ClusterCPUPressure` firing → Alertmanager webhook → burst-controller 先把 Route 53 權重改成起手值 50/50 喚醒 ocp-g 的 Knative，之後**每 15 秒依兩邊 ready pod 數的比例動態調整權重**（例如 ocp-a 10 個、ocp-g 4 個 → 權重 10:4）

**回縮：** 壓力下降 → 告警 resolved（Alertmanager 的 `send_resolved: true`）→ webhook 把權重改回 100/0 → ocp-g 沒流量約 1 分鐘後 Knative 自動 scale-to-zero。

以上數字（閾值、權重、pod 數下限、間隔）全部在 `demo.ini` 調整；`BURST_MODE = fixed` 可改回固定 50/50。

---

## 參數檔 `demo.ini` — 所有設定只改這一個地方

```bash
cp demo.ini.example demo.ini
vi demo.ini            # 至少填 BASE_DOMAIN、HOSTED_ZONE_ID、[aws] 金鑰、oc context 名稱
source scripts/env.sh  # 把 demo.ini 匯出成環境變數（README 每個 $變數 都來自這裡）
demo_config            # 檢查目前生效的參數
```

| 區段 | 參數 | 說明 |
|---|---|---|
| `[dns]` | `BASE_DOMAIN`、`HOSTED_ZONE_ID` | Route 53 hosted zone（必填） |
| | `APP_HOST`、`AWS_ENTRY_HOST`、`GCP_ENTRY_HOST`、`DB_HOST` | 留空自動用 `app.` / `app-aws.` / `app-gcp.` / `db.` + `BASE_DOMAIN` |
| | `DNS_TTL` | 加權記錄 TTL，預設 15s |
| `[clusters]` | `CTX_A`、`CTX_G`、`KUBECONFIG_A`、`KUBECONFIG_G`、`NAMESPACE` | oc context / kubeconfig / namespace |
| | `AWS_ROUTER_HOSTNAME`、`GCP_ROUTER_IP` | 留空由 `setup-dns.sh` 自動用 oc 查 |
| `[aws]` | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_REGION` | burst-controller 用的 IAM key（只需 Route 53 權限） |
| `[database]` | `DB_USER`、`DB_PASSWORD`、`DB_NAME` | PostgreSQL 帳密 |
| `[scaling]` | `HPA_*`、`CPU_PRESSURE_*` | 兩層擴展的閾值 |
| | `BURST_MODE` | `proportional`（依 pod 數比例）或 `fixed`（固定權重） |
| | `BURST_AWS_WEIGHT` / `BURST_GCP_WEIGHT` | fixed 模式權重；proportional 模式的起手權重 |
| | `BURST_GCP_MIN_PODS`、`BURST_RECONCILE_SECONDS` | proportional：ocp-g 最低計算 pod 數、重算間隔 |
| `[loadtest]` | `LOAD_*` | `load-test.sh` 預設值 |

`demo.ini` 已列入 `.gitignore`（含金鑰），只有 `demo.ini.example` 會進 git。

**yaml 怎麼吃到參數？** `ocp-a/`、`ocp-g/` 裡的檔案用 `${參數名}` 佔位，`./scripts/render.sh` 會代換成 `demo.ini` 的值輸出到 `rendered/`（同樣被 gitignore），之後一律 `oc apply -f rendered/...`。改了 `demo.ini` 就重跑一次 `render.sh`。

**程式碼在哪？** 前端 `app/app.py` 與 controller `app/controller.py` 是單一來源，`render.sh` 會把它們塞進 ocp-a / ocp-g 的 ConfigMap，所以兩個叢集跑的一定是同一份 code；改程式也是改完重跑 `render.sh` + `oc apply`。

---

## AWS 上需要的服務（ocp-a 以外）

| 服務 | 用途 |
|---|---|
| **Route 53 Hosted Zone** | 全域流量分配（取代 GLB）。加權 CNAME + 短 TTL（15s） |
| **IAM user/key** | 給 burst-controller，只需 `route53:ChangeResourceRecordSets` + `route53:ListResourceRecordSets` 對該 zone 的權限 |

不需要 Global Accelerator（endpoint 不能跨到 GCP）、不需要額外 ALB（叢集的 router ELB 由 installer 建好）。

IAM policy 範例：

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"],
    "Resource": "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
  }]
}
```

---

## 前置條件

- ocp-a（AWS）與 ocp-g（GCP）都已安裝完成，`oc` 可分別登入（context 名稱填在 `demo.ini` 的 `CTX_A` / `CTX_G`）
- 一個由 Route 53 管理的網域
- 本機有 `aws` CLI（設定 DNS 用）、`perl`（render 用，macOS/Linux 內建）、建議安裝 [`hey`](https://github.com/rakyll/hey) 壓測工具（`brew install hey`）

DNS 名稱規劃（名稱由 `demo.ini` 決定，以下是預設）：

| 名稱 | 類型 | 指向 |
|---|---|---|
| `$AWS_ENTRY_HOST`（app-aws.…） | CNAME | ocp-a 的 router ELB hostname |
| `$GCP_ENTRY_HOST`（app-gcp.…） | A | ocp-g 的 router LB IP（GCP 給 IP） |
| `$APP_HOST`（app.…） | 加權 CNAME ×2 | → app-aws（權重 100）、→ app-gcp（權重 0） |
| `$DB_HOST`（db.…） | CNAME | ocp-a 的 router ELB hostname |

> 加權記錄必須同名同類型，所以兩筆都用 CNAME 指向中繼名稱，這是刻意的兩層設計。

---

## Step 0：載入參數並產生 manifest

```bash
source scripts/env.sh && demo_config
./scripts/render.sh
```

## Step 1+2：建立 Route 53 記錄

```bash
./scripts/setup-dns.sh
```

這個 script 會：用 `oc` 查兩邊 router 的入口（`demo.ini` 有填就直接用）→ 建立三筆固定入口記錄 → 呼叫 `set-weights.sh 100 0` 建立加權記錄。想手動做，等同於：

```bash
oc --context $CTX_A -n openshift-ingress get svc router-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
oc --context $CTX_G -n openshift-ingress get svc router-default -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# 再用 aws route53 change-resource-record-sets 建 $AWS_ENTRY_HOST / $GCP_ENTRY_HOST / $DB_HOST
./scripts/set-weights.sh 100 0
```

## Step 3：建立 Secret（兩個叢集）

```bash
./scripts/setup-secrets.sh
```

會建立：namespace（兩邊）、`db-credentials`（兩邊）、`postgres-tls`（自簽憑證，CN = `$DB_HOST`，只在 ocp-a）、`aws-route53`（ocp-a，內容來自 `demo.ini` 的 `[aws]`）。

## Step 4：部署 ocp-a（DB + 前端 + HPA + controller）

```bash
oc --context $CTX_A apply \
  -f rendered/ocp-a/02-postgres.yaml \
  -f rendered/ocp-a/03-frontend.yaml \
  -f rendered/ocp-a/04-hpa.yaml \
  -f rendered/ocp-a/06-burst-controller.yaml
```

驗證：

```bash
curl $APP_URL/whoami   # 應回 {"site":"ocp-a(AWS)",...}
curl $APP_URL/db       # 應回 {"db":"ok","db_via":"postgres.<ns>.svc.cluster.local:5432 (sslmode=disable)",...}
curl $APP_URL/api/db   # DB 內容（hits 計數 + 最近留言）
open $APP_URL/         # 瀏覽器：面板第三張卡就是 DB 內容
```

## Step 5：部署告警規則（ocp-a）

```bash
oc --context $CTX_A apply -f rendered/ocp-a/05-alert-rule.yaml
```

> 閾值 `CPU_PRESSURE_PERCENT` / `CPU_PRESSURE_FOR` 依你的 worker 規格調整：先跑一次壓測看 Console 的
> Observe → Metrics 查 `(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))) * 100`
> 確認能推得上去。demo 時想更快觸發可把 `CPU_PRESSURE_FOR` 改 `1m`（改完重跑 render + apply）。

## Step 6：設定 Alertmanager webhook（ocp-a）

```bash
oc --context $CTX_A -n openshift-monitoring extract secret/alertmanager-main --to=/tmp --confirm
```

編輯 `/tmp/alertmanager.yaml`，在 `route.routes` 加入子路由、`receivers` 加入 receiver
（完整片段見 `rendered/ocp-a/07-alertmanager-receiver.yaml`，webhook URL 已帶入你的 namespace）：

```yaml
route:
  routes:
    - matchers:
        - alertname = ClusterCPUPressure
      receiver: burst-webhook
      group_wait: 10s
      repeat_interval: 5m
receivers:
  - name: burst-webhook
    webhook_configs:
      - url: http://burst-controller.<NAMESPACE>.svc.cluster.local:8080/alert
        send_resolved: true
```

回寫：

```bash
oc --context $CTX_A -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager.yaml \
  --dry-run=client -o yaml | oc --context $CTX_A -n openshift-monitoring replace -f -
```

## Step 7：部署 ocp-g（Serverless + Knative 前端）

```bash
oc --context $CTX_G apply -f rendered/ocp-g/01-serverless-operator.yaml
# 等 operator 裝好（csv 顯示 Succeeded）
oc --context $CTX_G -n openshift-serverless get csv -w
oc --context $CTX_G apply -f rendered/ocp-g/02-knative-serving.yaml
oc --context $CTX_G -n knative-serving get knativeserving knative-serving -w   # Ready=True

oc --context $CTX_G apply -f rendered/ocp-g/03-namespace-and-code.yaml -f rendered/ocp-g/04-frontend-ksvc.yaml
```

驗證 ocp-g（直接打 GCP 入口，繞過加權 DNS）：

```bash
curl -H "Host: $APP_HOST" $GCP_ENTRY_URL/db
# 應回 {"site":"ocp-g(GCP)","db":"ok","db_via":"db.<domain>:443 (sslmode=require)",...}
#   ← 證明 GCP 端跨雲（走 ocp-a 的 TLS passthrough Route）連回同一顆 DB 成功
curl -s -X POST -H "Host: $APP_HOST" -H 'Content-Type: application/json' \
  -d '{"text":"hello from GCP"}' $GCP_ENTRY_URL/api/message
curl $APP_URL/api/db   # 從 AWS 端讀，應該看得到剛才 GCP 寫的留言
# 等 60 秒後 oc get pods 應看到 pod 消失（scale-to-zero）
```

## Step 8：讓 burst-controller 能讀 ocp-g 的 pod 數（proportional 模式）

```bash
./scripts/setup-reader.sh
```

會在 ocp-g 建唯讀 ServiceAccount `burst-reader`（只能 list 該 namespace 的 pod），把 token / CA / API URL 放進 ocp-a 的 secret `ocp-g-reader`，並重啟 burst-controller。確認：

```bash
oc --context $CTX_A -n $NAMESPACE logs deploy/burst-controller | grep started
# → burst-controller started: mode=proportional ... remote=configured
```

沒做這步 controller 仍可運作，但 bursting 時只會維持起手權重（等同 fixed）。

## Step 9：演示！

終端機 1 — 觀察面板：

```bash
./scripts/watch-demo.sh
```

終端機 2 — 開壓（參數取 `demo.ini` 的 `[loadtest]`，也可用命令列覆蓋 `URL 併發 秒數 burn_ms`）：

```bash
./scripts/load-test.sh
```

終端機 3 — controller 的決策：

```bash
oc --context $CTX_A -n $NAMESPACE logs deploy/burst-controller -f
# 或看目前狀態（模式 / 權重 / 兩邊 pod 數）
oc --context $CTX_A -n $NAMESPACE exec deploy/burst-controller -- curl -s localhost:8080/status
```

預期時間軸（約 8–10 分鐘）：

| 時間 | 現象 |
|---|---|
| 0–1 min | frontend CPU 飆高，HPA 開始加 replica（1→4→7→10） |
| 2–4 min | worker 節點平均 CPU 突破閾值，`ClusterCPUPressure` 進入 pending → firing |
| 4–5 min | Alertmanager 發 webhook，controller 設起手權重 50/50（log: `bursting 起手權重`） |
| 5–6 min | 新 DNS 解析開始打到 ocp-g，Knative pod 從 0 喚醒，watch 面板出現 `→ ocp-g(GCP)` |
| 6 min 起 | controller 每 15 秒依 pod 數重算：log 出現 `weights set: ocp-a=10 ocp-g=4 (pods a=10 g=4)` 之類 |
| 停止壓測後 | HPA 縮回 → 告警 resolved → 權重回 100/0 → ocp-g 約 1 分鐘後歸零 |

輔助觀察：

```bash
# 告警狀態
oc --context $CTX_A -n openshift-monitoring exec alertmanager-main-0 -- amtool alert --alertmanager.url=http://localhost:9093
# Route 53 目前權重
aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
  --query "ResourceRecordSets[?Name=='$RECORD_NAME'].[SetIdentifier,Weight]" --output table
```

### 視覺化演示（瀏覽器）

前端首頁本身就是 demo 面板，打開 `$APP_URL/`：

- **整頁底色**顯示這個頁面是誰服務的：橘色 = AWS (Primary)、藍色 = GCP (Burst)，並顯示 pod 名稱
- **請求落點燈條**：頁面每 2 秒背景發一個 `/whoami` 請求，橘點/藍點即時排開並累計數字。
  bursting 觸發後，觀眾會看到藍點開始混入，比例會隨兩邊 pod 數變化；回縮後藍點消失
- **PostgreSQL 內容卡**（每 5 秒從 `/api/db` 更新）：顯示本站到 DB 的連線路徑（AWS 頁面是叢集內 svc、
  GCP 頁面是 `db.<domain>:443 sslmode=require`，一眼看出跨雲）、各站點累計 hits、最近 10 則留言（標記是哪個站點的哪個 pod 寫的），
  底下有留言框——**在 GCP 服務的頁面留言，AWS 頁面 5 秒內就會出現**，反過來也一樣，證明兩朵雲讀寫的是 ocp-a 上同一顆 DB
- 想看「整頁變藍」的效果，在分流生效後開一個**新的無痕視窗**重新載入（新連線 + 新 DNS 解析）

保底手法（100% 確定給觀眾看到 GCP 版頁面）：

```bash
curl -s -H "Host: $APP_HOST" $GCP_ENTRY_URL/whoami
```

`hits_by_site` 是**由兩邊共同寫入同一個 DB 的累計數**（每次 `/db` 請求加一筆）——demo 時可以在終端機跑
`while true; do curl -s $APP_URL/db >/dev/null; sleep 1; done`，bursting 期間畫面上 `ocp-g(GCP)` 的計數會開始成長，同時證明了分流與跨雲 DB 連線兩件事。

DNS 快取備註：app 已回應 `Connection: close` 與 `Cache-Control: no-store` 避免黏連線，但 Chrome 自身的 DNS 快取約 60 秒，所以權重切換後燈條大約 15–60 秒才會出現藍點——這正好給你講解的時間。`load-test.sh` 每 30 秒重啟 hey 以重新解析 DNS。若當場告警沒觸發，用 `./scripts/set-weights.sh 50 50` 手動切換救場（注意：controller 在 bursting 狀態下會每 15 秒覆蓋回比例權重；非 bursting 狀態不會動它）。

## 清理

```bash
oc --context $CTX_A delete ns $NAMESPACE
oc --context $CTX_A -n openshift-monitoring delete prometheusrule bursting-demo-rules
oc --context $CTX_G delete ns $NAMESPACE
./scripts/set-weights.sh 100 0
```

---

## 檔案清單

| 檔案 | 內容 |
|---|---|
| `demo.ini.example` | **參數範本**，複製成 `demo.ini` 填寫 |
| `scripts/env.sh` | 讀 `demo.ini` → 環境變數（`source` 用）；提供 `demo_config` |
| `scripts/render.sh` | 把 `${參數}` 代換進 yaml、`app/*.py` 塞進 ConfigMap，輸出到 `rendered/` |
| `scripts/setup-dns.sh` | Step 1+2：查 router 入口、建 Route 53 記錄 |
| `scripts/setup-secrets.sh` | Step 3：namespace + 三個 secret |
| `scripts/setup-reader.sh` | Step 8：ocp-g 唯讀 SA → ocp-a secret `ocp-g-reader` |
| `scripts/load-test.sh` | 壓測腳本 |
| `scripts/watch-demo.sh` | 演示觀察面板 |
| `scripts/set-weights.sh` | 手動調整 Route 53 權重（救場用） |
| `ocp-a/01-namespace.yaml` | namespace |
| `ocp-a/02-postgres.yaml` | PostgreSQL（兩邊共用的 DB）+ TLS passthrough Route 給 ocp-g 跨雲連線 |
| `app/app.py` | **前端程式碼（單一來源）**：demo 面板、`/whoami`、`/api/db`、`/api/message`、`/db`、`/burn` |
| `app/controller.py` | **burst-controller 程式碼（單一來源）** |
| `ocp-a/03-frontend.yaml` | 前端 ConfigMap（由 render.sh 塞入 app.py）+ Deployment + Route |
| `ocp-a/04-hpa.yaml` | HPA（CPU / Mem 閾值與上下限來自 ini） |
| `ocp-a/05-alert-rule.yaml` | PrometheusRule：ClusterCPUPressure |
| `ocp-a/06-burst-controller.yaml` | controller ConfigMap（由 render.sh 塞入）+ Deployment + SA/RBAC |
| `ocp-a/07-alertmanager-receiver.yaml` | Alertmanager 設定片段（參考用） |
| `ocp-g/01-serverless-operator.yaml` | OpenShift Serverless Operator |
| `ocp-g/02-knative-serving.yaml` | KnativeServing 實例 |
| `ocp-g/03-namespace-and-code.yaml` | namespace + 前端 ConfigMap（同一份 app.py） |
| `ocp-g/04-frontend-ksvc.yaml` | Knative Service（scale-to-zero）+ DomainMapping |
| `ocp-g/05-burst-reader-rbac.yaml` | 給 burst-controller 讀 pod 數的唯讀 SA + token |
