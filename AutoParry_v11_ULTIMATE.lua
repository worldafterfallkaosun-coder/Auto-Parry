-- ============================================================
--  HIGH SCHOOL ANIME — Combat Tools v5.0 APEX
--  Gaussian humanizer · Poisson spam · Kalman lock
--  AnimWindow pre-fire · Adaptive rate cap · Decoy scatter
--  Score-priority lock · Hysteresis switch · Smooth camera
-- ============================================================

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local Stats        = game:GetService("Stats")
local TweenService = game:GetService("TweenService")
local RepStorage   = game:GetService("ReplicatedStorage")

local LP     = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local PGui   = LP:WaitForChild("PlayerGui")

-- randomise RNG seed per load so timing signatures differ each session
math.randomseed(math.floor(os.clock() * 1e6) % (2^31 - 1))

-- ============================================================
--  REMOTES
-- ============================================================
local CombatRemotes = RepStorage:WaitForChild("CombatRemotes", 10)
if not CombatRemotes then warn("[HSA] CombatRemotes missing"); return end

local RequestBlock = CombatRemotes:WaitForChild("RequestBlock", 5)
local ReactionFX   = CombatRemotes:WaitForChild("ReactionFX", 5)
local ParryFX      = CombatRemotes:WaitForChild("ParryFX", 5)
local CounterHitFX = CombatRemotes:WaitForChild("CounterHitFX", 5)
local GuardBreakFX = CombatRemotes:WaitForChild("GuardBreakFX", 5)
local HitRunFX     = CombatRemotes:WaitForChild("HitRunFX", 5)
local KickComboFX  = CombatRemotes:WaitForChild("KickComboFX", 5)
local HeavyPunchFX = CombatRemotes:WaitForChild("HeavyPunchFX", 5)
local KOFX         = CombatRemotes:WaitForChild("KOFX", 5)

if not RequestBlock then warn("[HSA] RequestBlock missing"); return end

-- ============================================================
--  FPS MONITOR
-- ============================================================
local FPS = {
    current   = 60,
    frametime = 1/60,
    samples   = {},
    maxSamp   = 20,
    lastT     = os.clock(),
}

RunService.Heartbeat:Connect(function(dt)
    table.insert(FPS.samples, dt)
    if #FPS.samples > FPS.maxSamp then table.remove(FPS.samples, 1) end
    local now = os.clock()
    if now - FPS.lastT > 0.5 then
        local sum = 0
        for _, s in ipairs(FPS.samples) do sum = sum + s end
        FPS.frametime = sum / #FPS.samples
        FPS.current   = math.floor(1 / math.max(FPS.frametime, 0.001))
        FPS.lastT     = now
    end
end)

-- ============================================================
--  PING MONITOR
-- ============================================================
local Ping = { current = 80, samples = {}, maxSamp = 10, lastT = 0 }

function Ping:update()
    local now = os.clock()
    if now - self.lastT < 0.3 then return end
    self.lastT = now
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and v and v > 0 then
        table.insert(self.samples, v)
        if #self.samples > self.maxSamp then table.remove(self.samples, 1) end
        local sum = 0
        for _, s in ipairs(self.samples) do sum = sum + s end
        self.current = sum / #self.samples
    end
end

function Ping:get()   self:update(); return self.current end
function Ping:lead()
    local p = self:get()
    return math.min(0.120, math.max(0, (p - 60) / 1000 * 2.5))
end
function Ping:cooldown(heavy)
    local p = self:get()
    local base = heavy and 0.20 or 0.28
    if p > 180 then return math.max(base * 0.55, base - 0.08)
    elseif p > 120 then return math.max(base * 0.70, base - 0.04) end
    return base
end

-- ============================================================
--  MATH UTILITIES
-- ============================================================
local _TWO_PI = 2 * math.pi

-- Gaussian sample via Box-Muller; clamped at ±2.5σ
local function GaussJitter(mean, sigma)
    local u1 = math.max(1e-10, math.random())
    local u2 = math.random()
    local z  = math.sqrt(-2 * math.log(u1)) * math.cos(_TWO_PI * u2)
    return math.clamp(mean + z * sigma, mean - 2.5 * sigma, mean + 2.5 * sigma)
end

-- Exponential inter-arrival time for Poisson process at rate_hz events/sec
local function PoissonWait(rate_hz)
    rate_hz = math.max(rate_hz, 0.1)
    local u = math.max(1e-10, math.random())
    return -math.log(u) / rate_hz
end

