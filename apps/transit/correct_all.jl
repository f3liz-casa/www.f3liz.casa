#!/usr/bin/env julia
# 全バス路線へ、実測補正を広げる。― 予算つき・再開可能・「赤/青の長さ比」でカバレッジ。
#
# なぜ round-robin か：
#   一路線を覆うのに ~90 サンプル要る（3001 実績 92req）。一路線ずつ張り付くと 534 本で
#   数百時間。だから毎サイクル、各路線を「1リクエストずつ」順に叩いて回る＝全路線を薄く
#   並行に育てる。버스위치は1発でその路線の全バスを返す（経路上に散らばった点が一度に採れる）
#   ので、各路線が1サンプルでも前に進む。これが correct_route.jl の効率の核を横に広げた形。
#
# 予算：開発キー 10000/日。使い切ったら checkpoint して終了 → 翌日また同じコマンドで続きから。
#       サービス時間外（全路線でバス0が続く）も、予算を焼かずに終了する。
#
# 状態：progress/<routeid>.json に、停留所・点群・覆えた区間・カバレッジを持つ（再開の素）。
#       出力は corrected/<routeid>_corrected.geojson（単体版と同じ形＝地図がそのまま拾う）。
#
# 速さ：poll（バス位置）はネットワーク往復 ~2.4s が支配的（ローカル処理は ~0.1s）。逐次だと
# それが下限で 10000 に ~7h。so **同時 conc 本を並列ポーリング**してネットワーク待ちを重ねる
# （Julie の @async + Downloads は I/O で yield するので重なる）。conc=6 で実効 ~2.5 req/s ≒ 10000/~1h。
#
# 使い方（サービス時間中）：
#   julia correct_all.jl [cities=busan] [dailyBudget=9500] [cover=0.95] [conc=6] [plateau=8]
#   例（釜山を1万で、同時8本で速く）: julia correct_all.jl busan 10000 0.95 8

include(joinpath(@__DIR__, "correct_route.jl"))  # poll/metric/segprogress/reconstruct/save_geojson/seg_lengths/length_coverage/num/mean1 を借りる

const CITYCODE = Dict("busan" => "21", "daegu" => "22")
const DATADIR = get(ENV, "TAGO_DATA_DIR", @__DIR__)   # 生成データ(progress/corrected/daily)の置き場。コンテナでは永続volume。既定=スクリプト隣（従来どおり）
const PROGDIR = joinpath(DATADIR, "progress")
const OUTDIR = joinpath(DATADIR, "corrected")
const LIVEDIR = joinpath(DATADIR, "live")   # バスの現在位置（地図表示用の最新スナップ, live/<routeid>.json）
const DAILY = joinpath(DATADIR, "daily.json")   # 今日の API 消費（再起動をまたいで日次上限を守る＋dashboard 表示）

# 釜山の妥当な緯度経度域。GPS無効時のプレースホルダ（例 125,30 のチェジュ沖）を捨てる。
# overlay-bridge の inBusan と同じ域（거제まで含むよう少し広め）。
in_busan(lat, lng) = 34.5 < lat < 35.7 && 128.4 < lng < 129.6

const TRUNK = joinpath(DATADIR, "trunk.json")   # 区間別固有度(uniqueness)地図。precompute_trunk.jl が書く。無ければ一様に退化。
const SEL_ALPHA = 1.0   # スケジューラ積極度: 選抜確率 ∝ need/平均need。1.0で平均need路線は毎sweep選抜、高needは常時、低need(幹線赤)は薄く。
const SEL_EPS = 0.05    # ε探索フロア: どの路線も最低5%のsweepで見る（枯渇/ドリフト再訪防止）。
const MODELF = joinpath(DATADIR, "model.json")   # learn.jl が書く速度モデル＋検証残差。無ければ幾何uniqのみ。
const LEARN_W = 1.5     # 学習不確実性の重み: 残差の大きい(=予測が外れる)区間ほど need を上げる強さ。
const RESID_TYP = 120.0 # 残差(m)の正規化基準。残差=RESID_TYP で boost が LEARN_W 分。
const RESID_CAP = 3.0   # boost 上限（暴走防止）。
const MODEL_MIN_N = 5   # この本数未満の区間は学習を信じない＝幾何uniq へ退化。
# 速度モデル（rid => seg => (中央速度, std, 検証残差m, n)）。learn.jl の /data/model.json から起動時ロード。
const MODEL = Ref(Dict{String,Dict{Int,NTuple{4,Float64}}}())
const EMPTY_SEG = Dict{Int,NTuple{4,Float64}}()

