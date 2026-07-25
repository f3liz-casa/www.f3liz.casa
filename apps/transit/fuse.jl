#!/usr/bin/env julia
# 路線間 fusion（補間）。同じ2連続停留所(同一 nodeid)を通る2路線は間の道が同じ→
# 片方が実測した赤い形を、もう片方の青い区間へ借用する。純幾何・API費用ゼロ。
#   出力 /data/fused/<rid>_corrected.geojson（properties.confirmed: 1=実測赤 / 2=借用ピンク / 0=推測青）
# 自分の実測 geojson(/data/corrected)・カバレッジ metric は無傷。fusion は派生・表示用の別層。
# nodeid 未捕捉の路線/区間は借用対象外＝従来どおり（安全退化）。
using JSON3, LinearAlgebra
include(joinpath(@__DIR__, "clouddb.jl"))
const RECON_CAP = parse(Int, get(ENV, "RECON_CAP", "30000"))   # 幾何は直近 RECON_CAP 点で（reconstruct と揃える）

const DATADIR = get(ENV, "TAGO_DATA_DIR", @__DIR__)
const PROGDIR = joinpath(DATADIR, "progress")
const OUTDIR = joinpath(DATADIR, "fused")
const GAP = 250.0   # 区間が「実測赤」になる最大の点間隔（地図の gap 規則と同じ）
const BINM = 30.0   # 区間内で点を束ねる弧長サブビン(m)。ジグザグ除去＋Nが増えるほど締まる。
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

metric(lat, lng, lat0) = (lng * cosd(lat0) * 111320.0, lat * 111320.0)
dm(a, b, lat0) = (ax = metric(a[1], a[2], lat0); bx = metric(b[1], b[2], lat0); hypot(ax[1] - bx[1], ax[2] - bx[2]))

# 物理の事前分布：車ごと(vehicleno)の軌跡を 等速カルマン＋RTS スムーザで掃除（reconstruct と同じ・地図一致のため）。
# ゲートで「動きとしてありえない」GPS（マルチパス飛び）を弾く。correct_route.jl の同名関数と同一実装。
function smooth_tracks(cloud, lat0)
    out = collect(cloud)
    tracks = Dict{String,Vector{Int}}()
    for (i, p) in enumerate(cloud)
        (length(p) >= 7 && !isempty(String(p[7])) && Float64(p[6]) > 0) || continue
        push!(get!(tracks, String(p[7]), Int[]), i)
    end
    σz = 12.0; σa = 1.5; gate = 13.8; VMAX = 30.0
    H = [1.0 0 0 0; 0 1 0 0]; R = Matrix(Diagonal([σz^2, σz^2]))
    for (_, idxs) in tracks
        length(idxs) < 3 && continue
        sort!(idxs, by = i -> Float64(cloud[i][6]))
        n = length(idxs)
        X = [collect(metric(cloud[i][2], cloud[i][3], lat0)) for i in idxs]
        T = [Float64(cloud[i][6]) for i in idxs]
        Xc = [copy(x) for x in X]                         # Hampel: ±3窓の中央値から120m超を飛びとみなし中央値へ置換（有界・頑健）
        for i in 1:n
            lo = max(1, i - 3); hi = min(n, i + 3)
            mx = med([X[j][1] for j in lo:hi]); my = med([X[j][2] for j in lo:hi])
            hypot(X[i][1] - mx, X[i][2] - my) > 120.0 && (Xc[i] = [mx, my])
        end
        fmean = Vector{Vector{Float64}}(undef, n); fcov = Vector{Matrix{Float64}}(undef, n)
        pmean = Vector{Vector{Float64}}(undef, n); pcov = Vector{Matrix{Float64}}(undef, n)
        Fs = Vector{Matrix{Float64}}(undef, n)
        s = [Xc[1][1], Xc[1][2], 0.0, 0.0]; P = Matrix(Diagonal([σz^2, σz^2, 100.0, 100.0]))
        fmean[1] = copy(s); fcov[1] = copy(P); pmean[1] = copy(s); pcov[1] = copy(P); Fs[1] = Matrix{Float64}(I, 4, 4)
        for k in 2:n
            dt = clamp(T[k] - T[k-1], 0.1, 90.0)          # 外挿を制限（疎な間隔で飛ばないように）
            F = [1.0 0 dt 0; 0 1 0 dt; 0 0 1 0; 0 0 0 1]
            Q = σa^2 * [dt^4/4 0 dt^3/2 0; 0 dt^4/4 0 dt^3/2; dt^3/2 0 dt^2 0; 0 dt^3/2 0 dt^2]
            sp = F * s; Pp = F * P * F' + Q
            pmean[k] = sp; pcov[k] = Pp; Fs[k] = F
            z = Xc[k]; ν = z - H * sp; S = H * Pp * H' + R
            d2 = ν' * (S \ ν)
            if d2 > gate                                  # 残った外れは観測を捨てて予測を採用
                s = sp; P = Pp
            else
                K = Pp * H' / S
                s = sp + K * ν; P = (I - K * H) * Pp
            end
            vm = hypot(s[3], s[4]); vm > VMAX && (s[3] *= VMAX / vm; s[4] *= VMAX / vm)   # 速度を物理上限に（外挿の発散防止）
            fmean[k] = copy(s); fcov[k] = copy(P)
        end
        smpos = Vector{Tuple{Float64,Float64}}(undef, n)
        sm = copy(fmean[n]); smpos[n] = (sm[1], sm[2])
        for k in (n-1):-1:1
            C = fcov[k] * Fs[k+1]' / pcov[k+1]
            sm = fmean[k] + C * (sm - pmean[k+1])
            smpos[k] = (sm[1], sm[2])
        end
        for (j, i) in enumerate(idxs)
            x, y = smpos[j]
            hypot(x - Xc[j][1], y - Xc[j][2]) > 300.0 && ((x, y) = (Xc[j][1], Xc[j][2]))   # 発散安全弁
            p = cloud[i]
            out[i] = (p[1], y / 111320.0, x / (cosd(lat0) * 111320.0), p[4], p[5], p[6], p[7])
        end
    end
    return out
