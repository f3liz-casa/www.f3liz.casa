#!/usr/bin/env node
// transit.f3liz.casa の web：地図(/) ＋ ダッシュボード(/dashboard) ＋ 収集データ。
//   /            地図（全路線の赤青オーバーレイ＋バス現在位置）
//   /dashboard   全路線の状態テーブル
//   /corrected/<id>_corrected.geojson   確定線
//   /routes.json 収集済み routeid 一覧
//   /buses.json  バスの現在位置（collector が /data/live に書いた最新）
//   /status.json 集計（地図バー＋ダッシュボード共用）
const http = require("http"), fs = require("fs"), path = require("path");
const WEB = path.join(__dirname, "web");
const ROOT = __dirname;
const DATA = process.env.TAGO_DATA_DIR || __dirname;
const CORRECTED = path.join(DATA, "corrected");
const FUSED = path.join(DATA, "fused");   // 路線間fusion(借用)を載せた派生geojson。あれば /corrected で優先配信。
const PROG = path.join(DATA, "progress");
const LIVE = path.join(DATA, "live");
const PORT = process.env.WEB_PORT || 8080;
const BUDGET = Number(process.env.BUDGET) || 10000;

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript",
  ".wasm": "application/wasm", ".css": "text/css", ".json": "application/json",
  ".geojson": "application/json", ".f32": "application/octet-stream",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
};
const send = (res, code, body, type) => {
  res.writeHead(code, { "Content-Type": type || "text/plain; charset=utf-8", "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*" });
  res.end(body);
};
const serveFile = (res, fp) => fs.readFile(fp, (e, buf) => e ? send(res, 404, "not found") : send(res, 200, buf, MIME[path.extname(fp).toLowerCase()] || "application/octet-stream"));

function routesManifest() {
  let ids = [];
  try { ids = fs.readdirSync(CORRECTED).filter((f) => /_corrected\.geojson$/.test(f) && !f.startsWith("._")).map((f) => f.replace("_corrected.geojson", "")); } catch {}
  if (!ids.length) { try { for (const l of fs.readFileSync(path.join(ROOT, "busan", "routes.jsonl"), "utf8").split("\n")) { if (l.trim()) ids.push(JSON.parse(l).routeid); } } catch {} }
  return ids;
}

// バスの現在位置：collector が /data/live/<rid>.json に書いた最新をまとめる。
function liveBuses() {
  const out = [];
  const now = Date.now();
  let files = []; try { files = fs.readdirSync(LIVE).filter((f) => f.endsWith(".json") && !f.startsWith("._")); } catch {}
  for (const f of files) {
    try {
      const fp = path.join(LIVE, f);
      if (now - fs.statSync(fp).mtimeMs > 300000) continue;   // 5分より古い＝いま叩いてない路線→現在位置でないので出さない(focus回転で古いのを残さない)
      const a = JSON.parse(fs.readFileSync(fp, "utf8"));
      for (const b of a) out.push([b.lng, b.lat]);
    } catch {}
  }
  return out;
}

