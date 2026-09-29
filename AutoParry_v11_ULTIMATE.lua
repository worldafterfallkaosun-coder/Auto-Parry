local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local Stats             = game:GetService("Stats")
local TweenService      = game:GetService("TweenService")

local LP     = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local PGui   = LP:WaitForChild("PlayerGui")

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

local HitConfirm = nil
local HIT_NAMES = {
    "HitConfirm","DealDamage","HitEffect","AttackHit",
    "DamageDone","HitTarget","OnHit","AttackConnected",
    "HitSuccess","DamageDealt","MeleeHit","HitRegistered",
    "HitSomeone","DamageEvent","CombatHit","StrikeHit",
}
for _,n in ipairs(HIT_NAMES) do
    if Packets[n] then HitConfirm = Packets[n]; break end
end

local PCFG = {
    Range             = 22,
    TapWindow         = 0.032,
    CooldownM1        = 0.22,
    CooldownM2        = 0.15,
    ToggleKey         = Enum.KeyCode.RightShift,
    BurstEnabled      = true,
    BurstTrigger      = 2,
    BurstFireCount    = 5,
    BurstFireDelay    = 0.045,
    BurstCooldown     = 0.12,
    M2InstantEnabled  = true,
    M2PreCount        = 4,
    M2PreDelay        = 0.05,
    PingCompEnabled   = true,
    PingCompMax       = 0.70,
    MultiFireEnabled  = true,
    MultiFireBase     = 3,
    MultiFireMax      = 7,
    MultiFireDelay    = 0.055,
    AdaptiveCooldown  = true,
    ScoreThreshold    = 15,
    ThresholdFloor    = 10,
    MissDecay         = 2,
    HeartbeatDebounce = 0.015,
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
    ComboLockWindow   = 0.18,
    ComboLockMax      = 10,
    BackParryGuard    = true,
    BackAngleThresh   = -0.25,
}

local ACFG = {
    ON             = false,
    Range          = 25,
    LeashRange     = 30,   -- beyond this = release, no auto-switch
    LockDuration   = 60,
    NoAutoSwitch   = true,
    SwitchOnHit    = true,
    SwitchCooldown = 0.8,
    PredictFactor  = 0.12,
    VelLerpBase    = 0.35,
    Responsiveness = 40,
    MaxTorque      = 1e6,
    ProxRange      = 12,
    ToggleKey      = Enum.KeyCode.RightControl,
    SwitchKey      = Enum.KeyCode.RightShift,
    BlockedStates  = {
        "State_Ragdolled","State_Safe","State_Dead",
        "State_Downed","State_Gripped","State_Carried","State_Stunned",
    },
}

local Ping = {cache = 80, lastCheck = 0}

function Ping:get()
    local now = os.clock()
    if now - self.lastCheck > 0.25 then
        local s,v = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        self.cache = (s and v) or self.cache
        self.lastCheck = now
    end
    return self.cache
end

function Ping:lead()
    if not PCFG.PingCompEnabled then return 0 end
    return math.min(PCFG.PingCompMax, (self:get()/1000)*3.2)
end

function Ping:cooldown(isHeavy)
    local base = isHeavy and PCFG.CooldownM2 or PCFG.CooldownM1
    if not PCFG.AdaptiveCooldown then return base end
    local p = self:get()
    if p > 150 then
        return math.max(base*0.55, base - math.min(0.09,(p-150)/1800))
    end
    return math.max(base*0.70, base*(1+(p-80)/1200))
end

-- higher ping = smoother lerp to reduce jitter
function Ping:velLerp()
    local p = self:get()
    return math.clamp(ACFG.VelLerpBase - (p-80)/2000, 0.12, 0.5)
end

local PS = {}

local function GetPS(uid)
    if not PS[uid] then
        PS[uid] = {
            prevVel        = Vector3.zero,
            heavyAlert     = false,
            heavyAlertExp  = 0,
            combo          = 0,
            lastHitTime    = 0,
            history        = {},
            avgInterval    = nil,
            lastAnimFire   = {},
            comboLockOn    = false,
            comboLockExp   = 0,
            comboLockCount = 0,
            m2Detected     = false,
            m2DetectedExp  = 0,
            burstOn        = false,
            burstExp       = 0,
            lastVelSpike   = 0,
            watched        = false,
            cachedScore    = 0,
            cachedHeavy    = false,
            cacheTime      = 0,
        }
    end
    return PS[uid]
end

local function CleanPS(uid)
    PS[uid] = nil
end

Players.PlayerRemoving:Connect(function(p)
    CleanPS(p.UserId)
end)

local MyChar = {char=nil, hum=nil, root=nil}

local function RefreshChar()
    local c = LP.Character
    if not c then MyChar.char=nil; MyChar.hum=nil; MyChar.root=nil; return false end
    MyChar.char = c
    MyChar.hum  = c:FindFirstChildWhichIsA("Humanoid")
    MyChar.root = c:FindFirstChild("HumanoidRootPart")
    return MyChar.root ~= nil
end

LP.CharacterAdded:Connect(function(c)
    MyChar.char = c
    MyChar.hum  = c:WaitForChild("Humanoid")
    MyChar.root = c:WaitForChild("HumanoidRootPart")
end)

local Parry = {
    on           = false,
    nextFire     = 0,
    firing       = false,
    firingAt     = 0,
    parryCount   = 0,
    missCount    = 0,
    consecMiss   = 0,
    dynThreshold = PCFG.ScoreThreshold,
    lastHB       = 0,
}

local function Dist(a, b)
    if not a or not b then return 9999 end
    return (a.Position - b.Position).Magnitude
end

local SELF_ATKS = {
    "State_Attacking","IsAttacking","Attacking","SwingActive",
    "M1","Swinging","InAttack","AttackState","HitActive","StrikeActive",
}

