// 地図の上に、私たちの"画布"を一枚。
//
// ── 段階3：soa_flatten + instancing + GPU camera ──
// Julie（scene.jl）が Sprite を soa_flatten して draw_rects(flat) を1回呼ぶ。
// overlay(JS) は、その flat（8つ/体：x,y,w,h,r,g,b,a）を storage buffer に
// 丸ごと積み、Naver の cam を camera uniform に書いて、instancing で全体を
// 1 draw。world→画面の変換は WGSL の中で GPU がやる（ecs_gpu_camera.jl の形）。
//
//   Julie(on_frame) → soa_flatten → draw_rects(flat)
//     → host_gpu_draw_rects(JS) → storage buffer + 1 instanced draw_frame(...,n)
//     → WGSL が instance_index で各体を world→NDC（camera uniform）
//
// gpuBridge(OCaml) は触っていない（draw_rects を再利用）。Julie 本体は無傷。

// storage の位置＋camera uniform で world→NDC。頂点は @builtin(vertex_index)、
// 体は @builtin(instance_index)。色・サイズも体ごと（storage から）。
const INSTANCED_WGSL = `
  struct Camera { panX: f32, panY: f32, pxPerMeter: f32, halfW: f32, halfH: f32 };
  @group(0) @binding(0) var<storage, read> sprites: array<f32>;
  @group(0) @binding(1) var<uniform> camera: Camera;

  struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,          // quad 内の -1..1 位置（丸マスク用）
  };

  @vertex
  fn vs_main(@builtin(vertex_index) vidx: u32, @builtin(instance_index) iidx: u32) -> VertexOutput {
    let base = iidx * 8u;                       // 8つ/体：x,y,w,h,r,g,b,a
    let wx = sprites[base] - camera.panX;       // 原点相対メートル − カメラのパン
    let wy = sprites[base + 1u] - camera.panY;
    let ndcX = wx * camera.pxPerMeter / camera.halfW;
    let ndcY = wy * camera.pxPerMeter / camera.halfH;
    let hw = (sprites[base + 2u] * 0.5) * camera.pxPerMeter / camera.halfW; // 半幅(NDC)
    let hh = (sprites[base + 3u] * 0.5) * camera.pxPerMeter / camera.halfH;
    var corners = array<vec2<f32>, 6>(
      vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
      vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
    );
    let local = corners[vidx] * vec2<f32>(hw, hh);
    let a = sprites[base + 7u];
    var out: VertexOutput;
    out.position = vec4<f32>(ndcX + local.x, ndcY + local.y, 0.0, 1.0);
    // premultiplied 合成なので rgb に a を掛けておく。
    out.color = vec4<f32>(sprites[base + 4u] * a, sprites[base + 5u] * a, sprites[base + 6u] * a, a);
    out.uv = corners[vidx];              // フラグメントへ渡して丸く抜く
    return out;
  }

  @fragment
  fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // quad を丸に：中心からの距離が 1 を超えたら透明、縁は少し羽根で AA（premultiplied なので色ごと掛ける）。
    let m = 1.0 - smoothstep(0.8, 1.0, length(in.uv));
    return in.color * m;
  }
`;

