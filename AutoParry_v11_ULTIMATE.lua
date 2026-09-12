-- Auto Parry v13.0 — ULTRA INSTINCT
-- Chief Edition: Combo Burst + M2 Instant + Clean Log
-- Delta Executor

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
if not ok then return end

local DSR      = Packets.DefenseStateRequest
local CTChange = Packets.CombatTagChanged
local ParryOK  = Packets.ParrySuccess
local BlockHit = Packets.BlockHitReaction
local GotHit   = Packets.GotHitScreenEffect

local function tryPkt(n)
    local s,v = pcall(function() return Packets[n] end)
    return (s and v) or nil
end
local HeavyAtk  = tryPkt("HeavyAttack")
local ChargeAtk = tryPkt("ChargeAttack")
local M2Pkt     = tryPkt("M2Attack")
local RedSig    = tryPkt("DangerIndicator")
local ComboPkt  = tryPkt("ComboAttack")

-- ─── CONFIG ───────────────────────────────────────────────
local CFG = {
    Range             = 22,
    TapWindow         = 0.032,      -- lebih ketat
    CooldownM1        = 0.22,       -- lebih cepet dari v12
    CooldownM2        = 0.15,       -- M2 ultra cepet
    ToggleKey         = Enum.KeyCode.RightShift,

    -- COMBO BURST (fitur baru)
    BurstEnabled      = true,
    BurstTrigger      = 2,          -- setelah 2 hit = burst mode
    BurstFireCount    = 5,          -- fire 5x beruntun
    BurstFireDelay    = 0.045,      -- jeda antar burst fire
    BurstCooldown     = 0.12,       -- cooldown saat burst

    -- M2 INSTANT
    M2InstantEnabled  = true,
    M2PreCount        = 4,          -- fire 4x untuk M2
    M2PreDelay        = 0.05,

    -- PING
    PingCompEnabled   = true,
    PingCompMax       = 0.70,

    -- MULTI FIRE
    MultiFireEnabled  = true,
    MultiFireBase     = 3,
    MultiFireMax      = 7,
    MultiFireDelay    = 0.055,

    -- ADAPTIVE
    AdaptiveCooldown  = true,
    ScoreThreshold    = 15,
    ThresholdFloor    = 10,
    MissDecay         = 2,

    -- MISC
    Range             = 22,
    HeartbeatDebounce = 0.015,      -- lebih sering scan
    FiringTimeout     = 0.6,
    HistoryDepth      = 24,
    ChainWindow       = 1.2,
    MaxQueueTargets   = 6,
    PreFireThreshold  = 0.06,
    VelPreFire        = true,
    VelPreFireThresh  = 7,
    AnglePredict      = true,
    VelSharpening     = true,
    SelfGuard         = true,
    ForceAll          = true,
    ComboLockEnabled  = true,
    ComboLockWindow   = 0.18,       -- lebih ketat
    ComboLockMax      = 10,
}

-- ─── STATE ────────────────────────────────────────────────
local ON            = true
local NextParry     = 0
local Firing        = false
local FiringAt      = 0
local ParryCount    = 0
local MissCount     = 0
local ConsecMiss    = 0
local DynThreshold  = CFG.ScoreThreshold
local Watched       = {}
local PrevVel       = {}
local HeavyAlert    = {}
local ComboTracker  = {}
local LastHitTime   = {}
local HitHistory    = {}
local LastAnimFire  = {}
local LastHeartbeat = 0
local ComboLockActive = {}
local ComboLockUntil  = {}
local ComboLockCount  = {}
local LastVelSpike    = {}
local M2Detected      = {}
local BurstActive     = {}  -- NEW: burst mode per enemy
local BurstUntil      = {}  -- NEW: burst expiry

-- ─── PING ─────────────────────────────────────────────────
local PingCache     = 80
local PingLastCheck = 0

local function GetPing()
    local now = os.clock()
    if now - PingLastCheck > 0.25 then
        local s,v = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        PingCache     = (s and v) or PingCache
        PingLastCheck = now
    end
    return PingCache
end

