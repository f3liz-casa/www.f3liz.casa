#!/usr/bin/env julia
# バスの動きを学習する（S3/S4）。蓄積 cloud(vehicleno×ts) から:
#   ・区間速度表 V[rid][seg] = median/std/n（＝渋滞・BRT・信号待ちの層でもある）
#   ・予測の検証残差 resid[rid][seg]（＝校正済み不確実性。当てづらい区間ほど大）
#   ・全体 RMSE：区間中央値モデル 対 「動かない(慣性)」ベースライン
# 出力 /data/model.json を collector が route_need(不確実性項) に、dashboard が RMSE/渋滞表示に使う。
# 純Julia・API費用ゼロ。ML lib不要（median表＝十分強い, Python無し）。
#
# 注：残差は現状 in-sample（速度表を作った同じ pair で測る＝やや楽観）。データが貯まったら
# 時間holdout に上げる余地あり。いまは「モデルが慣性より当たるか」の一次シグナルとして使う。
using JSON3, Statistics
include(joinpath(@__DIR__, "clouddb.jl"))
const CLOUD_CAP = parse(Int, get(ENV, "CLOUD_CAP", "100000"))   # 速度モデルは直近 CLOUD_CAP 点まで使う（幾何より多くてよい）

const DATADIR = get(ENV, "TAGO_DATA_DIR", @__DIR__)
const PROGDIR = joinpath(DATADIR, "progress")
const OUT = joinpath(DATADIR, "model.json")

metric(lat, lng, lat0) = (lng * cosd(lat0) * 111320.0, lat * 111320.0)

# 区間長 seglen[k]（k=停留所ord k→k+1, m）と累積弧長 cum[k]（停留所1→k）。
function geom(stopxy, nseg, lat0)
    seglen = zeros(nseg)
    for k in 1:nseg
        if haskey(stopxy, k) && haskey(stopxy, k + 1)
            ax, ay = metric(stopxy[k][1], stopxy[k][2], lat0)
            bx, by = metric(stopxy[k+1][1], stopxy[k+1][2], lat0)
            seglen[k] = hypot(bx - ax, by - ay)
        end
    end
    cum = zeros(nseg + 1)
    for k in 2:nseg+1
        cum[k] = cum[k-1] + (k - 1 <= length(seglen) ? seglen[k-1] : 0.0)
    end
    return seglen, cum
end
# op=ord+t（弧長 m）。ord<1 は 0。
function arc(op, seglen, cum)
    k = floor(Int, op); t = op - k
    k < 1 && return 0.0
    base = k <= length(cum) ? cum[k] : (isempty(cum) ? 0.0 : cum[end])
    return base + t * (k <= length(seglen) ? seglen[k] : 0.0)
end

function main()
    isdir(PROGDIR) || (println("no progress dir → model.json 未生成（collector は幾何uniqのみ）"); return)
    files = filter(f -> endswith(f, ".json") && !startswith(f, "._"), readdir(PROGDIR))
    db = open_clouddb()
    routesOut = Dict{String,Dict{String,Vector{Float64}}}()
    allspeeds = Float64[]
    rm2 = 0.0; rp2 = 0.0; nval = 0                       # RMSE(model/persist) の二乗和
    for f in files
        s = try
            JSON3.read(read(joinpath(PROGDIR, f), String))
        catch
            continue
        end
        (haskey(s, :stops) && haskey(s, :nseg) && haskey(s, :rid)) || continue
        rid = String(s.rid); nseg = Int(s.nseg)
        nseg >= 1 || continue
        stopxy = Dict{Int,Tuple{Float64,Float64}}()
        for t in s.stops
            stopxy[Int(t[1])] = (Float64(t[2]), Float64(t[3]))
        end
        length(stopxy) < 2 && continue
        lat0 = mean(v[1] for v in values(stopxy))
        seglen, cum = geom(stopxy, nseg, lat0)
        # vehicleno ごとに (ts, op) を集める（cloud は SQLite から直近 CLOUD_CAP 点）
        tracks = Dict{String,Vector{Tuple{Float64,Float64}}}()
        for p in cloud_query(db, rid, CLOUD_CAP)
            length(p) >= 7 || continue
            vno = String(p[7]); ts = Float64(p[6])
            (isempty(vno) || ts <= 0) && continue
            push!(get!(tracks, vno, Tuple{Float64,Float64}[]), (ts, Float64(p[1])))
        end
        # 連続観測 pair → (k0..k1, dt, darc, arc1, arc2, v)
        pairs = Tuple{Int,Int,Float64,Float64,Float64,Float64,Float64}[]
        for (_, pts) in tracks
            length(pts) < 2 && continue
            sort!(pts, by = x -> x[1])
            for i in 2:length(pts)
                ts1, op1 = pts[i-1]; ts2, op2 = pts[i]
                dt = ts2 - ts1
                (5.0 <= dt <= 900.0) || continue
                a1 = arc(op1, seglen, cum); a2 = arc(op2, seglen, cum)
                darc = a2 - a1
                (0.0 < darc <= 30.0 * dt) || continue        # 前進のみ・<=30m/s（新運行/ループ跳びを除外）
                k0 = clamp(floor(Int, op1), 1, nseg); k1 = clamp(floor(Int, op2), 1, nseg)
                push!(pairs, (k0, k1, dt, darc, a1, a2, darc / dt))
            end
        end
        isempty(pairs) && continue
        # 区間速度表（渡った全区間に速度を付ける）
        segspeeds = Dict{Int,Vector{Float64}}()
        for pr in pairs
            for k in pr[1]:pr[2]
                push!(get!(segspeeds, k, Float64[]), pr[7])
            end
            push!(allspeeds, pr[7])
        end
        segmed = Dict(k => median(vs) for (k, vs) in segspeeds)
        # 検証＋区間残差（開始区間 k0 の中央速度で予測）
        segresid = Dict{Int,Vector{Float64}}()
        for pr in pairs
            vm = get(segmed, pr[1], NaN)
            isnan(vm) && continue
            predarc = pr[5] + vm * pr[3]
            e = pr[6] - predarc
            rm2 += e^2; rp2 += pr[4]^2; nval += 1           # persist=「動かない」→残差=実移動 darc
            push!(get!(segresid, pr[1], Float64[]), abs(e))
        end
        m = Dict{String,Vector{Float64}}()
        for (k, vs) in segspeeds
            isempty(vs) && continue
            resid = haskey(segresid, k) && !isempty(segresid[k]) ? mean(segresid[k]) : 0.0
            m[string(k)] = [median(vs), std(vs; corrected = false), resid, Float64(length(vs))]
        end
        isempty(m) || (routesOut[rid] = m)
    end
    gmed = isempty(allspeeds) ? 0.0 : median(allspeeds)
    out = Dict(
        "global_speed" => gmed, "n_pairs" => length(allspeeds),
        "rmse_model" => nval > 0 ? sqrt(rm2 / nval) : 0.0,
        "rmse_persist" => nval > 0 ? sqrt(rp2 / nval) : 0.0,
        "n_val" => nval, "routes" => routesOut,
    )
    open(io -> JSON3.write(io, out), OUT, "w")
    println("model.json: $(length(routesOut))路線 / 速度中央値 $(round(gmed, digits=1))m/s / RMSE モデル $(round(out["rmse_model"], digits=1))m vs 慣性 $(round(out["rmse_persist"], digits=1))m (n=$(nval)) → $OUT")
end

main()