// 線シェーダ：1インスタンス＝1線分（8つ：ax,ay,bx,by,r,g,b,a）。向きに沿った細い帯を作る。
// 太さは画面ピクセル固定（ズームで太くならない道路図らしさ）。
const LINE_WGSL = `
  struct Camera { panX: f32, panY: f32, pxPerMeter: f32, halfW: f32, halfH: f32 };
  @group(0) @binding(0) var<storage, read> segs: array<f32>;
  @group(0) @binding(1) var<uniform> camera: Camera;

  struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
  };

  @vertex
  fn vs_main(@builtin(vertex_index) vidx: u32, @builtin(instance_index) iidx: u32) -> VertexOutput {
    let base = iidx * 8u;
    let ppm = camera.pxPerMeter;
    // 端点を、画面ピクセル空間（中心原点）へ。
    let Ax = (segs[base] - camera.panX) * ppm;
    let Ay = (segs[base + 1u] - camera.panY) * ppm;
    let Bx = (segs[base + 2u] - camera.panX) * ppm;
    let By = (segs[base + 3u] - camera.panY) * ppm;
    var d = vec2<f32>(Bx - Ax, By - Ay);
    let len = max(length(d), 0.0001);
    d = d / len;
    let perp = vec2<f32>(-d.y, d.x);
    let hw = 1.2; // 線の半分の太さ（物理px）
    var corners = array<vec2<f32>, 6>(
      vec2<f32>(Ax, Ay) - perp * hw, vec2<f32>(Bx, By) - perp * hw, vec2<f32>(Ax, Ay) + perp * hw,
      vec2<f32>(Ax, Ay) + perp * hw, vec2<f32>(Bx, By) - perp * hw, vec2<f32>(Bx, By) + perp * hw,
    );
    let c = corners[vidx];
    let a = segs[base + 7u];
    var out: VertexOutput;
    out.position = vec4<f32>(c.x / camera.halfW, c.y / camera.halfH, 0.0, 1.0);
    out.color = vec4<f32>(segs[base + 4u] * a, segs[base + 5u] * a, segs[base + 6u] * a, a);
    return out;
  }

  @fragment
  fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
  }
`;

// ── 経路を「一本の滑らかな線」で描く（最初の一歩）───────────────────────
// 道路網（LINE_WGSL）と同じ world-meters・同じ camera uniform に乗る、経路専用
// パイプライン。LINE_WGSL を土台に「画面固定の太さ＋smoothstep の羽根で AA」を
// 足しただけ。roads は別パイプラインで無傷。Rust も Julie も触らない。
//
// 平滑化のつまみ（目で見て回す）↓
// Visvalingam-Whyatt: この面積(m^2)未満の出っぱりを間引く（大きいほど直線的）。
// 3001実データで較正：40≈無効(形ズレ1m)、1000≈点79%/形ズレ11m(道幅内=甘い所)、
// 2000≈72%/26m、5000+は角が壊れる(257m)。まず 1000。目で見て回す。
const VW_AREA = 1000;
const CHAIKIN_ITERS = 2; // Chaikin コーナーカットの反復（多いほど丸い）
const ROUTE_COLOR = [0.92, 0.22, 0.2, 0.95]; // 経路の色（暫定。系統ごとの色は Q2 で。A/Bを際立たせたいなら白や琥珀に）

const ROUTE_WGSL = `
  struct Camera { panX: f32, panY: f32, pxPerMeter: f32, halfW: f32, halfH: f32 };
  @group(0) @binding(0) var<storage, read> segs: array<f32>;
  @group(0) @binding(1) var<uniform> camera: Camera;

  struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) off: f32,          // 中心線からの符号つきピクセル距離（AA用）
  };

  const HW: f32 = 3.0;              // 線の半分の太さ（物理px, 画面固定）← 太さのつまみ
  const FEATHER: f32 = 1.0;         // 縁の羽根（px）

  @vertex
  fn vs_main(@builtin(vertex_index) vidx: u32, @builtin(instance_index) iidx: u32) -> VertexOutput {
    let base = iidx * 8u;           // 8つ/線分：ax,ay,bx,by,r,g,b,a（LINE_WGSL と同じ並び）
    let ppm = camera.pxPerMeter;
    let Ax = (segs[base] - camera.panX) * ppm;
    let Ay = (segs[base + 1u] - camera.panY) * ppm;
    let Bx = (segs[base + 2u] - camera.panX) * ppm;
    let By = (segs[base + 3u] - camera.panY) * ppm;
    var dir = vec2<f32>(Bx - Ax, By - Ay);
    let len = max(length(dir), 0.0001);
    dir = dir / len;
    let perp = vec2<f32>(-dir.y, dir.x);
    let hg = HW + FEATHER;          // 羽根ぶん広げた幾何半幅（羽根がクリップされないように）
    var ends = array<vec2<f32>, 6>(
      vec2<f32>(Ax, Ay), vec2<f32>(Bx, By), vec2<f32>(Ax, Ay),
      vec2<f32>(Ax, Ay), vec2<f32>(Bx, By), vec2<f32>(Bx, By),
    );
    var signs = array<f32, 6>(-1.0, -1.0, 1.0, 1.0, -1.0, 1.0);
    let sgn = signs[vidx];
    let c = ends[vidx] + perp * (hg * sgn);
    let a = segs[base + 7u];
    var out: VertexOutput;
    out.position = vec4<f32>(c.x / camera.halfW, c.y / camera.halfH, 0.0, 1.0);
    out.color = vec4<f32>(segs[base + 4u] * a, segs[base + 5u] * a, segs[base + 6u] * a, a);
    out.off = hg * sgn;             // ±(HW+FEATHER)、フラグメントへ線形補間
    return out;
  }

  @fragment
  fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // 中心線から HW を超えた分を smoothstep で羽根に（premultiplied なので色ごと掛ける）。
    let aa = 1.0 - smoothstep(HW - FEATHER, HW + FEATHER, abs(in.off));
    return in.color * aa;
  }
`;