-- Random alphanumeric string for obfuscated instance names
local _NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local function RandName(len)
    local t = {}
    for i = 1, len do
        local idx = math.random(1, #_NAME_CHARS)
        t[i] = _NAME_CHARS:sub(idx, idx)
    end
    return table.concat(t)
end

-- ============================================================
--  DYNAMIC RATE CAP
--  Starts conservative, probes ceiling upward over time.
--  Backs off if a cap-hit was observed in the last window.
-- ============================================================
local DynRL = {
    floor   = 8,
    ceiling = 18,
    current = 10,
    probeT  = 0,
    probeCd = 14.0,
    hitCap  = false,
}

function DynRL:probe()
    local now = os.clock()
    if now - self.probeT < self.probeCd then return end
    self.probeT = now
    if not self.hitCap then
        self.current = math.min(self.ceiling, self.current + 1)
    else
        self.current = math.max(self.floor, self.current - 1)
    end
    self.hitCap = false
end

function DynRL:cap()
    self:probe()
    return self.current
end

-- ============================================================
--  ADAPTIVE TIMING ENGINE
-- ============================================================
local Adaptive = {}

function Adaptive:compute()
    local p   = Ping:get()
    local fps = FPS.current
    local ft  = FPS.frametime
    local windowEst = 0.095 + math.min(0.06, p / 2500)

    local tapTime
    if fps >= 55 then tapTime = 0.052
    elseif fps >= 35 then tapTime = 0.042
    else tapTime = 0.032 end

    local interval
    if fps >= 55 then interval = 0.050
    elseif fps >= 35 then interval = 0.040
    else interval = 0.030 end

    local fireTime  = tapTime + interval
    local spamCount = math.ceil(windowEst / fireTime)
    spamCount = math.clamp(spamCount, 3, 9)

    -- ceiling from dynamic rate cap
    local maxByRate = math.floor(DynRL:cap() / 2)
    spamCount = math.min(spamCount, maxByRate)

    return { tapTime = tapTime, interval = interval, spamCount = spamCount, windowEst = windowEst }
end

-- ============================================================
--  RATE LIMITER — uses DynRL for ceiling
-- ============================================================
local RL = { calls = {} }

function RL:ok()
    local now   = os.clock()
    local fresh = {}
    for _, t in ipairs(self.calls) do
        if now - t < 1.0 then table.insert(fresh, t) end
    end
    self.calls = fresh
    local cap = DynRL:cap()
    if #self.calls >= cap then DynRL.hitCap = true end
    return #self.calls < cap
end

function RL:mark()  table.insert(self.calls, os.clock()) end
function RL:count() return #self.calls end

-- ============================================================
--  ANIMATION WINDOW PREDICTOR
--  Given a playing AnimationTrack, estimates seconds until
--  the hitbox window center (≈30% of animation length).
--  Returns 0 if data is unreliable.
-- ============================================================
local function AnimWindowPredict(track)
    if not track or not track.IsPlaying then return 0 end
    local ok, dur = pcall(function() return track.Length end)
    if not ok or not dur or dur <= 0 then return 0 end
    local pos   = track.TimePosition
    local spd   = track.Speed
    if spd <= 0 then return 0 end
    local hitCenter = dur * 0.30
    local remaining = (hitCenter - pos) / spd
    return math.max(0, remaining)
end

-- ============================================================
--  ATTR / ANIM LISTS
-- ============================================================
local SELF_ATKS = {
    "IsPunching","IsHeavyPunching","IsHitRunning",
    "IsKickCombo","IsFiring","IsActionLocked","IsStartingBattle",
}
local M2_ATTR = { "IsHeavyPunching","IsFiring" }
local ALL_ATTR = {
    "IsPunching","IsHeavyPunching","IsHitRunning",
    "IsKickCombo","IsFiring","IsStartingBattle","FightMode",
}
local M2_KW = {
    "heavy","heavypunch","heavyfirst","heavysecond","heavythird",
    "heavyend","heavyspam","fire","spam","kickcombo","hitrun",
    "kick","launch","slam","smash","charge","unblockable","break","burst",
}
local M1_KW = {
    "light","lightpunch","punch","m1","combo","attack",
    "swing","strike","jab","hit","1","2","3","4","5","slot",
}
local LOCK_BLOCKED = {
    "IsKO","IsBeingCarried","IsCarrying","IsStunned","IsGrabbing",
    "IsBeingGrabbed","IsHitFrozen","IsFinishing","IsBeingFinished",
    "IsActionLocked","IsWakingUp","IsDodging","IsVaulting","IsSliding","IsClashing",
}

local M2_ATTR_SET = {}; for _,k in ipairs(M2_ATTR) do M2_ATTR_SET[k]=true end
local M2_KW_SET   = {}; for _,k in ipairs(M2_KW)   do M2_KW_SET[k]=true   end

-- ============================================================
--  CHAR REF
-- ============================================================
local MC = { char=nil, hum=nil, root=nil }

local function RefreshChar()
    local c = LP.Character
    if not c then MC.char=nil; MC.hum=nil; MC.root=nil; return false end
    MC.char = c
    MC.hum  = c:FindFirstChildWhichIsA("Humanoid")
    MC.root = c:FindFirstChild("HumanoidRootPart")
    return MC.root ~= nil
end

LP.CharacterAdded:Connect(function(c)
    MC.char = c
    MC.hum  = c:WaitForChild("Humanoid")
    MC.root = c:WaitForChild("HumanoidRootPart")
end)

-- ============================================================
--  PER-PLAYER STATE (includes Kalman fields)
-- ============================================================
local PS = {}
local function GetPS(uid)
    if not PS[uid] then
        PS[uid] = {
            -- parry tracking
            prevVel       = Vector3.zero,
            heavyAlert    = false,
            heavyAlertExp = 0,
            combo         = 0,
            lastHitTime   = 0,
            history       = {},
            avgInterval   = nil,
            lastAnimFire  = {},
            lastVelSpike  = 0,
            watched       = false,
            cachedScore   = 0,
            cachedHeavy   = false,
            cacheTime     = 0,
            m2Detected    = false,
            m2DetectedExp = 0,
            -- Kalman filter
            kalmanPos     = nil,
            kalmanVel     = Vector3.zero,
            kalmanAcc     = Vector3.zero,
            kalmanPrevVel = Vector3.zero,
            kalmanTime    = 0,
        }
    end
    return PS[uid]
end
local function CleanPS(uid) PS[uid] = nil end
Players.PlayerRemoving:Connect(function(p) CleanPS(p.UserId) end)

-- ============================================================
--  KALMAN FILTER (constant-acceleration model, horizontal only)
-- ============================================================
local function KalmanUpdate(ps, pos, now)
    local dt = now - ps.kalmanTime
    ps.kalmanTime = now
    if ps.kalmanPos and dt > 0 and dt < 0.35 then
        local rawVel = (pos - ps.kalmanPos) / dt
        local alpha  = math.clamp(0.40 - (Ping:get() - 80) / 2400, 0.15, 0.55)
        local newVel = ps.kalmanVel:Lerp(rawVel, alpha)
        local rawAcc = (newVel - ps.kalmanVel) / dt
        ps.kalmanAcc     = ps.kalmanAcc:Lerp(rawAcc, 0.18)
        ps.kalmanPrevVel = ps.kalmanVel
        ps.kalmanVel     = newVel
    end
    ps.kalmanPos = pos
end

local function KalmanPredict(ps, ahead)
    if not ps.kalmanPos then return nil end
    local vel = ps.kalmanVel
    local acc = ps.kalmanAcc
    -- horizontal-biased prediction; cap vertical acc (jumps are brief)
    local hVel = Vector3.new(vel.X, vel.Y * 0.25, vel.Z)
    local hAcc = Vector3.new(acc.X * 0.5, 0, acc.Z * 0.5)
    return ps.kalmanPos + hVel * ahead + hAcc * (0.5 * ahead * ahead)
end

-- ============================================================
--  PARRY STATE
-- ============================================================
local Parry = {
    on           = false,
    nextFire     = 0,
    firing       = false,
    firingAt     = 0,
    parryCount   = 0,
    missCount    = 0,
    consecMiss   = 0,
    dynThreshold = 8.0,  -- EMA now, float
    lastHB       = 0,
    spamActive   = false,
    lastSpamT    = 0,
}

-- ============================================================
--  LOCK STATE
-- ============================================================
-- randomised attachment names so static-name scanners miss them
local ATT_NAME = RandName(9)
local AO_NAME  = RandName(9)

local Lock = {
    on          = false,
    target      = nil,
    expireTime  = 0,
    combatTime  = 0,
    inCombat    = false,
    alignOri    = nil,
    att0        = nil,
    candidates  = {},
    camTargetCF = nil,   -- smooth camera target
}

local LOCK_SWITCH_HYSTERESIS = 20  -- new target must outscore current by this much

-- ============================================================
--  HELPERS
-- ============================================================
local function Dist(a, b)
    if not a or not b then return 9999 end
    return (a.Position - b.Position).Magnitude
end

local function IsSelfAttacking()
    local c = MC.char; local h = MC.hum
    if not c then return false end
    for _, a in ipairs(SELF_ATKS) do
        if c:GetAttribute(a) == true then return true end
        if h and h:GetAttribute(a) == true then return true end
    end
    return false
end

local function IsFromBack(er)
    local root = MC.root
    if not root or not er then return false end
    local toE  = Vector3.new(er.Position.X - root.Position.X, 0, er.Position.Z - root.Position.Z)
    if toE.Magnitude < 0.1 then return false end
    local look = root.CFrame.LookVector
    look = Vector3.new(look.X, 0, look.Z)
    if look.Magnitude < 0.1 then return false end
    return look.Unit:Dot(toE.Unit) < -0.20
end

local function IsM2Anim(n)
    n = n:lower()
    for k in pairs(M2_KW_SET) do if n:find(k, 1, true) then return true end end
    return false
end
local function IsM1Anim(n)
    n = n:lower()
    for _, k in ipairs(M1_KW) do if n:find(k, 1, true) then return true end end
    return false
end
local function IsHeavyAttr(a) return M2_ATTR_SET[a] == true end

local function ScanAttrs(char, eh)
    for _, a in ipairs(ALL_ATTR) do
        local v = char:GetAttribute(a)
        if v == true then return true, IsHeavyAttr(a), a end
        if type(v) == "string" and (v:lower():find("attack") or v:lower():find("heavy")) then
            return true, IsHeavyAttr(a), a
        end
        if eh then
            v = eh:GetAttribute(a)
            if v == true then return true, IsHeavyAttr(a), a end
        end
    end
    return false, false, nil
end

-- ============================================================
--  COMBAT MARK
-- ============================================================
local function MarkCombat()
    Lock.combatTime = os.clock()
    Lock.inCombat   = true
end

local function CheckNeutral()
    if not Lock.inCombat then return end
    if os.clock() - Lock.combatTime > 3.5 then
        Lock.inCombat = false
        if not Lock.on then Lock.target = nil end
    end
end

-- ============================================================
--  SCORE SYSTEM (tightened cache TTL = 8ms)
-- ============================================================
local SCORE_TTL = 0.008

local function GetSwingBonus(er, root)
    local toMe = root.Position - er.Position
    local d    = toMe.Magnitude
    if d < 0.1 then return 0 end
    local dirN = toMe / d
    local fDot = er.CFrame.LookVector:Dot(dirN)
    local sDot = math.abs(er.CFrame.RightVector:Dot(dirN))
    local b = 0
    if fDot > 0.45 then b = b + 14 end
    if sDot > 0.35 then b = b + 10 end
    if fDot > 0.75 then b = b + 8  end
    return b
end

local function GetVelBonus(ps, er, root)
    local vel  = er.Velocity
    local prev = ps.prevVel
    ps.prevVel = vel
    local acc  = (vel - prev).Magnitude
    if acc < 1.5 then return 0 end
    local toMe = root.Position - er.Position
    if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return 0 end
    local dot = toMe.Unit:Dot(vel.Unit)
    local b = 0
    if dot > 0.20 then b = b + math.floor(dot * 32) end
    if math.abs(vel.Unit.Y) > 0.30 and dot > 0.1 then b = b + 12 end
    return math.min(b, 45)
end

local function Score(p, ps)
    local now = os.clock()
    if now - ps.cacheTime < SCORE_TTL then
        return ps.cachedScore, ps.cachedHeavy
    end
    local ec   = p.Character
    local root = MC.root
    if not ec or not root then ps.cachedScore = 0; return 0, false end
    local er = ec:FindFirstChild("HumanoidRootPart")
    local eh = ec:FindFirstChildWhichIsA("Humanoid")
    if not er or not eh or eh.Health <= 0 then ps.cachedScore = 0; return 0, false end

    local d = Dist(root, er)
    if d > 22 or IsFromBack(er) then ps.cachedScore = 0; return 0, false end

    local sc = 0; local hvy = false
    sc = sc + math.floor((1 - d / 22) * 18)

    local hasAttr, isHAttr = ScanAttrs(ec, eh)
    if isHAttr     then sc = sc + 90; hvy = true
    elseif hasAttr then sc = sc + 58 end

    if ec:GetAttribute("InCombat") == true  then sc = sc + 12 end
    if ec:GetAttribute("FightMode") == true then sc = sc + 10 end

    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok, tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok and tracks then
            for _, t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n   = t.Animation.Name
                    local pos = t.TimePosition
                    if IsM2Anim(n) then
                        hvy = true
                        sc  = sc + (pos <= 0.04 and 85 or pos <= 0.10 and 72 or pos < 0.22 and 58 or 40)
                        break
                    elseif IsM1Anim(n) then
                        sc  = sc + (pos <= 0.04 and 75 or pos <= 0.08 and 62 or pos < 0.16 and 50 or 28)
                        break
                    end
                end
            end
        end
    end

    if ps.heavyAlert and now < ps.heavyAlertExp then sc = sc + 38; hvy = true end

    local combo = ps.combo
    if combo > 0 then sc = sc + math.min(combo * 12, 55) end
    local avg = ps.avgInterval
    if avg and avg < 0.4 then sc = sc + math.floor((1 - avg / 0.4) * 22) end

    sc = sc + GetSwingBonus(er, root)
    sc = sc + GetVelBonus(ps, er, root)

    if d < 7 then
        local toMe = (root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.58 then sc = sc + 18 end
    end

    local final = math.min(sc, 140)
    ps.cachedScore = final; ps.cachedHeavy = hvy; ps.cacheTime = now
    return final, hvy
end

-- ============================================================
--  DECOY SCATTER
--  Fires RequestBlock(false) on a Gaussian-spaced schedule
--  during neutral state, making remote call pattern organic.
-- ============================================================
local Decoy = { nextT = 0 }

function Decoy:schedule()
    -- random gap 8–22s with Gaussian centre at 14s
    self.nextT = os.clock() + math.abs(GaussJitter(14.0, 3.5))
end

function Decoy:tick()
    if Parry.on then return end                -- parry active: no redundant decoys
    if os.clock() < self.nextT then return end
    if not RL:ok() then self:schedule(); return end
    pcall(function()
        task.delay(math.abs(GaussJitter(0.09, 0.025)), function()
            RequestBlock:FireServer(false)
            RL:mark()
        end)
    end)
    self:schedule()
end

Decoy:schedule()

-- ============================================================
--  RAW PARRY — Gaussian tap + jitter
-- ============================================================
local function RawParry(tapOverride)
    if not RL:ok() then return false end
    local p   = Ping:get()
    -- Gaussian tap: mean 55ms σ=8ms → human-like hold duration
    local tap = tapOverride or math.clamp(GaussJitter(0.055, 0.008), 0.028, 0.090)
    if p > 160 then tap = math.max(0.028, tap - (p - 160) / 6000) end

    -- Gaussian pre/post jitter; always positive
    local jPre  = math.abs(GaussJitter(0.010, 0.004))
    local jPost = math.abs(GaussJitter(0.008, 0.003))

    pcall(function()
        task.wait(jPre)
        RequestBlock:FireServer(true)
        RL:mark()
        task.wait(tap)
        task.wait(jPost)
        RequestBlock:FireServer(false)
    end)
    return true
end

-- ============================================================
--  ADAPTIVE SPAM PARRY
--  Poisson-spaced fires + optional AnimWindow pre-delay
-- ============================================================
local spamLock = false

local function AdaptiveSpamParry(isHeavy, urgency, animTrack)
    if spamLock then return end
    spamLock = true
    Parry.lastSpamT = os.clock()

    local timing = Adaptive:compute()
    local count  = timing.spamCount
    if isHeavy                 then count = math.min(count + 2, 10) end
    if urgency == "instant"    then count = math.min(count + 1, 10) end

    local pingLead = Ping:lead()

    task.spawn(function()
        -- precision pre-delay: use anim window data when available
        if animTrack and urgency ~= "instant" then
            local ahead = AnimWindowPredict(animTrack)
            if ahead > 0.002 and ahead < 0.10 then
                task.wait(ahead)
            elseif pingLead > 0.003 then
                task.wait(pingLead * 0.45)
            end
        elseif pingLead > 0.003 and urgency ~= "instant" then
            task.wait(pingLead * 0.45)
        end

        for i = 1, count do
            if not Parry.on then break end
            if not RL:ok() then task.wait(timing.interval) end
            RawParry(timing.tapTime)
            if i < count then
                -- Poisson inter-arrival, bounded to 40–250% of base interval
                local rate = 1 / timing.interval
                local iv   = PoissonWait(rate)
                iv = math.clamp(iv, timing.interval * 0.40, timing.interval * 2.5)
                -- add micro Gaussian noise on top of Poisson
                iv = iv + GaussJitter(0, 0.003)
                task.wait(math.max(iv, 0.005))
            end
        end

        spamLock = false
    end)
end

-- ============================================================
--  FIRE PARRY — gated, adaptive
-- ============================================================
local function CanFire()
    if not Parry.on then return false end
    if Parry.firing then
        if os.clock() - Parry.firingAt > 0.6 then
            Parry.firing = false
        else return false end
    end
    if os.clock() < Parry.nextFire then return false end
    if not MC.root then return false end
    if IsSelfAttacking() then return false end
    return true
end

local function FireParry(isHeavy, ps, urgency, animTrack)
    if not CanFire() then return false end
    local cd  = Ping:cooldown(isHeavy)
    -- Gaussian cooldown jitter
    local cdJ = GaussJitter(0, 0.012)

    Parry.firing   = true
    Parry.firingAt = os.clock()
    Parry.nextFire = os.clock() + cd + cdJ

    local timing         = Adaptive:compute()
    local totalSpamTime  = timing.spamCount * (timing.tapTime + timing.interval)

    task.spawn(function()
        AdaptiveSpamParry(isHeavy, urgency or "normal", animTrack)
        task.wait(totalSpamTime + 0.04)
        Parry.firing = false
    end)

    return true
end

-- dedup gate: FX events can stack within one attack
local lastInstantT = 0
local function SafeFireInstant(isHeavy)
    local now = os.clock()
    if now - lastInstantT < 0.075 then return end
    lastInstantT = now
    Parry.nextFire = 0
    Parry.firing   = false
    spamLock       = false
    AdaptiveSpamParry(isHeavy or true, "instant", nil)
end

-- ============================================================
--  COMBO / HISTORY
-- ============================================================
local function RecordHit(ps, isHeavy, src)
    local now = os.clock()
    table.insert(ps.history, { t = now, h = isHeavy, s = src })
    if #ps.history > 20 then table.remove(ps.history, 1) end
    ps.lastHitTime = now
    if #ps.history >= 3 then
        local sum, n = 0, 0
        for i = 2, #ps.history do
            sum = sum + ps.history[i].t - ps.history[i-1].t; n = n + 1
        end
        ps.avgInterval = sum / n
    else ps.avgInterval = nil end
end

local function UpdateCombo(ps, uid, isHeavy, src)
    if os.clock() - ps.lastHitTime > 1.2 then ps.combo = 0 end
    RecordHit(ps, isHeavy, src)
    ps.combo = ps.combo + 1
    return ps.combo
end

-- EMA threshold: decays toward 5 on miss, toward 9 on success
local function UpdateThreshold(missed)
    local target = missed and 5 or 9
    Parry.dynThreshold = Parry.dynThreshold * 0.82 + target * 0.18
    Parry.dynThreshold = math.clamp(Parry.dynThreshold, 4, 10)
    if missed then
        Parry.consecMiss = Parry.consecMiss + 1
    else
        Parry.consecMiss = 0
    end
end

-- ============================================================
--  BUILD QUEUE
-- ============================================================
local function BuildQueue()
    local q = {}
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local ps    = GetPS(p.UserId)
            local sc, hv = Score(p, ps)
            if sc >= Parry.dynThreshold then
                table.insert(q, { player = p, score = sc, heavy = hv, ps = ps })
            end
        end
    end
    table.sort(q, function(a, b) return a.score > b.score end)
    while #q > 3 do table.remove(q) end
    return q
end

-- ============================================================
--  VEL PRE-FIRE
-- ============================================================
local function CheckVelPreFire(p, ps, er)
    if not MC.root or not er then return end
    if IsFromBack(er) then return end
    local vel = er.Velocity
    local acc = (vel - ps.prevVel).Magnitude
    if acc >= 6 then
        local toMe = MC.root.Position - er.Position
        if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return end
        local dot = toMe.Unit:Dot(vel.Unit)
        if dot > 0.25 then
            local now = os.clock()
            if now - ps.lastVelSpike > 0.13 then
                ps.lastVelSpike = now
                FireParry(false, ps, "normal", nil)
            end
        end
    end
end

-- ============================================================
--  HEARTBEAT — main scan (tighter scan rate: 1.5× frametime)
-- ============================================================
local lastHBTime = 0

RunService.Heartbeat:Connect(function()
    if not Parry.on then Decoy:tick(); return end
    if not MC.root then RefreshChar(); return end
    if IsSelfAttacking() then return end

    local now      = os.clock()
    local scanRate = math.max(0.008, FPS.frametime * 1.5)
    if now - lastHBTime < scanRate then return end
    lastHBTime = now

    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and Dist(MC.root, er) <= 22 and not IsFromBack(er) then
                CheckVelPreFire(p, GetPS(p.UserId), er)
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
        local fired = FireParry(top.heavy, ps, "normal", nil)
        if fired then UpdateCombo(ps, uid, top.heavy, "HB"); UpdateThreshold(false) end
    end
end)

-- ============================================================
--  WATCH CHAR — zero-latency attr + anim listeners
--  Passes AnimationTrack into FireParry for window prediction
-- ============================================================
local function WatchChar(p, char)
    if not char then return end
    local er  = char:FindFirstChild("HumanoidRootPart")
    local eh  = char:FindFirstChildWhichIsA("Humanoid")
    local uid = p.UserId
    local ps  = GetPS(uid)

    local function onAttr(obj, attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not Parry.on or IsSelfAttacking() then return end
                local v = obj:GetAttribute(attr)
                if not (v == true or (type(v) == "string" and
                    (v:lower():find("attack") or v:lower():find("heavy")))) then return end
                er = char:FindFirstChild("HumanoidRootPart")
                if not er or not MC.root then return end
                if Dist(MC.root, er) > 22 then return end
                if IsFromBack(er) then return end
                local isHvy = IsHeavyAttr(attr)
                if isHvy then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = os.clock() + 3
                    if not ps.m2Detected or os.clock() >= ps.m2DetectedExp then
                        ps.m2Detected    = true
                        ps.m2DetectedExp = os.clock() + 2
                        UpdateCombo(ps, uid, true, attr)
                        SafeFireInstant(true); return
                    end
                end
                UpdateCombo(ps, uid, isHvy, attr)
                FireParry(isHvy, ps, "normal", nil)
            end)
        end)
    end

    for _, a in ipairs(ALL_ATTR) do
        onAttr(char, a)
        if eh then onAttr(eh, a) end
    end

    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not Parry.on or not track then return end
                if IsSelfAttacking() then return end
                local ok, n = pcall(function() return track.Animation.Name end)
                if not ok or not n then return end
                local isH = IsM2Anim(n); local isM = IsM1Anim(n)
                if not isH and not isM then return end
                er = char:FindFirstChild("HumanoidRootPart")
                if not er or not MC.root then return end
                if Dist(MC.root, er) > 22 then return end
                if IsFromBack(er) then return end
                local now = os.clock()
                local cK  = string.format("%d_%s", uid, n)
                if now - (ps.lastAnimFire[cK] or 0) < 0.14 then return end
                ps.lastAnimFire[cK] = now
                UpdateCombo(ps, uid, isH, n)
                if isH then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = now + 3
                    -- pass track for window prediction
                    SafeFireInstant(true)
                else
                    FireParry(false, ps, "normal", track)  -- precision first fire
                end
            end)
        end)
    end

    if eh then
        local an = eh:FindFirstChildOfClass("Animator")
        if an then watchAnim(an)
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
        ps.watched = false; CleanPS(p.UserId)
        task.wait(0.4); Watch(p)
    end)