end

struct Route
    rid::String
    nseg::Int
    maxord::Int
    lat0::Float64
    stopxy::Dict{Int,Tuple{Float64,Float64}}   # ord => (lat,lng)
    stopnode::Dict{Int,String}                 # ord => nodeid
    byseg::Dict{Int,Vector{Tuple{Float64,Float64,Float64}}}  # 区間k => 実測GPS点列(ordpos順, (ordpos,lat,lng))
end

function load_route(path, db)
    s = try; JSON3.read(read(path, String)); catch; return nothing; end
    (haskey(s, :stops) && haskey(s, :nseg) && haskey(s, :rid)) || return nothing
    stopxy = Dict{Int,Tuple{Float64,Float64}}()
    for t in s.stops; stopxy[Int(t[1])] = (Float64(t[2]), Float64(t[3])); end
    length(stopxy) < 2 && return nothing
    stopnode = Dict{Int,String}()
    if haskey(s, :stopnodes)
        for t in s.stopnodes; stopnode[Int(t[1])] = String(t[2]); end
    end
    lat0 = Float64(s.lat0)
    # cloud は SQLite から直近 RECON_CAP 点 → 物理(KF+RTS)で掃除 → 区間ごとにまとめる。
    raw = cloud_query(db, String(s.rid), RECON_CAP)
    raw = try
        smooth_tracks(raw, lat0)                     # 地図(fused)も reconstruct と同じ平滑に揃える
    catch
        raw
    end
    tmp = Dict{Int,Vector{Tuple{Float64,Float64,Float64}}}()   # k => (ordpos,lat,lng)
    for p in raw
        k = floor(Int, p[1])
        push!(get!(tmp, k, Tuple{Float64,Float64,Float64}[]), (p[1], p[2], p[3]))
    end
    byseg = Dict{Int,Vector{Tuple{Float64,Float64,Float64}}}()
    for (k, v) in tmp
        sort!(v, by = x -> x[1])
        byseg[k] = v
    end
    return Route(String(s.rid), Int(s.nseg), Int(s.maxord), lat0, stopxy, stopnode, byseg)
end