local function IsSelfAttacking()
    if not PCFG.SelfGuard then return false end
    local c = MyChar.char; local h = MyChar.hum
    if not c then return false end
    for _,a in ipairs(SELF_ATKS) do
        if c:GetAttribute(a) == true then return true end
        if h and h:GetAttribute(a) == true then return true end
    end
    return false
end

local function IsFromBack(er)
    if not PCFG.BackParryGuard then return false end
    local root = MyChar.root
    if not root or not er then return false end
    local toEnemy = er.Position - root.Position
    toEnemy = Vector3.new(toEnemy.X, 0, toEnemy.Z)
    if toEnemy.Magnitude < 0.1 then return false end
    local myLook = root.CFrame.LookVector
    myLook = Vector3.new(myLook.X, 0, myLook.Z)
    if myLook.Magnitude < 0.1 then return false end
    return myLook.Unit:Dot(toEnemy.Unit) < PCFG.BackAngleThresh
end

local M2_KW = {
    "m2","heavy","charge","charged","block_break","smash","slam",
    "uppercut","overhead","power","special","red","danger","unblockable",
    "fury","burst","rage","break","grab","throw","launch","spin","finisher",
    "execute","stomp","ground","aoe","super","ultra","final","critical"
}
local M1_KW = {
    "m1","m3","m4","m5","attack","atk","swing","swipe","slash",
    "punch","hit","combo","strike","jab","lunge","thrust","kick","light",
    "fast","quick","right","left","normal","basic","combat","fight",
    "claw","stab","cut","slice","chop"
}
local M2_ATTR = {
    "State_HeavyAttack","State_M2","HeavyAttacking","M2","IsHeavy",
    "ChargingAttack","PowerAttack","BlockBreak","IsUnblockable","RedAttack",
    "SpecialAttack","FuryAttack","DangerState","ChargeState","HeavyState","UnblockState"
}
local ALL_ATTR = {
    "State_Attacking","State_AttackAnimation","State_Combat","Attacking",
    "AttackAnimation","IsAttacking","IsSwinging","M1","Swinging","Punching",
    "Hitting","InAttack","AttackState","Fighting","SwingActive","HitActive",
    "StrikeActive","State_HeavyAttack","State_M2","HeavyAttacking","M2",
    "IsHeavy","ChargingAttack","PowerAttack","BlockBreak","IsUnblockable",
    "RedAttack","SpecialAttack","FuryAttack","DangerState","ChargeState",
    "HeavyState","UnblockState"
}

-- O(1) lookup via set; linear scan over M2_KW was bottleneck on Score() hot path
local M2_KW_SET   = {}; for _,k in ipairs(M2_KW)  do M2_KW_SET[k]   = true end
local M2_ATTR_SET = {}; for _,k in ipairs(M2_ATTR) do M2_ATTR_SET[k] = true end

local function IsM2Anim(n)
    n = n:lower()
    for k in pairs(M2_KW_SET) do if n:find(k,1,true) then return true end end
    return false
end
local function IsM1Anim(n)
    n = n:lower()
    for _,k in ipairs(M1_KW) do if n:find(k,1,true) then return true end end
    return false
end
local function IsHeavyAttr(a) return M2_ATTR_SET[a] == true end

local function ScanAttrs(char, eh)
    for _,a in ipairs(ALL_ATTR) do
        local v = char:GetAttribute(a)
        if v == true then return true, IsHeavyAttr(a), a end
        if type(v)=="string" and (v:lower():find("attack") or v:lower():find("heavy")) then
            return true, IsHeavyAttr(a), a
        end
        if eh then
            v = eh:GetAttribute(a)
            if v == true then return true, IsHeavyAttr(a), a end
        end
    end
    return false, false, nil
end

-- avgInterval recomputed here and cached; callers read ps.avgInterval directly
local function RecordHit(ps, isHeavy, src)
    local now = os.clock()
    local h   = ps.history
    table.insert(h, {t=now, h=isHeavy, s=src})
    if #h > PCFG.HistoryDepth then table.remove(h, 1) end
    ps.lastHitTime = now
    if #h >= 3 then
        local sum, n = 0, 0
        for i = 2, #h do sum = sum + h[i].t - h[i-1].t; n = n+1 end
        ps.avgInterval = sum/n
    else
        ps.avgInterval = nil
    end
end

local function ActivateBurst(ps)
    if not PCFG.BurstEnabled then return end
    ps.burstOn  = true
    ps.burstExp = os.clock() + (PCFG.BurstFireCount * PCFG.BurstFireDelay) + 0.3
end

local function IsBurst(ps)
    if not ps.burstOn then return false end
    if os.clock() > ps.burstExp then ps.burstOn = false; return false end
    return true
end

local function ActivateComboLock(ps, cycles)
    if not PCFG.ComboLockEnabled then return end
    ps.comboLockOn    = true
    ps.comboLockCount = math.min(cycles or 4, PCFG.ComboLockMax)
    ps.comboLockExp   = os.clock() + PCFG.ComboLockWindow
end

local function TickComboLock(ps)
    if not ps.comboLockOn then return false end
    if os.clock() >= ps.comboLockExp then
        if ps.comboLockCount > 0 then
            ps.comboLockCount = ps.comboLockCount - 1
            ps.comboLockExp   = os.clock() + PCFG.ComboLockWindow
            return true
        else
            ps.comboLockOn = false; return false
        end
    end
    return false
end

local function UpdateCombo(ps, uid, isHeavy, src)
    local now = os.clock()
    if now - ps.lastHitTime > PCFG.ChainWindow then
        ps.combo = 0; ps.comboLockOn = false; ps.burstOn = false
    end
    RecordHit(ps, isHeavy, src)
    ps.combo = ps.combo + 1
    if ps.combo >= PCFG.BurstTrigger then ActivateBurst(ps) end
    if ps.combo >= 2 then
        local avg = ps.avgInterval
        if avg and avg < 0.6 then
            ActivateComboLock(ps, math.min(ps.combo+3, PCFG.ComboLockMax))
        end
    end
    return ps.combo
end