# 集中＋ローテーション収集（500k を密に使う）。need 上位 FOCUS_K 路線に窓 FOCUS_WINDOW 秒だけ集中し、
# 各 route を REFRESH 秒間隔で密に叩く（API 更新周期より速く叩いても重複なので REFRESH で頭打ち）。
# 窓が終わると need を再計算して次の群へローテーション。dense poll でも重い reconstruct は RECON_MIN 間引く。
# ※精密さ(絞る) と 500k消費(広げる) はトレードオフ：REFRESH=18s なら 500k を使い切るのに FOCUS_K≈120 要る。
const FOCUS_K = parse(Int, get(ENV, "FOCUS_K", "60"))
const REFRESH = parse(Float64, get(ENV, "REFRESH", "18"))
const FOCUS_WINDOW = parse(Float64, get(ENV, "FOCUS_WINDOW", "1200"))
const RECON_MIN = parse(Float64, get(ENV, "RECON_MIN", "30"))
const CLOUD_CAP = parse(Int, get(ENV, "CLOUD_CAP", "100000"))   # DB保持/速度モデルが使う直近点数（cloudはSQLite・追記O(new)）
const RECON_CAP = parse(Int, get(ENV, "RECON_CAP", "30000"))    # reconstruct(幾何)が query する直近点数。30k≒59ms・bias床で100kと同等。100kは289msで poll経路を塞ぐため。
include(joinpath(@__DIR__, "clouddb.jl"))                       # cloud を SQLite に（open_clouddb/cloud_insert!/cloud_query/cloud_count）
const CLOUDDB = open_clouddb()
const LAST_RECON = Dict{String,Float64}()   # rid → 最後に reconstruct した時刻（throttle）
const LAST_BANDS = Dict{String,Any}()       # rid → band別点数（write_route_geojson が計算, dashboardの時間帯表示用）
const NODEID_TRIED = Set{String}()          # nodeid backfill を試みた rid（欠落時の毎poll再取得ドレイン防止）

# コンテナは UTC で回るので、KST(UTC+9・夏時間なし)を明示計算する。band(時間帯)と日次リセットの基準。
now_kst() = Dates.now(Dates.UTC) + Dates.Hour(9)
today_kst() = Dates.format(now_kst(), "yyyy-mm-dd")   # KST の日付（TAGO quota も KST 深夜リセット）

# 今日ここまでに使った req 数（日付が変われば 0 から）。
function load_daily()
    d = today_kst()
    if isfile(DAILY)
        try
            j = JSON3.read(read(DAILY, String))
            String(j.date) == d && return (d, Int(j.spent))
        catch
        end
    end
    return (d, 0)
end
save_daily(spent) = open(io -> JSON3.write(io, Dict("date" => today_kst(), "spent" => spent)), DAILY, "w")

