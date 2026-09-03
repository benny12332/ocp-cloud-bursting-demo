# 前端 app（ocp-a 與 ocp-g 共用同一份，由 scripts/render.sh 塞進兩邊的 ConfigMap）
#   /            demo 面板：誰在服務、請求落點燈條、PostgreSQL 內容（兩邊都連 ocp-a 的 DB）
#   /whoami      回報 site / pod（燈條用）
#   /api/db      唯讀：DB 連線資訊、各站點 hits 計數、最近留言（面板每 5 秒撈一次）
#   /api/message POST 留言 → 寫進 DB（從 GCP 頁面寫的留言，AWS 頁面也看得到）
#   /db          寫一筆 hit 並回傳計數（curl 驗證用）
#   /burn        燒 CPU（觸發 HPA 用），?ms=500 控制每個 request 燒多久
import os, time, socket, threading
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)
SITE = os.environ.get("SITE", "unknown")
POD = socket.gethostname()
IS_GCP = "gcp" in SITE.lower()
COLOR = "#1a73e8" if IS_GCP else "#e8590c"
CLOUD = "GCP &mdash; Burst" if IS_GCP else "AWS &mdash; Primary"
DB_HOST = os.environ.get("DB_HOST", "?")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_SSLMODE = os.environ.get("DB_SSLMODE", "disable")
DB_VIA = f"{DB_HOST}:{DB_PORT} (sslmode={DB_SSLMODE})"
DISPLAY_TZ = os.environ.get("DISPLAY_TZ", "Asia/Taipei")

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>Cloud Bursting Demo</title>
<style>
  body{margin:0;font-family:system-ui,sans-serif;color:#fff;background:__COLOR__;
       display:flex;flex-direction:column;align-items:center;min-height:100vh;
       transition:background 1s;padding-bottom:2rem}
  .card{background:rgba(0,0,0,.28);padding:1.2rem 2.5rem;border-radius:14px;
        margin-top:1.8rem;text-align:center;max-width:85vw;min-width:min(85vw,640px)}
  h1{font-size:3.2rem;margin:.2em 0}
  h2{font-size:1.1rem;margin:0 0 .6rem;opacity:.9;font-weight:600}
  .pod,.via{opacity:.85;font-size:.9rem}
  #strip{display:flex;flex-wrap:wrap;gap:5px;justify-content:center;
         max-width:70vw;margin-top:1rem;min-height:26px}
  .dot{width:20px;height:20px;border-radius:50%;border:2px solid #fff}
  .aws{background:#e8590c}.gcp{background:#1a73e8}
  #stats{font-size:1.3rem;margin-top:.8rem}
  .badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:.85rem;
         font-weight:600;margin:0 4px}
  table{margin:.6rem auto 0;border-collapse:collapse;font-size:.92rem;width:100%}
  th,td{padding:4px 10px;text-align:left;border-bottom:1px solid rgba(255,255,255,.25)}
  th{opacity:.8;font-weight:600}
  td.site{white-space:nowrap}
  form{margin-top:.8rem;display:flex;gap:6px;justify-content:center}
  input{flex:1;max-width:420px;padding:6px 10px;border-radius:8px;border:none;font-size:1rem}
  button{padding:6px 14px;border-radius:8px;border:none;background:#fff;color:#333;
         font-weight:600;cursor:pointer}
  #dbstat.err{color:#ffd1d1}
</style></head><body>
<div class="card"><div>這個頁面由誰服務？</div><h1>__CLOUD__</h1>
  <div class="pod">pod: __POD__</div></div>

<div class="card"><h2>即時請求落點（每 2 秒一發，最近 60 個）</h2>
  <div id="strip"></div><div id="stats"></div></div>

<div class="card"><h2>PostgreSQL 內容（DB 在 ocp-a / AWS）</h2>
  <div class="via">本站連線路徑：<code>__DB_VIA__</code></div>
  <div id="dbstat">連線中…</div>
  <div id="counts" style="margin-top:.5rem"></div>
  <table><thead><tr><th>#</th><th>寫入站點</th><th>pod</th><th>留言</th><th>時間</th></tr></thead>
    <tbody id="msgs"></tbody></table>
  <form id="f"><input id="msg" maxlength="200" placeholder="留言會寫進 ocp-a 的 DB，另一朵雲的頁面也會看到">
    <button>送出</button></form>
</div>

<script>
  let c={aws:0,gcp:0};
  const isG=s=>(s||'').toLowerCase().includes('gcp');
  const badge=s=>'<span class="badge '+(isG(s)?'gcp':'aws')+'">'+s+'</span>';
  const esc=s=>String(s).replace(/[&<>"]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]));
  async function ping(){
    try{
      const r=await fetch('/whoami?ts='+Date.now(),{cache:'no-store'});
      const d=await r.json();
      const g=isG(d.site);
      c[g?'gcp':'aws']++;
      const dot=document.createElement('div');
      dot.className='dot '+(g?'gcp':'aws');
      dot.title=d.site+' / '+d.pod;
      const s=document.getElementById('strip');
      s.prepend(dot);
      while(s.children.length>60)s.removeChild(s.lastChild);
      document.getElementById('stats').textContent='AWS: '+c.aws+'  |  GCP: '+c.gcp;
    }catch(e){}
  }
  async function refreshDb(){
    const st=document.getElementById('dbstat');
    try{
      const r=await fetch('/api/db?ts='+Date.now(),{cache:'no-store'});
      const d=await r.json();
      if(d.db!=='ok'){st.className='err';st.textContent='DB 連線失敗：'+d.detail;return;}
      st.className='';st.textContent='DB 連線 OK（這筆資料由 '+d.site+' / '+d.pod+' 讀出）';
      const h=d.hits_by_site||{};
      document.getElementById('counts').innerHTML='累計 hits：'+
        (Object.keys(h).length?Object.entries(h).map(([k,v])=>badge(k)+' '+v).join(' '):'（尚無）');
      document.getElementById('msgs').innerHTML=(d.messages||[]).map(m=>
        '<tr><td>'+m.id+'</td><td class="site">'+badge(m.site)+'</td><td>'+esc(m.pod)+'</td>'+
        '<td>'+esc(m.text)+'</td><td>'+esc(m.ts)+'</td></tr>').join('');
    }catch(e){st.className='err';st.textContent='DB 讀取失敗：'+e;}
  }
  document.getElementById('f').addEventListener('submit',async ev=>{
    ev.preventDefault();
    const inp=document.getElementById('msg');const text=inp.value.trim();if(!text)return;
    await fetch('/api/message',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({text})});
    inp.value='';refreshDb();
  });
  setInterval(ping,2000);ping();
  setInterval(refreshDb,5000);refreshDb();
</script></body></html>"""

_db_ready = False
_db_lock = threading.Lock()

def db_conn():
    import psycopg
    return psycopg.connect(
        host=DB_HOST, port=DB_PORT,
        user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
        dbname=os.environ["DB_NAME"], sslmode=DB_SSLMODE, connect_timeout=5,
    )

def ensure_schema(cur):
    global _db_ready
    if _db_ready:
        return
    with _db_lock:
        cur.execute("CREATE TABLE IF NOT EXISTS hits (id serial PRIMARY KEY, site text, pod text, ts timestamptz DEFAULT now())")
        cur.execute("CREATE TABLE IF NOT EXISTS messages (id serial PRIMARY KEY, site text, pod text, text text, ts timestamptz DEFAULT now())")
        cur.execute("SELECT count(*) FROM messages")
        if cur.fetchone()[0] == 0:
            cur.execute("INSERT INTO messages (site, pod, text) VALUES (%s, %s, %s)",
                        (SITE, POD, "DB 初始化完成（第一個連上來的站點寫的）"))
        _db_ready = True

def no_cache(resp):
    resp.headers["Cache-Control"] = "no-store"
    resp.headers["Connection"] = "close"   # 避免 keep-alive 黏在同一個叢集
    return resp

@app.route("/")
def index():
    html = (PAGE.replace("__COLOR__", COLOR).replace("__CLOUD__", CLOUD)
                .replace("__POD__", POD).replace("__DB_VIA__", DB_VIA))
    return no_cache(make_response(html))

@app.route("/whoami")
def whoami():
    return no_cache(jsonify(site=SITE, pod=POD))

@app.route("/burn")
def burn():
    ms = min(int(request.args.get("ms", "500")), 5000)
    end = time.time() + ms / 1000.0
    x = 0
    while time.time() < end:
        x += 1
    return jsonify(site=SITE, pod=POD, burned_ms=ms)

@app.route("/api/db")
def api_db():
    try:
        with db_conn() as conn, conn.cursor() as cur:
            ensure_schema(cur)
            cur.execute("SELECT site, count(*) FROM hits GROUP BY site ORDER BY site")
            hits = {k: v for k, v in cur.fetchall()}
            cur.execute("SELECT id, site, pod, text, to_char(ts AT TIME ZONE %s, 'MM-DD HH24:MI:SS') "
                        "FROM messages ORDER BY id DESC LIMIT 10", (DISPLAY_TZ,))
            msgs = [dict(id=r[0], site=r[1], pod=r[2], text=r[3], ts=r[4]) for r in cur.fetchall()]
        return no_cache(jsonify(site=SITE, pod=POD, db="ok", db_via=DB_VIA, hits_by_site=hits, messages=msgs))
    except Exception as e:
        return no_cache(jsonify(site=SITE, pod=POD, db="error", db_via=DB_VIA, detail=str(e))), 500

@app.route("/api/message", methods=["POST"])
def api_message():
    data = request.get_json(silent=True) or request.form
    text = (data.get("text") or "").strip()[:200]
    if not text:
        return jsonify(ok=False, detail="empty"), 400
    try:
        with db_conn() as conn, conn.cursor() as cur:
            ensure_schema(cur)
            cur.execute("INSERT INTO messages (site, pod, text) VALUES (%s, %s, %s) RETURNING id", (SITE, POD, text))
            new_id = cur.fetchone()[0]
        return no_cache(jsonify(ok=True, id=new_id, site=SITE, pod=POD))
    except Exception as e:
        return no_cache(jsonify(ok=False, site=SITE, pod=POD, detail=str(e))), 500

@app.route("/db")
def db():
    try:
        with db_conn() as conn, conn.cursor() as cur:
            ensure_schema(cur)
            cur.execute("INSERT INTO hits (site, pod) VALUES (%s, %s)", (SITE, POD))
            cur.execute("SELECT site, count(*) FROM hits GROUP BY site")
            rows = dict(cur.fetchall())
        return no_cache(jsonify(site=SITE, pod=POD, db="ok", db_via=DB_VIA, hits_by_site=rows))
    except Exception as e:
        return no_cache(jsonify(site=SITE, pod=POD, db="error", db_via=DB_VIA, detail=str(e))), 500

app.run(host="0.0.0.0", port=8080, threaded=True)
