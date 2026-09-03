# OpenShift 跨雲 Cloud Bursting Demo（AWS → GCP）

## 架構總覽

```
                         ┌─────────── Route 53 (加權 DNS = GLB) ───────────┐
                         │  app.example.com                                │
                         │   ├─ ocp-a 權重 100→50   ├─ ocp-g 權重 0→50     │
                         └────────┬────────────────────────┬───────────────┘
                                  ▼                        ▼
        ┌──────────── ocp-a (AWS) ────────────┐   ┌──── ocp-g (GCP) ─────┐
        │  frontend (Deployment + HPA 1→10)   │   │  frontend            │
        │  postgres ◄── TLS passthrough Route─┼───┼── (Knative Service,  │
        │  Prometheus → ClusterCPUPressure    │   │   scale-to-zero)     │
        │  Alertmanager ──webhook──┐          │   └──────────────────────┘
        │  burst-controller ◄──────┘          │
        │        └──── Route53 API 改權重 ────┘
        └─────────────────────────────────────┘
```

**兩層擴展：**
1. **HPA**（Pod 層）：frontend CPU > 60% → 加 replica，最多 10 個
2. **Cloud Bursting**（叢集層）：worker 節點平均 CPU > 65% 持續 2 分鐘 → `ClusterCPUPressure` firing → Alertmanager webhook → burst-controller 把 Route 53 權重改成 50/50 → 流量開始打到 ocp-g，Knative 從 0 喚醒

**回縮：** 壓力下降 → 告警 resolved（Alertmanager 的 `send_resolved: true`）→ webhook 把權重改回 100/0 → ocp-g 沒流量約 1 分鐘後 Knative 自動 scale-to-zero。

---

## AWS 上需要的服務（ocp-a 以外）

| 服務 | 用途 |
|---|---|
| **Route 53 Hosted Zone** | 全域流量分配（取代 GLB）。加權 CNAME + 短 TTL（15s） |
| **IAM user/key** | 給 burst-controller，只需 `route53:ChangeResourceRecordSets` + `route53:ListResourceRecordSets` 對該 zone 的權限 |

不需要 Global Accelerator（endpoint 不能跨到 GCP）、不需要額外 ALB（叢集的 router ELB 由 installer 建好）。

---

## 前置條件