local function GetLead()
    if not CFG.PingCompEnabled then return 0 end
    local raw = (GetPing() / 1000) * 3.2
    return math.min(CFG.PingCompMax, raw)
end

local function GetCooldown(isHeavy)
    local base = isHeavy and CFG.CooldownM2 or CFG.CooldownM1
    if not CFG.AdaptiveCooldown then return base end
    local ping = GetPing()
    if ping > 150 then
        return math.max(base * 0.55, base - math.min(0.09,(ping-150)/1800))
    end
    return math.max(base * 0.70, base * (1 + (ping-80)/1200))
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
        "SendNotification",{Title="⚔️ AP v13",Text=t,Duration=d or 2})
end

-- ─── SELF GUARD ───────────────────────────────────────────
local SELF_ATKS = {
    "State_Attacking","IsAttacking","Attacking","SwingActive",
    "M1","Swinging","InAttack","AttackState","HitActive","StrikeActive",
}

local function IsSelfAttacking()
    if not CFG.SelfGuard or not Char then return false end
    for _,a in ipairs(SELF_ATKS) do
        if Char:GetAttribute(a)==true then return true end
        if Hum and Hum:GetAttribute(a)==true then return true end
    end
    return false
end

-- ─── ADAPTIVE THRESHOLD ───────────────────────────────────
local function UpdateThreshold(missed)
    if missed then
        ConsecMiss   += 1
        DynThreshold  = math.max(CFG.ThresholdFloor,
            DynThreshold - CFG.MissDecay * math.min(ConsecMiss, 4))
    else
        ConsecMiss    = 0
        DynThreshold  = math.min(CFG.ScoreThreshold, DynThreshold + 1)
    end
end

-- ─── CAN FIRE ─────────────────────────────────────────────
local function CanFire(force)
    if not ON then return false end
    if Firing then
        if os.clock() - FiringAt > CFG.FiringTimeout then Firing = false
        else return false end
    end
    if os.clock() < NextParry then return false end
    if not Refresh() then return false end
    if IsSelfAttacking() then return false end
    return true
end

-- ─── HIT HISTORY ──────────────────────────────────────────
local function RecordHit(uid, isHeavy, src)
    local now = os.clock()
    if not HitHistory[uid] then HitHistory[uid] = {} end
    table.insert(HitHistory[uid], {t=now,h=isHeavy,s=src})
    if #HitHistory[uid] > CFG.HistoryDepth then
        table.remove(HitHistory[uid], 1)
    end
    LastHitTime[uid] = now
end

local function GetAvgInterval(uid)
    local h = HitHistory[uid]
    if not h or #h < 3 then return nil end
    local sum, n = 0, 0
    for i = 2, #h do sum += h[i].t - h[i-1].t; n += 1 end
    return n > 0 and (sum/n) or nil
end

-- ─── BURST MODE (NEW v13) ─────────────────────────────────
local function ActivateBurst(uid)
    if not CFG.BurstEnabled then return end
    BurstActive[uid] = true
    BurstUntil[uid]  = os.clock() + (CFG.BurstFireCount * CFG.BurstFireDelay) + 0.3
end

local function IsBurst(uid)
    if not BurstActive[uid] then return false end
    if os.clock() > BurstUntil[uid] then
        BurstActive[uid] = false
        return false
    end
    return true
end

-- ─── COMBO LOCK ───────────────────────────────────────────
local function ActivateComboLock(uid, cycles)
    if not CFG.ComboLockEnabled then return end
    local c = math.min(cycles or 4, CFG.ComboLockMax)
    ComboLockActive[uid] = true
    ComboLockCount[uid]  = c
    ComboLockUntil[uid]  = os.clock() + CFG.ComboLockWindow
end

local function TickComboLock(uid)
    if not ComboLockActive[uid] then return false end
    local now = os.clock()
    if now >= ComboLockUntil[uid] then
        if ComboLockCount[uid] > 0 then
            ComboLockCount[uid] -= 1
            ComboLockUntil[uid]  = now + CFG.ComboLockWindow
            return true
        else
            ComboLockActive[uid] = false
            return false
        end
    end
    return false
