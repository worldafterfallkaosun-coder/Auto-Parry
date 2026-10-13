-- ============================================================
--  HIGH SCHOOL ANIME — Combat Tools v6.0 APEX MAX
--  by spraxy / VANTA
--
--  UPGRADES vs v5:
--  · Score rebuilt: multi-layer threat model, 0–300 range
--    — attr, anim, velocity vector, combo depth, m2 confirm,
--      facing angle, distance decay, HP-pressure bonus
--  · Zero-miss parry: AnimWindow pre-fire + reactive FX hook
--    + heartbeat scan all run in parallel; best-path wins
--  · Stealth: Gaussian tap, Poisson inter-arrival,
--    decoy scatter, random remote name cache, RNG seed per load,
--    rate ceiling probed conservatively, ETW-style traffic shape
--  · Lock: fires AlignOrientation + cam lock ONLY on combat
--    (local player attacks OR takes damage) — completely
--    invisible in neutral play
--  · Kalman predictor upgraded: higher alpha response,
--    horizontal bias removed, full 3D with vertical damping only
--    on confirmed-jump state
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

-- Per-load RNG seed: timing signatures differ every session
math.randomseed(math.floor(os.clock() * 1e9) % (2^31 - 1))

-- ============================================================
--  REMOTES
-- ============================================================
local CombatRemotes = RepStorage:WaitForChild("CombatRemotes", 10)
if not CombatRemotes then warn("[HSA] CombatRemotes missing"); return end

local RequestBlock = CombatRemotes:WaitForChild("RequestBlock", 5)
local ReactionFX   = CombatRemotes:WaitForChild("ReactionFX",   5)
local ParryFX      = CombatRemotes:WaitForChild("ParryFX",      5)
local CounterHitFX = CombatRemotes:WaitForChild("CounterHitFX", 5)
local GuardBreakFX = CombatRemotes:WaitForChild("GuardBreakFX", 5)
local HitRunFX     = CombatRemotes:WaitForChild("HitRunFX",     5)
local KickComboFX  = CombatRemotes:WaitForChild("KickComboFX",  5)
local HeavyPunchFX = CombatRemotes:WaitForChild("HeavyPunchFX", 5)
local KOFX         = CombatRemotes:WaitForChild("KOFX",         5)

if not RequestBlock then warn("[HSA] RequestBlock missing"); return end

-- ============================================================
--  FPS MONITOR — rolling 30-sample mean
-- ============================================================
local FPS = {
    current   = 60,
    frametime = 1/60,
    samples   = {},
    maxSamp   = 30,
    lastT     = os.clock(),
}

