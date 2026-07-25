#!/usr/bin/env julia
# 旧 progress/<rid>.json の cloud を SQLite(cloud.db) へ一度だけ移行する（idempotent）。
# entrypoint で learn/fuse/correct_all より「先」に走らせる（先に走らないと空DBで全青のfusedを書いてしまう）。
# 既に DB にある路線は skip。in_busan で域外の異常点は落とす。save_state が JSON cloud を空にした後は何もしない。
include(joinpath(@__DIR__, "clouddb.jl"))
using JSON3

const DATADIR = get(ENV, "TAGO_DATA_DIR", @__DIR__)
const PROGDIR = joinpath(DATADIR, "progress")
_inb(lat, lng) = 34.5 < lat < 35.7 && 128.4 < lng < 129.6

function main()
    isdir(PROGDIR) || (println("no progress → migrate なし"); return)
    db = open_clouddb()
    n = 0; pts = 0
    for f in filter(x -> endswith(x, ".json") && !startswith(x, "._"), readdir(PROGDIR))
        s = try
            JSON3.read(read(joinpath(PROGDIR, f), String))
        catch
            continue
        end
        (haskey(s, :rid) && haskey(s, :cloud) && !isempty(s.cloud)) || continue
        rid = String(s.rid)
        cloud_count(db, rid) == 0 || continue   # 既に移行済み
        mig = [(Float64(p[1]), Float64(p[2]), Float64(p[3]), Int(p[4]),
                length(p) >= 5 ? Int(p[5]) : -1, length(p) >= 6 ? Float64(p[6]) : -1.0,
                length(p) >= 7 ? String(p[7]) : "") for p in s.cloud]
        filter!(p -> _inb(p[2], p[3]), mig)
        cloud_insert!(db, rid, mig)
        n += 1; pts += length(mig)
    end
    println("migrate: $(n) 路線 / $(pts) 点を SQLite へ")
end

main()