mutable struct RS
    rid::String
    cc::String
    stopxy::Dict{Int,Tuple{Float64,Float64}}
    nseg::Int
    maxord::Int
    lat0::Float64
    seglen::Vector{Float64}
    cloud::Vector{Tuple{Float64,Float64,Float64,Int,Int,Float64,String}}   # 末尾3つ＝band(KST時,seed=-1), ts(生epoch秒,seed=-1), vehicleno(seed="")
    covered::Set{Int}
    reqs::Int
    cov::Float64
    done::Bool         # 真の完了（cov>=目標）だけ。永久にスキップ。
    hold::Int          # 連続で「新カバレッジ無し」の回数（plateau 判定）
    stops_ok::Bool     # 停留所を取得済みか
    held::Bool         # plateau で「保留」。このセッションは休む が、次の run で revisit（done とは別）。
    uniq::Vector{Float64}   # trunk地図: 区間kの固有度∈(0,1]（1=完全固有,小=共通幹線）。trunk.json由来・静的。空=一様
    last_obs::Float64       # 最後にバスを見た epoch秒（staleness用）。0=未観測
    stopnode::Dict{Int,String}   # ord→nodeid（표준노드ID）。路線間で共有＝路線間fusion(補間)の鍵。progressに永続。
end

fresh(rid, cc) = RS(rid, cc, Dict{Int,Tuple{Float64,Float64}}(), 0, 0, 0.0,
    Float64[], Tuple{Float64,Float64,Float64,Int,Int,Float64,String}[], Set{Int}(), 0, 0.0, false, 0, false, false,
    Float64[], 0.0, Dict{Int,String}())

progpath(rid) = joinpath(PROGDIR, "$(rid).json")

function load_routes(cities)
    rs = Tuple{String,String}[]
    for city in cities
        cc = get(CITYCODE, city, nothing)
        cc === nothing && error("unknown city: $city （busan か daegu）")
        f = joinpath(@__DIR__, city, "routes.jsonl")
        isfile(f) || error("routes.jsonl が無い: $f")
        for line in eachline(f)
            isempty(strip(line)) && continue
            o = JSON3.read(line)
            push!(rs, (String(o.routeid), cc))
        end
    end
    return rs
end

function save_state(s::RS)
    d = Dict{String,Any}(
        "rid" => s.rid, "cc" => s.cc, "nseg" => s.nseg, "maxord" => s.maxord, "lat0" => s.lat0,
        "stops" => [[k, v[1], v[2]] for (k, v) in s.stopxy],
        "cloud" => Any[],   # cloud は SQLite(cloud.db)へ移行。JSONには書かない（毎poll の O(cloud) rewrite を無くす）
        "npts" => cloud_count(CLOUDDB, s.rid),   # dashboard/status の「GPS点」表示用（cloudはDBにあるので数だけ持つ）
        "bands" => get(LAST_BANDS, s.rid, Dict{String,Int}()),   # 時間帯別点数（write_route_geojson が計算）
        "covered" => collect(s.covered), "reqs" => s.reqs, "cov" => s.cov,
        "done" => s.done, "hold" => s.hold, "stops_ok" => s.stops_ok, "held" => s.held,
        "last_obs" => s.last_obs,
        "stopnodes" => [[k, v] for (k, v) in s.stopnode],
    )
    tmp = progpath(s.rid) * ".tmp"
    open(io -> JSON3.write(io, d), tmp, "w")
    mv(tmp, progpath(s.rid); force = true)   # 半端書きで壊さないよう、書き切ってから置き換え
end