end
local function WatchAll()
    for _, p in pairs(Players:GetPlayers()) do Watch(p) end
end
WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.3); Watch(p) end)

-- ============================================================
--  FX HOOKS — SafeFireInstant prevents duplicate fires
-- ============================================================
if ReactionFX then
    ReactionFX.OnClientEvent:Connect(function()
        MarkCombat()
        Parry.missCount = Parry.missCount + 1
        UpdateThreshold(true)
        local root = MC.root
        for _, p in pairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local er = p.Character:FindFirstChild("HumanoidRootPart")
                if er and root and Dist(root, er) <= 22 and not IsFromBack(er) then
                    local ps = GetPS(p.UserId)
                    UpdateCombo(ps, p.UserId, false, "ReactionFX")
                    if Lock.on or Lock.inCombat then
                        Lock.target = p; Lock.expireTime = os.clock() + 60
                    end
                end
            end
        end
        SafeFireInstant(false)
    end)
end

if HeavyPunchFX then
    HeavyPunchFX.OnClientEvent:Connect(function(attacker)
        MarkCombat()
        if attacker and attacker ~= LP then
            local ps = GetPS(attacker.UserId)
            if ps then ps.heavyAlert = true; ps.heavyAlertExp = os.clock() + 3 end
            if Lock.on or Lock.inCombat then
                Lock.target = attacker; Lock.expireTime = os.clock() + 60
            end
        end
        SafeFireInstant(true)
    end)
