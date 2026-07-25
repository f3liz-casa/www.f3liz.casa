# transit.f3liz.casa

釜山バスの GPS を **24/7 で収集し続ける** 1 コンテナ。sukhi.f3liz.casa と同じ箱に相乗りし、
kamal-proxy が `transit.f3liz.casa` をこのコンテナへ振る。

**成果物の芯**（[map.f3liz.casa/GTFS-RESEARCH.md](../../map.f3liz.casa/GTFS-RESEARCH.md) 参照）：
韓国の既存 GTFS（KTDB）にも無い **実GPS由来の道なり形状・実測速度/所要** を作るための、
継続 harvest 基盤。集めたものはやがて CC0 GTFS-with-shapes として配る。

## 何が動くか（1コンテナ）

- **収集ループ（Julia, 常時）** — `correct_all.jl` を回し続ける。「本日予算(`daily.json`)到達」
  または「サービス時間外（全路線バス0）」で自然終了 → `LOOP_SLEEP` 秒休んで再開。
  日付が変われば `daily.json` が自動リセット＝翌日ぶんを続ける。日次上限は再起動をまたいで守る。
- **web（node, 前面）** — `dashboard.js`（:8080）。全路線の収集状態をライブ表示。
  コンテナの生存＝この web。

コードと seed（`busan/routes.jsonl`）はイメージに焼く。生成データ（`progress/` `corrected/`
`daily.json`）は `TAGO_DATA_DIR=/data` の**永続 volume**に出す。停留所は API から都度取得。

## デプロイ（Kamal, sukhi-deploy と完全に同じ流儀）

sukhi と同じ箱・同じ registry・同じ Cloudflare Origin 証明書に相乗り。kamal は build せず
**箱上でビルド**して箱ローカル registry へ push → `--skip-push` で登録。

```bash
# 1. 秘密（sukhi の分を流用）
cp .kamal/secrets.example .kamal/secrets      # TAGO_KEY(このマシンの ~/sandbox/tago/.tago_key),
                                              # REGISTRY_PASSWORD(sukhi と同じ)
mkdir -p config/tls
cp /path/to/sukhi/config/tls/origin.crt config/tls/origin.crt   # *.f3liz.casa（transit も covers）
cp /path/to/sukhi/config/tls/origin.key config/tls/origin.key

# 2. 箱と DNS
export DEPLOY_HOST=<sukhi と同じ箱>
# Cloudflare: A/CNAME transit.f3liz.casa → 箱（proxied/orange, sukhi と同じ）／SSL は Full (Strict)

# 3. 箱でビルド → デプロイ
./bin/build-on-box.sh v0      # rsync→箱で docker build→127.0.0.1:5000 へ push
kamal deploy --skip-push      # web role に登録＋Origin 証明書 upload

# 版を上げるとき（コード更新後）は 3 を再実行。
```

> Kamal を使わず、箱で素の Docker でも動く：
> `docker build -t transit . && docker run -d --restart=always -p 8080:8080 -v transit_data:/data -e TAGO_KEY=$(cat ~/sandbox/tago/.tago_key) transit`
> （この場合 TLS/ドメインは別途 reverse proxy で。）

## 設定（env）

| env | 既定 | 意味 |
|---|---|---|
| `TAGO_KEY` | （secret・必須） | data.go.kr 서비스키。無いと収集は起動せず web のみ |
| `CITIES` | `busan` | 収集都市（`busan,daegu` も可） |
| `BUDGET` | `10000` | 1日の req 上限。**운영계정を取ったら `100000`** |
| `CONC` | `3` | 同時ポーリング数（大きいほど速い・API に強い） |
| `COVER` | `0.95` | 路線の目標カバレッジ（honest gap250。実質 plateau で終わる） |
| `LOOP_SLEEP` | `1800` | 予算到達/サービス外で終了後、次passまで休む秒 |
| `TAGO_DATA_DIR` | `/data` | 生成データ置き場（volume） |
| `WEB_PORT` | `8080` | dashboard のポート（proxy の app_port と揃える） |

## 既存データを引き継ぐ（任意）

ローカル(`~/sandbox/tago`)で貯めたぶんを箱の volume に seed すると、続きから積み増せる：

```bash
# 箱側で transit_data volume に progress/ corrected/ daily.json を置く（rsync/docker cp）
```

seed しなくても空から再収集して育つ（`daily.json` が今日ぶんを管理）。

## 運영계정（quota 拡大）の申請理由

「韓国に GTFS が無いから作る」ではない（既存の KTDB 全国 GTFS あり）。
**「既存 GTFS は道なり形状も実測速度も持たない。~300 路線のバス位置を継続的に密に harvest して
それらを導くため、開発枠 10,000/日 を超える運용枠が要る」** ＝ このコンテナがその harvest 基盤。

## ファイル

- `correct_all.jl` / `correct_route.jl` — 収集本体（round-robin 並列・honest カバレッジ・
  時間帯/生時刻タグ・保留(revisit)・日次予算）。dev は `~/sandbox/tago`、更新時はここへ同期。
- `dashboard.js` — 全路線状態の web（:8080, `/status.json`）。
- `report.js` — CLI 集計（`node report.js`）。
- `busan/routes.jsonl` — 収集対象の路線一覧（seed）。
- `Dockerfile` / `docker-entrypoint.sh` — 1コンテナ（収集ループ+web）。
- `config/deploy.yml` / `.kamal/secrets.example` — Kamal デプロイ。
