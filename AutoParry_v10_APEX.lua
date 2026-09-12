-- Auto Parry v10 — APEX EDITION
-- Upgrade dari v9: smarter scoring, adaptive timing, hit prediction, priority queue
-- Logika & sistem inti tetap identik

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local Stats             = game:GetService("Stats")

local LP   = Players.LocalPlayer
local Char = LP.Character or LP.CharacterAdded:Wait()
local Hum  = Char:WaitForChild("Humanoid")
local Root = Char:WaitForChild("HumanoidRootPart")

-- ─── PACKETS ──────────────────────────────────────────────
local ok, Packets = pcall(function()
    local S = ReplicatedStorage:WaitForChild("Modules",5)
                               :WaitForChild("Shared",5)
    return require(S:WaitForChild("Packets",5))
end)
if not ok then warn("[AP10] Packets failed"); return end

local DSR       = Packets.DefenseStateRequest
local CTChanged = Packets.CombatTagChanged
local ParryOK   = Packets.ParrySuccess
local BlockHit  = Packets.BlockHitReaction
local GotHit    = Packets.GotHitScreenEffect

local function tryPkt(name)
    local s,v = pcall(function() return Packets[name] end)
    return (s and v) or nil
end
local HeavyAtk  = tryPkt("HeavyAttack")
local ChargeAtk = tryPkt("ChargeAttack")
local M2Pkt     = tryPkt("M2Attack")
local RedSig    = tryPkt("DangerIndicator")
local ComboPkt  = tryPkt("ComboAttack")

-- ─── CONFIG ───────────────────────────────────────────────
local CFG = {
    Range             = 16,
    TapWindow         = 0.04,
    CooldownM1        = 0.36,
    CooldownM2        = 0.26,
    ScoreThreshold    = 16,       -- v10: lebih sensitif dari v9
    ToggleKey         = Enum.KeyCode.RightShift,

    PreFireEnabled    = true,
    PreFireThreshold  = 0.07,     -- lebih ketat dari v9

    MultiFireEnabled  = true,
    MultiFireCount    = 3,        -- base count, adaptive di runtime
    MultiFireDelay    = 0.11,

    ChainEnabled      = true,
    ChainWindow       = 0.65,     -- sedikit lebih lebar

    ForceAll          = true,

    PingCompEnabled   = true,
    PingCompMax       = 0.35,

    -- v10 NEW
    AdaptiveCooldown  = true,     -- cooldown ngikutin ping
    AnglePredict      = true,     -- score bonus dari swing arc
    HitFreqAnalysis   = true,     -- predict interval hit
    PriorityQueue     = true,     -- fire order by threat
    StreakTrack       = true,     -- track parry streak / miss
    VelSharpening     = true,     -- vel vector 3D dot sharpened
    AnimCacheStrict   = true,     -- strict dedup anim
    MaxQueueTargets   = 3,        -- max target di priority queue
}

-- ─── STATE ────────────────────────────────────────────────
local ON            = true
local NextParry     = 0
local Firing        = false
local ParryCount    = 0
local MissCount     = 0
local ParryStreak   = 0
local Watched       = {}
local PrevVel       = {}
local PrevAnims     = {}
local HeavyAlert    = {}
local ComboTracker  = {}
local LastHitTime   = {}

-- v10 NEW state
local HitIntervals  = {}   -- track interval antar hit untuk prediction
local LastAnimFire  = {}   -- strict anim dedup per uid+animname
local ThreatQueue   = {}   -- priority queue targets

-- ─── PING ─────────────────────────────────────────────────
local PingCache     = 80
local PingLastCheck = 0

local function GetPing()
    local now = os.clock()
    if now - PingLastCheck > 0.5 then   -- v10: cache ping, refresh tiap 0.5s
        local ok2,v = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        PingCache     = (ok2 and v) or PingCache
        PingLastCheck = now
    end
    return PingCache
end

local function GetLead()
    if not CFG.PingCompEnabled then return 0 end
    local ping = GetPing()
    -- v10: non-linear lead, ping tinggi = agresif kompensasi
    local raw = (ping/1000) * 2.0
    return math.min(CFG.PingCompMax, raw)
end