- ocp-a（AWS）與 ocp-g（GCP）都已安裝完成，`oc` 可分別登入
- 一個由 Route 53 管理的網域（以下以 `demo.example.com` 為例，**所有檔案中的 domain 都要改成你的**）
- 本機有 `aws` CLI（設定 DNS 用）、建議安裝 [`hey`](https://github.com/rakyll/hey) 壓測工具（`brew install hey`）

本文假設的 DNS 名稱規劃：

| 名稱 | 類型 | 指向 |
|---|---|---|
| `app-aws.demo.example.com` | CNAME | ocp-a 的 router ELB hostname |
| `app-gcp.demo.example.com` | A | ocp-g 的 router LB IP（GCP 給 IP） |
| `app.demo.example.com` | 加權 CNAME ×2 | → app-aws（權重 100）、→ app-gcp（權重 0） |
| `db.bursting.demo.example.com` | CNAME | ocp-a 的 router ELB hostname |

---

## Step 1：取得兩邊 router 的入口位址

```bash
# ocp-a：取得 router ELB hostname
oc --context ocp-a -n openshift-ingress get svc router-default \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

```bash
# ocp-g：取得 router LB IP
oc --context ocp-g -n openshift-ingress get svc router-default \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Step 2：建立 Route 53 記錄

```bash
export ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name demo.example.com \
  --query 'HostedZones[0].Id' --output text | cut -d/ -f3)

# 2a. 兩個叢集的固定入口（把 <ELB_HOSTNAME> / <GCP_IP> 換成 Step 1 的結果）
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{
  "Changes": [
    {"Action":"UPSERT","ResourceRecordSet":{"Name":"app-aws.demo.example.com","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"<ELB_HOSTNAME>"}]}},
    {"Action":"UPSERT","ResourceRecordSet":{"Name":"app-gcp.demo.example.com","Type":"A","TTL":60,"ResourceRecords":[{"Value":"<GCP_IP>"}]}},
    {"Action":"UPSERT","ResourceRecordSet":{"Name":"db.bursting.demo.example.com","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"<ELB_HOSTNAME>"}]}}
  ]}'

# 2b. 全域 app 網域：加權 CNAME（初始 100/0）
./scripts/set-weights.sh 100 0   # 先修改腳本內的 ZONE_ID 與網域
```

> 加權記錄必須同名同類型，所以兩筆都用 CNAME 指向 2a 的中繼名稱，這是刻意的兩層設計。

## Step 3：建立 Secret（兩個叢集都要）

```bash
# DB 帳密（ocp-a 與 ocp-g 都要建，內容相同）
for ctx in ocp-a ocp-g; do
  oc --context $ctx apply -f ocp-a/01-namespace.yaml 2>/dev/null || true
  oc --context $ctx -n bursting-demo create secret generic db-credentials \
    --from-literal=user=demo --from-literal=password='demo1234' --from-literal=database=demodb
done
```

```bash
# Postgres TLS 憑證（自簽，CN = db route host）— 只在 ocp-a
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /tmp/db-tls.key -out /tmp/db-tls.crt \
  -subj "/CN=db.bursting.demo.example.com"
oc --context ocp-a -n bursting-demo create secret generic postgres-tls \
  --from-file=tls.crt=/tmp/db-tls.crt --from-file=tls.key=/tmp/db-tls.key
```

```bash
# burst-controller 的 AWS 認證（IAM user 只給 Route53 change/list 權限）
oc --context ocp-a -n bursting-demo create secret generic aws-route53 \
  --from-literal=AWS_ACCESS_KEY_ID=AKIA... \
  --from-literal=AWS_SECRET_ACCESS_KEY=...
```

IAM policy 範例：

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"],
    "Resource": "arn:aws:route53:::hostedzone/<ZONE_ID>"
  }]
}
```

## Step 4：部署 ocp-a（DB + 前端 + HPA + controller）

先把這些檔案裡標 `← 改` 的 domain / zone ID 改成你的：
[02-postgres.yaml](ocp-a/02-postgres.yaml)、[03-frontend.yaml](ocp-a/03-frontend.yaml)、[06-burst-controller.yaml](ocp-a/06-burst-controller.yaml)

```bash
oc --context ocp-a apply -f ocp-a/02-postgres.yaml -f ocp-a/03-frontend.yaml -f ocp-a/04-hpa.yaml -f ocp-a/06-burst-controller.yaml
```

驗證：

```bash
curl http://app.demo.example.com/        # 應回 {"site":"ocp-a(AWS)",...}
curl http://app.demo.example.com/db      # 應回 {"db":"ok",...}
```

## Step 5：部署告警規則（ocp-a）

```bash
oc --context ocp-a apply -f ocp-a/05-alert-rule.yaml
```

> 閾值（65%、for 2m）依你的 worker 規格調整：先跑一次壓測看 Console 的
> Observe → Metrics 查 `(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))) * 100`
> 確認能推得上去。demo 時想更快觸發可把 `for` 縮到 `1m`。

## Step 6：設定 Alertmanager webhook（ocp-a）

```bash
# 取出現行設定
oc --context ocp-a -n openshift-monitoring extract secret/alertmanager-main --to=/tmp --confirm
```

編輯 `/tmp/alertmanager.yaml`，在 `route.routes` 加入子路由、`receivers` 加入 receiver
（參考 [07-alertmanager-receiver.yaml](ocp-a/07-alertmanager-receiver.yaml)）：

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
      - url: http://burst-controller.bursting-demo.svc.cluster.local:8080/alert
        send_resolved: true
```

回寫：

```bash
oc --context ocp-a -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager.yaml \
  --dry-run=client -o yaml | oc --context ocp-a -n openshift-monitoring replace -f -
```

## Step 7：部署 ocp-g（Serverless + Knative 前端）

```bash
oc --context ocp-g apply -f ocp-g/01-serverless-operator.yaml
# 等 operator 裝好（csv 顯示 Succeeded）
oc --context ocp-g -n openshift-serverless get csv -w
oc --context ocp-g apply -f ocp-g/02-knative-serving.yaml
oc --context ocp-g -n knative-serving get knativeserving knative-serving -w   # Ready=True
```

改 [04-frontend-ksvc.yaml](ocp-g/04-frontend-ksvc.yaml) 裡的 domain 後：

```bash
oc --context ocp-g apply -f ocp-g/03-namespace-and-code.yaml
oc --context ocp-g -n bursting-demo create secret generic db-credentials \
  --from-literal=user=demo --from-literal=password='demo1234' --from-literal=database=demodb 2>/dev/null || true
oc --context ocp-g apply -f ocp-g/04-frontend-ksvc.yaml
```

驗證 ocp-g（直接打 GCP 入口，繞過加權 DNS）：

```bash
curl -H 'Host: app.demo.example.com' http://app-gcp.demo.example.com/db
# 應回 {"site":"ocp-g(GCP)","db":"ok",...} ← 證明跨雲連回 ocp-a 的 DB 成功
# 等 60 秒後 oc get pods 應看到 pod 消失（scale-to-zero）
```

## Step 8：演示！

終端機 1 — 觀察面板：

```bash
KUBECONFIG_A=~/ocp-a/auth/kubeconfig KUBECONFIG_G=~/ocp-g/auth/kubeconfig \
  ./scripts/watch-demo.sh http://app.demo.example.com
```

終端機 2 — 開壓：

```bash
./scripts/load-test.sh http://app.demo.example.com 150 900 1000
```

預期時間軸（約 8–10 分鐘）：