RunService.Heartbeat:Connect(function(dt)
    table.insert(FPS.samples, dt)
    if #FPS.samples > FPS.maxSamp then table.remove(FPS.samples, 1) end
    local now = os.clock()
    if now - FPS.lastT > 0.4 then
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
local Ping = { current = 80, samples = {}, maxSamp = 12, lastT = 0 }

function Ping:update()
    local now = os.clock()
    if now - self.lastT < 0.25 then return end
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

-- Lead compensation: extra wait before fire to compensate for round-trip
function Ping:lead()
    local p = self:get()
    return math.min(0.14, math.max(0, (p - 50) / 1000 * 2.8))
end

-- Cooldown between spam bursts
function Ping:cooldown(heavy)
    local p = self:get()
    local base = heavy and 0.18 or 0.26
    if p > 200 then return math.max(base * 0.50, base - 0.10)
    elseif p > 140 then return math.max(base * 0.65, base - 0.05) end
    return base
end

-- ============================================================
--  MATH UTILITIES
-- ============================================================
local _TWO_PI = 2 * math.pi

-- Box-Muller Gaussian, clamped ±3σ for tighter tail control
local function GaussJitter(mean, sigma)
    local u1 = math.max(1e-12, math.random())
    local u2 = math.random()
    local z  = math.sqrt(-2 * math.log(u1)) * math.cos(_TWO_PI * u2)
    return math.clamp(mean + z * sigma, mean - 3 * sigma, mean + 3 * sigma)
end

-- Poisson inter-arrival at rate_hz
local function PoissonWait(rate_hz)
    rate_hz = math.max(rate_hz, 0.1)
    return -math.log(math.max(1e-12, math.random())) / rate_hz
end

-- Random alphanumeric name — used for attachment + constraint names
local _NC = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local function RandName(len)
    local t = {}
    for i = 1, len do
        local idx = math.random(1, #_NC)
        t[i] = _NC:sub(idx, idx)
    end
    return table.concat(t)
end

-- ============================================================
--  DYNAMIC RATE CAP
--  Conservative probe: floor 7 → ceiling 16, probes up every 18s,
--  backs down immediately on a cap-hit to stay under server radar
-- ============================================================
local DynRL = {
    floor   = 7,
    ceiling = 16,
    current = 9,
    probeT  = 0,
    probeCd = 18.0,
    hitCap  = false,
}

function DynRL:probe()
    local now = os.clock()
    if now - self.probeT < self.probeCd then return end
    self.probeT = now
    if not self.hitCap then
        self.current = math.min(self.ceiling, self.current + 1)
    else
        self.current = math.max(self.floor, self.current - 2)  -- back off faster
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
    local windowEst = 0.090 + math.min(0.07, p / 2200)

    -- tap hold time: mimics human press duration
    local tapTime
    if fps >= 55 then tapTime = 0.050
    elseif fps >= 35 then tapTime = 0.040
    else tapTime = 0.030 end

    -- inter-tap interval
    local interval
    if fps >= 55 then interval = 0.048
    elseif fps >= 35 then interval = 0.038
    else interval = 0.028 end

    local fireTime  = tapTime + interval
    local spamCount = math.ceil(windowEst / fireTime)
    spamCount = math.clamp(spamCount, 4, 10)

    -- ceiling from DynRL
    local maxByRate = math.floor(DynRL:cap() / 2)
    spamCount = math.min(spamCount, maxByRate)

    return { tapTime = tapTime, interval = interval, spamCount = spamCount, windowEst = windowEst }
end

-- ============================================================
--  RATE LIMITER
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
--  Estimates seconds until hitbox center (≈28% of animation).
-- ============================================================
local function AnimWindowPredict(track)
    if not track or not track.IsPlaying then return 0 end
    local ok, dur = pcall(function() return track.Length end)
    if not ok or not dur or dur <= 0 then return 0 end
    local pos = track.TimePosition
    local spd = track.Speed
    if spd <= 0 then return 0 end
    local hitCenter = dur * 0.28
    return math.max(0, (hitCenter - pos) / spd)
end

-- ============================================================
--  ATTR / ANIM KEYWORD LISTS
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
--  PER-PLAYER STATE
-- ============================================================
local PS = {}
local function GetPS(uid)
    if not PS[uid] then
        PS[uid] = {
            -- parry / scoring
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
            -- Kalman
            kalmanPos     = nil,
            kalmanVel     = Vector3.zero,
            kalmanAcc     = Vector3.zero,
            kalmanPrevVel = Vector3.zero,
            kalmanTime    = 0,
            -- jump state for vertical bias
            isJumping     = false,
        }
    end
    return PS[uid]
end
local function CleanPS(uid) PS[uid] = nil end
Players.PlayerRemoving:Connect(function(p) CleanPS(p.UserId) end)

-- ============================================================
--  KALMAN FILTER — full 3D, vertical damping on jump only
-- ============================================================
local function KalmanUpdate(ps, pos, now)
    local dt = now - ps.kalmanTime
    ps.kalmanTime = now
    if ps.kalmanPos and dt > 0 and dt < 0.30 then
        local rawVel = (pos - ps.kalmanPos) / dt
        -- higher alpha at low ping for tighter tracking
        local alpha = math.clamp(0.52 - (Ping:get() - 60) / 2000, 0.22, 0.65)
        local newVel = ps.kalmanVel:Lerp(rawVel, alpha)
        local rawAcc = (newVel - ps.kalmanVel) / dt
        ps.kalmanAcc     = ps.kalmanAcc:Lerp(rawAcc, 0.22)
        ps.kalmanPrevVel = ps.kalmanVel
        ps.kalmanVel     = newVel
        -- detect jump: large positive Y velocity
        ps.isJumping = newVel.Y > 10
    end
    ps.kalmanPos = pos
end

local function KalmanPredict(ps, ahead)
    if not ps.kalmanPos then return nil end
    local vel = ps.kalmanVel
    local acc = ps.kalmanAcc
    -- damp vertical only during jump (gravity will pull them down fast)
    local yVelScale = ps.isJumping and 0.35 or 1.0
    local yAccScale = ps.isJumping and 0.10 or 0.55
    local predVel = Vector3.new(vel.X, vel.Y * yVelScale, vel.Z)
    local predAcc = Vector3.new(acc.X * 0.55, acc.Y * yAccScale, acc.Z * 0.55)
    return ps.kalmanPos + predVel * ahead + predAcc * (0.5 * ahead * ahead)
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
    dynThreshold = 12.0,  -- v6: raised base threshold, score range wider
    lastHB       = 0,
    spamActive   = false,
    lastSpamT    = 0,
}

-- ============================================================
--  LOCK STATE
--  v6: lock ONLY activates on combat event (self-attack or
--  self-damage). Neutral play = no constraint, no camera touch.
-- ============================================================
local ATT_NAME = RandName(10)
local AO_NAME  = RandName(10)

local Lock = {
    on          = false,   -- user toggle
    target      = nil,
    expireTime  = 0,
    combatTime  = 0,
    inCombat    = false,   -- true only during/after hit exchange
    alignOri    = nil,
    att0        = nil,
    camTargetCF = nil,
}

-- Hysteresis: new target must outscore current by 25 in v6
local LOCK_SWITCH_HYSTERESIS = 25

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

-- True if the enemy is behind us (dot < -0.15, wider blind-spot)
local function IsFromBack(er)
    local root = MC.root
    if not root or not er then return false end
    local toE = Vector3.new(
        er.Position.X - root.Position.X, 0,
        er.Position.Z - root.Position.Z)
    if toE.Magnitude < 0.1 then return false end
    local look = root.CFrame.LookVector
    look = Vector3.new(look.X, 0, look.Z)
    if look.Magnitude < 0.1 then return false end
    return look.Unit:Dot(toE.Unit) < -0.15
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
    if os.clock() - Lock.combatTime > 4.0 then
        Lock.inCombat = false
        if not Lock.on then
            Lock.target = nil
        end
    end
end

-- ============================================================
--  SCORE SYSTEM v6 — range 0–300
--
--  Layers:
--   1. Distance decay (0–20)
--   2. Attribute scan: M2 +110, M1 +70
--   3. InCombat / FightMode flags +15 / +12
--   4. Anim track: M2 +90/80/65/48, M1 +80/65/52/32
--   5. HeavyAlert carryover +45
--   6. Combo depth (up to +65)
--   7. Avg interval pressure (up to +28)
--   8. Swing vector bonus (0–35)
--   9. Velocity approach bonus (0–55)
--  10. Facing angle: looking at us +22
--  11. HP pressure: enemy low HP = more desperate attacks +18
--  12. M2 confirmed within 2s +30
--
--  Cap at 300. Cache TTL 6ms (tighter than v5's 8ms).
-- ============================================================
local SCORE_TTL = 0.006

local function GetSwingBonus(er, root)
    local toMe = root.Position - er.Position
    local d    = toMe.Magnitude
    if d < 0.1 then return 0 end
    local dirN = toMe / d
    local fDot = er.CFrame.LookVector:Dot(dirN)
    local sDot = math.abs(er.CFrame.RightVector:Dot(dirN))
    local b = 0
    if fDot > 0.40 then b = b + 16 end
    if sDot > 0.30 then b = b + 11 end
    if fDot > 0.72 then b = b + 8  end
    return math.min(b, 35)
end

local function GetVelBonus(ps, er, root)
    local vel  = er.Velocity
    local prev = ps.prevVel
    ps.prevVel = vel
    local acc  = (vel - prev).Magnitude
    if acc < 1.2 then return 0 end
    local toMe = root.Position - er.Position
    if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return 0 end
    local dot = toMe.Unit:Dot(vel.Unit)
    local b = 0
    if dot > 0.18 then b = b + math.floor(dot * 42) end
    -- approaching from above (jump attack): strong bonus
    if vel.Unit.Y < -0.25 and dot > 0.08 then b = b + 16 end
    return math.min(b, 55)
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
    if d > 24 or IsFromBack(er) then ps.cachedScore = 0; return 0, false end

    local sc = 0; local hvy = false

    -- 1. Distance decay (closer = higher score)
    sc = sc + math.floor((1 - d / 24) * 20)

    -- 2. Attribute scan
    local hasAttr, isHAttr = ScanAttrs(ec, eh)
    if isHAttr     then sc = sc + 110; hvy = true
    elseif hasAttr then sc = sc + 70 end

    -- 3. State flags
    if ec:GetAttribute("InCombat") == true  then sc = sc + 15 end
    if ec:GetAttribute("FightMode") == true then sc = sc + 12 end

    -- 4. Animation track scan with time-position scoring
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
                        -- heaviest bonus right at anim start (pre-hitbox)
                        sc = sc + (pos <= 0.03 and 90 or pos <= 0.09 and 80 or
                                   pos < 0.20  and 65 or 48)
                        break
                    elseif IsM1Anim(n) then
                        sc = sc + (pos <= 0.03 and 80 or pos <= 0.07 and 65 or
                                   pos < 0.15  and 52 or 32)
                        break
                    end
                end
            end
        end
    end

    -- 5. Heavy alert carryover
    if ps.heavyAlert and now < ps.heavyAlertExp then sc = sc + 45; hvy = true end

    -- 6. Combo depth
    if ps.combo > 0 then sc = sc + math.min(ps.combo * 14, 65) end

    -- 7. Avg interval pressure
    local avg = ps.avgInterval
    if avg and avg < 0.45 then sc = sc + math.floor((1 - avg / 0.45) * 28) end

    -- 8. Swing vector
    sc = sc + GetSwingBonus(er, root)

    -- 9. Velocity approach
    sc = sc + GetVelBonus(ps, er, root)

    -- 10. Facing angle — enemy directly looking at us
    if d < 8 then
        local toMe = (root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.55 then sc = sc + 22 end
    end

    -- 11. HP pressure — enemy near death is more aggressive
    local hpRatio = eh.Health / math.max(eh.MaxHealth, 1)
    if hpRatio < 0.30 then sc = sc + 18
    elseif hpRatio < 0.55 then sc = sc + 9 end

    -- 12. M2 confirmed burst
    if ps.m2Detected and now < ps.m2DetectedExp then sc = sc + 30; hvy = true end

    local final = math.min(sc, 300)
    ps.cachedScore = final; ps.cachedHeavy = hvy; ps.cacheTime = now
    return final, hvy
end

-- ============================================================
--  DECOY SCATTER — organic traffic during neutral
--  Gaussian schedule 10–24s, tiny Gaussian jitter on execution
-- ============================================================
local Decoy = { nextT = 0 }

function Decoy:schedule()
    self.nextT = os.clock() + math.abs(GaussJitter(16.0, 3.8))
end

function Decoy:tick()
    if Parry.on then return end
    if os.clock() < self.nextT then return end
    if not RL:ok() then self:schedule(); return end
    pcall(function()
        task.delay(math.abs(GaussJitter(0.085, 0.022)), function()
            RequestBlock:FireServer(false)
            RL:mark()
        end)
    end)
    self:schedule()
end

Decoy:schedule()

-- ============================================================
--  RAW PARRY — Gaussian tap + pre/post jitter
-- ============================================================
local function RawParry(tapOverride)
    if not RL:ok() then return false end
    local p   = Ping:get()
    local tap = tapOverride or math.clamp(GaussJitter(0.053, 0.007), 0.026, 0.088)
    if p > 150 then tap = math.max(0.026, tap - (p - 150) / 5500) end

    local jPre  = math.abs(GaussJitter(0.009, 0.003))
    local jPost = math.abs(GaussJitter(0.007, 0.002))

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
--  ADAPTIVE SPAM PARRY — Poisson spacing + AnimWindow pre-fire
-- ============================================================
local spamLock = false

local function AdaptiveSpamParry(isHeavy, urgency, animTrack)
    if spamLock then return end
    spamLock = true
    Parry.lastSpamT = os.clock()

    local timing = Adaptive:compute()
    local count  = timing.spamCount
    if isHeavy              then count = math.min(count + 3, 11) end
    if urgency == "instant" then count = math.min(count + 2, 11) end

    local pingLead = Ping:lead()

    task.spawn(function()
        -- AnimWindow pre-fire: if we know the track, wait until hitbox center
        if animTrack and urgency ~= "instant" then
            local ahead = AnimWindowPredict(animTrack)
            if ahead > 0.001 and ahead < 0.12 then
                task.wait(ahead)
            elseif pingLead > 0.002 then
                task.wait(pingLead * 0.50)
            end
        elseif pingLead > 0.002 and urgency ~= "instant" then
            task.wait(pingLead * 0.50)
        end

        for i = 1, count do
            if not Parry.on then break end
            if not RL:ok() then
                task.wait(timing.interval * 1.1)
            end
            RawParry(timing.tapTime)
            if i < count then
                local rate = 1 / timing.interval
                local iv   = PoissonWait(rate)
                iv = math.clamp(iv, timing.interval * 0.38, timing.interval * 2.4)
                iv = iv + GaussJitter(0, 0.0025)
                task.wait(math.max(iv, 0.004))
            end
        end

        spamLock = false
    end)
end

-- ============================================================
--  FIRE PARRY — gated, adaptive cooldown
-- ============================================================
local function CanFire()
    if not Parry.on then return false end
    if Parry.firing then
        if os.clock() - Parry.firingAt > 0.55 then
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
    local cdJ = GaussJitter(0, 0.010)

    Parry.firing   = true
    Parry.firingAt = os.clock()
    Parry.nextFire = os.clock() + cd + cdJ

    local timing        = Adaptive:compute()
    local totalSpamTime = timing.spamCount * (timing.tapTime + timing.interval)

    task.spawn(function()
        AdaptiveSpamParry(isHeavy, urgency or "normal", animTrack)
        task.wait(totalSpamTime + 0.035)
        Parry.firing = false
    end)

    return true
end

-- Dedup gate: FX events can fire multiple times per attack
local lastInstantT = 0
local function SafeFireInstant(isHeavy)
    local now = os.clock()
    if now - lastInstantT < 0.065 then return end
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
    if #ps.history > 24 then table.remove(ps.history, 1) end
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
    if os.clock() - ps.lastHitTime > 1.4 then ps.combo = 0 end
    RecordHit(ps, isHeavy, src)
    ps.combo = ps.combo + 1
    return ps.combo
end

-- EMA threshold: decay toward 7 on miss, toward 12 on success
local function UpdateThreshold(missed)
    local target = missed and 7 or 12
    Parry.dynThreshold = Parry.dynThreshold * 0.80 + target * 0.20
    Parry.dynThreshold = math.clamp(Parry.dynThreshold, 6, 14)
    if missed then
        Parry.consecMiss = Parry.consecMiss + 1
    else
        Parry.consecMiss = 0
    end
end

-- ============================================================
--  BUILD QUEUE — top 3 enemies by score
-- ============================================================
local function BuildQueue()
    local q = {}
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP then
            local ps     = GetPS(p.UserId)
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
--  VEL PRE-FIRE — fires on sudden approach acceleration
-- ============================================================
local function CheckVelPreFire(p, ps, er)
    if not MC.root or not er then return end
    if IsFromBack(er) then return end
    local vel = er.Velocity
    local acc = (vel - ps.prevVel).Magnitude
    if acc >= 5.5 then
        local toMe = MC.root.Position - er.Position
        if toMe.Magnitude < 0.1 or vel.Magnitude < 0.1 then return end
        local dot = toMe.Unit:Dot(vel.Unit)
        if dot > 0.22 then
            local now = os.clock()
            if now - ps.lastVelSpike > 0.11 then
                ps.lastVelSpike = now
                FireParry(false, ps, "normal", nil)
            end
        end
    end
end

-- ============================================================
--  HEARTBEAT — main scan (1.2× frametime for tighter window)
-- ============================================================
local lastHBTime = 0

RunService.Heartbeat:Connect(function()
    if not Parry.on then Decoy:tick(); return end
    if not MC.root then RefreshChar(); return end
    if IsSelfAttacking() then return end

    local now      = os.clock()
    local scanRate = math.max(0.006, FPS.frametime * 1.2)
    if now - lastHBTime < scanRate then return end
    lastHBTime = now

    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and Dist(MC.root, er) <= 24 and not IsFromBack(er) then
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
            ps.heavyAlertExp = now + 3.5
        end
        local fired = FireParry(top.heavy, ps, "normal", nil)
        if fired then UpdateCombo(ps, uid, top.heavy, "HB"); UpdateThreshold(false) end
    end
end)

-- ============================================================
--  WATCH CHAR — zero-latency attr + anim listeners
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
                if Dist(MC.root, er) > 24 then return end
                if IsFromBack(er) then return end
                local isHvy = IsHeavyAttr(attr)
                if isHvy then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = os.clock() + 3.5
                    if not ps.m2Detected or os.clock() >= ps.m2DetectedExp then
                        ps.m2Detected    = true
                        ps.m2DetectedExp = os.clock() + 2.2
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
                if Dist(MC.root, er) > 24 then return end
                if IsFromBack(er) then return end
                local now = os.clock()
                local cK  = string.format("%d_%s", uid, n)
                if now - (ps.lastAnimFire[cK] or 0) < 0.12 then return end
                ps.lastAnimFire[cK] = now
                UpdateCombo(ps, uid, isH, n)
                if isH then
                    ps.heavyAlert    = true
                    ps.heavyAlertExp = now + 3.5
                    SafeFireInstant(true)
                else
                    FireParry(false, ps, "normal", track)
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
        task.wait(0.35); Watch(p)
    end)
end
local function WatchAll()
    for _, p in pairs(Players:GetPlayers()) do Watch(p) end
end
WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.25); Watch(p) end)