-- v10: adaptive cooldown berdasar ping
local function GetCooldown(isHeavy)
    local base = isHeavy and CFG.CooldownM2 or CFG.CooldownM1
    if not CFG.AdaptiveCooldown then return base end
    local ping = GetPing()
    -- ping < 50  → cooldown lebih pendek (lo fast)
    -- ping > 150 → cooldown lebih panjang (jaga-jaga delay)
    local factor = 1 + ((ping - 80) / 800)
    return math.max(base * 0.75, math.min(base * 1.3, base * factor))
end

-- ─── HELPERS ──────────────────────────────────────────────
local function Refresh()
    Char = LP.Character
    if not Char then return false end
    Hum  = Char:FindFirstChildWhichIsA("Humanoid")
    Root = Char:FindFirstChild("HumanoidRootPart")
    return Char ~= nil and Root ~= nil
end

local function Dist(a,b)
    if not a or not b then return 9999 end
    return (a.Position - b.Position).Magnitude
end

local function Notify(t,d)
    pcall(game.StarterGui.SetCore, game.StarterGui,
        "SendNotification",{Title="⚔️ AP v10",Text=t,Duration=d or 2})
end

local function CanFire(force)
    if not ON then return false end
    if Firing then return false end
    if os.clock() < NextParry then return false end
    if not Refresh() then return false end
    if not force and not CFG.ForceAll then
        if Char:GetAttribute("State_Ragdolled") then return false end
        if Char:GetAttribute("State_Safe")      then return false end
    end
    return true
end

-- ─── HIT FREQUENCY ANALYZER (v10) ────────────────────────
-- Track interval antar hit, predict kapan next hit
local function RecordHitInterval(uid)
    local now  = os.clock()
    local last = LastHitTime[uid]
    if last then
        if not HitIntervals[uid] then HitIntervals[uid] = {} end
        table.insert(HitIntervals[uid], now - last)
        -- keep max 8 samples
        if #HitIntervals[uid] > 8 then
            table.remove(HitIntervals[uid], 1)
        end
    end
    LastHitTime[uid] = now
end

local function GetAvgInterval(uid)
    local samples = HitIntervals[uid]
    if not samples or #samples < 2 then return nil end
    local sum = 0
    for _,v in ipairs(samples) do sum += v end
    return sum / #samples
end

-- Predict apakah hit berikutnya segera dateng
local function IsHitImminent(uid)
    local avg = GetAvgInterval(uid)
    if not avg then return false, 0 end
    local last = LastHitTime[uid] or 0
    local elapsed = os.clock() - last
    local confidence = math.max(0, 1 - math.abs(elapsed - avg) / avg)
    -- imminent kalau elapsed mendekati average interval
    return (elapsed >= avg * 0.75 and elapsed <= avg * 1.4), confidence
end

-- ─── COMBO TRACKER ────────────────────────────────────────
local function UpdateCombo(uid)
    local now  = os.clock()
    local last = LastHitTime[uid] or 0
    if not ComboTracker[uid] then ComboTracker[uid] = 0 end
    if now - last > CFG.ChainWindow then
        ComboTracker[uid] = 0
    end
    RecordHitInterval(uid)   -- v10: record interval tiap update combo
    ComboTracker[uid] += 1
    LastHitTime[uid]   = now
    return ComboTracker[uid]
end

-- v10: smart multi-fire count berdasar combo depth
local function GetMultiFireCount(uid)
    if not CFG.MultiFireEnabled then return 1 end
    local combo = ComboTracker[uid] or 0
    -- combo dalam = fire lebih banyak
    if combo >= 4 then return 5
    elseif combo >= 2 then return 4
    else return CFG.MultiFireCount end
end

-- ─── CORE PARRY ───────────────────────────────────────────
local function RawParry()
    pcall(function()
        if CFG.ForceAll then
            pcall(function() DSR:Fire("EndRagdoll")   end)
            pcall(function() DSR:Fire("EndKnockback") end)
            pcall(function() DSR:Fire("CancelAction") end)
        end
        task.wait(0.01)
        DSR:Fire("BeginBlock")
        task.wait(CFG.TapWindow)
        DSR:Fire("BeginParry")
        task.wait(0.035)
        DSR:Fire("EndBlock")
    end)
end