// Visvalingam-Whyatt 簡略化：三角形の面積が一番小さい点から間引く。両端は残す。
// 点は数百なので素朴な O(n^2)（毎回全走査）で十分。形を保つ簡略化＝道への対応を壊さない。
function simplifyVW(pts, areaTol) {
  if (pts.length <= 2) return pts.slice();
  const keep = pts.map((_, i) => i);
  while (keep.length > 2) {
    let minArea = Infinity,
      minPos = -1;
    for (let k = 1; k < keep.length - 1; k++) {
      const a = pts[keep[k - 1]],
        b = pts[keep[k]],
        c = pts[keep[k + 1]];
      const area = Math.abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])) * 0.5;
      if (area < minArea) {
        minArea = area;
        minPos = k;
      }
    }
    if (minPos < 0 || minArea >= areaTol) break;
    keep.splice(minPos, 1);
  }
  return keep.map((i) => pts[i]);
}

// Chaikin コーナーカット：各線分を 1/4・3/4 で切って角を内側へ丸める。両端は残す。
function chaikin(pts, iters) {
  let p = pts;
  for (let it = 0; it < iters; it++) {
    if (p.length < 3) break;
    const q = [p[0]];
    for (let i = 0; i < p.length - 1; i++) {
      const a = p[i],
        b = p[i + 1];
      q.push([a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25]);
      q.push([a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75]);
    }
    q.push(p[p.length - 1]);
    p = q;
  }
  return p;
}

// 釜山の妥当な緯度経度域。これを外れる座標は、GPS無効時のプレースホルダ（例 125,30 の
// チェジュ沖）等の異常値なので捨てる。거제まで含むよう少し広め。
function inBusan(lng, lat) {
  return lat > 34.5 && lat < 35.7 && lng > 128.4 && lng < 129.6;
}

// 緯度経度 → 原点からの東西・南北メートル（東 +x、北 +y）。
// overlay-bridge の _camera / offsetEastMeters と同じ換算。
function metersFromOrigin(lat, lng, oLat, oLng) {
  const north = (lat - oLat) * 111320;
  const east = (lng - oLng) * 111320 * Math.cos((oLat * Math.PI) / 180);
  return [east, north];
}