local function UpdateThreshold(missed)
    if missed then
        Parry.consecMiss   = Parry.consecMiss + 1
        Parry.dynThreshold = math.max(
            PCFG.ThresholdFloor,
            Parry.dynThreshold - PCFG.MissDecay * math.min(Parry.consecMiss, 4)
        )
    else
        Parry.consecMiss   = 0
        Parry.dynThreshold = math.min(PCFG.ScoreThreshold, Parry.dynThreshold + 1)
    end
end

local function GetMultiFire(ps)
    if not PCFG.MultiFireEnabled then return 1 end
    local combo = ps.combo
    local base  = PCFG.MultiFireBase
    if combo >= 5 then base = PCFG.MultiFireMax
    elseif combo >= 3 then base = base + 2
    elseif combo >= 1 then base = base + 1 end
    local avg = ps.avgInterval
    if avg and avg < 0.25 then base = math.min(PCFG.MultiFireMax, base+1) end
    local p = Ping:get()
    if p > 150 then base = math.min(PCFG.MultiFireMax, base+1) end
    if p > 250 then base = math.min(PCFG.MultiFireMax, base+1) end
    if IsBurst(ps) then base = PCFG.MultiFireMax end
    return math.min(PCFG.MultiFireMax, base)
end

local function RawParry()
    local p      = Ping:get()
    -- tap window shrinks at high ping to compensate server-side timing
    local dynTap = p > 150
        and math.max(0.018, PCFG.TapWindow - (p-150)/9000)
        or  PCFG.TapWindow
    pcall(function()
        task.wait(0.006)
        DSR:Fire("BeginBlock")
        task.wait(dynTap)
        DSR:Fire("BeginParry")
        task.wait(0.020)
        DSR:Fire("EndBlock")
    end)
end

local function CanFire()
    if not Parry.on then return false end
    if Parry.firing then
        if os.clock() - Parry.firingAt > PCFG.FiringTimeout then
            Parry.firing = false
        else
            return false
        end
    end
    if os.clock() < Parry.nextFire then return false end
    if not MyChar.root then return false end
    if IsSelfAttacking() then return false end
    return true
end

local function FireParry(isHeavy, force, ps)
    if not CanFire() then return false end
    local cd = Ping:cooldown(isHeavy)
    Parry.firing   = true
    Parry.firingAt = os.clock()
    Parry.nextFire = os.clock() + ((ps and IsBurst(ps)) and PCFG.BurstCooldown or cd)
    local lead    = Ping:lead()
    local mfCount = ps and GetMultiFire(ps) or 1
    task.spawn(function()
        pcall(function()
            if lead > 0.005 then task.wait(lead) end
            for i = 1, mfCount do
                if IsSelfAttacking() then break end
                RawParry()
                if i < mfCount then
                    task.wait((ps and IsBurst(ps)) and PCFG.BurstFireDelay or PCFG.MultiFireDelay)
                end
            end
        end)
        task.wait(0.035)
        Parry.firing = false
    end)
    return true
end

local function FireM2Instant(ps)
    if not PCFG.M2InstantEnabled then return end
    if Parry.firing and os.clock()-Parry.firingAt > 0.08 then Parry.firing = false end
    Parry.nextFire = 0
    task.spawn(function()
        for i = 1, PCFG.M2PreCount do
            RawParry()
            task.wait(PCFG.M2PreDelay)
        end
    end)
end

local function GetSwingBonus(er, root)
    if not PCFG.AnglePredict or not root or not er then return 0 end
    local toMe = root.Position - er.Position
    local d    = toMe.Magnitude
    if d < 0.1 then return 0 end
    local dirN = toMe/d
    local fDot = er.CFrame.LookVector:Dot(dirN)
    local sDot = math.abs(er.CFrame.RightVector:Dot(dirN))
    local b = 0
    if fDot > 0.5  then b = b + 14 end
    if sDot > 0.4  then b = b + 10 end
    if fDot > 0.78 then b = b + 8  end
    return b
end

local function GetVelBonus(ps, er, root)
    if not PCFG.VelSharpening or not root or not er then return 0 end
    local vel  = er.Velocity
    local prev = ps.prevVel
    ps.prevVel = vel
    local acc  = (vel - prev).Magnitude
    if acc < 2 then return 0 end
    local toMe = root.Position - er.Position
    if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return 0 end
    local dot = toMe.Unit:Dot(vel.Unit)
    local b = 0
    if dot > 0.25 then b = b + math.floor(dot*30) end
    if math.abs(vel.Unit.Y) > 0.35 and dot > 0.1 then b = b + 12 end
    return math.min(b, 42)
end

local SCORE_CACHE_TTL = 0.020