# 区間 k の形（[stop_k, 弧長サブビンごとの中央値…, stop_{k+1}]）と、実測赤か（全点間隔<=GAP かつ 実測点>=1）。
# 全点を線でつなぐ（ジグザグ）のでなく、区間内を BINM の弧長サブビンで束ねて中央値＝掃除＋間引き。
function seg_shape(r::Route, k::Int)
    (haskey(r.stopxy, k) && haskey(r.stopxy, k + 1)) || return (Tuple{Float64,Float64}[], false, 0)
    raw = get(r.byseg, k, Tuple{Float64,Float64,Float64}[])   # (ordpos,lat,lng) 昇順
    npts = length(raw)
    shape = Tuple{Float64,Float64}[r.stopxy[k]]
    if npts >= 1
        # 停留所ベクトルの座標系：along はサブビンの弧位置、cross(横ズレ)だけ中央値＝タングル低減。
        ax, ay = metric(r.stopxy[k][1], r.stopxy[k][2], r.lat0)
        bx, by = metric(r.stopxy[k+1][1], r.stopxy[k+1][2], r.lat0)
        L = max(hypot(bx - ax, by - ay), 1.0)
        boff = Dict{Int,Vector{Float64}}(); order = Int[]
        for (op, la, ln) in raw
            px, py = metric(la, ln, r.lat0)
            cross = ((px - ax) * -(by - ay) + (py - ay) * (bx - ax)) / L   # 垂直成分(signed)
            b = floor(Int, clamp(op - k, 0.0, 1.0) * L / BINM)             # 区間内の弧長サブビン
            haskey(boff, b) || push!(order, b)
            push!(get!(boff, b, Float64[]), cross)
        end
        sort!(order)
        for b in order
            t = clamp((b + 0.5) * BINM / L, 0.0, 1.0); m = med(boff[b])
            cx = ax + (bx - ax) * t + m * -(by - ay) / L
            cy = ay + (by - ay) * t + m * (bx - ax) / L
            push!(shape, (cy / 111320.0, cx / (cosd(r.lat0) * 111320.0)))
        end
    end
    push!(shape, r.stopxy[k+1])
    red = npts >= 1
    if red
        for i in 2:length(shape)
            if dm(shape[i-1], shape[i], r.lat0) > GAP
                red = false; break
            end
        end
    end
    return (shape, red, npts)
end

nkey(a, b) = string(a, ">", b)

function main()
    isdir(PROGDIR) || (println("no progress → fusion なし"); return)
    mkpath(OUTDIR)
    files = filter(f -> endswith(f, ".json") && !startswith(f, "._"), readdir(PROGDIR))
    db = open_clouddb()
    routes = Route[]
    for f in files
        r = load_route(joinpath(PROGDIR, f), db)
        r === nothing || push!(routes, r)
    end
    # PASS1: 区間ライブラリ（有向 nodeidペア => 一番点数の多い実測赤の形）
    lib = Dict{String,Vector{Tuple{Float64,Float64}}}()
    libn = Dict{String,Int}()
    for r in routes, k in 1:r.nseg
        (haskey(r.stopnode, k) && haskey(r.stopnode, k + 1)) || continue
        shape, red, npts = seg_shape(r, k)
        red || continue
        key = nkey(r.stopnode[k], r.stopnode[k+1])
        if npts > get(libn, key, 0)
            lib[key] = shape; libn[key] = npts
        end
    end
    # PASS2: 各路線の fused geojson を組む（実測赤 / 借用ピンク / 推測青）
    nfused = 0; nborrow = 0
    for r in routes
        coords = Vector{Float64}[]; flags = Int[]
        borrowed = 0
        for k in 1:max(r.maxord - 1, 0)
            (haskey(r.stopxy, k) && haskey(r.stopxy, k + 1)) || continue
            shape, red, npts = seg_shape(r, k)
            local seg, fl
            key = (haskey(r.stopnode, k) && haskey(r.stopnode, k + 1)) ? nkey(r.stopnode[k], r.stopnode[k+1]) : ""
            if red
                seg = shape; fl = 1                       # 自分で実測
            elseif !isempty(key) && haskey(lib, key)
                seg = lib[key]; fl = 2; borrowed += 1     # 他路線から借用
            else
                seg = Tuple{Float64,Float64}[r.stopxy[k], r.stopxy[k+1]]; fl = 0   # 推測(直線)
            end
            for (i, (la, ln)) in enumerate(seg)
                (i == 1 && !isempty(coords)) && continue  # 接合点の重複を避ける
                push!(coords, [ln, la]); push!(flags, fl)
            end
        end
        length(coords) >= 2 || continue
        gj = Dict("type" => "Feature",
            "geometry" => Dict("type" => "LineString", "coordinates" => coords),
            "properties" => Dict("confirmed" => flags, "routeid" => r.rid, "fused" => true, "borrowed" => borrowed))
        open(io -> JSON3.write(io, gj), joinpath(OUTDIR, "$(r.rid)_corrected.geojson"), "w")
        nfused += 1; borrowed > 0 && (nborrow += 1)
    end
    println("fuse: $(nfused)路線 fused / うち借用あり $(nborrow)路線 / ライブラリ区間 $(length(lib)) → $OUTDIR")
end

main()