end

if HitRunFX then
    HitRunFX.OnClientEvent:Connect(function()
        MarkCombat(); SafeFireInstant(false)
    end)
end

if KickComboFX then
    KickComboFX.OnClientEvent:Connect(function()
        MarkCombat(); SafeFireInstant(true)
    end)
end

if CounterHitFX then
    CounterHitFX.OnClientEvent:Connect(function()
        MarkCombat(); SafeFireInstant(false)
    end)
end

if GuardBreakFX then
    GuardBreakFX.OnClientEvent:Connect(function()
        Parry.nextFire = 0; Parry.firing = false; spamLock = false
    end)
end

if ParryFX then
    ParryFX.OnClientEvent:Connect(function()
        MarkCombat()
        Parry.parryCount = Parry.parryCount + 1
        UpdateThreshold(false)
    end)
end

-- ============================================================
--  SMART LOCK — score-based target with hysteresis
-- ============================================================
local function LockBlocked()
    local c = LP.Character; if not c then return true end
    for _, s in ipairs(LOCK_BLOCKED) do
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
    return MC.root and Dist(MC.root, r) <= 38
end

local function DestroyConstraint()
    pcall(function()
        if Lock.alignOri then Lock.alignOri:Destroy(); Lock.alignOri = nil end
        if Lock.att0     then Lock.att0:Destroy();     Lock.att0     = nil end
    end)