local function Score(p, ps)
    local now = os.clock()
    if now - ps.cacheTime < SCORE_CACHE_TTL then
        return ps.cachedScore, ps.cachedHeavy
    end
    local ec   = p.Character
    local root = MyChar.root
    if not ec or not root then ps.cachedScore=0; return 0, false end
    local er = ec:FindFirstChild("HumanoidRootPart")
    local eh = ec:FindFirstChildWhichIsA("Humanoid")
    if not er or not eh or eh.Health <= 0 then
        ps.cachedScore=0; return 0, false
    end
    local d = Dist(root, er)
    if d > PCFG.Range or IsFromBack(er) then
        ps.cachedScore=0; return 0, false
    end

    local sc = 0; local hvy = false
    sc = sc + math.floor((1 - d/PCFG.Range)*15)

    local hasAttr, isHAttr = ScanAttrs(ec, eh)
    if isHAttr then sc=sc+80; hvy=true
    elseif hasAttr then sc=sc+50 end

    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok2, tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok2 and tracks then
            for _,t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n   = t.Animation.Name
                    local pos = t.TimePosition
                    if IsM2Anim(n) then
                        hvy = true
                        sc  = sc + (pos <= PCFG.PreFireThreshold and 75 or pos < 0.25 and 60 or 35)
                        break
                    elseif IsM1Anim(n) then
                        sc  = sc + (pos <= PCFG.PreFireThreshold and 65 or pos < 0.18 and 50 or 22)
                        break
                    end
                end
            end
        end
    end

    if ps.heavyAlert and os.clock() < ps.heavyAlertExp then sc=sc+30; hvy=true end

    local combo = ps.combo
    if combo > 0 then sc = sc + math.min(combo*12, 60) end
    if IsBurst(ps) then sc = sc + 40 end
    local avg = ps.avgInterval
    if avg and avg < 0.4 then sc = sc + math.floor((1-avg/0.4)*20) end

    sc = sc + GetSwingBonus(er, root)
    sc = sc + GetVelBonus(ps, er, root)

    if d < 8 then
        local toMe = (root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.62 then sc = sc + 15 end
    end

    local final     = math.min(sc, 140)
    ps.cachedScore  = final
    ps.cachedHeavy  = hvy
    ps.cacheTime    = now
    return final, hvy
end

local function BuildQueue()
    local q = {}
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local ps    = GetPS(p.UserId)
            local sc,hv = Score(p, ps)
            if sc >= Parry.dynThreshold then
                table.insert(q, {player=p, score=sc, heavy=hv, ps=ps})
            end
        end
    end
    table.sort(q, function(a,b) return a.score > b.score end)
    while #q > PCFG.MaxQueueTargets do table.remove(q) end
    return q
end

local function CheckVelPreFire(p, ps, er)
    if not PCFG.VelPreFire or not MyChar.root or not er then return end
    if IsFromBack(er) then return end
    local vel  = er.Velocity
    local prev = ps.prevVel
    local acc  = (vel - prev).Magnitude
    if acc >= PCFG.VelPreFireThresh then
        local toMe = MyChar.root.Position - er.Position
        if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return end
        local dot = toMe.Unit:Dot(vel.Unit)
        if dot > 0.3 then
            local now = os.clock()
            if now - ps.lastVelSpike > 0.11 then
                ps.lastVelSpike = now
                FireParry(false, true, ps)
            end
        end
    end
end

RunService.Heartbeat:Connect(function()
    if not Parry.on then return end
    if not MyChar.root then RefreshChar() end
    if not MyChar.root then return end
    if IsSelfAttacking() then return end

    local now = os.clock()
    if now - Parry.lastHB < PCFG.HeartbeatDebounce then return end
    Parry.lastHB = now

    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and Dist(MyChar.root, er) <= PCFG.Range then
                if not IsFromBack(er) then
                    local ps = GetPS(p.UserId)
                    if ps.comboLockOn and TickComboLock(ps) then
                        if now >= Parry.nextFire then FireParry(false, true, ps) end
                    end
                    if IsBurst(ps) and now >= Parry.nextFire then
                        FireParry(false, true, ps)
                    end
                    CheckVelPreFire(p, ps, er)
                end
            end
        end
    end

    if now < Parry.nextFire then return end
    local q = BuildQueue()
    if #q > 0 then
        local top = q[1]; local ps = top.ps; local uid = top.player.UserId
        if top.heavy then
            ps.heavyAlert    = true
            ps.heavyAlertExp = now + 3
        end
        local fired = FireParry(top.heavy, true, ps)
        if fired then UpdateCombo(ps, uid, top.heavy, "HB"); UpdateThreshold(false) end
    end
end)

local function WatchChar(p, char)
    if not char then return end
    local er  = char:FindFirstChild("HumanoidRootPart")
    local eh  = char:FindFirstChildWhichIsA("Humanoid")
    local uid = p.UserId
    local ps  = GetPS(uid)

    local function onAttrChange(obj, attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not Parry.on or IsSelfAttacking() then return end
                local v = obj:GetAttribute(attr)
                if not (v==true or (type(v)=="string" and
                    (v:lower():find("attack") or v:lower():find("heavy")))) then return end
                er = char:FindFirstChild("HumanoidRootPart")
                if not er or not MyChar.root then return end
                if Dist(MyChar.root, er) > PCFG.Range then return end
                if IsFromBack(er) then return end
                local isHvy = IsHeavyAttr(attr)
                if isHvy then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = os.clock() + 3
                    if not ps.m2Detected or os.clock() >= ps.m2DetectedExp then
                        ps.m2Detected    = true
                        ps.m2DetectedExp = os.clock() + 2
                        FireM2Instant(ps); return
                    end
                end
                UpdateCombo(ps, uid, isHvy, attr)
                FireParry(isHvy, true, ps)
            end)
        end)
    end

    for _,a in ipairs(ALL_ATTR) do
        onAttrChange(char, a)
        if eh then onAttrChange(eh, a) end
    end

    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not Parry.on or not track then return end
                if IsSelfAttacking() then return end
                local ok2, n = pcall(function() return track.Animation.Name end)
                if not ok2 or not n then return end
                local isH = IsM2Anim(n); local isM = IsM1Anim(n)
                if not isH and not isM then return end
                er = char:FindFirstChild("HumanoidRootPart")
                if not er or not MyChar.root then return end
                if Dist(MyChar.root, er) > PCFG.Range then return end
                if IsFromBack(er) then return end
                local now = os.clock()
                local cK  = string.format("%d_%s", uid, n)
                if now - (ps.lastAnimFire[cK] or 0) < 0.18 then return end
                ps.lastAnimFire[cK] = now
                UpdateCombo(ps, uid, isH, n)
                if isH then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = now + 3
                    FireM2Instant(ps)
                else
                    FireParry(false, true, ps)
                end
            end)
        end)
    end

    if eh then
        local an = eh:FindFirstChildOfClass("Animator")
        if an then
            watchAnim(an)
        else
            eh.ChildAdded:Connect(function(c)
                if c:IsA("Animator") then watchAnim(c) end
            end)
        end
    end
end

