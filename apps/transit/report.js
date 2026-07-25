#!/usr/bin/env node
// 収集の進み具合を、progress/ から集計して見せる。`node ~/sandbox/tago/report.js`
const fs = require("fs"), path = require("path");
const dir = path.join(__dirname, "progress");
if (!fs.existsSync(dir)) { console.log("progress/ がまだ無い（未実行）"); process.exit(0); }
const files = fs.readdirSync(dir).filter(f => f.endsWith(".json"));
let stopsOk = 0, withBuses = 0, totReq = 0, done = 0, totCloud = 0;
const rows = [];
const bandPts = {};  // 時間帯（KST 時, -1=seed 既存分）ごとの GPS 点数
for (const f of files) {
  let s; try { s = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch { continue; }
  if (s.stops_ok) stopsOk++;
  totReq += s.reqs || 0;
  totCloud += (s.cloud || []).length;
  if ((s.cloud || []).length > 0) withBuses++;
  if (s.done) done++;
  for (const p of s.cloud || []) { const b = p.length >= 5 ? p[4] : -1; bandPts[b] = (bandPts[b] || 0) + 1; }
  rows.push({ rid: s.rid, cov: s.cov || 0, reqs: s.reqs || 0, cloud: (s.cloud || []).length, nseg: s.nseg || 0, done: !!s.done });
}
// 時間帯を読みやすい名前に丸める
const BANDNAME = h => h < 0 ? "既存(-1)" : h < 5 ? "深夜" : h < 7 ? "早朝" : h < 9 ? "朝ラッシュ" : h < 12 ? "午前" : h < 15 ? "昼" : h < 18 ? "午後" : h < 20 ? "夕ラッシュ" : h < 23 ? "夜" : "深夜";
const bandAgg = {};
for (const [h, n] of Object.entries(bandPts)) { const nm = BANDNAME(+h); bandAgg[nm] = (bandAgg[nm] || 0) + n; }
const avg = rows.length ? rows.reduce((a, r) => a + r.cov, 0) / rows.length : 0;
const pct = x => (100 * x).toFixed(1) + "%";
console.log(`=== 釜山バス収集 進捗（${new Date().toLocaleString("ja-JP", { timeZone: "Asia/Seoul" })} KST）===`);
console.log(`路線 ${files.length}／302  ｜  停留所取得 ${stopsOk}  ｜  実バス点あり ${withBuses}  ｜  done ${done}`);
console.log(`累計サンプルreq ${totReq}  ｜  実GPS点 ${totCloud}  ｜  平均カバレッジ（赤/全長） ${pct(avg)}`);
const bandLine = Object.entries(bandAgg).sort((a, b) => b[1] - a[1]).map(([nm, n]) => `${nm} ${n}`).join(" ｜ ");
console.log(`時間帯別GPS点: ${bandLine || "(なし)"}`);
const sorted = [...rows].sort((a, b) => b.cov - a.cov);
console.log(`\n-- カバレッジ上位5 --`);
for (const r of sorted.slice(0, 5)) console.log(`  ${r.rid}  ${pct(r.cov).padStart(6)}  (${r.nseg}区間 ${r.cloud}点 ${r.reqs}req${r.done ? " done" : ""})`);
console.log(`-- 下位5（バス少/短距離）--`);
for (const r of sorted.slice(-5)) console.log(`  ${r.rid}  ${pct(r.cov).padStart(6)}  (${r.nseg}区間 ${r.cloud}点 ${r.reqs}req${r.done ? " done" : ""})`);
