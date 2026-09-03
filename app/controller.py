# burst-controller（由 scripts/render.sh 塞進 ocp-a/06-burst-controller.yaml 的 ConfigMap）
# 接收 Alertmanager webhook，依兩邊 ready pod 數比例調整 Route 53 加權；細節見 yaml 檔頭註解
import os, time, threading
import boto3, requests
from flask import Flask, request, jsonify

app = Flask(__name__)
ZONE = os.environ["HOSTED_ZONE_ID"]
RECORD = os.environ["RECORD_NAME"]            # 例 app.demo.example.com.
AWS_TARGET = os.environ["AWS_TARGET"]          # 例 app-aws.demo.example.com.
GCP_TARGET = os.environ["GCP_TARGET"]          # 例 app-gcp.demo.example.com.
TTL = int(os.environ.get("TTL", "15"))
NS = os.environ["NAMESPACE"]
MODE = os.environ.get("BURST_MODE", "proportional")       # proportional | fixed
KICK_AWS = int(os.environ.get("BURST_AWS_WEIGHT", "50"))  # fixed 模式權重 / proportional 起手權重
KICK_GCP = int(os.environ.get("BURST_GCP_WEIGHT", "50"))
GCP_MIN_PODS = int(os.environ.get("BURST_GCP_MIN_PODS", "2"))
INTERVAL = int(os.environ.get("RECONCILE_SECONDS", "15"))
LOCAL_SEL = os.environ.get("LOCAL_POD_SELECTOR", "app=frontend")
REMOTE_SEL = os.environ.get("REMOTE_POD_SELECTOR", "serving.knative.dev/service=frontend")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

r53 = boto3.client("route53")
lock = threading.Lock()
state = {"mode": "normal", "weights": {"ocp-a": None, "ocp-g": None},
         "pods": {"ocp-a": None, "ocp-g": None}, "last_error": None}

def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)

# ---------- Route 53 ----------
def upsert(identifier, target, weight):
    return {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": RECORD, "Type": "CNAME", "TTL": TTL,
        "SetIdentifier": identifier, "Weight": weight,
        "ResourceRecords": [{"Value": target}]}}

def set_weights(aws_w, gcp_w, reason=""):
    aws_w, gcp_w = int(aws_w), int(gcp_w)
    with lock:
        if state["weights"] == {"ocp-a": aws_w, "ocp-g": gcp_w}:
            return
        r53.change_resource_record_sets(HostedZoneId=ZONE, ChangeBatch={"Changes": [
            upsert("ocp-a", AWS_TARGET, aws_w), upsert("ocp-g", GCP_TARGET, gcp_w)]})
        state["weights"] = {"ocp-a": aws_w, "ocp-g": gcp_w}
    log(f"weights set: ocp-a={aws_w} ocp-g={gcp_w} {reason}")

# ---------- Kubernetes API：算 ready pod 數 ----------
def local_api():
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(f"{SA_DIR}/token") as f:
        return f"https://{host}:{port}", f.read().strip(), f"{SA_DIR}/ca.crt"

def remote_api():
    api, tok = os.environ.get("OCP_G_API"), os.environ.get("OCP_G_TOKEN")
    if not api or not tok:
        return None
    ca = os.environ.get("OCP_G_CA")
    verify = True
    if ca:
        with open("/tmp/ocp-g-ca.crt", "w") as f:
            f.write(ca)
        verify = "/tmp/ocp-g-ca.crt"
    elif os.environ.get("OCP_G_INSECURE", "false").lower() == "true":
        verify = False
    return api.rstrip("/"), tok.strip(), verify

def ready_pods(api, token, verify, selector):
    r = requests.get(f"{api}/api/v1/namespaces/{NS}/pods",
                     params={"labelSelector": selector},
                     headers={"Authorization": f"Bearer {token}"},
                     verify=verify, timeout=10)
    r.raise_for_status()
    n = 0
    for p in r.json().get("items", []):
        if p.get("metadata", {}).get("deletionTimestamp"):
            continue
        conds = p.get("status", {}).get("conditions", [])
        if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds):
            n += 1
    return n

def proportional_weights():
    pa = ready_pods(*local_api(), LOCAL_SEL)
    rem = remote_api()
    if rem is None:
        raise RuntimeError("沒有 ocp-g-reader secret，無法讀 ocp-g pod 數（退回起手權重）")
    pg = ready_pods(*rem, REMOTE_SEL)
    state["pods"] = {"ocp-a": pa, "ocp-g": pg}
    if pg == 0:
        # ocp-g 還沒醒：維持起手權重，讓 Knative 先被喚醒
        return KICK_AWS, KICK_GCP, f"(pods a={pa} g=0, 等待 ocp-g 喚醒)"
    wa, wg = max(pa, 1), max(pg, GCP_MIN_PODS)
    scale = 255 / max(wa, wg) if max(wa, wg) > 255 else 1   # Route 53 權重上限 255
    return max(1, round(wa * scale)), max(1, round(wg * scale)), f"(pods a={pa} g={pg})"

def reconcile_loop():
    while True:
        time.sleep(INTERVAL)
        if state["mode"] != "bursting" or MODE != "proportional":
            continue
        try:
            a, g, why = proportional_weights()
            set_weights(a, g, why)
            state["last_error"] = None
        except Exception as e:
            state["last_error"] = str(e)
            log(f"reconcile error: {e}")

# ---------- Alertmanager webhook ----------
@app.route("/alert", methods=["POST"])
def alert():
    payload = request.get_json(force=True)
    status = payload.get("status", "unknown")
    names = [a.get("labels", {}).get("alertname") for a in payload.get("alerts", [])]
    log(f"webhook received: status={status} alerts={names}")
    if status == "firing":
        first = state["mode"] != "bursting"
        state["mode"] = "bursting"
        if first:
            set_weights(KICK_AWS, KICK_GCP, "(bursting 起手權重)")
    elif status == "resolved":
        state["mode"] = "normal"
        set_weights(100, 0, "(resolved，回縮)")
    return jsonify(ok=True, mode=state["mode"], weights=state["weights"])

@app.route("/status")
def status():
    return jsonify(mode=state["mode"], balance_mode=MODE, weights=state["weights"],
                   pods=state["pods"], last_error=state["last_error"])

threading.Thread(target=reconcile_loop, daemon=True).start()
log(f"burst-controller started: mode={MODE} kick={KICK_AWS}/{KICK_GCP} interval={INTERVAL}s "
    f"remote={'configured' if remote_api() else 'NOT configured'}")
app.run(host="0.0.0.0", port=8080)