local function FireParry(src, isHeavy, force, uid)
    if not CanFire(force or CFG.ForceAll) then return false end

    local cd      = GetCooldown(isHeavy)   -- v10: adaptive cooldown
    Firing        = true
    NextParry     = os.clock() + cd

    local lead    = GetLead()
    local mfCount = uid and GetMultiFireCount(uid) or CFG.MultiFireCount

    task.spawn(function()
        if lead > 0.01 then task.wait(lead) end

        if isHeavy and CFG.MultiFireEnabled then
            for i = 1, mfCount do
                RawParry()
                if i < mfCount then
                    task.wait(CFG.MultiFireDelay)
                    NextParry = os.clock() + cd
                end
            end
            print(string.format("[AP10] 🔴 HEAVY x%d fired ← %s | cd:%.3f", mfCount, src, cd))
        else
            RawParry()
            print(string.format("[AP10] ⚔️ M1 fired ← %s | ping:%d | cd:%.3f", src, GetPing(), cd))
        end

        task.wait(0.05)
        Firing = false
    end)

    return true
end

-- ─── ANIM KEYWORDS ────────────────────────────────────────
local M2_KW = {
    "m2","heavy","charge","charged","block_break","smash","slam",
    "uppercut","overhead","power","special","red","danger",
    "unblockable","fury","burst","rage","break","grab","throw",
    "launch","spin","twirl","windmill","finisher","execute",
    "stomp","ground","aoe","explosion","super","ultra","final",
}
local M1_KW = {
    "m1","m3","m4","m5","attack","atk","swing","swipe","slash",
    "punch","hit","combo","strike","jab","smash","lunge","thrust",
    "kick","light","fast","quick","right","left","normal","basic",
    "wind","combat","fight","claw","stab","cut","slice","chop",
}

local function IsM2Anim(n)
    n=n:lower()
    for _,k in ipairs(M2_KW) do if n:find(k,1,true) then return true end end
    return false
end
local function IsM1Anim(n)
    n=n:lower()
    for _,k in ipairs(M1_KW) do if n:find(k,1,true) then return true end end
    return false
end

-- ─── ATTR KEYWORDS ────────────────────────────────────────
local M2_ATTR = {
    "State_HeavyAttack","State_M2","HeavyAttacking","M2",
    "IsHeavy","ChargingAttack","PowerAttack","BlockBreak",
    "IsUnblockable","RedAttack","SpecialAttack","FuryAttack",
    "DangerState","ChargeState","HeavyState","UnblockState",
}
local ALL_ATTR = {
    "State_Attacking","State_AttackAnimation","State_Combat",
    "Attacking","AttackAnimation","IsAttacking","IsSwinging",
    "Combat_Attacking","M1","Swinging","Punching","Hitting",
    "InAttack","Action_Attack","AttackState","Fighting",
    "IsInCombat","SwingActive","HitActive","StrikeActive",
    "State_HeavyAttack","State_M2","HeavyAttacking","M2",
    "IsHeavy","ChargingAttack","PowerAttack","BlockBreak",
    "IsUnblockable","RedAttack","SpecialAttack","FuryAttack",
    "DangerState","ChargeState","HeavyState","UnblockState",
}

local function IsHeavyAttr(a)
    for _,k in ipairs(M2_ATTR) do if a==k then return true end end
    return false
end

local function ScanAttrs(char,eh)
    for _,a in ipairs(ALL_ATTR) do
        local v = char:GetAttribute(a)
        if v==true then return true,IsHeavyAttr(a),a end
        if type(v)=="string" and (v:lower():find("attack") or v:lower():find("heavy")) then
            return true,IsHeavyAttr(a),a
        end
        if eh then
            v = eh:GetAttribute(a)
            if v==true then return true,IsHeavyAttr(a),a end
        end
    end
    return false,false,nil
end

-- ─── ANGLE PREDICTOR (v10) ────────────────────────────────
-- Cek apakah musuh lagi dalam swing arc ke arah lo
local function GetSwingArcBonus(er)
    if not CFG.AnglePredict or not Root or not er then return 0 end
    local toMe = (Root.Position - er.Position)
    local dist = toMe.Magnitude
    if dist < 0.1 then return 0 end
    local dirNorm  = toMe / dist
    local lookVec  = er.CFrame.LookVector
    local rightVec = er.CFrame.RightVector

    -- musuh facing ke lo
    local faceDot = lookVec:Dot(dirNorm)
    -- musuh swing ke sisi yang nyampe lo (right swing ke kanan, etc)
    local sideDot = math.abs(rightVec:Dot(dirNorm))

    local bonus = 0
    if faceDot > 0.55 then bonus += 10 end   -- musuh lagi ngadepin lo
    if sideDot > 0.45 then bonus += 8  end   -- swing arc crossing ke lo
    if faceDot > 0.8  then bonus += 6  end   -- extra kalau langsung lurus
    return bonus