// rid -> {routeno, routetp, city}
function loadInventory() {
  const inv = {};
  for (const [city] of [["busan", "21"], ["daegu", "22"]]) {
    const f = path.join(ROOT, city, "routes.jsonl");
    if (!fs.existsSync(f)) continue;
    for (const line of fs.readFileSync(f, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { const o = JSON.parse(line); inv[o.routeid] = { routeno: o.routeno, routetp: o.routetp, city }; } catch {}
    }
  }
  return inv;
}
const bandName = (h) => (h = +h, h < 0 ? "기존" : h < 5 ? "심야" : h < 7 ? "새벽" : h < 9 ? "출근" : h < 12 ? "오전" : h < 15 ? "낮" : h < 18 ? "오후" : h < 20 ? "퇴근" : h < 23 ? "밤" : "심야");

function buildStatus() {
  const INV = loadInventory();
  const routes = [];
  const bandAgg = {};
  const activeCities = new Set();
  let totReq = 0, totPts = 0, done = 0, held = 0, touched = 0, withBuses = 0, covSum = 0;
  const seen = new Set();
  let files = []; try { files = fs.readdirSync(PROG).filter((f) => f.endsWith(".json") && !f.startsWith("._")); } catch {}
  for (const f of files) {
    let s; try { s = JSON.parse(fs.readFileSync(path.join(PROG, f), "utf8")); } catch { continue; }
    const rid = s.rid; if (!rid) continue;
    seen.add(rid);
    const meta = INV[rid] || {};
    if (meta.city) activeCities.add(meta.city);
    // cloud は SQLite にあるので、collector が metadata に書いた npts(点数) と bands(時間帯別) を使う。
    for (const [b, c] of Object.entries(s.bands || {})) { bandAgg[bandName(b)] = (bandAgg[bandName(b)] || 0) + c; }
    const pts = s.npts != null ? s.npts : (s.cloud || []).length;
    routes.push({ rid, routeno: meta.routeno || rid, routetp: meta.routetp || "", cov: s.cov || 0, reqs: s.reqs || 0, pts, nseg: s.nseg || 0, done: !!s.done, held: !!s.held, touched: true });
    totReq += s.reqs || 0; totPts += pts; covSum += s.cov || 0; touched++;
    if (s.done) done++; if (s.held) held++; if (pts > 0) withBuses++;
  }
  for (const [rid, meta] of Object.entries(INV)) {
    if (seen.has(rid) || !activeCities.has(meta.city)) continue;
    routes.push({ rid, routeno: meta.routeno, routetp: meta.routetp, cov: 0, reqs: 0, pts: 0, nseg: 0, done: false, held: false, touched: false });
  }
  routes.sort((a, b) => b.cov - a.cov || b.pts - a.pts || String(a.routeno).localeCompare(String(b.routeno)));
  let daily = { date: "", spent: 0 }; try { daily = JSON.parse(fs.readFileSync(path.join(DATA, "daily.json"), "utf8")); } catch {}
  return { ts: Date.now(), total: routes.length, touched, done, held, withBuses, avgCov: touched ? covSum / touched : 0, totReq, totPts, points: totPts, budget: BUDGET, daily, bandAgg, routes };
}

http.createServer((req, res) => {
  const url = decodeURIComponent((req.url || "/").split("?")[0]);
  if (url === "/routes.json") return send(res, 200, JSON.stringify({ routes: routesManifest() }), "application/json");
  if (url === "/buses.json") return send(res, 200, JSON.stringify({ buses: liveBuses() }), "application/json");
  if (url === "/status.json") return send(res, 200, JSON.stringify(buildStatus()), "application/json");
  if (url === "/model.json") return serveFile(res, path.join(DATA, "model.json"));   // learn.jl の速度モデル＋検証残差
  if (url === "/dashboard" || url === "/dashboard/") return serveFile(res, path.join(WEB, "dashboard.html"));
  if (url.startsWith("/corrected/")) {
    const name = path.basename(url);
    if (!/^[\w.-]+_corrected\.geojson$/.test(name)) return send(res, 400, "bad");
    const fused = path.join(FUSED, name);   // fusion 済みがあれば優先（借用=ピンク付き）、無ければ自分の実測のみ
    return fs.access(fused, fs.constants.R_OK, (e) => serveFile(res, e ? path.join(CORRECTED, name) : fused));
  }
  const rel = url === "/" ? "/index.html" : url;
  const fp = path.normalize(path.join(WEB, rel));
  if (!fp.startsWith(WEB)) return send(res, 400, "bad");
  serveFile(res, fp);
}).listen(PORT, () => console.log("transit web: http://localhost:" + PORT + "  (/ 地図, /dashboard, /corrected, /routes.json, /buses.json, /status.json)"));