function load_state(rid, cc)
    p = progpath(rid)
    isfile(p) || return fresh(rid, cc)
    try
        s = JSON3.read(read(p, String))
        stopxy = Dict{Int,Tuple{Float64,Float64}}()
        for t in s.stops
            stopxy[Int(t[1])] = (Float64(t[2]), Float64(t[3]))
        end
        nseg = Int(s.nseg)
        lat0 = Float64(s.lat0)
        # 旧JSONの cloud を一度だけ SQLite へ移行（in_busanフィルタ）。以後 save_state は cloud を書かないので再移行しない。
        if haskey(s, :cloud) && !isempty(s.cloud) && cloud_count(CLOUDDB, String(rid)) == 0
            mig = [(Float64(p[1]), Float64(p[2]), Float64(p[3]), Int(p[4]),
                    length(p) >= 5 ? Int(p[5]) : -1, length(p) >= 6 ? Float64(p[6]) : -1.0,
                    length(p) >= 7 ? String(p[7]) : "") for p in s.cloud]
            filter!(p -> in_busan(p[2], p[3]), mig)
            cloud_insert!(CLOUDDB, String(rid), mig)
        end
        last_obs = haskey(s, :last_obs) ? Float64(s.last_obs) : 0.0
        stopnode = Dict{Int,String}()
        if haskey(s, :stopnodes)
            for t in s.stopnodes
                stopnode[Int(t[1])] = String(t[2])
            end
        end
        return RS(rid, cc, stopxy, nseg, Int(s.maxord), lat0,
            seg_lengths(stopxy, nseg, lat0),
            Tuple{Float64,Float64,Float64,Int,Int,Float64,String}[],   # cloud は空（実体は SQLite）
            Set(Int(x) for x in s.covered), Int(s.reqs), Float64(s.cov),
            Bool(s.done), Int(s.hold), Bool(s.stops_ok), false,   # held は毎 run リセット＝revisit
            Float64[], last_obs, stopnode)   # uniq は起動時 load_trunk! で埋める
    catch e
        @warn "state 読めず、作り直し: $rid" exception = e
        return fresh(rid, cc)
    end
end

# 停留所を1回だけ取る（1 req）。nodeord→座標・区間数・区間長。
function ensure_stops!(s::RS)
    (s.stops_ok && !isempty(s.stopnode)) && return true   # 座標も nodeid も揃ってれば skip。nodeid 無ければ再取得で backfill。
    stops = try
        poll(STOPS, s.cc, s.rid)
    catch
        return false
    end
    isempty(stops) && return false
    for st in stops
        ord = Int(num(st.nodeord))
        s.stopxy[ord] = (num(st.gpslati), num(st.gpslong))
        haskey(st, :nodeid) && (s.stopnode[ord] = String(st.nodeid))   # 路線間fusion(補間)の鍵
    end
    isempty(s.stopxy) && return false
    s.maxord = maximum(keys(s.stopxy))
    s.nseg = s.maxord - 1
    s.lat0 = mean1([v[1] for v in values(s.stopxy)])
    s.seglen = seg_lengths(s.stopxy, s.nseg, s.lat0)
    s.stops_ok = true
    return true
end

# バス1スナップショット（1 req）を束ねる。返り値＝そのとき走っていたバス台数。
function sample!(s::RS)
    buses = poll(LOC, s.cc, s.rid)
    band = Dates.hour(now_kst()); ts = time()   # band=KST時(0-23, UTC+9明示), ts=生epoch秒（取得時刻そのもの）
    live = Vector{Tuple{Float64,Float64,Int}}()    # 地図表示用の最新スナップ（lat,lng,ord）
    newpts = Tuple{Float64,Float64,Float64,Int,Int,Float64,String}[]   # この poll の新点（DBへ追記）
    for b in buses
        ord = Int(num(b.nodeord))
        lat = num(b.gpslati)
        lng = num(b.gpslong)
        in_busan(lat, lng) || continue             # 異常GPS（無効時プレースホルダ）は雲にも地図にも入れない
        vno = haskey(b, :vehicleno) ? string(b.vehicleno) : ""   # 同一車の連続観測を繋ぐ鍵＝速度推定の土台（API費用ゼロ）
        op = (haskey(s.stopxy, ord) && haskey(s.stopxy, ord + 1)) ?
            Float64(ord) + segprogress(lat, lng, s.stopxy[ord], s.stopxy[ord+1], s.lat0) : Float64(ord)
        push!(newpts, (op, lat, lng, ord, band, ts, vno))
        push!(s.covered, ord)
        push!(live, (lat, lng, ord))
    end
    cloud_insert!(CLOUDDB, s.rid, newpts)   # SQLite へ追記（O(new)。頭打ちの原因だった JSON 全書き直しを廃止）
    # バスの現在位置（最新スナップ）を書く。空でも上書き＝運行外の古い点を残さない。
    try
        open(io -> JSON3.write(io, [Dict("lat" => p[1], "lng" => p[2], "ord" => p[3]) for p in live]),
             joinpath(LIVEDIR, "$(s.rid).json"), "w")
    catch
    end
    return length(buses)