end

local function SetupConstraint()
    local root = MC.root; if not root then return end
    if Lock.alignOri and Lock.alignOri.Parent == root then return end
    DestroyConstraint()
    local att = Instance.new("Attachment")
    att.Name = ATT_NAME; att.Parent = root; Lock.att0 = att
    local ao = Instance.new("AlignOrientation")
    ao.Name               = AO_NAME
    ao.Mode               = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0        = att
    ao.MaxTorque          = 1e6
    ao.MaxAngularVelocity = math.huge
    ao.Responsiveness     = 42
    ao.RigidityEnabled    = false
    ao.PrimaryAxisOnly    = false
    ao.Parent             = root
    Lock.alignOri         = ao
end

-- Score-based target selection (uses parry Score system)
local function GetBestTarget(range)
    local root = MC.root; if not root then return nil end
    range = range or 38
    local best, bestScore = nil, -1
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local c = p.Character; if not c then continue end
            local r = c:FindFirstChild("HumanoidRootPart")
            local h = c:FindFirstChild("Humanoid")
            if not r or not h or h.Health <= 0 then continue end
            local d = Dist(root, r)
            if d > range then continue end
            local ps = GetPS(p.UserId)
            local sc, _ = Score(p, ps)
            -- slight distance decay so equal-scored targets prefer closer
            local effective = sc - d * 0.25
            if effective > bestScore then bestScore = effective; best = p end
        end
    end
    return best