local function Watch(p)
    if not p or p == LP then return end
    local ps = GetPS(p.UserId)
    if ps.watched then return end
    ps.watched = true
    if p.Character then WatchChar(p, p.Character) end
    p.CharacterAdded:Connect(function(c)
        ps.watched = false
        CleanPS(p.UserId)
        task.wait(0.4); Watch(p)
    end)
end

local function WatchAll()
    for _,p in pairs(Players:GetPlayers()) do Watch(p) end
end
WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.3); Watch(p) end)

local function pktHook(pkt, heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        Parry.nextFire = 0; Parry.firing = false
        if heavy then FireM2Instant(nil) else FireParry(false, true, nil) end
    end)
end
pktHook(M2Pkt, true); pktHook(HeavyAtk, true)
pktHook(ChargeAtk, true); pktHook(RedSig, true); pktHook(ComboPkt, false)

GotHit.OnClientEvent:Connect(function()
    Parry.nextFire  = 0; Parry.firing = false
    Parry.missCount = Parry.missCount + 1
    UpdateThreshold(true)

    local root        = MyChar.root
    local shouldParry = false

    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and root and Dist(root, er) <= PCFG.Range then
                if not IsFromBack(er) then
                    local ps = GetPS(p.UserId)
                    UpdateCombo(ps, p.UserId, false, "GotHit")
                    ActivateComboLock(ps, PCFG.ComboLockMax)
                    ActivateBurst(ps)
                    shouldParry = true
                end
            end
        end
    end

    if shouldParry then FireParry(false, true, nil) end

    if ACFG.ON then
        AS.InCombat = true
        if ACFG.SwitchOnHit then
            local now = os.clock()
            if now - AS.LastSwitch >= ACFG.SwitchCooldown then
                AS.LastSwitch = now
                local root2 = MyChar.root
                local closest, cd = nil, ACFG.Range
                for _,p in pairs(Players:GetPlayers()) do
                    if p ~= LP and p ~= AS.Target and p.Character then
                        local er = p.Character:FindFirstChild("HumanoidRootPart")
                        local eh = p.Character:FindFirstChild("Humanoid")
                        if er and eh and eh.Health > 0 then
                            local d = root2 and Dist(root2, er) or 9999
                            if d < cd then cd=d; closest=p end
                        end
                    end
                end
                if closest then LockOn(closest)
                elseif not AS.Target then
                    local b = GetBestTarget(true); if b then LockOn(b) end
                else RefreshLock() end
            end
        else
            local b = GetBestTarget(true); if b then LockOn(b) end
        end
    end
end)

BlockHit.OnClientEvent:Connect(function()
    Parry.nextFire = 0; Parry.firing = false
    local root        = MyChar.root
    local shouldParry = false
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and root and Dist(root, er) <= PCFG.Range then
                if not IsFromBack(er) then shouldParry=true; break end
            end
        end
    end
    if shouldParry or not root then FireParry(false, true, nil) end
end)

CTChange.OnClientEvent:Connect(function(t)
    if t then Parry.nextFire=0; Parry.firing=false end
    AS.InCombat = t
    if t and AS.Target then RefreshLock() end
end)

ParryOK.OnClientEvent:Connect(function()
    Parry.parryCount = Parry.parryCount + 1
end)

LP.CharacterAdded:Connect(function(c)
    RefreshChar()
    Parry.nextFire=0; Parry.firing=false; Parry.firingAt=0; Parry.lastHB=0
    for uid in pairs(PS) do PS[uid]=nil end
    Parry.dynThreshold = PCFG.ScoreThreshold
    Parry.consecMiss   = 0
    task.wait(0.7); WatchAll()
end)

local AS = {
    Target     = nil,
    ExpireTime = 0,
    InCombat   = false,
    PrevPos    = nil,
    Vel        = Vector3.zero,
    LastVelT   = 0,
    AlignOri   = nil,
    Att0       = nil,
    Candidates = {},
    IsAtk      = false,
    LastProx   = 0,
    LastSwitch = 0,
}

local function IsBlocked()
    local c = LP.Character; if not c then return true end
    for _,s in ipairs(ACFG.BlockedStates) do
        if c:GetAttribute(s) == true then return true end
    end
    return false
end

local function ValidTarget(t)
    if not t or not t.Parent then return false end
    local c = t.Character; if not c then return false end
    local h = c:FindFirstChild("Humanoid")
    if not h or h.Health <= 0 then return false end
    local r = c:FindFirstChild("HumanoidRootPart"); if not r then return false end
    local myR = MyChar.root; if not myR then return false end
    return Dist(myR, r) <= ACFG.LeashRange
end

local function RefreshLock() AS.ExpireTime = os.clock() + ACFG.LockDuration end

local function DestroyConstraint()
    pcall(function()
        if AS.AlignOri then AS.AlignOri:Destroy(); AS.AlignOri=nil end
        if AS.Att0     then AS.Att0:Destroy();     AS.Att0=nil     end
    end)
end

local function SetupConstraint()
    local root = MyChar.root; if not root then return end
    -- skip rebuild if constraint is already parented to current root
    if AS.AlignOri and AS.AlignOri.Parent == root then return end
    DestroyConstraint()
    local att  = Instance.new("Attachment")
    att.Name   = "_AA_A0"; att.Parent = root; AS.Att0 = att
    local ao   = Instance.new("AlignOrientation")
    ao.Name    = "_AA_AO"
    ao.Mode    = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0        = att
    ao.MaxTorque          = ACFG.MaxTorque
    ao.MaxAngularVelocity = math.huge
    ao.Responsiveness     = ACFG.Responsiveness
    ao.RigidityEnabled    = false
    ao.PrimaryAxisOnly    = false
    ao.Parent = root; AS.AlignOri = ao
end

local function SetAimDir(pos)
    if not AS.AlignOri or IsBlocked() then return end
    local root = MyChar.root; if not root then return end
    local dir  = pos - root.Position
    -- retain 10% Y so aim stays stable on sloped terrain
    dir = Vector3.new(dir.X, dir.Y * 0.1, dir.Z)
    if dir.Magnitude < 0.05 then return end
    dir = dir.Unit
    local up    = Vector3.new(0, 1, 0)
    local right = dir:Cross(up)
    if right.Magnitude < 0.01 then return end
    right = right.Unit
    AS.AlignOri.CFrame = CFrame.fromMatrix(Vector3.zero, right, right:Cross(dir).Unit)