end

# 上書き阻止：既存の corrected geojson（前の収集ぶん）を、雲へ「時刻不明(band=-1)」の
# 実GPS点として取り込む。再収集がゼロから始まって古い赤を消すのを防ぐ＝積み増しになる。
# 停留所取得後・雲が空のときだけ1回（＝progress の無い既存路線だけ）。
function seed_from_existing!(s::RS)
    p = joinpath(OUTDIR, "$(s.rid)_corrected.geojson")
    isfile(p) || return 0
    gj = try
        JSON3.read(read(p, String))
    catch
        return 0
    end
    coords = gj.geometry.coordinates
    flags = gj.properties.confirmed
    length(coords) == length(flags) || return 0
    seeds = Tuple{Float64,Float64,Float64,Int,Int,Float64,String}[]
    for i in 1:length(coords)
        flags[i] == 1 || continue                          # 実GPS(赤)だけ引き継ぐ
        lng = Float64(coords[i][1]); lat = Float64(coords[i][2])
        px, py = metric(lat, lng, s.lat0)
        bestk = 0; bestt = 0.0; bestd = Inf
        for k in 1:s.nseg
            (haskey(s.stopxy, k) && haskey(s.stopxy, k + 1)) || continue
            t = segprogress(lat, lng, s.stopxy[k], s.stopxy[k+1], s.lat0)
            ax, ay = metric(s.stopxy[k][1], s.stopxy[k][2], s.lat0)
            bx, by = metric(s.stopxy[k+1][1], s.stopxy[k+1][2], s.lat0)
            d = hypot(px - (ax + (bx - ax) * t), py - (ay + (by - ay) * t))
            d < bestd && (bestd = d; bestk = k; bestt = t)
        end
        bestk == 0 && continue
        push!(seeds, (Float64(bestk) + bestt, lat, lng, bestk, -1, -1.0, ""))   # band=-1,ts=-1,vno=""（既存seed=時刻不明）
        push!(s.covered, bestk)
    end
    cloud_insert!(CLOUDDB, s.rid, seeds)   # 既存 geojson の確定点を SQLite へ（上書き阻止）
    return length(seeds)
end

function write_route_geojson!(s::RS, binM, gapM)
    cloud = cloud_query(CLOUDDB, s.rid, RECON_CAP)   # 幾何は直近 RECON_CAP 点で（bias床で十分・poll経路を塞がない）
    coords, flags = reconstruct(cloud, s.stopxy, s.maxord, s.lat0, binM)
    isempty(coords) && return   # 空を書いて既存 geojson を壊さない（stops未取得/cloud空など）
    s.cov = line_coverage(coords, flags, s.lat0, gapM)   # 地図と同じ gap 規則で honest に
    bh = band_hist(cloud); LAST_BANDS[s.rid] = bh   # dashboard の時間帯別表示用に metadata へ回す
    save_geojson(joinpath(OUTDIR, "$(s.rid)_corrected.geojson"), coords, flags, s.rid, s.cov, s.reqs, bh)
end

