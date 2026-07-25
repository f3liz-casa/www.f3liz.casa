# cloud（バスGPS点群）を SQLite に置く。旧: progress/<rid>.json に cloud 全体を毎poll書き直し(O(cloud))
# → 新: 追記INSERT(O(new))＋路線ごと query。RS は cloud を持たず、reconstruct 時に query して渡す
# ＝10万点×302路線を RAM に載せない（メモリは1路線ぶんで有界）。幾何コード(reconstruct等)は無改造。
# correct_all.jl / fuse.jl / learn.jl が include。entrypoint で逐次実行なので同時書き込みは無い（WALで安全）。
using SQLite, DBInterface

_clouddb_path() = joinpath(get(ENV, "TAGO_DATA_DIR", @__DIR__), "cloud.db")

function open_clouddb()
    db = SQLite.DB(_clouddb_path())
    DBInterface.execute(db, "PRAGMA journal_mode=WAL")
    DBInterface.execute(db, "PRAGMA synchronous=NORMAL")
    DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS cloud(rid TEXT, op REAL, lat REAL, lng REAL, ord INTEGER, band INTEGER, ts REAL, vno TEXT)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS ix_cloud_rid_ts ON cloud(rid, ts)")
    return db
end

# pts: Vector of (op,lat,lng,ord,band,ts,vno)。SQLite.load! で一括追記（内部でトランザクション）。
# @async は協調的でこの呼び出し中は yield しない(SQLiteはC呼び出し)ので、並列 process_route! でも競合しない。
function cloud_insert!(db, rid, pts)
    isempty(pts) && return
    rows = [(rid=rid, op=Float64(p[1]), lat=Float64(p[2]), lng=Float64(p[3]),
             ord=Int(p[4]), band=Int(p[5]), ts=Float64(p[6]), vno=String(p[7])) for p in pts]
    SQLite.load!(rows, db, "cloud")
    return
end

# 直近 limit 点を 7要素タプルの Vector で返す（reconstruct/fuse/learn が受ける形）。順不同でよい（binで束ねるので）。
function cloud_query(db, rid, limit)
    q = DBInterface.execute(db, "SELECT op,lat,lng,ord,band,ts,vno FROM cloud WHERE rid=? ORDER BY ts DESC LIMIT ?", (rid, limit))
    out = Tuple{Float64,Float64,Float64,Int,Int,Float64,String}[]
    for r in q
        v = r.vno
        push!(out, (Float64(r.op), Float64(r.lat), Float64(r.lng), Int(r.ord), Int(r.band), Float64(r.ts), v === missing ? "" : String(v)))
    end
    return out
end

function cloud_count(db, rid)
    for r in DBInterface.execute(db, "SELECT count(*) AS c FROM cloud WHERE rid=?", (rid,))
        return Int(r.c)
    end
    return 0
end