end

-- ─── VELOCITY SHARPENING (v10) ────────────────────────────
local function GetVelBonus(uid, er)
    if not CFG.VelSharpening or not Root or not er then return 0 end
    local vel  = er.Velocity
    local prev = PrevVel[uid] or vel
    PrevVel[uid] = vel

    local acc  = (vel - prev).Magnitude
    if acc < 3 then return 0 end

    local toMe  = (Root.Position - er.Position)
    local dist  = toMe.Magnitude
    if dist < 0.1 then return 0 end
    local dirN  = toMe / dist

    local velMag = vel.Magnitude
    if velMag < 0.1 then return 0 end
    local velU  = vel.Unit

    -- v10: pakai full 3D dot, bukan flatten
    local approachDot = dirN:Dot(velU)
    local upComp      = math.abs(velU.Y)   -- deteksi jump attack

    local bonus = 0
    if approachDot > 0.3 then
        bonus += math.floor(approachDot * 22)   -- max 22
    end
    if upComp > 0.4 and approachDot > 0.1 then
        bonus += 8   -- jump attack bonus
    end
    return math.min(bonus, 30)
end

-- ─── SCORE ENGINE ─────────────────────────────────────────
local function Score(p)
    local ec = p.Character
    if not ec then return 0,false,"" end
    local er = ec:FindFirstChild("HumanoidRootPart")
    local eh = ec:FindFirstChildWhichIsA("Humanoid")
    if not er or not eh or eh.Health<=0 then return 0,false,"" end
    if not Root then return 0,false,"" end

    local d = Dist(Root,er)
    if d > CFG.Range then return 0,false,"" end

    local sc  = 0
    local hvy = false
    local rsn = ""
    local uid = p.UserId

    -- Distance (0-12)
    sc += math.floor((1 - d/CFG.Range) * 12)

    -- Heavy attr (0-75)
    local hasAttr,isHAttr,attrN = ScanAttrs(ec,eh)
    if isHAttr then
        sc  += 75; hvy = true
        rsn  = "HvyAttr:"..attrN
    elseif hasAttr then
        sc  += 42
        rsn  = "Attr:"..tostring(attrN)
    end

    -- Animation (0-70)
    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        for _,t in pairs(anim:GetPlayingAnimationTracks()) do
            if t.IsPlaying then
                local n   = t.Animation.Name
                local pos = t.TimePosition
                if IsM2Anim(n) then
                    hvy = true
                    if pos <= CFG.PreFireThreshold then sc+=70; rsn="M2Early:"..n
                    elseif pos < 0.3 then sc+=55; rsn="M2Mid:"..n
                    else sc+=30; rsn="M2Late:"..n end
                    break
                elseif IsM1Anim(n) then
                    if pos <= CFG.PreFireThreshold then sc+=60; rsn="M1Early:"..n
                    elseif pos < 0.2 then sc+=45; rsn="M1Mid:"..n
                    else sc+=18; rsn="M1Late:"..n end
                    break
                end
            end
        end
    end

    -- Heavy alert
    if HeavyAlert[uid] then sc+=25; hvy=true end

    -- Combo tracker
    local combo = ComboTracker[uid] or 0
    if combo > 0 then
        local bonus = math.min(combo * 8, 30)
        sc  += bonus
        rsn  = rsn=="" and ("Combo:"..combo) or rsn
    end

    -- v10: Hit Frequency Prediction
    if CFG.HitFreqAnalysis then
        local imminent, conf = IsHitImminent(uid)
        if imminent then
            local freqBonus = math.floor(conf * 25)
            sc  += freqBonus
            rsn  = rsn=="" and ("FreqPred:"..string.format("%.0f%%",conf*100)) or rsn
            print(string.format("[AP10] 📊 HitFreq: uid=%d conf=%.0f%% bonus=%d", uid, conf*100, freqBonus))
        end
    end

    -- v10: Angle predictor
    local arcBonus = GetSwingArcBonus(er)
    sc += arcBonus

    -- v10: Velocity sharpening (replaces old vel block)
    local velBonus = GetVelBonus(uid, er)
    sc += velBonus

    -- LookAt close (0-12)
    if d < 7 then
        local toMe = (Root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.7 then sc+=12 end
    end

    return math.min(sc,100), hvy, rsn~="" and rsn or "Multi"
end

-- ─── PRIORITY QUEUE (v10) ─────────────────────────────────
-- Kumpulin semua target yang qualified, sort by score, fire yang tertinggi
local function BuildThreatQueue()
    local queue = {}
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local sc,hv,r = Score(p)
            if sc >= CFG.ScoreThreshold then
                table.insert(queue, {player=p, score=sc, heavy=hv, reason=r})
            end
        end
    end
    table.sort(queue, function(a,b) return a.score > b.score end)
    -- cap ke MaxQueueTargets
    while #queue > CFG.MaxQueueTargets do
        table.remove(queue)
    end
    return queue
end

-- ─── HEARTBEAT ────────────────────────────────────────────
RunService.Heartbeat:Connect(function()
    if not ON or not Refresh() then return end
    if os.clock() < NextParry then return end

    if CFG.PriorityQueue then
        -- v10: priority queue mode
        local queue = BuildThreatQueue()
        if #queue > 0 then
            local top = queue[1]
            if top.heavy then
                HeavyAlert[top.player.UserId]=true
                task.delay(2.5,function() HeavyAlert[top.player.UserId]=nil end)
            end
            FireParry(
                string.format("[%d]%s/%s", top.score, top.reason, top.player.Name),
                top.heavy, true, top.player.UserId
            )
        end
    else
        -- fallback: original single-best mode
        local best,bH,bR,bP = 0,false,"",nil
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP then
                local sc,hv,r = Score(p)
                if sc>best then best,bH,bR,bP=sc,hv,r,p end
            end
        end
        if best>=CFG.ScoreThreshold and bP then
            if bH then
                HeavyAlert[bP.UserId]=true
                task.delay(2.5,function() HeavyAlert[bP.UserId]=nil end)
            end
            FireParry(string.format("[%d]%s/%s",best,bR,bP.Name), bH, true, bP.UserId)
        end
    end
end)

-- ─── REALTIME WATCHERS ────────────────────────────────────
local function WatchChar(p,char)
    if not char then return end
    local er  = char:FindFirstChild("HumanoidRootPart")
    local eh  = char:FindFirstChildWhichIsA("Humanoid")
    local uid = p.UserId

    local function watchA(obj,attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not ON then return end
                if os.clock()<NextParry then return end
                local v = obj:GetAttribute(attr)
                if not(v==true or(type(v)=="string" and(v:lower():find("attack") or v:lower():find("heavy")))) then return end
                if not er or not Root then return end
                if Dist(Root,er)>CFG.Range then return end
                local isHvy = IsHeavyAttr(attr)
                if isHvy then
                    HeavyAlert[uid]=true
                    task.delay(2.5,function() HeavyAlert[uid]=nil end)
                end
                FireParry("WAttr:"..attr, isHvy, true, uid)
            end)
        end)
    end

    for _,a in ipairs(ALL_ATTR) do
        watchA(char,a)
        if eh then watchA(eh,a) end
    end

    -- v10: strict anim cache dedup
    local function watchAnim(animator)
        animator.AnimationPlayed:Connect(function(track)
            if not ON then return end
            local n   = track.Animation.Name
            local isH = IsM2Anim(n)
            local isM = IsM1Anim(n)
            if not isH and not isM then return end
            if not er or not Root then return end
            if Dist(Root,er)>CFG.Range then return end

            -- v10: strict dedup pakai uid+name+timestamp bucket
            local now    = os.clock()
            local cacheK = string.format("%d_%s", uid, n)
            if CFG.AnimCacheStrict then
                local lastFire = LastAnimFire[cacheK] or 0
                if now - lastFire < 0.3 then return end   -- strict 0.3s cooldown per anim
                LastAnimFire[cacheK] = now
            else
                if PrevAnims[cacheK] then return end
                PrevAnims[cacheK]=true
                task.delay(0.35,function() PrevAnims[cacheK]=nil end)
            end

            if isH then
                HeavyAlert[uid]=true
                task.delay(2.5,function() HeavyAlert[uid]=nil end)
                print("[AP10] 🔴 M2 ANIM: "..n)
            end

            FireParry("AnimPlay:"..n, isH, true, uid)
        end)
    end

    if eh then
        local an = eh:FindFirstChildOfClass("Animator")
        if an then watchAnim(an)
        else eh.ChildAdded:Connect(function(c)
            if c:IsA("Animator") then watchAnim(c) end
        end) end
    end

    char.ChildAdded:Connect(function(c)
        if not c:IsA("Tool") then return end
        if not ON or not er or not Root then return end
        if Dist(Root,er)>CFG.Range then return end
        FireParry("ToolEq:"..c.Name, false, false, uid)
    end)