// 実測点はまばら（バスのサンプル間隔）なので、表示だけ stepM ごとに補間して実線にする。
// データ（実測点）は触らない。区間は、両端とも確定 かつ 間隔が gapMax 以内のときだけ
// 確定（赤）。サンプルが離れすぎている区間は、間の直線が推測なので未確定（青）にする。
function densifyWithFlags(pts, flags, stepM, gapMax) {
  const x = [pts[0][0]],
    y = [pts[0][1]],
    c = [flags[0]];
  let leftover = stepM;
  for (let i = 1; i < pts.length; i++) {
    const ax = pts[i - 1][0],
      ay = pts[i - 1][1],
      bx = pts[i][0],
      by = pts[i][1];
    const L = Math.hypot(bx - ax, by - ay);
    if (L === 0) continue;
    const f = flags[i - 1] && flags[i] && L <= gapMax ? 1 : 0;
    let t = leftover;
    while (t <= L) {
      const r = t / L;
      x.push(ax + (bx - ax) * r);
      y.push(ay + (by - ay) * r);
      c.push(f);
      t += stepM;
    }
    leftover = t - L;
  }
  return { x, y, c };
}

window.initJulieOverlay = function (map, options) {
  options = options || {};
  const origin = options.origin || map.getCenter();
  const sceneUrl = options.scene || "/scene.jl";
  // サンプル間隔がこれを超える区間は未確定（青）扱い。URL の ?gap=N で調整可（既定 250m）。
  const gapMax = Number(new URLSearchParams(location.search).get("gap")) || 250;

  function CanvasOverlay() {
    this._canvas = null;
    this._raf = null;
    this._zooming = false;
    this._gpu = null; // { gpu, pipeline, cameraBuf, spriteBuf, spriteBufBytes }
    this._julieReady = false;
    this._cam = null;
    this.setMap(map);
  }
  CanvasOverlay.prototype = new naver.maps.OverlayView();
  CanvasOverlay.prototype.constructor = CanvasOverlay;

  CanvasOverlay.prototype.onAdd = function () {
    const c = document.createElement("canvas");
    c.style.position = "absolute";
    c.style.left = "0";
    c.style.top = "0";
    c.style.pointerEvents = "none";
    this._canvas = c;
    this.getPanes().overlayLayer.appendChild(c);
    this._resize();

    this._setup().catch((e) => console.error("julie overlay setup failed:", e));

    // 静的な線なので、変化があったフレームだけ描く（dirty フラグ）。
    const markDirty = () => {
      this._needsDraw = true;
    };
    naver.maps.Event.addListener(map, "zoom_changed", () => {
      this._zooming = true;
    });
    naver.maps.Event.addListener(map, "idle", () => {
      this._zooming = false;
      markDirty();
    });
    naver.maps.Event.addListener(map, "drag", markDirty);
    naver.maps.Event.addListener(map, "bounds_changed", markDirty);
    naver.maps.Event.addListener(map, "resize", markDirty);
    this._needsDraw = true;

    const loop = () => {
      this._frameTick();
      this._raf = requestAnimationFrame(loop);
    };
    this._raf = requestAnimationFrame(loop);
  };

  CanvasOverlay.prototype.onRemove = function () {
    if (this._raf) cancelAnimationFrame(this._raf);
    if (this._pollTimer) clearInterval(this._pollTimer);
    if (this._busTimer) clearInterval(this._busTimer);
    if (this._canvas) this._canvas.remove();
    this._canvas = null;
  };

  CanvasOverlay.prototype.draw = function () {
    this._resize();
    this._needsDraw = true;
  };

  CanvasOverlay.prototype._resize = function () {
    const c = this._canvas;
    if (!c) return;
    const el = map.getElement();
    const dpr = window.devicePixelRatio || 1;
    const w = el.clientWidth,
      h = el.clientHeight;
    const pw = Math.round(w * dpr),
      ph = Math.round(h * dpr);
    if (c.width === pw && c.height === ph) return;
    c.style.width = w + "px";
    c.style.height = h + "px";
    c.width = pw;
    c.height = ph;
    this._dpr = dpr;
    this._cssW = w;
    this._cssH = h;
    if (this._gpu) this._gpu.gpu.configure_canvas(c, pw, ph, "premultiplied");
  };

  CanvasOverlay.prototype._setup = async function () {
    const gpu = await import("/julie-gpu/julie_gpu.js");
    await gpu.default();
    await gpu.gpu_init();
    const c = this._canvas;
    gpu.configure_canvas(c, c.width, c.height, "premultiplied");
    const pipeline = await gpu.create_render_pipeline(
      INSTANCED_WGSL,
      "vs_main",
      "fs_main",
      ["storage-read", "uniform"],
      "triangle-list",
      "premultiplied-alpha"
    );
    const linePipeline = await gpu.create_render_pipeline(
      LINE_WGSL,
      "vs_main",
      "fs_main",
      ["storage-read", "uniform"],
      "triangle-list",
      "premultiplied-alpha"
    );
    const routePipeline = await gpu.create_render_pipeline(
      ROUTE_WGSL,
      "vs_main",
      "fs_main",
      ["storage-read", "uniform"],
      "triangle-list",
      "premultiplied-alpha"
    );
    const cameraBuf = gpu.create_buffer(5 * 4, "uniform"); // panX,panY,ppm,halfW,halfH
    this._gpu = { gpu, pipeline, linePipeline, routePipeline, cameraBuf, spriteBuf: null, spriteBufBytes: 0 };
    this._routeLineBuf = null; // 平滑化した経路線（world-meters, 8つ/線分）
    this._nRouteSegs = 0;

    // 道路の下地（표준노드링크）を、GPU に一度だけ積む（静的なので毎フレーム作り直さない）。
    this._loadRoads();

    // Julie が呼ぶ host。draw_rects(flat) → instancing で全体を1 draw。
    const self = this;
    globalThis.host_gpu_draw_rects = (flat) => self._drawInstances(flat);
    // 1体版が来ても通るように（保険）。
    globalThis.host_gpu_draw_rect = (x, y, w, h, r, g, b, a) =>
      self._drawInstances([x, y, w, h, r, g, b, a]);
    globalThis.host_gpu_clear = () => {};
    globalThis.host_key_down = () => false;
    globalThis.host_mouse_x = () => 0;
    globalThis.host_mouse_y = () => 0;

    // ── 確定パスの受け渡し ── Julie が毎フレーム get_data で引く「原点からのメートル」。
    // overlay 側が /corrected/<routeid> を定期的に読んで、ここへ入れておく。焼き込まない。
    this._routeX = [];
    this._routeY = [];
    this._routeC = [];
    globalThis.host_get_data = (name) =>
      name === "route_x" ? self._routeX :
      name === "route_y" ? self._routeY :
      name === "route_c" ? self._routeC : [];

    // 全路線の確定 geojson を読んで、赤青の線をまとめて ROUTE_WGSL で直描き（Julie 言語は不要）。
    // harvester が書くそばから、青→赤に育つのが live で見える。
    this._loadAllRoutes();
    this._pollTimer = setInterval(() => self._loadAllRoutes(), 20000);

    // バスの現在位置（/buses.json、collector が最新を書く）を黄色い点で。
    // 位置は動くので、路線より速く 12 秒ごとに拾い直す。
    this._busBuf = null;
    this._nBuses = 0;
    this._loadBuses();
    this._busTimer = setInterval(() => self._loadBuses(), 12000);
    this._julieReady = true;
  };

  // バスの現在位置を、原点相対メートルの小さな四角（黄）にして GPU に積む。
  // INSTANCED_WGSL（8つ/体：x,y,w,h,r,g,b,a）を路線と同じ camera uniform で描く。
  CanvasOverlay.prototype._loadBuses = async function () {
    const g = this._gpu;
    if (!g) return;
    try {
      const j = await (await fetch(`/buses.json?t=${Date.now()}`, { cache: "no-store" })).json();
      const pts = (j.buses || []).filter((p) => inBusan(p[0], p[1]));
      const oLat = origin.lat(),
        oLng = origin.lng();
      const cosLat = Math.cos((oLat * Math.PI) / 180);
      const SZ = 150; // 丸の直径のメートル（ズームで大きくなる。ちいさめ）
      const flat = new Float32Array(pts.length * 8);
      for (let i = 0; i < pts.length; i++) {
        const o = i * 8;
        flat[o] = (pts[i][0] - oLng) * 111320 * cosLat; // x 東
        flat[o + 1] = (pts[i][1] - oLat) * 111320; // y 北
        flat[o + 2] = SZ;
        flat[o + 3] = SZ;
        flat[o + 4] = 1.0; // 黄
        flat[o + 5] = 0.85;
        flat[o + 6] = 0.1;
        flat[o + 7] = 1.0;
      }
      if (this._busBuf) g.gpu.destroy_buffer(this._busBuf);
      this._busBuf = pts.length ? g.gpu.create_buffer(flat.byteLength, "storage-read") : null;
      if (this._busBuf) g.gpu.write_buffer(this._busBuf, flat);
      this._nBuses = pts.length;
      this._needsDraw = true;
    } catch (e) {
      // 一時的な失敗は無視（次のポーリングで拾う）
    }
  };

  // 全路線の確定 geojson を読んで、赤青の線分を一本のバッファにまとめて ROUTE_WGSL で描く。
  // 収集と同じ規則：区間は「両端が確定 かつ 間隔<=gapMax」なら赤（実測）、それ以外は青（推測）。
  // harvester が進むと、青が赤に変わっていくのが 20 秒ごとの再取得で live に見える。
  CanvasOverlay.prototype._loadAllRoutes = async function () {
    const g = this._gpu;
    if (!g) return;
    try {
      const manifest = await (await fetch(`/routes.json?t=${Date.now()}`, { cache: "no-store" })).json();
      const ids = (manifest.routes || manifest || [])
        .map((r) => (typeof r === "string" ? r : r.routeid))
        .filter(Boolean);
      const oLat = origin.lat(),
        oLng = origin.lng();
      const cosLat = Math.cos((oLat * Math.PI) / 180);
      const RED = [0.92, 0.22, 0.2],
        BLUE = [0.2, 0.45, 1.0],
        FUSED = [0.95, 0.5, 0.72]; // 借用（同一停留所を通る他路線が実測した道）＝ピンク
      const segs = []; // [ax,ay,bx,by,r,g,b,a] を全路線ぶん
      // 302 路線を並列取得（各 geojson は小さい）。
      await Promise.all(
        ids.map(async (rid) => {
          try {
            const r = await fetch(`/corrected/${rid}_corrected.geojson?t=${Date.now()}`, { cache: "no-store" });
            if (!r.ok) return;
            const gj = await r.json();
            const co = (gj.geometry && gj.geometry.coordinates) || [];
            const cf = (gj.properties && gj.properties.confirmed) || [];
            for (let i = 0; i < co.length - 1; i++) {
              // 釜山域外の異常座標（GPS無効時のプレースホルダ等）を持つ区間は捨てる。
              if (!inBusan(co[i][0], co[i][1]) || !inBusan(co[i + 1][0], co[i + 1][1])) continue;
              const ax = (co[i][0] - oLng) * 111320 * cosLat,
                ay = (co[i][1] - oLat) * 111320;
              const bx = (co[i + 1][0] - oLng) * 111320 * cosLat,
                by = (co[i + 1][1] - oLat) * 111320;
              const L = Math.hypot(bx - ax, by - ay);
              // 1=実測(赤) / 2=借用(ピンク) / それ以外=推測(青)。両端が確定 かつ 間隔<=gapMax のときだけ確定色。
              const fa = cf[i], fb = cf[i + 1];
              const conf = (x) => x === 1 || x === 2;
              let c, a;
              if (conf(fa) && conf(fb) && L <= gapMax) {
                c = fa === 2 || fb === 2 ? FUSED : RED;
                a = 0.9;
              } else {
                // 未確定の直線（停留所間の推測）は、長いほど淡く。橋や急行の長区間が地図を横切って
                // 「飛んで」見えるのを抑える。連続性のヒントは残す（消しはしない）。
                c = BLUE;
                a = Math.max(0.05, Math.min(0.5, (0.9 * gapMax) / L));
              }
              segs.push(ax, ay, bx, by, c[0], c[1], c[2], a);
            }
          } catch (e) {}
        })
      );
      if (segs.length < 8) return;
      const flat = new Float32Array(segs);
      if (this._routeLineBuf) g.gpu.destroy_buffer(this._routeLineBuf);
      this._routeLineBuf = g.gpu.create_buffer(flat.byteLength, "storage-read");
      g.gpu.write_buffer(this._routeLineBuf, flat);
      this._nRouteSegs = (segs.length / 8) | 0;
      this._needsDraw = true;
    } catch (e) {
      // 一時的な失敗は無視（次のポーリングで拾う）
    }
  };

  // 釜山全域の道路網（표준노드링크, ~30m に打ち直した点列バイナリ）を GPU に一度だけ積む。
  // 黒い矩形で、リンク＝ノード間の線を描く。毎フレーム route の下に。静的なので作り直さない。
  CanvasOverlay.prototype._loadRoads = async function () {
    try {
      const r = await fetch("/roads/roads_segments.f32", { cache: "no-store" });
      if (!r.ok) return;
      const seg = new Float32Array(await r.arrayBuffer()); // [ax,ay,bx,by, ...] WGS84
      const oLat = origin.lat(),
        oLng = origin.lng();
      const cosLat = Math.cos((oLat * Math.PI) / 180);
      const R = 0.05,
        G = 0.05,
        B = 0.05,
        A = 0.8; // 黒
      const n = (seg.length / 4) | 0;
      const flat = new Float32Array(n * 8);
      for (let i = 0; i < n; i++) {
        const s = i * 4,
          o = i * 8;
        flat[o] = (seg[s] - oLng) * 111320 * cosLat; // ax 東
        flat[o + 1] = (seg[s + 1] - oLat) * 111320; // ay 北
        flat[o + 2] = (seg[s + 2] - oLng) * 111320 * cosLat; // bx
        flat[o + 3] = (seg[s + 3] - oLat) * 111320; // by
        flat[o + 4] = R;
        flat[o + 5] = G;
        flat[o + 6] = B;
        flat[o + 7] = A;
      }
      this._roadSegBuf = this._gpu.gpu.create_buffer(flat.byteLength, "storage-read");
      this._gpu.gpu.write_buffer(this._roadSegBuf, flat);
      this._nRoadSegs = n;
      this._needsDraw = true;
    } catch (e) {
      // 無視
    }
  };

  // ── 橋 ── 地図から、ワールド原点の画面座標とメートル→ピクセルを作る。
  CanvasOverlay.prototype._camera = function () {
    const proj = this.getProjection();
    if (!proj) return null;
    const o = proj.fromCoordToOffset(origin);
    const oE = proj.fromCoordToOffset(offsetEastMeters(origin, 100));
    const pxPerMeter = Math.hypot(oE.x - o.x, oE.y - o.y) / 100;
    return { originX: o.x, originY: o.y, pxPerMeter };
  };

  // 毎フレーム：Naver の cam を camera uniform に書いて、Julie の on_frame を回す。
  // begin_frame（透明クリア）→ julieRunFrame（中で draw_rects が1回）→ end_frame。
  CanvasOverlay.prototype._frameTick = function () {
    if (!this._gpu) return;
    if (this._zooming) return; // ズーム中は Naver の変換に委ねる
    if (!this._julieReady) return;
    if (!this._needsDraw) return; // 何も変わってなければ描かない（線は静的）
    if (!this._cssW) this._resize();
    const cam = this._camera();
    if (!cam) return;
    this._cam = cam;

    const { gpu, cameraBuf } = this._gpu;
    const c = this._canvas;
    const dpr = this._dpr;

    // パン対策：canvas は overlay pane の子で、pane は地図と一緒に平行移動する。
    // canvas はビューポート分の大きさしかないので、パンすると見える範囲が canvas の
    // 外に出て切れる。毎フレーム canvas を「今のビューポート」に合わせ直し、原点も
    // そのぶんずらす（起動時の位置を基準にした相対オフセット）。
    const er = map.getElement().getBoundingClientRect();
    const pr = c.parentElement.getBoundingClientRect();
    let dx = er.left - pr.left,
      dy = er.top - pr.top; // ビューポート左上の、pane 内オフセット（CSS px）
    if (this._dx0 === undefined) {
      this._dx0 = dx;
      this._dy0 = dy;
    }
    dx -= this._dx0;
    dy -= this._dy0;
    c.style.left = dx + "px";
    c.style.top = dy + "px";

    // 物理ピクセルで cam を組む（WGSL は物理ピクセルの canvas に描く）。
    const W = c.width,
      H = c.height;
    const halfW = W / 2,
      halfH = H / 2;
    const ppm = cam.pxPerMeter * dpr; // メートル→物理ピクセル
    // 原点を、動かした canvas 左上からの位置に直す（pane オフセットぶん引く）。
    const oX = (cam.originX - dx) * dpr,
      oY = (cam.originY - dy) * dpr; // ワールド原点の画面位置（物理px）
    // WGSL: ndcX = (worldX - panX)*ppm/halfW が、画面での
    // screen_x = oX + worldX*ppm と一致するように pan を決める。
    const panX = (halfW - oX) / ppm;
    const panY = (oY - halfH) / ppm; // 北が +y、画面は下向きなので符号が反転
    gpu.write_buffer(cameraBuf, new Float32Array([panX, panY, ppm, halfW, halfH]));

    gpu.begin_frame(0, 0, 0, 0); // 透明にクリア（地図が透ける）
    // 道路の下地（黒い線、静的バッファ）を先に。route（赤青）はその上に。
    if (this._roadSegBuf && this._nRoadSegs)
      gpu.draw_frame(this._gpu.linePipeline, new Uint32Array([this._roadSegBuf, cameraBuf]), 6, this._nRoadSegs);
    // その上に、全路線の赤青の線（ROUTE_WGSL）。harvester が進むと青→赤に育つ。
    if (this._routeLineBuf && this._nRouteSegs)
      gpu.draw_frame(this._gpu.routePipeline, new Uint32Array([this._routeLineBuf, cameraBuf]), 6, this._nRouteSegs);
    // いちばん上に、バスの現在位置（黄の点、INSTANCED_WGSL）。
    if (this._busBuf && this._nBuses)
      gpu.draw_frame(this._gpu.pipeline, new Uint32Array([this._busBuf, cameraBuf]), 6, this._nBuses);
    gpu.end_frame();
    this._needsDraw = false;
  };

  // draw_rects(flat) の実体：flat（8つ/体）を storage buffer に積んで、
  // instancing で n 体を1 draw。
  CanvasOverlay.prototype._drawInstances = function (flat) {
    const g = this._gpu;
    if (!g) return;
    const gpu = g.gpu;
    const len = flat.length | 0;
    const n = Math.floor(len / 8);
    if (n === 0) return;

    const bytes = len * 4;
    if (!g.spriteBuf || g.spriteBufBytes < bytes) {
      if (g.spriteBuf) gpu.destroy_buffer(g.spriteBuf);
      g.spriteBuf = gpu.create_buffer(bytes, "storage-read");
      g.spriteBufBytes = bytes;
    }
    // draw_rects からの flat は Float64Array。write_buffer は f32 を要る。
    const f32 = flat instanceof Float32Array ? flat : new Float32Array(flat);
    gpu.write_buffer(g.spriteBuf, f32);
    gpu.draw_frame(g.pipeline, new Uint32Array([g.spriteBuf, g.cameraBuf]), 6, n);
  };

  function offsetEastMeters(latlng, meters) {
    const lat = latlng.lat();
    const dLng = meters / (111320 * Math.cos((lat * Math.PI) / 180));
    return new naver.maps.LatLng(lat, latlng.lng() + dLng);
  }

  const overlay = new CanvasOverlay();
  naver.maps.Event.addListener(map, "resize", () => overlay._resize());
  return overlay;
};
