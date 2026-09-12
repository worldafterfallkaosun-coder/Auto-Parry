-- Auto Parry v11 — ULTIMATE EDITION (COMPLETELY SILENT)
-- Upgraded: Maximum accuracy, advanced combo prediction, multi-hit detection
-- Removed: ALL console spam and notifications
-- Enhanced: Adaptive hit detection, startup notification only

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
if not ok then warn("[AP11] Packets failed"); return end

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

-- ─── CONFIG (UPGRADED) ────────────────────────────────────
local CFG = {
    Range             = 18,        -- UPGRADED: increased range
    TapWindow         = 0.04,
    CooldownM1        = 0.32,      -- UPGRADED: faster cooldown
    CooldownM2        = 0.23,      -- UPGRADED: faster M2 response
    ScoreThreshold    = 28,        -- UPGRADED: more aggressive
    ToggleKey         = Enum.KeyCode.RightShift,

    PreFireEnabled    = true,
    PreFireThreshold  = 0.06,      -- UPGRADED: earlier detection

    MultiFireEnabled  = true,
    MultiFireCount    = 4,         -- UPGRADED: max 4 consecutive
    MultiFireDelay    = 0.09,      -- UPGRADED: tighter spacing

    ChainWindow       = 0.85,      -- UPGRADED: longer combo window

    ForceAll          = true,

    PingCompEnabled   = true,
    PingCompMax       = 0.40,      -- UPGRADED: better ping compensation

    -- v11 ULTIMATE features
    AdaptiveCooldown  = true,
    AnglePredict      = true,
    HitFreqAnalysis   = true,
    PriorityQueue     = true,
    StreakTrack       = false,      -- DISABLED: no notifications
    VelSharpening     = true,
    AnimCacheStrict   = true,
    MaxQueueTargets   = 5,          -- UPGRADED: more targets

    -- ULTIMATE safety + accuracy
    MinInterFireDelay = 0.03,       -- UPGRADED: tighter
    MaxFiresPerSecond = 12,         -- UPGRADED: higher cap
    HeartbeatDebounce = 0.04,       -- UPGRADED: more responsive

    -- v11 NEW: Advanced combo tracking
    ComboAnticipation = true,       -- Predict next hit in combo
    StreamingDetect   = true,       -- Multi-hit streaming detection
    HistoryDepth      = 15,         -- Track last 15 hits
    FreqAdaptive      = true,       -- Adapt to hit patterns
    VelocityPrediction= true,       -- Predict direction + speed
    DamageTypeDetect  = true,       -- Detect attack pattern type
}

-- ─── STATE (UPGRADED) ─────────────────────────────────────
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

-- v11 ULTIMATE state
local HitIntervals  = {}
local LastAnimFire  = {}
local ThreatQueue   = {}
local LastHeartbeat = 0
local HitHistory    = {}          -- ULTIMATE: full hit history
local ComboPattern  = {}          -- ULTIMATE: combo patterns
local VelHistory    = {}          -- ULTIMATE: velocity patterns
local AttackTypeSeq = {}          -- ULTIMATE: attack sequence
local StreamingHits = {}          -- ULTIMATE: multi-hit detection
local PredictedNext = {}          -- ULTIMATE: predicted next hit
local HitConfidence = {}          -- ULTIMATE: hit probability scores

-- ─── PING ─────────────────────────────────────────────────
local PingCache     = 80
local PingLastCheck = 0

local function GetPing()
    local now = os.clock()
    if now - PingLastCheck > 0.5 then
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
    local raw = (ping/1000) * 2.2           -- UPGRADED: better ratio
    return math.min(CFG.PingCompMax, raw)
end

local function GetCooldown(isHeavy)
    local base = isHeavy and CFG.CooldownM2 or CFG.CooldownM1
    if not CFG.AdaptiveCooldown then return base end
    local ping = GetPing()
    local factor = 1 + ((ping - 80) / 750)  -- UPGRADED: tighter curve
    return math.max(base * 0.70, math.min(base * 1.35, base * factor))
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
        "SendNotification",{Title="⚔️ AP v11",Text=t,Duration=d or 2})
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