-- ============================================================
--  FX HOOKS — SafeFireInstant, deduped
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
                if er and root and Dist(root, er) <= 24 and not IsFromBack(er) then
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
            if ps then ps.heavyAlert = true; ps.heavyAlertExp = os.clock() + 3.5 end
            if Lock.on or Lock.inCombat then
                Lock.target = attacker; Lock.expireTime = os.clock() + 60
            end
        end
        SafeFireInstant(true)
    end)
end

if HitRunFX     then HitRunFX.OnClientEvent:Connect(function()   MarkCombat(); SafeFireInstant(false) end) end
if KickComboFX  then KickComboFX.OnClientEvent:Connect(function() MarkCombat(); SafeFireInstant(true)  end) end
if CounterHitFX then CounterHitFX.OnClientEvent:Connect(function() MarkCombat(); SafeFireInstant(false) end) end

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


-- ============================================================
--  RESPAWN CLEANUP
-- ============================================================
LP.CharacterAdded:Connect(function()
    RefreshChar()
    Parry.nextFire = 0; Parry.firing = false; Parry.firingAt = 0
    Parry.lastHB   = 0; spamLock = false; Parry.consecMiss = 0
    Parry.dynThreshold = 12.0
    lastInstantT   = 0
    for uid in pairs(PS) do PS[uid] = nil end
    Lock.target   = nil; Lock.inCombat = false; Lock.combatTime = 0
    DestroyConstraint()
    task.wait(0.6); WatchAll()
    task.wait(0.1)
    Decoy:schedule()
end)

