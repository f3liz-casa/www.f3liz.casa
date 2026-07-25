#!/usr/bin/env julia
# 実バスのGPSで、路線の線を「実測」に確定する。― リクエスト効率をいちばんに。
#
# 効率の核心：버스위치API は 1リクエストで「その路線を走る全バスのスナップショット」を
# 返す。各バスは経路上の別々の nodeord にいる＝一発で経路全体に散らばった点が採れる。
# だから一台を追うのではなく、**全バスの点を毎回束ねる**。バスは経路上に散っているので、
# 各バスが「隣のバスまでの隙間」を進むだけで、合併が全線を覆う（一台追跡の約 N倍 効率的）。
# しかも同じ区間を複数バスが重ねて通る → **平均してGPSノイズを消せる**。
#
# 手順：
#   1. 停留所を1回取得（nodeord→座標・順序）。3001 のように nodeord は位置APIと同体系。
#   2. 全バスを interval 秒ごとにスナップ、点を貯める。各点を (nodeord, 区間内の進み具合)
#      で並べられるようにする。毎スナップ後、全区間が覆えたか判定 → 覆えたら即終了（適応終了）。
#   3. 弧長順に並べ、近い点どうしをまとめて平均（ノイズ除去）→ 道なり線を出力。
#
# 使い方（サービス時間中）：
#   julia correct_route.jl <routeId> <cityCode> [interval=12] [cover=0.97] [maxMin=40] [binM=50]
#   例: julia correct_route.jl BSB5203001000 21

using Downloads, JSON3, Dates, LinearAlgebra

const KEYFILE = get(ENV, "TAGO_KEY_FILE", joinpath(@__DIR__, ".tago_key"))
const SK = strip(read(KEYFILE, String))
const LOC   = "http://apis.data.go.kr/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList"
const STOPS = "http://apis.data.go.kr/1613000/BusRouteInfoInqireService/getRouteAcctoThrghSttnList"

function poll(url, cityCode, routeId)
    q = "serviceKey=$SK&pageNo=1&numOfRows=300&_type=json&cityCode=$cityCode&routeId=$routeId"
    local lasterr
    for attempt in 1:4  # ネット揺れ・空応答・エラー応答に、リトライで耐える
        try
            s = read(Downloads.download("$url?$q"), String)
            body = JSON3.read(s).response.body
            body isa AbstractString && return Any[]  # 空/エラー応答（body が "" のことがある）
            items = body.items
            (items === "" || items isa AbstractString) && return Any[]
            it = items.item
            return it isa JSON3.Array ? collect(it) : Any[it]
        catch e
            lasterr = e
            sleep(2)
        end
    end
    throw(lasterr)
end

num(x) = x isa Number ? Float64(x) : parse(Float64, String(x))

# 緯度経度 → ローカル・メートル（射影・距離の計算用）。
metric(lat, lng, lat0) = (lng * cosd(lat0) * 111320.0, lat * 111320.0)