end

local function UpdateVel(pos)
    local now = os.clock(); local dt = now - AS.LastVelT
    if AS.PrevPos and dt > 0 and dt < 0.3 then
        AS.Vel = AS.Vel:Lerp((pos - AS.PrevPos)/dt, Ping:velLerp())
    end
    AS.PrevPos = pos; AS.LastVelT = now
end

local function Predict(pos, dt)
    local hv = Vector3.new(AS.Vel.X, 0, AS.Vel.Z)
    return pos + hv * ACFG.PredictFactor * dt
end

local LockOn, UnlockAll, SwitchNext

local function GetBestTarget(rescan)
    local root = MyChar.root; if not root then return nil end
    if not rescan and AS.Target and ValidTarget(AS.Target) then return AS.Target end
    AS.Candidates = {}
    local best, bestD = nil, ACFG.Range
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local c = p.Character; if not c then continue end
            local r = c:FindFirstChild("HumanoidRootPart")
            local h = c:FindFirstChild("Humanoid")
            if not r or not h or h.Health <= 0 then continue end
            local d = Dist(root, r)
            if d <= ACFG.Range then
                table.insert(AS.Candidates, {p=p, dist=d})
                if d < bestD then bestD=d; best=p end
            end
        end
    end
    table.sort(AS.Candidates, function(a,b) return a.dist < b.dist end)
    return best
end

LockOn = function(t)
    if not t then return end
    local isNew = (t ~= AS.Target)
    AS.Target = t; AS.PrevPos = nil; AS.Vel = Vector3.zero
    RefreshLock()
    if isNew then SetupConstraint() end
end

UnlockAll = function()
    AS.Target = nil; AS.PrevPos = nil; AS.Vel = Vector3.zero
    DestroyConstraint()
end