# 1路線を1歩すすめる（停留所→seed→バス1サンプル→カバレッジ→保存）。@async から並列に呼ぶ。
# 各路線は自分の RS/ファイルだけ触るので競合なし。spent/busesTotal/gained は Ref で共有カウント
# （Julie の @async は協調的＝yield 間は不可分なので `[] += 1` は安全）。
function process_route!(s::RS, spent, busesTotal, gained, okPolls, dailyBudget, binM, gapM, coverGoal, plateauN)
    # 停留所未取得、または nodeid 未捕捉かつ未試行(既存路線の backfill を1回だけ)
    if !s.stops_ok || (isempty(s.stopnode) && !(s.rid in NODEID_TRIED))
        spent[] >= dailyBudget && return
        spent[] += 1
        push!(NODEID_TRIED, s.rid)   # 試行済み＝以後 nodeid 欠落でも再取得しない（予算ドレイン防止）
        if !ensure_stops!(s)
            s.hold += 1
            s.hold >= plateauN && (s.held = true)   # 停留所が取れない＝保留（次runでrevisit, doneにしない）
            save_state(s)
            return
        end
        cloud_count(CLOUDDB, s.rid) == 0 && seed_from_existing!(s)   # DBが空なら既存 geojson を取込＝上書き阻止
        save_state(s)
    end
    spent[] >= dailyBudget && return
    spent[] += 1
    s.reqs += 1
    local nb, ok
    try
        nb = sample!(s); ok = true
    catch
        nb = 0; ok = false          # poll 例外(API障害)＝「バス0」と区別（誤サービス外判定を防ぐ）
    end
    ok && (okPolls[] += 1)
    busesTotal[] += nb
    nowt = time()
    # 重い reconstruct(KF+集約) は RECON_MIN 間引く＝dense poll でも軽く保つ。cloud は毎回 save で積む。
    if nowt - get(LAST_RECON, s.rid, 0.0) >= RECON_MIN
        before = s.cov
        write_route_geojson!(s, binM, gapM)   # s.cov を coords+flags から honest に更新
        (s.cov > before + 1e-4) && (gained[] += 1)   # 伸びた（表示用）。cov天井plateauは正常→held にしない（低needでrotate out・pollsは速度/位置に有用）
        s.cov >= coverGoal && (s.done = true)         # 真の完了だけ done（永久スキップ）
        LAST_RECON[s.rid] = nowt
    end
    # 保留は「バスが居ない（運行外）」路線だけ。バスが居る限り取り続ける（保留にしない）。
    if nb > 0
        s.hold = 0
        s.last_obs = nowt        # staleness の基準（この路線を最後に観測した時刻）
    else
        s.hold += 1
    end
    (!s.done && s.hold >= plateauN) && (s.held = true)   # バス0が plateauN 回続いた＝運行外 → 保留(次runでrevisit)
    save_state(s)
end

# trunk.json（区間別 uniqueness）を読んで各路線の s.uniq を埋める。無ければ何もしない＝uniq空＝一様。
function load_trunk!(states)
    isfile(TRUNK) || return 0
    m = try
        JSON3.read(read(TRUNK, String))
    catch
        return 0
    end
    n = 0
    for s in states
        k = Symbol(s.rid)
        if haskey(m, k)
            s.uniq = Float64[Float64(x) for x in m[k]]
            n += 1
        end
    end
    return n
end

# model.json（速度モデル＋検証残差）を MODEL[] に読む。無ければ空＝route_need は幾何uniqのみ。
function load_model!()
    isfile(MODELF) || return 0
    j = try
        JSON3.read(read(MODELF, String))
    catch
        return 0
    end
    d = Dict{String,Dict{Int,NTuple{4,Float64}}}()
    if haskey(j, :routes)
        for (rid, segs) in j.routes
            m = Dict{Int,NTuple{4,Float64}}()
            for (segk, v) in segs
                length(v) >= 4 && (m[parse(Int, String(segk))] = (Float64(v[1]), Float64(v[2]), Float64(v[3]), Float64(v[4])))
            end
            d[String(rid)] = m
        end
    end
    MODEL[] = d
    return length(d)
end