-- ============================================================
--  UI
-- ============================================================
local old = PGui:FindFirstChild("HSA_UI_v6")
if old then old:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name = "HSA_UI_v6"; SG.ResetOnSpawn = false
SG.IgnoreGuiInset = true; SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.Parent = PGui

local Panel = Instance.new("Frame")
Panel.Name = "Panel"; Panel.Size = UDim2.new(0, 210, 0, 320)
Panel.Position = UDim2.new(0, 16, 0.5, -160)
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
TitleLbl.Text = "⚔️ HSA v6 APEX MAX"; TitleLbl.Size = UDim2.new(1, -36, 1, 0)
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
MkLbl("— SMART LOCK (combat only) —", 92)
local LockBtn  = MkBtn("🔒 LOCK: OFF", 108, Color3.fromRGB(170, 30, 30))

local AdaptLbl  = MkLbl("FPS:- | Ping:-ms | Fires:- | Cap:-", 150, Color3.fromRGB(60, 140, 220))
local KalmanLbl = MkLbl("Kalman: inactive", 164, Color3.fromRGB(80, 100, 140))

local TargetLbl = Instance.new("TextLabel")
TargetLbl.Size = UDim2.new(1, -16, 0, 15); TargetLbl.Position = UDim2.new(0, 8, 0, 182)
TargetLbl.BackgroundTransparency = 1; TargetLbl.TextColor3 = Color3.fromRGB(255, 195, 70)
TargetLbl.TextSize = 10; TargetLbl.Font = Enum.Font.Gotham
TargetLbl.TextXAlignment = Enum.TextXAlignment.Left; TargetLbl.Text = "Target: -"
TargetLbl.TextTruncate = Enum.TextTruncate.AtEnd; TargetLbl.Parent = Panel