SwitchNext = function()
    if #AS.Candidates < 1 then
        GetBestTarget(true)
        if #AS.Candidates < 1 then return end
    end
    if not AS.Target then LockOn(AS.Candidates[1].p); return end
    for i, c in ipairs(AS.Candidates) do
        if c.p == AS.Target then
            LockOn(AS.Candidates[i % #AS.Candidates + 1].p); return
        end
    end
    LockOn(AS.Candidates[1].p)
end

if HitConfirm then
    HitConfirm.OnClientEvent:Connect(function(t)
        if not ACFG.ON then return end
        AS.InCombat = true
        if t and typeof(t)=="Instance" and t:IsA("Player") and t ~= LP then
            LockOn(t)
        else
            local b = GetBestTarget(true); if b then LockOn(b) end
        end
    end)
end

local PROX_ATKS = {
    "State_Attacking","IsAttacking","Attacking","SwingActive","M1","InAttack"
}

local function ProxCheck()
    if HitConfirm or not ACFG.ON then return end
    local now = os.clock()
    if now - AS.LastProx < 0.12 then return end
    AS.LastProx = now
    local c = LP.Character; if not c then return end
    local isAtk = false
    for _,a in ipairs(PROX_ATKS) do
        if c:GetAttribute(a) == true then isAtk=true; break end
    end
    if isAtk and not AS.IsAtk then
        local root = MyChar.root; if not root then return end
        local closest, cd = nil, ACFG.ProxRange
        for _,p in pairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local er = p.Character:FindFirstChild("HumanoidRootPart")
                local eh = p.Character:FindFirstChild("Humanoid")
                if er and eh and eh.Health > 0 then
                    local d = Dist(root, er)
                    if d < cd then cd=d; closest=p end
                end
            end
        end
        if closest then AS.InCombat=true; LockOn(closest) end
    end
    AS.IsAtk = isAtk
end

RunService.Heartbeat:Connect(function(dt)
    if Camera.CameraType ~= Enum.CameraType.Custom then
        Camera.CameraType = Enum.CameraType.Custom
    end
    if not ACFG.ON then return end
    ProxCheck()
    if AS.Target and os.clock() > AS.ExpireTime then UnlockAll(); return end
    if AS.Target and not ValidTarget(AS.Target) then UnlockAll(); return end
    if not AS.Target then return end
    local ec = AS.Target.Character; if not ec then return end
    local er = ec:FindFirstChild("HumanoidRootPart"); if not er then return end
    UpdateVel(er.Position)
    SetAimDir(Predict(er.Position, dt))
end)

Players.PlayerRemoving:Connect(function(p)
    if AS.Target == p then UnlockAll() end
end)

LP.CharacterAdded:Connect(function()
    UnlockAll(); AS.InCombat=false; AS.IsAtk=false
    task.wait(0.5); SetupConstraint()
end)

UIS.InputBegan:Connect(function(i, g)
    if g then return end
    if i.KeyCode == ACFG.SwitchKey and ACFG.ON then
        GetBestTarget(true); SwitchNext()
    end
end)

local old = PGui:FindFirstChild("CombinedUI")
if old then old:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name           = "CombinedUI"
SG.ResetOnSpawn   = false
SG.IgnoreGuiInset = true
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.Parent         = PGui

local Panel = Instance.new("Frame")
Panel.Name                   = "Panel"
Panel.Size                   = UDim2.new(0,170,0,230)
Panel.Position               = UDim2.new(0,20,0.5,-115)
Panel.BackgroundColor3       = Color3.fromRGB(12,12,12)
Panel.BackgroundTransparency = 0.15
Panel.BorderSizePixel        = 0
Panel.Active                 = true
Panel.Parent                 = SG
Instance.new("UICorner",Panel).CornerRadius = UDim.new(0,10)

local PanelStroke = Instance.new("UIStroke",Panel)
PanelStroke.Thickness = 1.5
PanelStroke.Color     = Color3.fromRGB(60,60,60)

local Header = Instance.new("Frame")
Header.Size             = UDim2.new(1,0,0,30)
Header.BackgroundColor3 = Color3.fromRGB(22,22,22)
Header.BorderSizePixel  = 0
Header.Parent           = Panel
Instance.new("UICorner",Header).CornerRadius = UDim.new(0,10)

local HFix = Instance.new("Frame")
HFix.Size             = UDim2.new(1,0,0.5,0)
HFix.Position         = UDim2.new(0,0,0.5,0)
HFix.BackgroundColor3 = Color3.fromRGB(22,22,22)
HFix.BorderSizePixel  = 0
HFix.Parent           = Header

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Text                = "⚔️ COMBAT TOOLS"
TitleLbl.Size                = UDim2.new(1,-36,1,0)
TitleLbl.Position            = UDim2.new(0,10,0,0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.TextColor3          = Color3.fromRGB(220,220,220)
TitleLbl.TextSize            = 12
TitleLbl.Font                = Enum.Font.GothamBold
TitleLbl.TextXAlignment      = Enum.TextXAlignment.Left
TitleLbl.Parent              = Header

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size             = UDim2.new(0,22,0,22)
CloseBtn.Position         = UDim2.new(1,-26,0.5,-11)
CloseBtn.BackgroundColor3 = Color3.fromRGB(35,35,35)
CloseBtn.Text             = "✕"
CloseBtn.TextColor3       = Color3.fromRGB(160,160,160)
CloseBtn.TextSize         = 11
CloseBtn.Font             = Enum.Font.GothamBold
CloseBtn.BorderSizePixel  = 0
CloseBtn.Parent           = Header
Instance.new("UICorner",CloseBtn).CornerRadius = UDim.new(0,5)

local function MakeLabel(text, yPos)
    local lbl = Instance.new("TextLabel")
    lbl.Text                   = text
    lbl.Size                   = UDim2.new(1,-16,0,14)
    lbl.Position               = UDim2.new(0,8,0,yPos)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3             = Color3.fromRGB(100,100,100)
    lbl.TextSize               = 9
    lbl.Font                   = Enum.Font.GothamBold
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = Panel
    return lbl
end

local function MakeBtn(text, yPos, color)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1,-16,0,32)
    btn.Position         = UDim2.new(0,8,0,yPos)
    btn.BackgroundColor3 = color or Color3.fromRGB(40,40,40)
    btn.TextColor3       = Color3.fromRGB(255,255,255)
    btn.TextSize         = 12
    btn.Font             = Enum.Font.GothamBold
    btn.Text             = text
    btn.BorderSizePixel  = 0
    btn.Parent           = Panel
    Instance.new("UICorner",btn).CornerRadius = UDim.new(0,7)
    return btn
end

MakeLabel("— AUTO PARRY —", 36)
local ParryBtn = MakeBtn("⚔ PARRY: OFF", 52, Color3.fromRGB(180,35,35))
MakeLabel("— AUTO AIM —", 96)
local AimBtn   = MakeBtn("🎯 AIM: OFF", 112, Color3.fromRGB(180,35,35))

local TargetLbl = Instance.new("TextLabel")
TargetLbl.Size                   = UDim2.new(1,-16,0,16)
TargetLbl.Position               = UDim2.new(0,8,0,153)
TargetLbl.BackgroundTransparency = 1
TargetLbl.TextColor3             = Color3.fromRGB(255,200,80)
TargetLbl.TextSize               = 10
TargetLbl.Font                   = Enum.Font.Gotham
TargetLbl.TextXAlignment         = Enum.TextXAlignment.Left
TargetLbl.Text                   = "Target: -"
TargetLbl.TextTruncate           = Enum.TextTruncate.AtEnd
TargetLbl.Parent                 = Panel

local InfoLbl = Instance.new("TextLabel")
InfoLbl.Size                   = UDim2.new(1,-16,0,14)
InfoLbl.Position               = UDim2.new(0,8,0,171)
InfoLbl.BackgroundTransparency = 1
InfoLbl.TextColor3             = Color3.fromRGB(110,110,110)
InfoLbl.TextSize               = 9
InfoLbl.Font                   = Enum.Font.Gotham
InfoLbl.TextXAlignment         = Enum.TextXAlignment.Left
InfoLbl.Text                   = "Dist: - | HP: -"
InfoLbl.Parent                 = Panel

local StatsLbl = Instance.new("TextLabel")
StatsLbl.Size                   = UDim2.new(1,-16,0,12)
StatsLbl.Position               = UDim2.new(0,8,0,187)
StatsLbl.BackgroundTransparency = 1
StatsLbl.TextColor3             = Color3.fromRGB(80,80,80)
StatsLbl.TextSize               = 8
StatsLbl.Font                   = Enum.Font.Gotham
StatsLbl.TextXAlignment         = Enum.TextXAlignment.Left
StatsLbl.Text                   = "Parry:0 Miss:0 Ping:-"
StatsLbl.Parent                 = Panel

local SwBtn = MakeBtn("🔄 Switch Target", 201, Color3.fromRGB(50,85,180))

local ReopenBtn = Instance.new("TextButton")
ReopenBtn.Size             = UDim2.new(0,38,0,38)
ReopenBtn.Position         = Panel.Position
ReopenBtn.BackgroundColor3 = Color3.fromRGB(15,15,15)
ReopenBtn.Text             = "⚔️"
ReopenBtn.TextColor3       = Color3.fromRGB(255,255,255)
ReopenBtn.TextSize         = 18
ReopenBtn.Font             = Enum.Font.GothamBold
ReopenBtn.BorderSizePixel  = 0
ReopenBtn.Visible          = false
ReopenBtn.Active           = true
ReopenBtn.Parent           = SG
Instance.new("UICorner",ReopenBtn).CornerRadius = UDim.new(0,8)

local RStroke = Instance.new("UIStroke",ReopenBtn)
RStroke.Thickness = 1.5
RStroke.Color     = Color3.fromRGB(60,60,60)

local UILastUpdate = 0

local function UpdateUI()
    if Parry.on then
        ParryBtn.BackgroundColor3 = Color3.fromRGB(30,160,65)
        ParryBtn.Text             = "⚔ PARRY: ON"
    else
        ParryBtn.BackgroundColor3 = Color3.fromRGB(180,35,35)
        ParryBtn.Text             = "⚔ PARRY: OFF"
    end
    if ACFG.ON then
        AimBtn.BackgroundColor3 = Color3.fromRGB(30,120,200)
        AimBtn.Text             = "🎯 AIM: ON"
    else
        AimBtn.BackgroundColor3 = Color3.fromRGB(180,35,35)
        AimBtn.Text             = "🎯 AIM: OFF"
    end
    if Parry.on and ACFG.ON then
        PanelStroke.Color = Color3.fromRGB(0,220,180)
        RStroke.Color     = Color3.fromRGB(0,220,180)
    elseif ACFG.ON then
        PanelStroke.Color = Color3.fromRGB(30,120,200)
        RStroke.Color     = Color3.fromRGB(30,120,200)
    elseif Parry.on then
        PanelStroke.Color = Color3.fromRGB(30,160,65)
        RStroke.Color     = Color3.fromRGB(30,160,65)
    else
        PanelStroke.Color = Color3.fromRGB(60,60,60)
        RStroke.Color     = Color3.fromRGB(60,60,60)
    end
    if AS.Target and AS.Target.Character then
        local ec  = AS.Target.Character
        local er  = ec:FindFirstChild("HumanoidRootPart")
        local eh  = ec:FindFirstChild("Humanoid")
        local myR = MyChar.root
        local dist      = (er and myR) and math.floor(Dist(myR,er)) or 0
        local hp        = eh and math.floor(eh.Health) or 0
        local mhp       = eh and math.floor(eh.MaxHealth) or 0
        local remaining = math.max(0, math.floor(AS.ExpireTime - os.clock()))
        TargetLbl.Text  = "🎯 "..AS.Target.Name.." ["..remaining.."s]"
        InfoLbl.Text    = string.format("Dist:%d/%d | HP:%d/%d",
            dist, ACFG.LeashRange, hp, mhp)
    else
        TargetLbl.Text = "Target: -"
        InfoLbl.Text   = "Dist: - | HP: -"
    end
    StatsLbl.Text = string.format("Parry:%d Miss:%d Ping:%dms",
        Parry.parryCount, Parry.missCount, math.floor(Ping:get()))
end

RunService.RenderStepped:Connect(function()
    if not Panel.Visible then return end
    local now = os.clock()
    if now - UILastUpdate < 0.33 then return end
    UILastUpdate = now
    UpdateUI()
end)

local function TweenPop(btn)
    TweenService:Create(btn, TweenInfo.new(0.07), {Size=UDim2.new(1,-22,0,28)}):Play()
    task.wait(0.07)
    TweenService:Create(btn, TweenInfo.new(0.07), {Size=UDim2.new(1,-16,0,32)}):Play()
end

ParryBtn.MouseButton1Click:Connect(function()
    Parry.on       = not Parry.on
    Parry.nextFire = 0
    Parry.firing   = false
    TweenPop(ParryBtn); UpdateUI()
end)

AimBtn.MouseButton1Click:Connect(function()
    ACFG.ON = not ACFG.ON
    if not ACFG.ON then UnlockAll() end
    TweenPop(AimBtn); UpdateUI()
end)

SwBtn.MouseButton1Click:Connect(function()
    if not ACFG.ON then return end
    GetBestTarget(true); SwitchNext()
    TweenService:Create(SwBtn, TweenInfo.new(0.07),
        {BackgroundColor3=Color3.fromRGB(90,130,255)}):Play()
    task.wait(0.15)
    TweenService:Create(SwBtn, TweenInfo.new(0.07),
        {BackgroundColor3=Color3.fromRGB(50,85,180)}):Play()
end)

local savedPanelPos = Panel.Position

CloseBtn.MouseButton1Click:Connect(function()
    savedPanelPos = Panel.Position
    TweenService:Create(Panel,
        TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        {Size=UDim2.new(0,0,0,0), Position=UDim2.new(
            savedPanelPos.X.Scale, savedPanelPos.X.Offset+85,
            savedPanelPos.Y.Scale, savedPanelPos.Y.Offset+115)}):Play()
    task.wait(0.13)
    Panel.Visible     = false
    Panel.Size        = UDim2.new(0,170,0,230)
    Panel.Position    = savedPanelPos
    ReopenBtn.Visible = true
    ReopenBtn.Position = savedPanelPos
end)

ReopenBtn.MouseButton1Click:Connect(function()
    Panel.Position = savedPanelPos
    Panel.Visible  = true
    Panel.Size     = UDim2.new(0,0,0,0)
    ReopenBtn.Visible = false
    TweenService:Create(Panel,
        TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Size=UDim2.new(0,170,0,230)}):Play()
end)

UIS.InputBegan:Connect(function(i, g)
    if g then return end
    if i.KeyCode == PCFG.ToggleKey then
        Parry.on=not Parry.on; Parry.nextFire=0; Parry.firing=false; UpdateUI()
    end
    if i.KeyCode == ACFG.ToggleKey then
        ACFG.ON = not ACFG.ON
        if not ACFG.ON then UnlockAll() end; UpdateUI()
    end
end)

local function MakeDraggable(handle, target)
    local dragging, dragStart, startPos = false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch
        or i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging  = true
            dragStart = i.Position
            startPos  = target.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging=false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - dragStart
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            if target == Panel then savedPanelPos = Panel.Position end
        end
    end)
end

MakeDraggable(Header, Panel)
MakeDraggable(ReopenBtn, ReopenBtn)

UpdateUI()
print("Combat Tools v14.0")
