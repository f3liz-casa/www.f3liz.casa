# transit.f3liz.casa — 釜山バスGPS収集を 24/7 で回す 1 コンテナ。
# Julia の収集(correct_all.jl)を常時ループ + node のダッシュボード/配信を、同じコンテナで。
# コード + seed(routes.jsonl) はイメージに焼く。生成データ(progress/corrected/daily.json)は
# TAGO_DATA_DIR=/data の volume に出す（コードとデータを分離）。
FROM julia:1.12

# kamal が deploy 時に要求する service ラベル（sukhi は build-on-box の --label で付与）。
LABEL service=transit-f3liz

# node（ダッシュボード用・プレーンhttpのみ・依存パッケージ無し）＋ tini（PID1）
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

# JSON3 をイメージに焼いて precompile（毎起動の初回コンパイルを消す）
RUN julia -e 'using Pkg; Pkg.add(["JSON3", "SQLite", "DBInterface"]); using JSON3, Dates, Downloads, LinearAlgebra, Statistics, SQLite, DBInterface'

WORKDIR /app
COPY correct_all.jl correct_route.jl precompute_trunk.jl learn.jl fuse.jl clouddb.jl migrate.jl dashboard.js report.js server.js ./
COPY busan/ ./busan/
COPY web/ ./web/
COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 生成データは /data(volume)。APIキーは secret(env TAGO_KEY)→/app/.tago_key(揮発)に entrypoint が書く。
ENV TAGO_DATA_DIR=/data \
    CITIES=busan \
    BUDGET=10000 \
    COVER=0.95 \
    CONC=3 \
    LOOP_SLEEP=1800 \
    WEB_PORT=8080
VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