end

-- Hysteresis: only switch if new target meaningfully outscores current
local function ShouldSwitch(newTarget)
    if not Lock.target or not ValidTarget(Lock.target) then return true end
    if newTarget == Lock.target then return false end
    local curPs = GetPS(Lock.target.UserId)
    local curSc, _ = Score(Lock.target, curPs)
    local newPs = GetPS(newTarget.UserId)
    local newSc, _ = Score(newTarget, newPs)
    return (newSc - curSc) > LOCK_SWITCH_HYSTERESIS
end

local function SetAimDir(pos)
    if not Lock.alignOri or LockBlocked() then return end
    local root = MC.root; if not root then return end
    local dir = pos - root.Position
    dir = Vector3.new(dir.X, dir.Y * 0.1, dir.Z)
    if dir.Magnitude < 0.05 then return end
    dir = dir.Unit
    local up    = Vector3.new(0, 1, 0)
    local right = dir:Cross(up)
    if right.Magnitude < 0.01 then return end
    right = right.Unit
    Lock.alignOri.CFrame = CFrame.fromMatrix(Vector3.zero, right, right:Cross(dir).Unit)
end

local function AutoLock(target)
    if not target then return end
    local isNew = (target ~= Lock.target)
    Lock.target     = target
    Lock.expireTime = os.clock() + 60
    if isNew then SetupConstraint() end
end

-- Hook self-attacks for combat mark + auto lock re-acquisition
local function HookSelf(char)
    if not char then return end
    local hum = char:FindFirstChildWhichIsA("Humanoid")
    for _, attr in ipairs(SELF_ATKS) do
        pcall(function()
            char:GetAttributeChangedSignal(attr):Connect(function()
                if char:GetAttribute(attr) == true then
                    MarkCombat()
                    if Lock.on and (not Lock.target or not ValidTarget(Lock.target)) then
                        local best = GetBestTarget()
                        if best then AutoLock(best) end
                    end
                end
            end)
        end)
    end
    if hum then
        local prevHP = hum.Health
        hum:GetPropertyChangedSignal("Health"):Connect(function()
            if hum.Health < prevHP then
                MarkCombat()
                if Lock.on and (not Lock.target or not ValidTarget(Lock.target)) then
                    local best = GetBestTarget()
                    if best then AutoLock(best) end
                end
            end
            prevHP = hum.Health
        end)
    end
end

LP.CharacterAdded:Connect(function(c) task.wait(0.3); HookSelf(c) end)
if LP.Character then HookSelf(LP.Character) end

-- ============================================================
--  LOCK HEARTBEAT — target logic
-- ============================================================
local CAM_LERP_SPEED = 9  -- camera CFrame lerp factor (units/sec)

RunService.Heartbeat:Connect(function(dt)
    if Camera.CameraType ~= Enum.CameraType.Custom then
        Camera.CameraType = Enum.CameraType.Custom
    end

    CheckNeutral()

    local active = Lock.on or Lock.inCombat
    if not active then
        if Lock.target then DestroyConstraint(); Lock.target = nil end
        return
    end

    if Lock.target and os.clock() > Lock.expireTime then
        Lock.target = nil; DestroyConstraint(); return
    end
    if Lock.target and not ValidTarget(Lock.target) then
        Lock.target = nil; DestroyConstraint(); return
    end

    -- periodic best-target check with hysteresis
    local best = GetBestTarget()
    if best and ShouldSwitch(best) then AutoLock(best) end
    if not Lock.target and best then AutoLock(best); return end
    if not Lock.target then return end

    local ec = Lock.target.Character; if not ec then return end
    local er = ec:FindFirstChild("HumanoidRootPart"); if not er then return end

    -- Kalman update
    local ps = GetPS(Lock.target.UserId)
    KalmanUpdate(ps, er.Position, os.clock())

    -- predict ahead by half ping (compensation for camera lag)
    local ahead = math.clamp(Ping:get() / 1000 * 0.5, 0, 0.15)
    local pred  = KalmanPredict(ps, ahead) or er.Position
    local aimPt = Vector3.new(pred.X, pred.Y + 1.4, pred.Z)

    -- AlignOrientation (character body aim)
    SetAimDir(aimPt)

    -- smooth camera CFrame lerp toward predicted aim point
    if not LockBlocked() then
        local camPos  = Camera.CFrame.Position
        local targetCF = CFrame.lookAt(camPos, aimPt)
        local alpha    = math.clamp(CAM_LERP_SPEED * dt, 0, 1)
        pcall(function()
            Camera.CFrame = Camera.CFrame:Lerp(targetCF, alpha)
        end)
    end
end)

Players.PlayerRemoving:Connect(function(p)
    if Lock.target == p then Lock.target = nil; DestroyConstraint() end
end)

-- ============================================================
--  RESPAWN CLEANUP
-- ============================================================
LP.CharacterAdded:Connect(function()
    RefreshChar()
    Parry.nextFire = 0; Parry.firing = false; Parry.firingAt = 0
    Parry.lastHB = 0; spamLock = false; Parry.consecMiss = 0
    Parry.dynThreshold = 8.0
    lastInstantT = 0
    for uid in pairs(PS) do PS[uid] = nil end
    Lock.target = nil; Lock.inCombat = false; Lock.combatTime = 0
    DestroyConstraint()
    task.wait(0.7); WatchAll()
    task.wait(0.1)
    if Lock.on then SetupConstraint() end
    Decoy:schedule()
end)

-- ============================================================
--  UI
-- ============================================================
local old = PGui:FindFirstChild("HSA_UI_v5")
if old then old:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name = "HSA_UI_v5"; SG.ResetOnSpawn = false
SG.IgnoreGuiInset = true; SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.Parent = PGui

