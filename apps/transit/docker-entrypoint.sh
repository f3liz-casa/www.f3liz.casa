#!/usr/bin/env bash
# 1コンテナで：収集ループ(bg) ＋ ダッシュボード/配信(fg)。
# コンテナの生存 = web(fg)。収集は落ちても内側ループで再起動、web が落ちたらコンテナ再起動。
set -euo pipefail

: "${TAGO_DATA_DIR:=/data}"
: "${CITIES:=busan}"
: "${BUDGET:=10000}"
: "${COVER:=0.95}"
: "${CONC:=3}"
: "${LOOP_SLEEP:=1800}"

mkdir -p "$TAGO_DATA_DIR/progress" "$TAGO_DATA_DIR/corrected"

# TAGO APIキーは secret(env TAGO_KEY)から。イメージには焼かない・volume にも残さない。
if [ -n "${TAGO_KEY:-}" ]; then
  printf '%s' "$TAGO_KEY" > /app/.tago_key   # correct_route.jl の既定 KEYFILE(=@__DIR__/.tago_key)
  chmod 600 /app/.tago_key
else
  echo "WARN: TAGO_KEY 未設定 → 収集は起動しない。dashboard のみ稼働。" >&2
fi

# 収集ループ（常時）。correct_all は「本日予算(daily.json)到達」or「サービス時間外(全路線バス0)」で
# 自然終了する設計 → sleep して再試行。日付が変われば daily.json が自動リセット＝翌日ぶんを続ける。
if [ -n "${TAGO_KEY:-}" ]; then
  (
    while true; do
      echo "[collector] pass start $(date -u +%FT%TZ)  cities=$CITIES budget=$BUDGET cover=$COVER conc=$CONC"
      julia /app/migrate.jl || echo "[migrate] JSON→SQLite 移行 errored"
      julia /app/precompute_trunk.jl || echo "[trunk] precompute errored — uniqueness無しで一様継続"
      julia /app/learn.jl || echo "[learn] speed/verify errored — モデル無しで幾何uniqのみ継続"
      julia /app/fuse.jl || echo "[fuse] 路線間補間 errored — 借用無しで継続"
      julia /app/correct_all.jl "$CITIES" "$BUDGET" "$COVER" "$CONC" || echo "[collector] pass errored — 継続"
      echo "[collector] pass end → sleep ${LOOP_SLEEP}s"
      sleep "$LOOP_SLEEP"
    done
  ) &
fi

# web（地図＋データ配信）を前面で。kamal-proxy はここ(WEB_PORT)へ transit.f3liz.casa を振る。
# server.js が web/(地図) ＋ /corrected ＋ /routes.json ＋ /status.json を配信。
exec node /app/server.js