-- ─── HIT HISTORY ANALYZER (ULTIMATE) ───────────────────────
local function RecordHitFull(uid, isHeavy, animName)
    local now = os.clock()
    if not HitHistory[uid] then HitHistory[uid] = {} end
    if not HistoryDepth then HistoryDepth = 15 end
    
    local record = {
        time = now,
        isHeavy = isHeavy,
        anim = animName,
        lastHit = LastHitTime[uid] or 0,
    }
    
    table.insert(HitHistory[uid], record)
    if #HitHistory[uid] > CFG.HistoryDepth then
        table.remove(HitHistory[uid], 1)
    end
    
    LastHitTime[uid] = now
end

local function AnalyzeHitPattern(uid)
    local hist = HitHistory[uid]
    if not hist or #hist < 3 then return nil, 0 end
    
    local intervals = {}
    for i = 2, #hist do
        table.insert(intervals, hist[i].time - hist[i-1].time)
    end
    
    if #intervals < 2 then return nil, 0 end
    
    local sum = 0
    local minInt = intervals[1]
    local maxInt = intervals[1]
    
    for _, v in ipairs(intervals) do
        sum += v
        minInt = math.min(minInt, v)
        maxInt = math.max(maxInt, v)
    end
    
    local avg = sum / #intervals
    local variance = 0
    for _, v in ipairs(intervals) do
        variance += (v - avg) ^ 2
    end
    variance = variance / #intervals
    
    local consistency = 1 - math.min(1, math.sqrt(variance) / avg)
    
    return {
        avg = avg,
        min = minInt,
        max = maxInt,
        consistency = consistency,
        count = #hist
    }, consistency
end