end

-- ─── COMBO TRACKER ────────────────────────────────────────
local function UpdateCombo(uid, isHeavy, src)
    local now  = os.clock()
    local last = LastHitTime[uid] or 0
    if not ComboTracker[uid] then ComboTracker[uid] = 0 end
    if now - last > CFG.ChainWindow then
        ComboTracker[uid]    = 0
        ComboLockActive[uid] = false
        BurstActive[uid]     = false
    end
    RecordHit(uid, isHeavy, src)
    ComboTracker[uid] += 1

    -- Trigger burst saat combo >= BurstTrigger
    if ComboTracker[uid] >= CFG.BurstTrigger then
        ActivateBurst(uid)
    end

    if ComboTracker[uid] >= 2 then
        local avg = GetAvgInterval(uid)
        if avg and avg < 0.6 then
            ActivateComboLock(uid, math.min(ComboTracker[uid] + 3, CFG.ComboLockMax))
        end
    end
    return ComboTracker[uid]
end

local function GetMultiFire(uid, isHeavy)
    if not CFG.MultiFireEnabled then return 1 end
    local combo = ComboTracker[uid] or 0
    local base  = CFG.MultiFireBase
    if isHeavy then base = base + CFG.M2PreCount end
    if combo >= 5 then base = CFG.MultiFireMax
    elseif combo >= 3 then base = base + 2
    elseif combo >= 1 then base = base + 1 end
    local avg = GetAvgInterval(uid)
    if avg and avg < 0.25 then
        base = math.min(CFG.MultiFireMax, base + 1)
    end
    local ping = GetPing()
    if ping > 150 then base = math.min(CFG.MultiFireMax, base + 1) end
    if ping > 250 then base = math.min(CFG.MultiFireMax, base + 1) end
    if IsBurst(uid) then base = CFG.MultiFireMax end -- burst = max fire
    return math.min(CFG.MultiFireMax, base)
end

-- ─── CORE PARRY ───────────────────────────────────────────
local function RawParry()
    pcall(function()
        local ping = GetPing()
        local dynTap = ping > 150
            and math.max(0.018, CFG.TapWindow - (ping-150)/9000)
            or  CFG.TapWindow
        task.wait(0.006)
        DSR:Fire("BeginBlock")
        task.wait(dynTap)
        DSR:Fire("BeginParry")
        task.wait(0.020)
        DSR:Fire("EndBlock")
    end)
end

local function FireParry(isHeavy, force, uid)
    if not CanFire(force) then return false end
    local cd      = GetCooldown(isHeavy)
    Firing        = true
    FiringAt      = os.clock()

    -- Burst mode: CD lebih pendek
    NextParry = os.clock() + (IsBurst(uid) and CFG.BurstCooldown or cd)

    local lead    = GetLead()
    local mfCount = GetMultiFire(uid, isHeavy)

    task.spawn(function()
        pcall(function()
            if lead > 0.005 then task.wait(lead) end
            for i = 1, mfCount do
                if IsSelfAttacking() then break end
                RawParry()
                if i < mfCount then
                    task.wait(IsBurst(uid) and CFG.BurstFireDelay or CFG.MultiFireDelay)
                end
            end
        end)
        task.wait(0.035)
        Firing = false
    end)
    return true
end

local function FireM2Instant(uid)
    if not CFG.M2InstantEnabled then return end
    if Firing and os.clock() - FiringAt > 0.08 then Firing = false end
    NextParry = 0
    task.spawn(function()
        for i = 1, CFG.M2PreCount do
            RawParry()
            task.wait(CFG.M2PreDelay)
        end
    end)
end