end

local function Watch(p)
    if not p or p==LP then return end
    if Watched[p.UserId] then return end
    Watched[p.UserId]=true
    if p.Character then WatchChar(p,p.Character) end
    p.CharacterAdded:Connect(function(c)
        Watched[p.UserId]=nil
        task.wait(0.5); Watch(p)
    end)
end

local function WatchAll()
    for _,p in pairs(Players:GetPlayers()) do Watch(p) end
end

WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.3); Watch(p) end)
Players.PlayerRemoving:Connect(function(p)
    Watched[p.UserId]=nil
    PrevVel[p.UserId]=nil
    HeavyAlert[p.UserId]=nil
    ComboTracker[p.UserId]=nil
    HitIntervals[p.UserId]=nil
    LastHitTime[p.UserId]=nil
end)

-- ─── OPTIONAL PACKETS ─────────────────────────────────────
local function pktHook(pkt, src, heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        print("[AP10] 📦 PKT: "..src)
        NextParry=0; Firing=false
        if heavy then
            HeavyAlert["pkt"..src]=true
            task.delay(2,function() HeavyAlert["pkt"..src]=nil end)
        end
        FireParry("Pkt:"..src, heavy, true)
    end)
end
pktHook(M2Pkt,    "M2",     true)
pktHook(HeavyAtk, "Heavy",  true)
pktHook(ChargeAtk,"Charge", true)
pktHook(RedSig,   "RedSig", true)
pktHook(ComboPkt, "Combo",  false)

