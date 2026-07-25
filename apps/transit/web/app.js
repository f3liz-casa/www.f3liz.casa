// 地図を組み立てるところ。ふだんは、ここは触らなくて大丈夫。
// 足したいものは data.js のほうへ。

(function () {
  const mapEl = document.getElementById("map");

  // Naver の地図がまだ読み込めていないとき（キー未設定など）は、
  // 白い画面のかわりに、やさしい案内を出す。
  if (typeof naver === "undefined" || !naver.maps) {
    mapEl.classList.add("no-key");
    mapEl.innerHTML = `
      <div class="guide">
        <h1>もう少しで、地図が出ます</h1>
        <p>Naver の地図を出すには、<b>Client ID（キー）</b>がひとつ要ります。
        <code>index.html</code> の中の <code>YOUR_NAVER_KEY_ID</code> を、
        あなたのキーに書きかえてください。</p>
        <p>キーの取りかたは <code>README.md</code> に書いてあります。
        ゆっくりで大丈夫。</p>
      </div>`;
    return;
  }

  // 地図の中心：経路があれば経路に、なければ置いたものに、どちらも無ければソウルへ。
  const routePts = (window.ROUTES || []).flatMap((r) =>
    r.coords.map(([lat, lng]) => ({ lat, lng }))
  );
  const points = [...(window.PLACES || []), ...(window.AREAS || [])];
  const center = routePts.length
    ? avgLatLng(routePts)
    : points.length
      ? avgLatLng(points)
      : new naver.maps.LatLng(37.5563, 126.9300);

  const map = new naver.maps.Map(mapEl, {
    center,
    zoom: 14,
    mapTypeControl: false,
    scaleControl: false,
    logoControl: true,
    mapDataControl: false,
    zoomControl: true,
    zoomControlOptions: { position: naver.maps.Position.RIGHT_CENTER },
  });

  const info = new naver.maps.InfoWindow({
    borderWidth: 0,
    disableAnchor: false,
    backgroundColor: "#fff",
    borderColor: "#e7e1d6",
    anchorColor: "#fff",
    pixelOffset: new naver.maps.Point(0, -6),
  });

  // ── 街の空気：やわらかい色の円 ──
  (window.AREAS || []).forEach((a) => {
    const circle = new naver.maps.Circle({
      map,
      center: new naver.maps.LatLng(a.lat, a.lng),
      radius: a.radius,
      fillColor: a.color,
      fillOpacity: 0.22,
      strokeColor: a.color,
      strokeOpacity: 0.5,
      strokeWeight: 1,
      clickable: true,
    });
    naver.maps.Event.addListener(circle, "click", (e) => {
      info.setContent(
        `<div class="bubble area">
           <div class="head">${escapeHtml(a.name)}</div>
           <div class="mood">${escapeHtml(a.mood)}</div>
         </div>`
      );
      info.setPosition(e.coord);
      info.open(map);
    });
  });

  // ── 行ったところ：三色のピン ──
  const rateLabel = { suki: "すき", futsuu: "ふつう", imaichi: "いまいち" };
  (window.PLACES || []).forEach((p) => {
    const rate = rateLabel[p.rating] ? p.rating : "futsuu";
    const marker = new naver.maps.Marker({
      map,
      position: new naver.maps.LatLng(p.lat, p.lng),
      icon: {
        content: `<div class="pin ${rate}"></div>`,
        anchor: new naver.maps.Point(8, 8),
      },
      zIndex: 100,
    });
    naver.maps.Event.addListener(marker, "click", () => {
      info.setContent(
        `<div class="bubble">
           <div class="head">${escapeHtml(p.name)}</div>
           <span class="rate ${rate}">${rateLabel[rate]}</span>
           ${p.note ? `<div class="note">${escapeHtml(p.note)}</div>` : ""}
         </div>`
      );
      info.open(map, marker);
    });
  });

  // 経路ぜんたいが見えるように、地図をあわせる。
  if (routePts.length) {
    const b = new naver.maps.LatLngBounds(
      new naver.maps.LatLng(routePts[0].lat, routePts[0].lng),
      new naver.maps.LatLng(routePts[0].lat, routePts[0].lng)
    );
    routePts.forEach((p) => b.extend(new naver.maps.LatLng(p.lat, p.lng)));
    map.fitBounds(b);
  }

  // ── 手法A：停留所→道路グラフ最短経路 のマッチ結果（緑）。バスGPS(赤青)と見比べる用。 ──
  fetch("/roads/matched_3001.geojson")
    .then((r) => (r.ok ? r.json() : null))
    .then((gj) => {
      if (!gj) return;
      const g = gj.geometry;
      // MultiLineString（穴あき）。各線を描き、穴は描かない＝人が直す所。
      const lines = g.type === "MultiLineString" ? g.coordinates : [g.coordinates];
      lines.forEach((ln) => {
        const path = ln.map(([lng, lat]) => new naver.maps.LatLng(lat, lng));
        new naver.maps.Polyline({
          map,
          path,
          strokeColor: "#1a9850",
          strokeOpacity: 0.7,
          strokeWeight: 3,
          zIndex: 2,
        });
      });
    })
    .catch(() => {});

  // ── Julie の画布：確定パス（赤青）が、この道の上に乗る（overlay-bridge.js があれば） ──
  window.initJulieOverlay?.(map, { origin: center });

  // ── 道路をなぞるマップエディタ（editor.js があれば） ──
  window.initRouteEditor?.(map);

  // ── 地図をクリックすると、座標をそっと出す（data.js に貼る用） ──
  // ── 人の補正：正しい道をクリック→補正点として溜まる（ピンが立つ）。
  //    右下の表示をクリックで JSON をコピー → corrections_3001.json に貼って apply_corrections.py。 ──
  const coordEl = document.querySelector(".coord");
  const coordVal = document.getElementById("coord-val");
  const fixes = [];
  naver.maps.Event.addListener(map, "click", (e) => {
    if (window.__editMode) return; // エディタ編集中はこちらは無視
    const lng = +e.coord.lng().toFixed(6);
    const lat = +e.coord.lat().toFixed(6);
    fixes.push([lng, lat]);
    new naver.maps.Marker({
      map,
      position: e.coord,
      icon: {
        content:
          '<div style="width:10px;height:10px;border-radius:50%;background:#e83e8c;border:2px solid #fff;box-shadow:0 0 3px rgba(0,0,0,.4)"></div>',
        anchor: new naver.maps.Point(6, 6),
      },
      zIndex: 300,
    });
    coordVal.textContent = `補正点 ${fixes.length}個 · ここをクリックでJSONコピー`;
    coordEl.classList.remove("hidden");
  });
  coordEl.addEventListener("click", () => {
    navigator.clipboard?.writeText(JSON.stringify(fixes)).catch(() => {});
  });

  // ── ちいさな道具たち ──
  function avgLatLng(list) {
    const lat = list.reduce((s, x) => s + x.lat, 0) / list.length;
    const lng = list.reduce((s, x) => s + x.lng, 0) / list.length;
    return new naver.maps.LatLng(lat, lng);
  }
  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }
})();