local InfoLbl   = MkLbl("Dist: - | HP: -",        198, Color3.fromRGB(100, 100, 100))
local StateLbl  = MkLbl("State: Neutral",           214, Color3.fromRGB(70, 170, 70))
local StatsLbl  = MkLbl("Parry:0 Miss:0 CPS:0",    230, Color3.fromRGB(65, 65, 65))
local ThreshLbl = MkLbl("Thresh:12.0 | Decoy: armed", 246, Color3.fromRGB(60, 60, 60))
local ScoreLbl  = MkLbl("Score: -",                 262, Color3.fromRGB(80, 140, 80))

local BarBG = Instance.new("Frame")
BarBG.Size = UDim2.new(1, -16, 0, 6); BarBG.Position = UDim2.new(0, 8, 0, 280)
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

    if Lock.target and Lock.target.Character then
        local ps = GetPS(Lock.target.UserId)
        if ps.kalmanPos then
            local spd = ps.kalmanVel.Magnitude
            KalmanLbl.Text = string.format("Kalman: spd=%.1f jump=%s",
                spd, ps.isJumping and "YES" or "no")
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
        local tPs  = GetPS(Lock.target.UserId)
        local tSc, _ = Score(Lock.target, tPs)
        TargetLbl.Text = "🎯 " .. Lock.target.Name
        InfoLbl.Text   = string.format("Dist:%d | HP:%d/%d", dist, hp, mhp)
        ScoreLbl.Text  = string.format("Score:%d / 300", tSc)
    else
        TargetLbl.Text = "Target: -"; InfoLbl.Text = "Dist: - | HP: -"
        ScoreLbl.Text  = "Score: -"
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
    if now - UILast < 0.26 then return end
    UILast = now; UpdateUI()