-- ─── FALLBACK EVENTS ──────────────────────────────────────
GotHit.OnClientEvent:Connect(function()
    print("[AP10] 💥 GOT HIT — force+multi")
    NextParry=0; Firing=false
    MissCount += 1   -- v10: track miss
    if CFG.StreakTrack then
        ParryStreak = 0
        Notify(string.format("❌ Miss #%d | Streak reset", MissCount), 1.5)
    end
    if Root then
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er=p.Character:FindFirstChild("HumanoidRootPart")
                if er and Dist(Root,er)<=CFG.Range then
                    UpdateCombo(p.UserId)
                end
            end
        end
    end
    FireParry("GotHit", false, true)
end)

BlockHit.OnClientEvent:Connect(function()
    print("[AP10] 🛡️ BLOCK HIT — convert")
    NextParry=0; Firing=false
    FireParry("BlockHit", false, true)
end)

CTChanged.OnClientEvent:Connect(function(t)
    if t then NextParry=0; Firing=false
        print("[AP10] ⚔️ Combat ON") end
end)

ParryOK.OnClientEvent:Connect(function()
    ParryCount  += 1
    ParryStreak += 1   -- v10: streak increment
    local streakTxt = CFG.StreakTrack and string.format(" | 🔥x%d",ParryStreak) or ""
    Notify(string.format("✅ PARRY #%d | %dms%s", ParryCount, GetPing(), streakTxt))
    print(string.format("[AP10] ✅ PARRY #%d | streak:%d", ParryCount, ParryStreak))
end)

-- ─── RESPAWN ──────────────────────────────────────────────
LP.CharacterAdded:Connect(function(c)
    Char=c
    Hum=c:WaitForChild("Humanoid")
    Root=c:WaitForChild("HumanoidRootPart")
    NextParry=0; Firing=false
    Watched={}; PrevAnims={}
    HeavyAlert={}; ComboTracker={}; LastHitTime={}
    HitIntervals={}; LastAnimFire={}; ThreatQueue={}
    ParryStreak=0
    task.wait(0.8); WatchAll()
end)

-- ─── TOGGLE ───────────────────────────────────────────────
UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==CFG.ToggleKey then
        ON=not ON; NextParry=0; Firing=false
        Notify(ON and "✅ ON" or "❌ OFF")
    end
end)

-- ─── INIT ─────────────────────────────────────────────────
local p=GetPing()
Notify(string.format("⚔️ v10 APEX | %dms | RShift=Toggle",p),3)
print(string.format("[AP10] ⚔️ APEX ACTIVE | Ping:%dms | Lead:%.3fs | AdaptCD:%s | PQueue:%s",
    p, GetLead(),
    tostring(CFG.AdaptiveCooldown),
    tostring(CFG.PriorityQueue)
))