-- ─── ANIM KEYWORDS ────────────────────────────────────────
local M2_KW = {
    "m2","heavy","charge","charged","block_break","smash","slam",
    "uppercut","overhead","power","special","red","danger",
    "unblockable","fury","burst","rage","break","grab","throw",
    "launch","spin","finisher","execute","stomp","ground",
    "aoe","super","ultra","final","critical",
}
local M1_KW = {
    "m1","m3","m4","m5","attack","atk","swing","swipe","slash",
    "punch","hit","combo","strike","jab","lunge","thrust",
    "kick","light","fast","quick","right","left","normal","basic",
    "combat","fight","claw","stab","cut","slice","chop",
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

-- ─── ATTR LISTS ───────────────────────────────────────────
local M2_ATTR = {
    "State_HeavyAttack","State_M2","HeavyAttacking","M2",
    "IsHeavy","ChargingAttack","PowerAttack","BlockBreak",
    "IsUnblockable","RedAttack","SpecialAttack","FuryAttack",
    "DangerState","ChargeState","HeavyState","UnblockState",
}
local ALL_ATTR = {
    "State_Attacking","State_AttackAnimation","State_Combat",
    "Attacking","AttackAnimation","IsAttacking","IsSwinging",
    "M1","Swinging","Punching","Hitting","InAttack","AttackState",
    "Fighting","SwingActive","HitActive","StrikeActive",
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

-- ─── ANGLE + VEL BONUS ────────────────────────────────────
local function GetSwingBonus(er)
    if not CFG.AnglePredict or not Root or not er then return 0 end
    local toMe = (Root.Position - er.Position)
    local d    = toMe.Magnitude
    if d < 0.1 then return 0 end
    local dirN    = toMe / d
    local faceDot = er.CFrame.LookVector:Dot(dirN)
    local sideDot = math.abs(er.CFrame.RightVector:Dot(dirN))
    local bonus   = 0
    if faceDot > 0.5  then bonus += 14 end
    if sideDot > 0.4  then bonus += 10 end
    if faceDot > 0.78 then bonus += 8  end
    return bonus
end

local function GetVelBonus(uid, er)
    if not CFG.VelSharpening or not Root or not er then return 0 end
    local vel  = er.Velocity
    local prev = PrevVel[uid] or vel
    PrevVel[uid] = vel
    local acc = (vel - prev).Magnitude
    if acc < 2 then return 0 end
    local toMe = (Root.Position - er.Position)
    if toMe.Magnitude < 0.1 then return 0 end
    local dirN = toMe.Unit
    if vel.Magnitude < 0.1 then return 0 end
    local dot = dirN:Dot(vel.Unit)
    local bonus = 0
    if dot > 0.25 then bonus += math.floor(dot * 30) end
    if math.abs(vel.Unit.Y) > 0.35 and dot > 0.1 then bonus += 12 end
    return math.min(bonus, 42)
end

local function CheckVelPreFire(uid, er)
    if not CFG.VelPreFire or not Root or not er then return end
    local vel  = er.Velocity
    local prev = PrevVel[uid] or vel
    local acc  = (vel - prev).Magnitude
    if acc >= CFG.VelPreFireThresh then
        local toMe = (Root.Position - er.Position)
        if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return end
        local dot = toMe.Unit:Dot(vel.Unit)
        if dot > 0.3 then
            local now  = os.clock()
            if now - (LastVelSpike[uid] or 0) > 0.11 then
                LastVelSpike[uid] = now
                FireParry(false, true, uid)
            end
        end
    end
end

-- ─── SCORE ENGINE ─────────────────────────────────────────
local function Score(p)
    local ec = p.Character
    if not ec then return 0,false end
    local er = ec:FindFirstChild("HumanoidRootPart")
    local eh = ec:FindFirstChildWhichIsA("Humanoid")
    if not er or not eh or eh.Health<=0 or not Root then return 0,false end
    local d = Dist(Root,er)
    if d > CFG.Range then return 0,false end

    local sc=0; local hvy=false
    local uid = p.UserId

    sc += math.floor((1 - d/CFG.Range) * 15)

    local hasAttr,isHAttr,_ = ScanAttrs(ec,eh)
    if isHAttr      then sc+=80; hvy=true
    elseif hasAttr  then sc+=50 end

    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok2,tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok2 and tracks then
            for _,t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n=t.Animation.Name; local pos=t.TimePosition
                    if IsM2Anim(n) then
                        hvy=true
                        if pos<=CFG.PreFireThreshold then sc+=75
                        elseif pos<0.25 then sc+=60
                        else sc+=35 end
                        break
                    elseif IsM1Anim(n) then
                        if pos<=CFG.PreFireThreshold then sc+=65
                        elseif pos<0.18 then sc+=50
                        else sc+=22 end
                        break
                    end
                end
            end
        end
    end

    if HeavyAlert[uid] then sc+=30; hvy=true end

    local combo = ComboTracker[uid] or 0
    if combo > 0 then sc += math.min(combo*12, 60) end

    if IsBurst(uid) then sc += 40 end -- burst = score boost

    local avg = GetAvgInterval(uid)
    if avg and avg < 0.4 then
        sc += math.floor((1-avg/0.4)*20)
    end

    sc += GetSwingBonus(er)
    sc += GetVelBonus(uid, er)

    if d < 8 then
        local toMe = (Root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.62 then sc+=15 end
    end

    return math.min(sc,140), hvy
end

-- ─── PRIORITY QUEUE ───────────────────────────────────────
local function BuildQueue()
    local q={}
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP then
            local sc,hv=Score(p)
            if sc>=DynThreshold then
                table.insert(q,{player=p,score=sc,heavy=hv})
            end
        end
    end
    table.sort(q,function(a,b) return a.score>b.score end)
    while #q>CFG.MaxQueueTargets do table.remove(q) end
    return q
end

-- ─── HEARTBEAT ────────────────────────────────────────────
RunService.Heartbeat:Connect(function()
    if not ON or not Refresh() then return end
    if IsSelfAttacking() then return end
    local now = os.clock()
    if now - LastHeartbeat < CFG.HeartbeatDebounce then return end
    LastHeartbeat = now

    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and Root and Dist(Root,er)<=CFG.Range then
                local uid = p.UserId
                if ComboLockActive[uid] and TickComboLock(uid) then
                    if now >= NextParry then
                        FireParry(false, true, uid)
                    end
                end
                -- Burst mode: fire terus selama burst aktif
                if IsBurst(uid) and now >= NextParry then
                    FireParry(false, true, uid)
                end
                CheckVelPreFire(uid, er)
            end
        end
    end

    if now < NextParry then return end
    local q = BuildQueue()
    if #q > 0 then
        local top = q[1]
        local uid = top.player.UserId
        if top.heavy then
            HeavyAlert[uid] = true
            task.delay(3, function() HeavyAlert[uid]=nil end)
        end
        local fired = FireParry(top.heavy, true, uid)
        if fired then
            UpdateCombo(uid, top.heavy, "HB")
            UpdateThreshold(false)
        end
    end
end)

-- ─── REALTIME WATCHERS ────────────────────────────────────
local function WatchChar(p, char)
    if not char then return end
    local er  = char:FindFirstChild("HumanoidRootPart")
    local eh  = char:FindFirstChildWhichIsA("Humanoid")
    local uid = p.UserId

    local function watchA(obj, attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not ON then return end
                if IsSelfAttacking() then return end
                local v = obj:GetAttribute(attr)
                if not(v==true or(type(v)=="string" and
                    (v:lower():find("attack") or v:lower():find("heavy")))) then return end
                if not er or not Root then return end
                if Dist(Root,er) > CFG.Range then return end
                local isHvy = IsHeavyAttr(attr)
                if isHvy then
                    HeavyAlert[uid] = true
                    task.delay(3,function() HeavyAlert[uid]=nil end)
                    if not M2Detected[uid] then
                        M2Detected[uid] = true
                        task.delay(2,function() M2Detected[uid]=nil end)
                        FireM2Instant(uid)
                        return
                    end
                end
                UpdateCombo(uid, isHvy, attr)
                FireParry(isHvy, true, uid)
            end)
        end)
    end

    for _,a in ipairs(ALL_ATTR) do
        watchA(char, a)
        if eh then watchA(eh, a) end
    end

    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not ON or not track then return end
                if IsSelfAttacking() then return end
                local ok2,n = pcall(function() return track.Animation.Name end)
                if not ok2 or not n then return end
                local isH = IsM2Anim(n)
                local isM = IsM1Anim(n)
                if not isH and not isM then return end
                if not er or not Root then return end
                if Dist(Root,er) > CFG.Range then return end
                local now = os.clock()
                local cacheK = string.format("%d_%s",uid,n)
                if now-(LastAnimFire[cacheK] or 0) < 0.18 then return end
                LastAnimFire[cacheK] = now
                UpdateCombo(uid, isH, n)
                if isH then
                    HeavyAlert[uid] = true
                    task.delay(3,function() HeavyAlert[uid]=nil end)
                    FireM2Instant(uid)
                else
                    FireParry(false, true, uid)
                end
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
end

local function Watch(p)
    if not p or p==LP then return end
    if Watched[p.UserId] then return end
    Watched[p.UserId] = true
    if p.Character then WatchChar(p, p.Character) end
    p.CharacterAdded:Connect(function(c)
        Watched[p.UserId] = nil
        task.wait(0.4)
        Watch(p)
    end)
end

local function WatchAll()
    for _,p in pairs(Players:GetPlayers()) do Watch(p) end
end

WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.3); Watch(p) end)
Players.PlayerRemoving:Connect(function(p)
    local uid = p.UserId
    Watched[uid]=nil; PrevVel[uid]=nil; HeavyAlert[uid]=nil
    ComboTracker[uid]=nil; LastHitTime[uid]=nil; HitHistory[uid]=nil
    LastAnimFire[uid]=nil; ComboLockActive[uid]=nil
    ComboLockCount[uid]=nil; M2Detected[uid]=nil
    LastVelSpike[uid]=nil; BurstActive[uid]=nil
end)