# 情報必要度 need：未確定区間の長さを (固有度 × 学習不確実性) でゲートし、陳腐化で底上げ（gate+add）。
# uniq＝幾何prior(1/多重度)。学習不確実性＝予測残差の大きい区間ほど大（＝当てづらい所へ寄せる能動学習）。
# データ薄い区間は幾何のみへ退化。全赤でも staleness 分の底があり時々再訪（congestion ドリフト追随）。
function route_need(s::RS, now::Float64)
    s.stops_ok || return 500.0             # 停留所すら無い→高needで立ち上げ
    md = get(MODEL[], s.rid, EMPTY_SEG)    # 速度モデル（区間別）。無ければ空＝幾何uniqのみ。
    base = 0.0
    for k in 1:s.nseg
        (k in s.covered) && continue       # 既に赤(近似)は寄与0
        u = k <= length(s.uniq) ? s.uniq[k] : 1.0
        boost = 1.0
        st = get(md, k, nothing)           # (中央速度, std, 検証残差m, n)
        if st !== nothing && st[4] >= MODEL_MIN_N
            boost += LEARN_W * clamp(st[3] / RESID_TYP, 0.0, RESID_CAP)   # 残差(当てづらさ)で need を増やす
        end
        base += (k <= length(s.seglen) ? s.seglen[k] : 0.0) * u * boost   # 固有×学習不確実性でゲートした青長さ(m)
    end
    dt = s.last_obs > 0 ? (now - s.last_obs) / 3600 : 24.0
    return base + 80.0 * (min(dt, 24.0) / 24.0)   # +陳腐化ボーナス(最大80m相当)＝全赤でも再訪
end