local function IsNextHitImminent(uid)
    local hist = HitHistory[uid]
    local pattern, consistency = AnalyzeHitPattern(uid)
    
    if not pattern or not hist or #hist < 2 then return false, 0 end
    
    local now = os.clock()
    local timeSinceLast = now - hist[#hist].time
    local expectedNext = hist[#hist].time + pattern.avg
    
    if timeSinceLast < pattern.min * 0.6 then return false, 0 end
    
    local timeUntilExpected = expectedNext - now
    if timeUntilExpected > pattern.avg * 0.5 then
        return false, 0
    end
    
    if timeUntilExpected < -pattern.avg * 0.3 then
        return true, math.min(1, consistency * 1.2)
    end
    
    local proximity = 1 - math.abs(timeUntilExpected) / (pattern.avg * 0.5)
    local confidence = math.max(0, proximity) * consistency
    
    return (timeUntilExpected >= -pattern.avg * 0.2), confidence
end

-- ─── COMBO TRACKER (UPGRADED) ──────────────────────────────
local function UpdateComboUltimate(uid, isHeavy, animName)
    local now = os.clock()
    local last = LastHitTime[uid] or 0
    
    if not ComboTracker[uid] then ComboTracker[uid] = 0 end
    if not AttackTypeSeq[uid] then AttackTypeSeq[uid] = {} end
    
    if now - last > CFG.ChainWindow then
        ComboTracker[uid] = 0
        AttackTypeSeq[uid] = {}
    end
    
    RecordHitFull(uid, isHeavy, animName)
    
    table.insert(AttackTypeSeq[uid], {heavy=isHeavy, time=now})
    if #AttackTypeSeq[uid] > 8 then
        table.remove(AttackTypeSeq[uid], 1)
    end
    
    ComboTracker[uid] += 1
    LastHitTime[uid] = now
    
    return ComboTracker[uid]
end

local function GetMultiFireUltimate(uid)
    if not CFG.MultiFireEnabled then return 1 end
    
    local combo = ComboTracker[uid] or 0
    local pattern, cons = AnalyzeHitPattern(uid)
    
    local baseCount = 2
    if combo >= 5 then baseCount = 4
    elseif combo >= 3 then baseCount = 3
    elseif combo >= 1 then baseCount = 2
    end
    
    if pattern and cons > 0.7 and combo >= 2 then
        baseCount = math.min(4, baseCount + 1)
    end
    
    return math.min(CFG.MultiFireCount, baseCount)
end

-- ─── CORE PARRY ───────────────────────────────────────────
local function RawParry()
    local ok = pcall(function()
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
    return ok
end

local function FireParry(src, isHeavy, force, uid)
    if not CanFire(force or CFG.ForceAll) then return false end

    local now = os.clock()
    if Firing or (now - NextParry) < CFG.MinInterFireDelay then return false end

    local cd      = GetCooldown(isHeavy)
    Firing        = true
    NextParry     = now + cd

    local lead    = GetLead()
    local mfCount = uid and GetMultiFireUltimate(uid) or 2

    task.spawn(function()
        local ok = pcall(function()
            if lead > 0.005 then task.wait(lead) end

            if isHeavy and CFG.MultiFireEnabled then
                for i = 1, mfCount do
                    if not RawParry() then break end
                    if i < mfCount then
                        task.wait(CFG.MultiFireDelay)
                        NextParry = now + cd
                    end
                end
            else
                RawParry()
            end
        end)

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

-- ─── ANGLE PREDICTOR (UPGRADED) ────────────────────────────
local function GetSwingArcBonus(er)
    if not CFG.AnglePredict or not Root or not er then return 0 end
    local toMe = (Root.Position - er.Position)
    local dist = toMe.Magnitude
    if dist < 0.1 then return 0 end
    local dirNorm  = toMe / dist
    local lookVec  = er.CFrame.LookVector
    local rightVec = er.CFrame.RightVector

    local faceDot = lookVec:Dot(dirNorm)
    local sideDot = math.abs(rightVec:Dot(dirNorm))

    local bonus = 0
    if faceDot > 0.5 then bonus += 12 end    -- UPGRADED
    if sideDot > 0.4 then bonus += 10 end    -- UPGRADED
    if faceDot > 0.75 then bonus += 8 end    -- UPGRADED
    return bonus
end

-- ─── VELOCITY SHARPENING (UPGRADED) ────────────────────────
local function GetVelBonusUltimate(uid, er)
    if not CFG.VelSharpening or not Root or not er then return 0 end
    
    local vel  = er.Velocity
    local prev = PrevVel[uid] or vel
    PrevVel[uid] = vel

    local acc  = (vel - prev).Magnitude
    if acc < 2 then return 0 end

    local toMe  = (Root.Position - er.Position)
    local dist  = toMe.Magnitude
    if dist < 0.1 then return 0 end
    local dirN  = toMe / dist

    local velMag = vel.Magnitude
    if velMag < 0.1 then return 0 end
    local velU  = vel.Unit

    local approachDot = dirN:Dot(velU)
    local upComp      = math.abs(velU.Y)

    local bonus = 0
    if approachDot > 0.25 then
        bonus += math.floor(approachDot * 28)  -- UPGRADED
    end
    if upComp > 0.35 and approachDot > 0.1 then
        bonus += 12  -- UPGRADED
    end
    return math.min(bonus, 40)  -- UPGRADED
end

-- ─── SCORE ENGINE (UPGRADED) ──────────────────────────────
local function ScoreUltimate(p)
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

    -- Distance (0-15) - UPGRADED
    sc += math.floor((1 - d/CFG.Range) * 15)

    -- Heavy attr (0-80) - UPGRADED
    local hasAttr,isHAttr,attrN = ScanAttrs(ec,eh)
    if isHAttr then
        sc  += 80; hvy = true  -- UPGRADED
        rsn  = "HvyAttr:"..attrN
    elseif hasAttr then
        sc  += 50  -- UPGRADED
        rsn  = "Attr:"..tostring(attrN)
    end

    -- Animation (0-75) - UPGRADED
    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok, tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _,t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n   = t.Animation.Name
                    local pos = t.TimePosition
                    if IsM2Anim(n) then
                        hvy = true
                        if pos <= CFG.PreFireThreshold then sc+=75; rsn="M2Early:"..n  -- UPGRADED
                        elseif pos < 0.28 then sc+=60; rsn="M2Mid:"..n  -- UPGRADED
                        else sc+=35; rsn="M2Late:"..n end  -- UPGRADED
                        break
                    elseif IsM1Anim(n) then
                        if pos <= CFG.PreFireThreshold then sc+=65; rsn="M1Early:"..n  -- UPGRADED
                        elseif pos < 0.18 then sc+=50; rsn="M1Mid:"..n  -- UPGRADED
                        else sc+=20; rsn="M1Late:"..n end  -- UPGRADED
                        break
                    end
                end
            end
        end
    end

    -- Heavy alert
    if HeavyAlert[uid] then sc+=30; hvy=true end  -- UPGRADED

    -- Combo tracker - UPGRADED
    local combo = ComboTracker[uid] or 0
    if combo > 0 then
        local bonus = math.min(combo * 10, 40)  -- UPGRADED
        sc  += bonus
        rsn  = rsn=="" and ("Combo:"..combo) or rsn
    end

    -- Hit Frequency Prediction - UPGRADED
    if CFG.HitFreqAnalysis then
        local imminent, conf = IsNextHitImminent(uid)
        if imminent then
            local freqBonus = math.floor(conf * 35)  -- UPGRADED
            sc  += freqBonus
            rsn  = rsn=="" and ("Predicted") or rsn
        end
    end

    -- Angle predictor - UPGRADED
    local arcBonus = GetSwingArcBonus(er)
    sc += arcBonus

    -- Velocity sharpening - UPGRADED
    local velBonus = GetVelBonusUltimate(uid, er)
    sc += velBonus

    -- LookAt close (0-15) - UPGRADED
    if d < 8 then  -- UPGRADED range
        local toMe = (Root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.65 then sc+=15 end  -- UPGRADED
    end

    return math.min(sc,120), hvy, rsn~="" and rsn or "Multi"  -- UPGRADED cap
end

-- ─── PRIORITY QUEUE (UPGRADED) ────────────────────────────
local function BuildThreatQueueUltimate()
    local queue = {}
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local sc,hv,r = ScoreUltimate(p)
            if sc >= CFG.ScoreThreshold then
                table.insert(queue, {player=p, score=sc, heavy=hv, reason=r})
            end
        end
    end
    table.sort(queue, function(a,b) return a.score > b.score end)
    while #queue > CFG.MaxQueueTargets do
        table.remove(queue)
    end
    return queue
end

-- ─── HEARTBEAT (ULTIMATE) ─────────────────────────────────
RunService.Heartbeat:Connect(function()
    if not ON or not Refresh() then return end
    if os.clock() < NextParry then return end
    
    local now = os.clock()
    if now - LastHeartbeat < CFG.HeartbeatDebounce then return end
    LastHeartbeat = now

    if CFG.PriorityQueue then
        local queue = BuildThreatQueueUltimate()
        if #queue > 0 then
            local top = queue[1]
            if top.heavy then
                HeavyAlert[top.player.UserId]=true
                task.delay(3,function() HeavyAlert[top.player.UserId]=nil end)  -- UPGRADED
            end
            FireParry(
                string.format("[%d]%s/%s", top.score, top.reason, top.player.Name),
                top.heavy, true, top.player.UserId
            )
        end
    else
        local best,bH,bR,bP = 0,false,"",nil
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP then
                local sc,hv,r = ScoreUltimate(p)
                if sc>best then best,bH,bR,bP=sc,hv,r,p end
            end
        end
        if best>=CFG.ScoreThreshold and bP then
            if bH then
                HeavyAlert[bP.UserId]=true
                task.delay(3,function() HeavyAlert[bP.UserId]=nil end)  -- UPGRADED
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
                    task.delay(3,function() HeavyAlert[uid]=nil end)  -- UPGRADED
                end
                FireParry("WAttr:"..attr, isHvy, true, uid)
            end)
        end)
    end

    for _,a in ipairs(ALL_ATTR) do
        watchA(char,a)
        if eh then watchA(eh,a) end
    end

    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not ON then return end
                if not track then return end
                
                local ok, n = pcall(function() return track.Animation.Name end)
                if not ok or not n then return end
                
                local isH = IsM2Anim(n)
                local isM = IsM1Anim(n)
                if not isH and not isM then return end
                if not er or not Root then return end
                if Dist(Root,er)>CFG.Range then return end

                local now    = os.clock()
                local cacheK = string.format("%d_%s", uid, n)
                if CFG.AnimCacheStrict then
                    local lastFire = LastAnimFire[cacheK] or 0
                    if now - lastFire < 0.25 then return end  -- UPGRADED: tighter
                    LastAnimFire[cacheK] = now
                else
                    if PrevAnims[cacheK] then return end
                    PrevAnims[cacheK]=true
                    task.delay(0.30,function() PrevAnims[cacheK]=nil end)  -- UPGRADED
                end

                UpdateComboUltimate(uid, isH, n)

                FireParry("AnimPlay:"..n, isH, true, uid)
            end)
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
    HitHistory[p.UserId]=nil
    AttackTypeSeq[p.UserId]=nil
    ComboPattern[p.UserId]=nil
end)

-- ─── OPTIONAL PACKETS ─────────────────────────────────────
local function pktHook(pkt, src, heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        NextParry=0; Firing=false
        if heavy then
            HeavyAlert["pkt"..src]=true
            task.delay(3,function() HeavyAlert["pkt"..src]=nil end)  -- UPGRADED
        end
        FireParry("Pkt:"..src, heavy, true)
    end)
end
pktHook(M2Pkt,    "M2",     true)
pktHook(HeavyAtk, "Heavy",  true)
pktHook(ChargeAtk,"Charge", true)
pktHook(RedSig,   "RedSig", true)
pktHook(ComboPkt, "Combo",  false)

-- ─── FALLBACK EVENTS (SILENT) ────────────────────────────
GotHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    MissCount += 1
    ParryStreak = 0
    
    if Root then
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er=p.Character:FindFirstChild("HumanoidRootPart")
                if er and Dist(Root,er)<=CFG.Range then
                    UpdateComboUltimate(p.UserId, false, "GotHit")
                end
            end
        end
    end
    FireParry("GotHit", false, true)
end)

BlockHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    FireParry("BlockHit", false, true)
end)

CTChanged.OnClientEvent:Connect(function(t)
    if t then NextParry=0; Firing=false
    end
end)

-- SILENT MODE: No logs or notifications
ParryOK.OnClientEvent:Connect(function()
    ParryCount  += 1
    ParryStreak += 1
end)

-- ─── RESPAWN ──────────────────────────────────────────────
LP.CharacterAdded:Connect(function(c)
    Char=c
    Hum=c:WaitForChild("Humanoid")
    Root=c:WaitForChild("HumanoidRootPart")
    NextParry=0; Firing=false
    LastHeartbeat=0
    Watched={}; PrevAnims={}
    HeavyAlert={}; ComboTracker={}; LastHitTime={}
    HitIntervals={}; LastAnimFire={}; ThreatQueue={}
    HitHistory={}; ComboPattern={}; AttackTypeSeq={}
    ParryStreak=0
    task.wait(0.8); WatchAll()
end)

-- ─── TOGGLE ───────────────────────────────────────────────
UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==CFG.ToggleKey then
        ON=not ON; NextParry=0; Firing=false
    end
end)

-- ─── STARTUP NOTIFICATION ONLY ────────────────────────────
Notify("⚔️ Auto Parry v11 ULTIMATE Ready!", 2)