# 点が、区間 A(=stop[k]) → B(=stop[k+1]) の、どこまで進んだか（0..1）。
function segprogress(lat, lng, A, B, lat0)
    ax, ay = metric(A[1], A[2], lat0); bx, by = metric(B[1], B[2], lat0)
    px, py = metric(lat, lng, lat0)
    len2 = (bx - ax)^2 + (by - ay)^2
    len2 == 0 && return 0.0
    return clamp(((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len2, 0.0, 1.0)
end

mean1(v) = sum(v) / length(v)

# 雲の点を時間帯（KST の時, 0-23。seed した既存分は -1=時刻不明）ごとに数える。
# geojson の properties.bands に入れて「どの時間帯で何点採れたか」を残す＝時間帯別記録。
function band_hist(cloud)
    d = Dict{String,Int}()
    for p in cloud
        k = string(p[5])
        d[k] = get(d, k, 0) + 1
    end
    return d
end

# 各 stop-区間 k の長さ（メートル）。無い区間は 0。
function seg_lengths(stopxy, nseg, lat0)
    L = zeros(nseg)
    for k in 1:nseg
        if haskey(stopxy, k) && haskey(stopxy, k + 1)
            ax, ay = metric(stopxy[k][1], stopxy[k][2], lat0)
            bx, by = metric(stopxy[k+1][1], stopxy[k+1][2], lat0)
            L[k] = hypot(bx - ax, by - ay)
        end
    end
    return L
end

# カバレッジ＝赤の長さ / 全長。地図（overlay-bridge.js の densifyWithFlags）と同じ規則：
# 区間は「両端が確定 かつ 間隔<=gapM」のときだけ赤。離れた点の間（>gapM）は道が推測なので青。
# ＝「赤と青の線の長さ比」を、地図の見た目そのままで測る（1台居れば赤の楽観値ではなく）。
function line_coverage(coords, flags, lat0, gapM)
    red = 0.0
    tot = 0.0
    for i in 1:length(coords)-1
        ax, ay = metric(coords[i][2], coords[i][1], lat0)     # coords は [lng, lat]
        bx, by = metric(coords[i+1][2], coords[i+1][1], lat0)
        L = hypot(bx - ax, by - ay)
        tot += L
        (flags[i] == 1 && flags[i+1] == 1 && L <= gapM) && (red += L)
    end
    return tot <= 0 ? 0.0 : red / tot
end

# 成分別の中央値。マルチパスの飛びに強い（外れ値1つで平均が引っ張られるのを防ぐ）。
med(v) = (s = sort(v); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

# ── 物理の事前分布：車ごと(vehicleno)の軌跡を掃除する ──
# (a) Hampel: 局所中央値から大きく外れる点(マルチパス飛び)を、その中央値へ「置換」＝有界で頑健（弾いて
#     予測に頼ると疎な間隔で発散するので、捨てず置換する）。(b) 等速カルマン＋RTS で平滑。速度は物理上限に
#     クランプ、外挿の dt も制限（発散防止）。最後に掃除後の点から離れすぎたら戻す安全弁。lat,lng だけ掃除。
function smooth_tracks(cloud, lat0)
    out = collect(cloud)
    tracks = Dict{String,Vector{Int}}()
    for (i, p) in enumerate(cloud)
        (length(p) >= 7 && !isempty(String(p[7])) && Float64(p[6]) > 0) || continue   # vehicleno と生時刻がある実測点だけ
        push!(get!(tracks, String(p[7]), Int[]), i)
    end
    σz = 12.0; σa = 1.5; gate = 13.8; VMAX = 30.0         # GPS雑音(m)・加速度雑音(m/s²)・χ²(2)99.9%・速度上限(m/s)
    H = [1.0 0 0 0; 0 1 0 0]; R = Matrix(Diagonal([σz^2, σz^2]))
    for (_, idxs) in tracks
        length(idxs) < 3 && continue                     # 短すぎる軌跡は掃除しない
        sort!(idxs, by = i -> Float64(cloud[i][6]))       # ts順
        n = length(idxs)
        X = [collect(metric(cloud[i][2], cloud[i][3], lat0)) for i in idxs]   # (x,y) メートル
        T = [Float64(cloud[i][6]) for i in idxs]
        Xc = [copy(x) for x in X]                         # Hampel: ±3窓の中央値から120m超を飛びとみなし中央値へ置換
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
        # RTS 後ろ向き平滑（位置だけ書き戻す）
        smpos = Vector{Tuple{Float64,Float64}}(undef, n)
        sm = copy(fmean[n]); smpos[n] = (sm[1], sm[2])
        for k in (n-1):-1:1
            C = fcov[k] * Fs[k+1]' / pcov[k+1]
            sm = fmean[k] + C * (sm - pmean[k+1])
            smpos[k] = (sm[1], sm[2])
        end
        for (j, i) in enumerate(idxs)
            x, y = smpos[j]
            hypot(x - Xc[j][1], y - Xc[j][2]) > 300.0 && ((x, y) = (Xc[j][1], Xc[j][2]))   # 発散安全弁: 掃除後から離れすぎたら戻す
            p = cloud[i]
            out[i] = (p[1], y / 111320.0, x / (cosd(lat0) * 111320.0), p[4], p[5], p[6], p[7])
        end
    end
    return out
end

# 束ねた点群 → 物理(車ごとKF+RTS)で掃除 → 弧長の固定グリッドで中央値集約（サンプルが増えるほど締まる）
# → [lng,lat] の線 + 確定フラグ。覆えていない区間は停留所を結ぶ直線で密に埋め「未確定(青)」。
function reconstruct(cloud, stopxy, maxord, lat0, binM)
    cloud = try
        smooth_tracks(cloud, lat0)                        # 物理: 飛び除去＋平滑（失敗時は生の点へ退化）
    catch
        cloud
    end
    seglen = zeros(max(maxord, 1))
    for k in 1:maxord-1
        (haskey(stopxy, k) && haskey(stopxy, k + 1)) || continue
        ax, ay = metric(stopxy[k][1], stopxy[k][2], lat0)
        bx, by = metric(stopxy[k+1][1], stopxy[k+1][2], lat0)
        seglen[k] = hypot(bx - ax, by - ay)
    end
    cum = zeros(maxord)
    for k in 2:maxord
        cum[k] = cum[k-1] + (k - 1 <= length(seglen) ? seglen[k-1] : 0.0)
    end
    function arcof(op)                                     # op=ord+t → 弧長(m)
        k = floor(Int, op)
        k < 1 && return 0.0
        base = k <= length(cum) ? cum[k] : (isempty(cum) ? 0.0 : cum[end])
        return base + (op - k) * (k <= length(seglen) ? seglen[k] : 0.0)
    end
    covered = Set(p[4] for p in cloud)
    # 停留所ベクトルの座標系で確定線を作る：along(沿線位置)は bin の弧位置(単調)、cross(横ズレ)だけを中央値に。
    # ＝成分中央値より折り返し(タングル)が減る。cross は各点の停留所ベクトルへの符号付き垂直距離。
    boff = Dict{Int,Vector{Float64}}()
    for p in cloud
        k = floor(Int, p[1])
        (haskey(stopxy, k) && haskey(stopxy, k + 1)) || continue
        ax, ay = metric(stopxy[k][1], stopxy[k][2], lat0); bx, by = metric(stopxy[k+1][1], stopxy[k+1][2], lat0)
        L = hypot(bx - ax, by - ay); L < 1 && continue
        px, py = metric(p[2], p[3], lat0)
        cross = ((px - ax) * -(by - ay) + (py - ay) * (bx - ax)) / L   # 垂直成分(signed)
        push!(get!(boff, round(Int, arcof(p[1]) / binM), Float64[]), cross)
    end
    pts = Tuple{Float64,Float64,Float64,Bool}[]
    for (b, offs) in boff
        A = b * binM
        k = clamp(searchsortedlast(cum, A), 1, max(maxord - 1, 1))   # 弧 A の区間
        (haskey(stopxy, k) && haskey(stopxy, k + 1)) || continue
        ax, ay = metric(stopxy[k][1], stopxy[k][2], lat0); bx, by = metric(stopxy[k+1][1], stopxy[k+1][2], lat0)
        L = hypot(bx - ax, by - ay); L < 1 && continue
        t = clamp((A - cum[k]) / L, 0.0, 1.0); m = med(offs)
        cx = ax + (bx - ax) * t + m * -(by - ay) / L   # チョード点 + 横ズレ中央値
        cy = ay + (by - ay) * t + m * (bx - ax) / L
        push!(pts, (A, cy / 111320.0, cx / (cosd(lat0) * 111320.0), true))
    end
    # 未確定区間: 停留所直線で密に埋める（青が切れないように）
    for k in 1:maxord-1
        (!(k in covered) && haskey(stopxy, k) && haskey(stopxy, k + 1)) || continue
        A = stopxy[k]; B = stopxy[k+1]; L = seglen[k]; nfill = max(1, ceil(Int, L / binM))
        for sidx in 0:nfill
            t = sidx / nfill
            push!(pts, (cum[k] + t * L, A[1] + (B[1]-A[1])*t, A[2] + (B[2]-A[2])*t, false))
        end
    end
    sort!(pts, by = x -> x[1])
    coords = Vector{Vector{Float64}}(); flags = Int[]
    for (_, lat, lng, conf) in pts
        push!(coords, [lng, lat]); push!(flags, conf ? 1 : 0)
    end
    return coords, flags
end

function save_geojson(path, coords, flags, routeId, cover, req, bands=Dict{String,Int}())
    fc = Dict("type" => "Feature",
        "properties" => Dict("routeid" => routeId, "source" => "bus-gps-snapshot",
            "npts" => length(coords), "coverage" => round(cover, digits=3), "requests" => req,
            "bands" => bands, "confirmed" => flags),
        "geometry" => Dict("type" => "LineString", "coordinates" => coords))
    open(io -> JSON3.write(io, fc), path, "w")
end

function main()
    length(ARGS) < 2 && error("usage: julia correct_route.jl <routeId> <cityCode> [interval=12] [cover=0.97] [maxMin=40] [binM=30] [gapM=250]")
    routeId  = ARGS[1]; cityCode = ARGS[2]
    interval = length(ARGS) >= 3 ? parse(Int, ARGS[3])     : 12
    coverGoal= length(ARGS) >= 4 ? parse(Float64, ARGS[4]) : 0.97
    maxMin   = length(ARGS) >= 5 ? parse(Int, ARGS[5])     : 40
    binM     = length(ARGS) >= 6 ? parse(Float64, ARGS[6]) : 30.0
    gapM     = length(ARGS) >= 7 ? parse(Float64, ARGS[7]) : 250.0   # 地図の gapMax と揃える

    outdir = expanduser("~/sandbox/tago/corrected"); mkpath(outdir)
    outfile = joinpath(outdir, "$(routeId)_corrected.geojson")

    # 1) 停留所（1リクエスト）。nodeord→座標・順序・区間数。
    stops = poll(STOPS, cityCode, routeId)
    isempty(stops) && error("停留所が取れませんでした: $routeId")
    stopxy = Dict{Int,Tuple{Float64,Float64}}()
    for s in stops; stopxy[Int(num(s.nodeord))] = (num(s.gpslati), num(s.gpslong)); end
    maxord = maximum(keys(stopxy))
    nseg = maxord - 1
    lat0 = mean1([v[1] for v in values(stopxy)])
    seglen = seg_lengths(stopxy, nseg, lat0)
    println("route $(routeId): 停留所 $(length(stops))、区間 $(nseg)、全長 $(round(sum(seglen)/1000, digits=1))km、最終 nodeord $(maxord)")

    # 2) 全バス・スナップショット束ね（適応終了）。
    cloud = Vector{Tuple{Float64,Float64,Float64,Int,Int,Float64}}()   # 末尾2つ＝band(KST時), ts(生epoch秒)
    covered = Set{Int}()
    req = 1; t0 = time()
    while true
        buses = try
            b = poll(LOC, cityCode, routeId); req += 1; b
        catch e
            println("  … poll 失敗（$(sprint(showerror, e))）。$(interval)s 後に再試行"); sleep(interval); continue
        end
        band = Dates.hour(Dates.now()); ts = time()   # band=KST時(0-23), ts=生epoch秒(取得時刻そのもの)
        for b in buses
            ord = Int(num(b.nodeord)); lat = num(b.gpslati); lng = num(b.gpslong)
            (haskey(stopxy, ord) && haskey(stopxy, ord+1)) || (push!(cloud, (Float64(ord), lat, lng, ord, band, ts)); push!(covered, ord); continue)
            t = segprogress(lat, lng, stopxy[ord], stopxy[ord+1], lat0)
            push!(cloud, (Float64(ord) + t, lat, lng, ord, band, ts))
            push!(covered, ord)
        end
        coords, flags = reconstruct(cloud, stopxy, maxord, lat0, binM)
        cov = line_coverage(coords, flags, lat0, gapM)
        save_geojson(outfile, coords, flags, routeId, cov, req, band_hist(cloud))  # 落ちても残る
        missing_segs = [k for k in 1:nseg if !(k in covered)]
        ms = length(missing_segs) <= 8 ? string(missing_segs) : "$(length(missing_segs))区間"
        println("req $req  バス $(length(buses))  カバー $(round(Int,cov*100))%  点 $(length(coords))  未: $ms")

        cov >= coverGoal && (println("目標カバー到達。終了。"); break)
        (time() - t0) > maxMin * 60 && (println("時間上限。打ち切り。"); break)
        sleep(interval)
    end

    coords, flags = reconstruct(cloud, stopxy, maxord, lat0, binM)
    cov = line_coverage(coords, flags, lat0, gapM)
    save_geojson(outfile, coords, flags, routeId, cov, req, band_hist(cloud))
    println("\n完了: $(length(coords)) 点、カバー $(round(Int,cov*100))%、リクエスト $req")
    println("（参考：一台追跡なら全長ぶん ~数百リクエスト。今回 $req）")
    println("出力: $outfile")
end

# 単体実行のときだけ走る。correct_all.jl から include して関数を借りるときは走らせない。
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