function main_all()
    cities = length(ARGS) >= 1 ? String.(split(ARGS[1], ",")) : ["busan"]
    dailyBudget = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 9500
    coverGoal = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 0.95
    conc     = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 6           # 同時ポーリング数（ネットワーク待ちを重ねる＝速い）
    plateauN = length(ARGS) >= 5 ? parse(Int, ARGS[5]) : 8           # 新カバー無しが続いたら done（諦め）
    stagger  = 0.08                                                  # launch を少しずらす（同時発射の角を取る）
    binM = 30.0
    gapM = 250.0   # 地図の densifyWithFlags と同じ既定（間隔>gapM の点間は青＝推測）。地図の ?gap= と揃える。

    mkpath(PROGDIR)
    mkpath(OUTDIR)
    mkpath(LIVEDIR)
    routes = load_routes(cities)
    states = [load_state(rid, cc) for (rid, cc) in routes]
    # 旧ロジックの誤 plateau-done（cov<目標なのに done）を revisit へ戻す。真の完了だけ done を残す。
    for s in states
        (s.done && s.cov < coverGoal) && (s.done = false)
    end
    already = count(s -> s.done, states)
    ntrunk = load_trunk!(states)   # 区間別固有度(uniqueness)を読む。無ければ全uniq空＝一様に退化。
    nmodel = load_model!()         # 速度モデル＋検証残差(learn.jl)。無ければ幾何uniqのみ。
    (_, priorSpent) = load_daily()   # 今日ここまでの消費（再起動しても続く）
    println("路線 $(length(states)) 本（$(join(cities, "+"))）｜本日 $(priorSpent)/$(dailyBudget) req 消費済（残り $(max(0, dailyBudget - priorSpent))）｜目標カバー $(round(Int, coverGoal*100))%｜conc $(conc)｜再開時done $(already)｜trunk $(ntrunk)｜model $(nmodel)路線")
    flush(stdout)

    spent = Ref(priorSpent)   # 今日の累計から続ける＝日次上限を再起動でまたいで守る
    conc < 1 && (conc = 1)
    runDay = today_kst()
    emptyWins = 0
    win = 0
    while true
        # KST 日跨ぎ：spent を 0 にリセット（TAGO quota も KST 深夜リセット。前日ぶんを翌日へ持ち越さない）。
        if today_kst() != runDay
            runDay = today_kst(); spent[] = 0; save_daily(0)
            println("KST 日付変更 → 本日の spent を 0 にリセット")
        end
        cand = [s for s in states if !s.done && !s.held]
        isempty(cand) && (println("全路線 done か 保留。次 run で保留を revisit。"); break)
        # need 上位 FOCUS_K に集中（ローテーション）。窓の間その群だけを密に叩き、終わったら need 再計算で次群へ。
        nowt = time()
        order = sortperm([route_need(s, nowt) for s in cand], rev = true)
        focus = [cand[order[j]] for j in 1:min(max(FOCUS_K, 1), length(cand))]
        win += 1
        wstart = time(); passN = 0; winBuses = Ref(0); winGained = Ref(0); winOk = Ref(0); emptyPass = 0; apiDown = 0
        while time() - wstart < FOCUS_WINDOW && spent[] < dailyBudget
            act = [s for s in focus if !s.done && !s.held]
            isempty(act) && break                          # focus 群が尽きた→窓を畳んで次群へ
            passN += 1; pstart = time(); passBuses = Ref(0); passOk = Ref(0)
            i = 1
            while i <= length(act) && spent[] < dailyBudget
                batch = RS[]
                while length(batch) < conc && i <= length(act) && spent[] < dailyBudget
                    push!(batch, act[i]); i += 1
                end
                @sync for s in batch
                    @async try
                        process_route!(s, spent, passBuses, winGained, passOk, dailyBudget, binM, gapM, coverGoal, plateauN)
                    catch
                        # 1路線の失敗で pass を落とさない
                    end
                    sleep(stagger)
                end
                save_daily(spent[])
            end
            winBuses[] += passBuses[]; winOk[] += passOk[]
            # サービス外は「poll成功したのにバス0」のときだけ。API障害(poll全失敗)は別扱い(誤終了しない)。
            (passOk[] > 0 && passBuses[] == 0) ? (emptyPass += 1) : (emptyPass = 0)
            passOk[] == 0 ? (apiDown += 1) : (apiDown = 0)
            (emptyPass >= 3 || apiDown >= 3) && break       # サービス外 or API全滅で窓を畳む
            ptime = time() - pstart
            ptime < REFRESH && sleep(REFRESH - ptime)        # 各 route を ~REFRESH 秒間隔に（API更新周期に合わせ重複pollを避ける）
        end
        # 窓終了：stops成立・実データあり・窓中に未reconstruct の focus 路線だけ締める（空上書き/周期ストール防止）。
        for s in focus
            (s.stops_ok && cloud_count(CLOUDDB, s.rid) > 0) || continue
            time() - get(LAST_RECON, s.rid, 0.0) < RECON_MIN && continue
            try
                write_route_geojson!(s, binM, gapM); s.cov >= coverGoal && (s.done = true)
                LAST_RECON[s.rid] = time(); save_state(s)
            catch
            end
        end
        done_n = count(s -> s.done, states); held_n = count(s -> s.held, states)
        avg = round(Int, 100 * mean1([s.cov for s in states]))
        fr = join([s.rid for s in focus[1:min(3, length(focus))]], ",")
        println("focus窓 $(win)｜対象 $(length(focus))本[$(fr)…]｜pass $(passN)｜spent $(spent[])/$(dailyBudget)｜done $(done_n)｜保留 $(held_n)/$(length(states))｜平均カバー $(avg)%｜窓バス $(winBuses[])/成功poll $(winOk[])（伸びた $(winGained[])）")
        flush(stdout)

        spent[] >= dailyBudget && (println("\n本日の予算に到達。checkpoint して終了。日付が変われば自動でリセット、また同じコマンドで続きから。"); break)
        if winOk[] == 0
            println("API 応答なし（全 poll 失敗）→ 30s 待って再試行"); sleep(30.0)   # API障害: 終了せず back-off
        elseif winBuses[] == 0
            emptyWins += 1
            emptyWins >= 2 && (println("\n運行中でもバス0が続く＝サービス時間外。checkpoint して終了。時間帯を変えて再実行を。"); break)
        else
            emptyWins = 0
        end
    end

    save_daily(spent[])   # 終了時にも今日の消費を確定
    dn = count(s -> s.done, states)
    hn = count(s -> s.held, states)
    avg = round(Int, 100 * mean1([s.cov for s in states]))
    tot_req = sum(s.reqs for s in states)
    println("\n=== まとめ ===")
    println("done $(dn)｜保留 $(hn)/$(length(states))｜平均カバー $(avg)%｜今回使用 $(spent[]) req｜累計 $(tot_req) req")
    println("続き: 同じコマンドを再実行（progress/ から自動で続き）")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main_all()
end