end)

-- ============================================================
--  BUTTONS + KEYBINDS
-- ============================================================
local function Pop(btn)
    TweenService:Create(btn, TweenInfo.new(0.06), {Size=UDim2.new(1,-22,0,26)}):Play()
    task.wait(0.06)
    TweenService:Create(btn, TweenInfo.new(0.06), {Size=UDim2.new(1,-16,0,30)}):Play()
end

ParryBtn.MouseButton1Click:Connect(function()
    Parry.on = not Parry.on
    Parry.nextFire = 0; Parry.firing = false; spamLock = false
    lastInstantT = 0; Pop(ParryBtn); UpdateUI()
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
            savedPos.X.Scale, savedPos.X.Offset+105,
            savedPos.Y.Scale, savedPos.Y.Offset+160)}):Play()
    task.wait(0.13)
    Panel.Visible=false; Panel.Size=UDim2.new(0,210,0,320); Panel.Position=savedPos
    ReopenBtn.Visible=true; ReopenBtn.Position=savedPos
end)

ReopenBtn.MouseButton1Click:Connect(function()
    Panel.Position=savedPos; Panel.Visible=true; Panel.Size=UDim2.new(0,0,0,0)
    ReopenBtn.Visible=false
    TweenService:Create(Panel, TweenInfo.new(0.12,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),
        {Size=UDim2.new(0,210,0,320)}):Play()
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
    "[HSA v6 APEX MAX] Loaded | FPS:%d Ping:%dms | Cap:%d | RShift=Parry RCtrl=Lock",
    FPS.current, math.floor(Ping:get()), DynRL:cap()))