| 時間 | 現象 |
|---|---|
| 0–1 min | frontend CPU 飆高，HPA 開始加 replica（1→4→7→10） |
| 2–4 min | worker 節點平均 CPU 突破 65%，`ClusterCPUPressure` 進入 pending → firing |
| 4–5 min | Alertmanager 發 webhook，burst-controller 把權重改 50/50（看它的 log） |
| 5–6 min | 新 DNS 解析開始打到 ocp-g，Knative pod 從 0 喚醒，watch 面板出現 `→ ocp-g(GCP)` |
| 停止壓測後 | HPA 縮回 → 告警 resolved → 權重回 100/0 → ocp-g 約 1 分鐘後歸零 |

輔助觀察：

```bash
# controller 日誌（看 webhook 進來與改權重）
oc --context ocp-a -n bursting-demo logs deploy/burst-controller -f
```

```bash
# 告警狀態
oc --context ocp-a -n openshift-monitoring exec alertmanager-main-0 -- amtool alert --alertmanager.url=http://localhost:9093
```

### 視覺化演示（瀏覽器）

前端首頁本身就是 demo 面板，打開 `http://app.demo.example.com/`：

- **整頁底色**顯示這個頁面是誰服務的：橘色 = AWS (Primary)、藍色 = GCP (Burst)，並顯示 pod 名稱
- **請求落點燈條**：頁面每 2 秒背景發一個 `/whoami` 請求，橘點/藍點即時排開並累計數字。
  bursting 觸發後，觀眾會看到藍點開始混入；回縮後藍點消失
- 想看「整頁變藍」的效果，在分流生效後開一個**新的無痕視窗**重新載入（新連線 + 新 DNS 解析，約一半機率落在 GCP）

保底手法（100% 確定給觀眾看到 GCP 版頁面）：直接開 `http://app-gcp.demo.example.com/` 需帶 Host header 才會路由，所以更簡單的方式是用 curl 展示：

```bash
curl -s -H 'Host: app.demo.example.com' http://app-gcp.demo.example.com/whoami
```

另外 `/db` 端點回傳的 `hits_by_site` 是**由兩邊共同寫入同一個 DB 的累計數**——bursting 期間 `ocp-g(GCP)` 的計數會開始成長，同時證明了分流與跨雲 DB 連線兩件事。

DNS 快取備註：app 已回應 `Connection: close` 與 `Cache-Control: no-store` 避免黏連線，但 Chrome 自身的 DNS 快取約 60 秒，所以權重切換後燈條大約 15–60 秒才會出現藍點——這正好給你講解的時間。`load-test.sh` 每 30 秒重啟 hey 以重新解析 DNS。若當場告警沒觸發，用 `./scripts/set-weights.sh 50 50` 手動切換救場。

## 清理

```bash
oc --context ocp-a delete ns bursting-demo
oc --context ocp-a -n openshift-monitoring delete prometheusrule bursting-demo-rules
oc --context ocp-g delete ns bursting-demo
./scripts/set-weights.sh 100 0
```

---

## 檔案清單

| 檔案 | 內容 |
|---|---|
| [ocp-a/01-namespace.yaml](ocp-a/01-namespace.yaml) | namespace |
| [ocp-a/02-postgres.yaml](ocp-a/02-postgres.yaml) | PostgreSQL + TLS passthrough Route |
| [ocp-a/03-frontend.yaml](ocp-a/03-frontend.yaml) | 前端 app（/burn 燒 CPU、/db 讀寫 DB）+ Route |
| [ocp-a/04-hpa.yaml](ocp-a/04-hpa.yaml) | HPA（CPU 60% / Mem 80%，1→10） |
| [ocp-a/05-alert-rule.yaml](ocp-a/05-alert-rule.yaml) | PrometheusRule：ClusterCPUPressure |
| [ocp-a/06-burst-controller.yaml](ocp-a/06-burst-controller.yaml) | webhook 接收器，呼叫 Route 53 改權重 |
| [ocp-a/07-alertmanager-receiver.yaml](ocp-a/07-alertmanager-receiver.yaml) | Alertmanager 設定片段（參考用） |
| [ocp-g/01-serverless-operator.yaml](ocp-g/01-serverless-operator.yaml) | OpenShift Serverless Operator |
| [ocp-g/02-knative-serving.yaml](ocp-g/02-knative-serving.yaml) | KnativeServing 實例 |
| [ocp-g/03-namespace-and-code.yaml](ocp-g/03-namespace-and-code.yaml) | namespace + app code |
| [ocp-g/04-frontend-ksvc.yaml](ocp-g/04-frontend-ksvc.yaml) | Knative Service（scale-to-zero）+ DomainMapping |
| [scripts/load-test.sh](scripts/load-test.sh) | 壓測腳本 |
| [scripts/watch-demo.sh](scripts/watch-demo.sh) | 演示觀察面板 |
| [scripts/set-weights.sh](scripts/set-weights.sh) | 手動調整 Route 53 權重（救場用） |