local Panel = Instance.new("Frame")
Panel.Name = "Panel"; Panel.Size = UDim2.new(0, 200, 0, 308)
Panel.Position = UDim2.new(0, 16, 0.5, -154)
Panel.BackgroundColor3 = Color3.fromRGB(8, 8, 8)
Panel.BackgroundTransparency = 0.07; Panel.BorderSizePixel = 0
Panel.Active = true; Panel.Parent = SG
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 10)

local PStroke = Instance.new("UIStroke", Panel)
PStroke.Thickness = 1.5; PStroke.Color = Color3.fromRGB(55, 55, 55)

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 30)
Header.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
Header.BorderSizePixel = 0; Header.Parent = Panel
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local HFix = Instance.new("Frame")
HFix.Size = UDim2.new(1, 0, 0.5, 0); HFix.Position = UDim2.new(0, 0, 0.5, 0)
HFix.BackgroundColor3 = Color3.fromRGB(18, 18, 18); HFix.BorderSizePixel = 0; HFix.Parent = Header

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Text = "⚔️ HSA v5 APEX"; TitleLbl.Size = UDim2.new(1, -36, 1, 0)
TitleLbl.Position = UDim2.new(0, 10, 0, 0); TitleLbl.BackgroundTransparency = 1
TitleLbl.TextColor3 = Color3.fromRGB(220, 220, 220); TitleLbl.TextSize = 11
TitleLbl.Font = Enum.Font.GothamBold
TitleLbl.TextXAlignment = Enum.TextXAlignment.Left; TitleLbl.Parent = Header

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 22, 0, 22); CloseBtn.Position = UDim2.new(1, -26, 0.5, -11)
CloseBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35); CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(160, 160, 160); CloseBtn.TextSize = 11
CloseBtn.Font = Enum.Font.GothamBold; CloseBtn.BorderSizePixel = 0; CloseBtn.Parent = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 5)

local function MkLbl(txt, y, col)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -16, 0, 14); l.Position = UDim2.new(0, 8, 0, y)
    l.BackgroundTransparency = 1
    l.TextColor3 = col or Color3.fromRGB(90, 90, 90)
    l.TextSize = 10; l.Font = Enum.Font.Gotham
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = txt; l.Parent = Panel; return l
end

local function MkBtn(txt, y, col)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 30); b.Position = UDim2.new(0, 8, 0, y)
    b.BackgroundColor3 = col or Color3.fromRGB(40, 40, 40)
    b.TextColor3 = Color3.fromRGB(255, 255, 255); b.TextSize = 12
    b.Font = Enum.Font.GothamBold; b.Text = txt; b.BorderSizePixel = 0; b.Parent = Panel
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7); return b
end

MkLbl("— AUTO PARRY —", 36)
local ParryBtn = MkBtn("⚔ PARRY: OFF", 52, Color3.fromRGB(170, 30, 30))
MkLbl("— SMART LOCK —", 92)
local LockBtn  = MkBtn("🔒 LOCK: OFF", 108, Color3.fromRGB(170, 30, 30))

local AdaptLbl  = MkLbl("FPS:- | Ping:-ms | Fires:- | Cap:-", 148, Color3.fromRGB(60, 140, 220))
local KalmanLbl = MkLbl("Kalman: inactive", 162, Color3.fromRGB(80, 100, 140))

local TargetLbl = Instance.new("TextLabel")
TargetLbl.Size = UDim2.new(1, -16, 0, 15); TargetLbl.Position = UDim2.new(0, 8, 0, 180)
TargetLbl.BackgroundTransparency = 1; TargetLbl.TextColor3 = Color3.fromRGB(255, 195, 70)
TargetLbl.TextSize = 10; TargetLbl.Font = Enum.Font.Gotham
TargetLbl.TextXAlignment = Enum.TextXAlignment.Left; TargetLbl.Text = "Target: -"
TargetLbl.TextTruncate = Enum.TextTruncate.AtEnd; TargetLbl.Parent = Panel

local InfoLbl   = MkLbl("Dist: - | HP: -", 196, Color3.fromRGB(100, 100, 100))
local StateLbl  = MkLbl("State: Neutral", 212, Color3.fromRGB(70, 170, 70))
local StatsLbl  = MkLbl("Parry:0 Miss:0 CPS:0", 228, Color3.fromRGB(65, 65, 65))
local ThreshLbl = MkLbl("Thresh:8.0 | Decoy: armed", 244, Color3.fromRGB(60, 60, 60))

local BarBG = Instance.new("Frame")
BarBG.Size = UDim2.new(1, -16, 0, 6); BarBG.Position = UDim2.new(0, 8, 0, 262)
BarBG.BackgroundColor3 = Color3.fromRGB(30, 30, 30); BarBG.BorderSizePixel = 0
BarBG.Parent = Panel; Instance.new("UICorner", BarBG).CornerRadius = UDim.new(0, 3)

local BarFill = Instance.new("Frame")
BarFill.Size = UDim2.new(0, 0, 1, 0); BarFill.BackgroundColor3 = Color3.fromRGB(30, 160, 65)
BarFill.BorderSizePixel = 0; BarFill.Parent = BarBG
Instance.new("UICorner", BarFill).CornerRadius = UDim.new(0, 3)

local ReopenBtn = Instance.new("TextButton")
ReopenBtn.Size = UDim2.new(0, 38, 0, 38); ReopenBtn.Position = Panel.Position
ReopenBtn.BackgroundColor3 = Color3.fromRGB(12, 12, 12); ReopenBtn.Text = "⚔️"
ReopenBtn.TextColor3 = Color3.fromRGB(255, 255, 255); ReopenBtn.TextSize = 18
ReopenBtn.Font = Enum.Font.GothamBold; ReopenBtn.BorderSizePixel = 0
ReopenBtn.Visible = false; ReopenBtn.Active = true; ReopenBtn.Parent = SG
Instance.new("UICorner", ReopenBtn).CornerRadius = UDim.new(0, 8)
local RStroke = Instance.new("UIStroke", ReopenBtn)
RStroke.Thickness = 1.5; RStroke.Color = Color3.fromRGB(55, 55, 55)

