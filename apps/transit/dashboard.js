#!/usr/bin/env node
// 釜山バス収集の「全路線の状態」を見せる、ちいさなライブ・ダッシュボード。
// progress/ をリクエストのたびに集計して返す（collector は止めなくていい・別ポート）。
//   node ~/sandbox/tago/dashboard.js  →  http://localhost:8080
// 地図の線は出さない。カバレッジ・req・GPS点・時間帯・系統・状態だけ。
const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = __dirname;                               // コード＋seed（routes.jsonl）
const DATA = process.env.TAGO_DATA_DIR || __dirname;  // 生成データ（progress/daily）。コンテナでは volume
const PROG = path.join(DATA, "progress");
const PORT = process.env.WEB_PORT || 8080;
const BUDGET = Number(process.env.BUDGET) || 10000;

// rid -> {routeno, routetp, city}
function loadInventory() {
  const inv = {};
  for (const [city, cc] of [["busan", "21"], ["daegu", "22"]]) {
    const f = path.join(ROOT, city, "routes.jsonl");
    if (!fs.existsSync(f)) continue;
    for (const line of fs.readFileSync(f, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { const o = JSON.parse(line); inv[o.routeid] = { routeno: o.routeno, routetp: o.routetp, city }; } catch {}
    }
  }
  return inv;
}

const bandName = (h) => (h = +h, h < 0 ? "既存" : h < 5 ? "深夜" : h < 7 ? "早朝" : h < 9 ? "朝ラッシュ" : h < 12 ? "午前" : h < 15 ? "昼" : h < 18 ? "午後" : h < 20 ? "夕ラッシュ" : h < 23 ? "夜" : "深夜");

function buildStatus() {
  const INV = loadInventory();               // 起動後に路線が増えても拾えるよう毎回読む
  const routes = [];
  const bandAgg = {};
  const activeCities = new Set();
  let totReq = 0, totPts = 0, done = 0, held = 0, touched = 0, withBuses = 0, covSum = 0;
  const seen = new Set();

  let files = [];
  try { files = fs.readdirSync(PROG).filter((f) => f.endsWith(".json")); } catch {}
  for (const f of files) {
    let s;
    try { s = JSON.parse(fs.readFileSync(path.join(PROG, f), "utf8")); } catch { continue; }
    const rid = s.rid;
    if (!rid) continue;
    seen.add(rid);
    const meta = INV[rid] || {};
    if (meta.city) activeCities.add(meta.city);
    const bands = {};
    for (const p of s.cloud || []) {
      const b = p.length >= 5 ? p[4] : -1;
      bands[b] = (bands[b] || 0) + 1;
      const nm = bandName(b);
      bandAgg[nm] = (bandAgg[nm] || 0) + 1;
    }
    const pts = (s.cloud || []).length;
    routes.push({ rid, routeno: meta.routeno || rid, routetp: meta.routetp || "", city: meta.city || "", cov: s.cov || 0, reqs: s.reqs || 0, pts, nseg: s.nseg || 0, done: !!s.done, held: !!s.held, bands, touched: true });
    totReq += s.reqs || 0; totPts += pts; covSum += s.cov || 0; touched++;
    if (s.done) done++;
    if (s.held) held++;
    if (pts > 0) withBuses++;
  }
  // まだ手を付けてない路線（＝収集中の都市の残り）も「pending」で並べる
  for (const [rid, meta] of Object.entries(INV)) {
    if (seen.has(rid) || !activeCities.has(meta.city)) continue;
    routes.push({ rid, routeno: meta.routeno, routetp: meta.routetp, city: meta.city, cov: 0, reqs: 0, pts: 0, nseg: 0, done: false, bands: {}, touched: false });
  }
  routes.sort((a, b) => b.cov - a.cov || b.pts - a.pts || String(a.routeno).localeCompare(String(b.routeno)));
  let daily = { date: "", spent: 0 };
  try { daily = JSON.parse(fs.readFileSync(path.join(DATA, "daily.json"), "utf8")); } catch {}
  return { ts: Date.now(), total: routes.length, touched, done, held, withBuses, avgCov: touched ? covSum / touched : 0, totReq, totPts, budget: BUDGET, daily, bandAgg, cities: [...activeCities], routes };
}

const HTML = `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>釜山バス収集 — 全路線の状態</title>
<style>
  :root{--bg:#0f1216;--panel:#171b22;--panel2:#1e242d;--line:#2a323d;--ink:#e6eaf0;--dim:#8b97a7;--accent:#37c2a6;--track:#232a34;}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,"Hiragino Kaku Gothic ProN","Noto Sans KR",sans-serif}
  header{padding:16px 20px;border-bottom:1px solid var(--line);display:flex;align-items:baseline;gap:14px;flex-wrap:wrap;position:sticky;top:0;background:var(--bg);z-index:5}
  h1{font-size:17px;margin:0;font-weight:650}
  .sub{color:var(--dim);font-size:12px}
  .live{margin-left:auto;color:var(--dim);font-size:12px}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--accent);margin-right:5px;vertical-align:middle;animation:pulse 1.6s ease-in-out infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;padding:16px 20px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
  .card .k{color:var(--dim);font-size:11px;letter-spacing:.03em;text-transform:uppercase}
  .card .v{font-size:22px;font-weight:650;margin-top:3px;font-variant-numeric:tabular-nums}
  .card .v small{font-size:13px;color:var(--dim);font-weight:400}
  .bands{padding:0 20px 12px;display:flex;gap:6px;flex-wrap:wrap;align-items:center}
  .bands .lbl{color:var(--dim);font-size:12px;margin-right:2px}
  .chip{background:var(--panel2);border:1px solid var(--line);border-radius:999px;padding:3px 10px;font-size:12px;color:var(--ink)}
  .chip b{color:var(--accent);font-variant-numeric:tabular-nums}
  .toolbar{padding:0 20px 12px;display:flex;gap:10px;align-items:center}
  input[type=search]{background:var(--panel2);border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:7px 11px;font-size:13px;width:200px}
  .wrap{padding:0 20px 40px;overflow-x:auto}
  table{border-collapse:collapse;width:100%;min-width:720px}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
  th{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.03em;cursor:pointer;user-select:none;position:sticky;top:56px;background:var(--bg)}
  th.num,td.num{text-align:right;font-variant-numeric:tabular-nums}
  th[data-active]::after{content:" ▾";color:var(--accent)}
  th[data-active=asc]::after{content:" ▴";color:var(--accent)}
  tr:hover td{background:var(--panel)}
  .sys{display:inline-block;padding:2px 8px;border-radius:6px;font-size:11px;color:#0b0e12;font-weight:600}
  .bar{position:relative;width:150px;height:16px;background:var(--track);border-radius:5px;overflow:hidden;display:inline-block;vertical-align:middle}
  .bar>span{position:absolute;left:0;top:0;bottom:0;background:linear-gradient(90deg,#2f8f7d,var(--accent));border-radius:5px}
  .pct{display:inline-block;min-width:44px;text-align:right;font-variant-numeric:tabular-nums;margin-left:8px}
  .pending{color:var(--dim)}
  .badge{font-size:11px;padding:1px 7px;border-radius:5px;border:1px solid var(--line)}
  .badge.done{color:#0b0e12;background:var(--accent);border-color:var(--accent);font-weight:600}
  .badge.run{color:var(--accent)}
  .badge.held{color:#f2a63b;border-color:#5a4a26}
  .badge.wait{color:var(--dim)}
</style></head><body>
<header>
  <h1>釜山バス収集</h1><span class="sub">全路線の状態（線は表示しない）</span>
  <span class="live"><span class="dot"></span><span id="upd">…</span></span>
</header>
<div class="cards" id="cards"></div>
<div class="bands" id="bands"></div>
<div class="toolbar"><input id="q" type="search" placeholder="路線番号でしぼる…"></div>
<div class="wrap"><table><thead><tr id="head"></tr></thead><tbody id="rows"></tbody></table></div>
<script>
const SYS={"급행버스":"#e8463c","간선버스":"#2f6fd6","지선버스":"#37a24a","순환버스":"#f2a63b","마을버스":"#52b39a","광역버스":"#c0324a","일반버스":"#8a97a8","심야버스":"#7a5cc0"};
const sysColor=t=>SYS[t]||"#5a6472";
const COLS=[
  {k:"routeno",t:"路線",num:false,f:r=>r.routeno},
  {k:"routetp",t:"系統",num:false,f:r=>r.routetp?'<span class="sys" style="background:'+sysColor(r.routetp)+'">'+r.routetp.replace("버스","")+'</span>':''},
  {k:"cov",t:"カバレッジ 赤/全長",num:true,f:r=>{const p=(100*r.cov);const w=Math.max(p,r.touched?1.5:0);return '<span class="bar"><span style="width:'+w+'%"></span></span><span class="pct">'+(r.touched?p.toFixed(1)+'%':'—')+'</span>';}},
  {k:"reqs",t:"req",num:true,f:r=>r.reqs||0},
  {k:"pts",t:"GPS点",num:true,f:r=>r.pts||0},
  {k:"nseg",t:"区間",num:true,f:r=>r.nseg||0},
  {k:"status",t:"状態",num:false,f:r=>r.done?'<span class="badge done">done</span>':r.held?'<span class="badge held">保留</span>':r.touched?'<span class="badge run">収集中</span>':'<span class="badge wait">待機</span>'},
];
let sortK="cov",sortAsc=false,data=null,q="";
function fmtTime(ts){const d=new Date(ts);return d.toLocaleTimeString("ja-JP",{timeZone:"Asia/Seoul"})+" KST";}
function renderHead(){document.getElementById("head").innerHTML=COLS.map(c=>'<th class="'+(c.num?'num':'')+'" data-k="'+c.k+'"'+(c.k===sortK?' data-active="'+(sortAsc?'asc':'desc')+'"':'')+'>'+c.t+'</th>').join("");
  document.querySelectorAll("th").forEach(th=>th.onclick=()=>{const k=th.dataset.k;if(k===sortK)sortAsc=!sortAsc;else{sortK=k;sortAsc=false;}render();});}
function cards(d){const c=[
  ["着手 / 全",d.touched+' <small>/ '+d.total+'</small>'],
  ["完了 done",d.done],
  ["保留 revisit",d.held],
  ["収集中(バス有)",d.withBuses],
  ["平均カバレッジ",(100*d.avgCov).toFixed(1)+'<small>%</small>'],
  ["本日req",(d.daily&&d.daily.date?d.daily.spent:0)+' <small>/ '+d.budget+'</small>'],
  ["累計req(全期間)",d.totReq.toLocaleString()],
  ["実GPS点",d.totPts.toLocaleString()],
];document.getElementById("cards").innerHTML=c.map(([k,v])=>'<div class="card"><div class="k">'+k+'</div><div class="v">'+v+'</div></div>').join("");}
function bands(d){const order=["朝ラッシュ","午前","昼","午後","夕ラッシュ","夜","深夜","早朝","既存"];
  const es=Object.entries(d.bandAgg).sort((a,b)=>(order.indexOf(a[0])-order.indexOf(b[0])));
  document.getElementById("bands").innerHTML='<span class="lbl">時間帯別GPS点</span>'+(es.length?es.map(([k,v])=>'<span class="chip">'+k+' <b>'+v.toLocaleString()+'</b></span>').join(""):'<span class="chip">まだ無し</span>');}
function render(){if(!data)return;renderHead();cards(data);bands(data);
  const col=COLS.find(c=>c.k===sortK);
  let rows=data.routes.slice();
  if(q)rows=rows.filter(r=>String(r.routeno).toLowerCase().includes(q));
  rows.sort((a,b)=>{let x,y;if(sortK==="status"){const rk=r=>r.done?3:(r.touched&&!r.held?2:(r.held?1:0));x=rk(a);y=rk(b);}else if(sortK==="routeno"){x=String(a.routeno);y=String(b.routeno);return (sortAsc?1:-1)*x.localeCompare(y,undefined,{numeric:true});}else if(sortK==="routetp"){x=a.routetp||"";y=b.routetp||"";return (sortAsc?1:-1)*x.localeCompare(y);}else{x=a[sortK]||0;y=b[sortK]||0;}return sortAsc?x-y:y-x;});
  document.getElementById("rows").innerHTML=rows.map(r=>'<tr'+(r.touched?'':' class="pending"')+'>'+COLS.map(c=>'<td class="'+(c.num?'num':'')+'">'+c.f(r)+'</td>').join("")+'</tr>').join("");
  document.getElementById("upd").textContent="更新 "+fmtTime(data.ts)+" ・ "+rows.length+"路線";}
async function tick(){try{const r=await fetch("/status.json",{cache:"no-store"});data=await r.json();render();}catch(e){document.getElementById("upd").textContent="接続待ち…";}}
document.getElementById("q").addEventListener("input",e=>{q=e.target.value.trim().toLowerCase();render();});
tick();setInterval(tick,5000);
</script></body></html>`;

http.createServer((req, res) => {
  if (req.url.startsWith("/status.json")) {
    const body = JSON.stringify(buildStatus());
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*" });
    res.end(body);
  } else {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    res.end(HTML);
  }
}).listen(PORT, () => console.log("dashboard: http://localhost:" + PORT + "  （progress/ をライブ集計）"));