-- ─── OPTIONAL PACKETS ─────────────────────────────────────
local function pktHook(pkt,heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        NextParry=0; Firing=false
        if heavy then FireM2Instant(nil)
        else FireParry(false, true) end
    end)
end
pktHook(M2Pkt, true)
pktHook(HeavyAtk, true)
pktHook(ChargeAtk, true)
pktHook(RedSig, true)
pktHook(ComboPkt, false)

-- ─── FALLBACK EVENTS ──────────────────────────────────────
GotHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    MissCount += 1
    UpdateThreshold(true)
    if Root then
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er = p.Character:FindFirstChild("HumanoidRootPart")
                if er and Dist(Root,er)<=CFG.Range then
                    local uid = p.UserId
                    UpdateCombo(uid, false, "GotHit")
                    ActivateComboLock(uid, CFG.ComboLockMax)
                    ActivateBurst(uid)  -- kena hit = langsung burst
                end
            end
        end
    end
    FireParry(false, true)
end)

BlockHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    FireParry(false, true)
end)

CTChange.OnClientEvent:Connect(function(t)
    if t then NextParry=0; Firing=false end
end)

ParryOK.OnClientEvent:Connect(function()
    ParryCount += 1
end)

-- ─── RESPAWN ──────────────────────────────────────────────
LP.CharacterAdded:Connect(function(c)
    Char=c; Hum=c:WaitForChild("Humanoid"); Root=c:WaitForChild("HumanoidRootPart")
    NextParry=0; Firing=false; FiringAt=0; LastHeartbeat=0
    Watched={}; HeavyAlert={}; ComboTracker={}
    LastHitTime={}; HitHistory={}; LastAnimFire={}
    ComboLockActive={}; ComboLockCount={}; ComboLockUntil={}
    M2Detected={}; LastVelSpike={}; BurstActive={}; BurstUntil={}
    PrevVel={}; DynThreshold=CFG.ScoreThreshold; ConsecMiss=0
    task.wait(0.7); WatchAll()
end)

-- ─── TOGGLE ───────────────────────────────────────────────
UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==CFG.ToggleKey then
        ON=not ON; NextParry=0; Firing=false
        Notify(ON and "✅ v13 ON" or "❌ v13 OFF")
    end
end)

-- ─── INIT ─────────────────────────────────────────────────
Notify("⚔️ Auto Parry v13.0 — ULTRA INSTINCT", 3)