-- ============================================================
--  UI UPDATE
-- ============================================================
local UILast = 0
local function UpdateUI()
    ParryBtn.BackgroundColor3 = Parry.on
        and Color3.fromRGB(28, 155, 60) or Color3.fromRGB(170, 30, 30)
    ParryBtn.Text = Parry.on and "⚔ PARRY: ON" or "⚔ PARRY: OFF"

    LockBtn.BackgroundColor3 = Lock.on
        and Color3.fromRGB(28, 115, 195) or Color3.fromRGB(75, 75, 75)
    LockBtn.Text = Lock.on and "🔒 LOCK: ON" or "🔒 LOCK: OFF"

    local sc
    if Parry.on and Lock.on    then sc = Color3.fromRGB(0, 215, 175)
    elseif Lock.on             then sc = Color3.fromRGB(28, 115, 195)
    elseif Parry.on            then sc = Color3.fromRGB(28, 155, 60)
    else                            sc = Color3.fromRGB(55, 55, 55) end
    PStroke.Color = sc; RStroke.Color = sc

    local timing = Adaptive:compute()
    AdaptLbl.Text = string.format("FPS:%d | Ping:%dms | Fires:%d | Cap:%d",
        FPS.current, math.floor(Ping:get()), timing.spamCount, DynRL:cap())

    -- Kalman state
    if Lock.target and Lock.target.Character then
        local ps = GetPS(Lock.target.UserId)
        if ps.kalmanPos then
            local spd = ps.kalmanVel.Magnitude
            KalmanLbl.Text = string.format("Kalman: spd=%.1f", spd)
            KalmanLbl.TextColor3 = Color3.fromRGB(60, 180, 255)
        else
            KalmanLbl.Text = "Kalman: calibrating"
            KalmanLbl.TextColor3 = Color3.fromRGB(80, 100, 140)
        end
    else
        KalmanLbl.Text = "Kalman: inactive"
        KalmanLbl.TextColor3 = Color3.fromRGB(80, 100, 140)
    end

    if Lock.inCombat then
        StateLbl.TextColor3 = Color3.fromRGB(255, 90, 90)
        StateLbl.Text = "State: ⚔ COMBAT"
    else
        StateLbl.TextColor3 = Color3.fromRGB(70, 170, 70)
        StateLbl.Text = "State: Neutral"
    end

    if Lock.target and Lock.target.Character then
        local ec  = Lock.target.Character
        local er  = ec:FindFirstChild("HumanoidRootPart")
        local eh  = ec:FindFirstChild("Humanoid")
        local myR = MC.root
        local dist = (er and myR) and math.floor(Dist(myR, er)) or 0
        local hp   = eh and math.floor(eh.Health) or 0
        local mhp  = eh and math.floor(eh.MaxHealth) or 0
        TargetLbl.Text = "🎯 " .. Lock.target.Name
        InfoLbl.Text   = string.format("Dist:%d | HP:%d/%d", dist, hp, mhp)
    else
        TargetLbl.Text = "Target: -"; InfoLbl.Text = "Dist: - | HP: -"
    end

    StatsLbl.Text = string.format("Parry:%d Miss:%d CPS:%d/%d",
        Parry.parryCount, Parry.missCount, RL:count(), DynRL:cap())

    ThreshLbl.Text = string.format("Thresh:%.1f | Decoy: %s",
        Parry.dynThreshold,
        os.clock() < Decoy.nextT and "armed" or "ready")

    local pct = math.clamp(RL:count() / DynRL:cap(), 0, 1)
    BarFill.Size = UDim2.new(pct, 0, 1, 0)
    BarFill.BackgroundColor3 = pct > 0.75
        and Color3.fromRGB(220, 60, 60)
        or  pct > 0.5
        and Color3.fromRGB(220, 160, 30)
        or  Color3.fromRGB(30, 160, 65)
end

RunService.RenderStepped:Connect(function()
    if not Panel.Visible then return end
    local now = os.clock()
    if now - UILast < 0.28 then return end
    UILast = now; UpdateUI()
end)

-- ============================================================
--  BUTTONS + KEYS
-- ============================================================
local function Pop(btn)
    TweenService:Create(btn, TweenInfo.new(0.06), {Size=UDim2.new(1,-22,0,26)}):Play()
    task.wait(0.06)
    TweenService:Create(btn, TweenInfo.new(0.06), {Size=UDim2.new(1,-16,0,30)}):Play()
end

ParryBtn.MouseButton1Click:Connect(function()
    Parry.on = not Parry.on
    Parry.nextFire = 0; Parry.firing = false; spamLock = false
    lastInstantT = 0
    Pop(ParryBtn); UpdateUI()
end)

LockBtn.MouseButton1Click:Connect(function()
    Lock.on = not Lock.on
    if not Lock.on then Lock.target=nil; Lock.inCombat=false; DestroyConstraint() end
    Pop(LockBtn); UpdateUI()
end)

UIS.InputBegan:Connect(function(i, g)
    if g then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        Parry.on = not Parry.on
        Parry.nextFire=0; Parry.firing=false; spamLock=false; lastInstantT=0; UpdateUI()
    end
    if i.KeyCode == Enum.KeyCode.RightControl then
        Lock.on = not Lock.on
        if not Lock.on then Lock.target=nil; Lock.inCombat=false; DestroyConstraint() end
        UpdateUI()
    end
end)

local savedPos = Panel.Position

CloseBtn.MouseButton1Click:Connect(function()
    savedPos = Panel.Position
    TweenService:Create(Panel, TweenInfo.new(0.12,Enum.EasingStyle.Quad,Enum.EasingDirection.In),
        {Size=UDim2.new(0,0,0,0), Position=UDim2.new(
            savedPos.X.Scale, savedPos.X.Offset+100,
            savedPos.Y.Scale, savedPos.Y.Offset+154)}):Play()
    task.wait(0.13)
    Panel.Visible=false; Panel.Size=UDim2.new(0,200,0,308); Panel.Position=savedPos
    ReopenBtn.Visible=true; ReopenBtn.Position=savedPos
end)

ReopenBtn.MouseButton1Click:Connect(function()
    Panel.Position=savedPos; Panel.Visible=true; Panel.Size=UDim2.new(0,0,0,0)
    ReopenBtn.Visible=false
    TweenService:Create(Panel, TweenInfo.new(0.12,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),
        {Size=UDim2.new(0,200,0,308)}):Play()
end)

local function MkDrag(handle, target)
    local drag, ds, sp = false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.Touch
        or i.UserInputType==Enum.UserInputType.MouseButton1 then
            drag=true; ds=i.Position; sp=target.Position
            i.Changed:Connect(function()
                if i.UserInputState==Enum.UserInputState.End then drag=false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if not drag then return end
        if i.UserInputType==Enum.UserInputType.MouseMovement
        or i.UserInputType==Enum.UserInputType.Touch then
            local d=i.Position-ds
            target.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then
            drag=false
            if target==Panel then savedPos=Panel.Position end
        end
    end)
end

MkDrag(Header, Panel)
MkDrag(ReopenBtn, ReopenBtn)

UpdateUI()
print(string.format(
    "[HSA v5 APEX] Loaded | FPS:%d Ping:%dms | Cap:%d | RShift=Parry RCtrl=Lock",
    FPS.current, math.floor(Ping:get()), DynRL:cap()))
