#!/usr/bin/env julia
# trunk地図（区間別 uniqueness）を作る。純幾何・API消費ゼロ（停留所座標だけ）。
# uniq_k∈(0,1]: 区間 k=停留所ord k→k+1 のセル列で「何路線が通るか(多重度)」の逆数平均。
#   幹線(多くの路線が共有)→小、固有(その路線だけ)→1。
# 出力 /data/trunk.json {routeid=>[uniq_1..uniq_nseg]} を collector が起動時に load_trunk! で読む。
# 無ければ collector は一様に退化する（安全）。progress の stops から作るので、収集が進むほど精緻になる。
using JSON3

const DATADIR = get(ENV, "TAGO_DATA_DIR", @__DIR__)
const PROGDIR = joinpath(DATADIR, "progress")
const OUT = joinpath(DATADIR, "trunk.json")
const LAT0 = 35.15
const CELL = 70.0          # セル一辺(m)。停留所間隔(~300-500m)より十分細かい＝同じ道を走る2路線はほぼ同じセル列を共有。
const COSL = cosd(LAT0)
cellkey(lat, lng) = (round(Int, lng * COSL * 111320 / CELL), round(Int, lat * 111320 / CELL))

# 停留所 a→b を CELL/2 刻みで densify して触れるセル列（重複除去）。
function seg_cells(la1, ln1, la2, ln2)
    mx = (ln2 - ln1) * COSL * 111320; my = (la2 - la1) * 111320
    L = hypot(mx, my); n = max(1, ceil(Int, L / (CELL / 2)))
    cs = Tuple{Int,Int}[]
    for j in 0:n
        la = la1 + (la2 - la1) * j / n; ln = ln1 + (ln2 - ln1) * j / n
        push!(cs, cellkey(la, ln))
    end
    return unique(cs)
end

function main()
    isdir(PROGDIR) || (println("no progress dir: $PROGDIR（trunk.json 未生成＝collector は一様）"); return)
    files = filter(f -> endswith(f, ".json") && !startswith(f, "._"), readdir(PROGDIR))
    segcells = Dict{String,Dict{Int,Vector{Tuple{Int,Int}}}}()   # rid => (区間ord k => セル列)
    nsegOf = Dict{String,Int}()
    cellmult = Dict{Tuple{Int,Int},Int}()                        # セル => 触れた distinct 路線数
    for f in files
        s = try
            JSON3.read(read(joinpath(PROGDIR, f), String))
        catch
            continue
        end
        (haskey(s, :stops) && haskey(s, :nseg) && haskey(s, :rid)) || continue
        stopxy = Dict{Int,Tuple{Float64,Float64}}()
        for t in s.stops
            stopxy[Int(t[1])] = (Float64(t[2]), Float64(t[3]))
        end
        rid = String(s.rid); nseg = Int(s.nseg)
        sc = Dict{Int,Vector{Tuple{Int,Int}}}()
        routecells = Set{Tuple{Int,Int}}()
        for k in 1:nseg
            (haskey(stopxy, k) && haskey(stopxy, k + 1)) || continue
            (la1, ln1) = stopxy[k]; (la2, ln2) = stopxy[k+1]
            cs = seg_cells(la1, ln1, la2, ln2)
            sc[k] = cs
            for c in cs
                push!(routecells, c)
            end
        end
        segcells[rid] = sc; nsegOf[rid] = nseg
        for c in routecells                      # 路線内は1回だけ数える(distinct)＝多重度
            cellmult[c] = get(cellmult, c, 0) + 1
        end
    end
    out = Dict{String,Vector{Float64}}()
    for (rid, sc) in segcells
        uniq = fill(1.0, get(nsegOf, rid, 0))    # 既定1.0（stops欠けの区間は固有扱い＝安全側）
        for (k, cs) in sc
            k <= length(uniq) || continue
            m = isempty(cs) ? 1.0 : sum(cellmult[c] for c in cs) / length(cs)
            uniq[k] = 1.0 / m
        end
        out[rid] = uniq
    end
    open(io -> JSON3.write(io, out), OUT, "w")
    println("trunk.json: $(length(out)) 路線 → $OUT")
end

main()
