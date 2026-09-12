-- Auto Parry v12 — GODMODE EDITION
-- Rebuilt detection: dual-layer (pre-anim + post-anim), M2 pre-fire, combo lock
-- Silent mode, zero console spam

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
if not ok then warn("[AP12] Packets failed"); return end

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
    Range              = 20,
    TapWindow          = 0.038,
    CooldownM1         = 0.28,
    CooldownM2         = 0.20,
    ScoreThreshold     = 18,      -- lebih rendah = lebih sensitif
    ToggleKey          = Enum.KeyCode.RightShift,

    PreFireThreshold   = 0.05,    -- fire makin awal

    -- Multi-fire untuk combo spam
    MultiFireEnabled   = true,
    MultiFireBase      = 3,
    MultiFireMax       = 6,       -- naik ke 6 untuk combo spam
    MultiFireDelay     = 0.08,    -- lebih ketat

    ChainWindow        = 1.0,     -- window combo lebih lebar

    ForceAll           = true,

    PingCompEnabled    = true,
    PingCompMax        = 0.45,

    AdaptiveCooldown   = true,
    AnglePredict       = true,
    VelSharpening      = true,
    AnimCacheStrict    = true,
    MaxQueueTargets    = 5,

    -- v12 GODMODE
    FiringTimeout      = 0.8,     -- lebih pendek, biar ga stuck lama
    SelfGuard          = true,    -- jaga lo ga ke-interrupt
    ToolSelfGuard      = true,

    -- v12: Dual-layer detection
    PreAnimDetect      = true,    -- detect SEBELUM anim via attr spike
    VelPreFire         = true,    -- fire dari velocity spike aja
    VelPreFireThresh   = 8,       -- sensitivity velocity pre-fire

    -- v12: Combo lock mode
    ComboLockEnabled   = true,    -- kalau masuk combo, lock parry window
    ComboLockWindow    = 0.22,    -- tiap berapa detik expect hit berikutnya
    ComboLockMax       = 8,       -- max combo lock cycles

    -- v12: M2 pre-fire
    M2PreFireEnabled   = true,    -- fire segera saat M2 attr detected
    M2PreFireExtra     = 2,       -- extra fire count untuk M2

    -- v12: Adaptive threshold
    AdaptiveThreshold  = true,    -- threshold turun kalau sering miss
    ThresholdFloor     = 12,      -- minimum threshold
    MissDecay          = 2,       -- threshold turun per miss

    HeartbeatDebounce  = 0.02,    -- lebih responsif
    HistoryDepth       = 20,
}

-- ─── STATE ────────────────────────────────────────────────
local ON             = true
local NextParry      = 0
local Firing         = false
local FiringAt       = 0
local ParryCount     = 0
local MissCount      = 0
local ConsecMiss     = 0          -- v12: consecutive miss tracker
local DynThreshold   = CFG.ScoreThreshold  -- v12: dynamic threshold
local Watched        = {}
local PrevVel        = {}
local PrevAnims      = {}
local HeavyAlert     = {}
local ComboTracker   = {}
local LastHitTime    = {}
local HitHistory     = {}
local LastAnimFire   = {}
local LastHeartbeat  = 0

-- v12 GODMODE state
local ComboLockActive  = {}   -- uid → bool, lagi di combo lock
local ComboLockUntil   = {}   -- uid → timestamp batas lock
local ComboLockCount   = {}   -- uid → berapa cycle tersisa
local LastVelSpike     = {}   -- uid → last velocity spike time
local M2Detected       = {}   -- uid → M2 detected flag
local AttackTypeSeq    = {}   -- uid → sequence type

-- ─── SELF ATTACK ATTRS ────────────────────────────────────
local SELF_ATKS = {
    "State_Attacking","IsAttacking","Attacking","SwingActive",
    "M1","Swinging","InAttack","AttackState","HitActive","StrikeActive",
}

-- ─── PING ─────────────────────────────────────────────────
local PingCache     = 80
local PingLastCheck = 0

local function GetPing()
    local now = os.clock()
    if now - PingLastCheck > 0.4 then
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
    return math.min(CFG.PingCompMax, (GetPing()/1000) * 2.5)
end

local function GetCooldown(isHeavy)
    local base = isHeavy and CFG.CooldownM2 or CFG.CooldownM1
    if not CFG.AdaptiveCooldown then return base end
    local f = 1 + ((GetPing() - 80) / 750)
    return math.max(base * 0.65, math.min(base * 1.3, base * f))
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
        "SendNotification",{Title="⚔️ AP v12",Text=t,Duration=d or 2})
end

-- ─── SELF ATTACK GUARD ────────────────────────────────────
local function IsSelfAttacking()
    if not CFG.SelfGuard then return false end
    if not Char then return false end
    for _,a in ipairs(SELF_ATKS) do
        local v = Char:GetAttribute(a)
        if v == true then return true end
        if Hum then
            v = Hum:GetAttribute(a)
            if v == true then return true end
        end
    end
    return false
end

-- ─── DYNAMIC THRESHOLD ────────────────────────────────────
-- kalau sering miss, threshold otomatis turun biar lebih sensitif
local function UpdateThreshold(missed)
    if not CFG.AdaptiveThreshold then return end
    if missed then
        ConsecMiss   += 1
        DynThreshold  = math.max(CFG.ThresholdFloor,
            DynThreshold - CFG.MissDecay * math.min(ConsecMiss, 3))
    else
        ConsecMiss   = 0
        -- slowly recover threshold
        DynThreshold = math.min(CFG.ScoreThreshold,
            DynThreshold + 1)
    end
end

-- ─── CAN FIRE ─────────────────────────────────────────────
local function CanFire(force)
    if not ON then return false end
    if Firing then
        -- safety timeout
        if os.clock() - FiringAt > CFG.FiringTimeout then
            Firing = false
        else
            return false
        end
    end
    if os.clock() < NextParry then return false end
    if not Refresh() then return false end
    if IsSelfAttacking() then return false end
    if not force and not CFG.ForceAll then
        if Char:GetAttribute("State_Ragdolled") then return false end
        if Char:GetAttribute("State_Safe") then return false end
    end
    return true
end

-- ─── HIT HISTORY ──────────────────────────────────────────
local function RecordHit(uid, isHeavy, src)
    local now = os.clock()
    if not HitHistory[uid] then HitHistory[uid] = {} end
    table.insert(HitHistory[uid], {t=now, h=isHeavy, s=src})
    if #HitHistory[uid] > CFG.HistoryDepth then
        table.remove(HitHistory[uid], 1)
    end
    LastHitTime[uid] = now
end

local function GetAvgInterval(uid)
    local h = HitHistory[uid]
    if not h or #h < 3 then return nil end
    local sum, n = 0, 0
    for i = 2, #h do
        sum += h[i].t - h[i-1].t
        n   += 1
    end
    return n > 0 and (sum/n) or nil
end

-- ─── v12: COMBO LOCK ──────────────────────────────────────
-- Ketika detect combo, aktifin lock mode:
-- tiap ComboLockWindow detik, auto-fire parry tanpa nunggu score
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
            return true   -- fire now
        else
            -- lock expired
            ComboLockActive[uid] = false
            ComboLockCount[uid]  = 0
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
        ComboTracker[uid] = 0
        ComboLockActive[uid] = false
    end
    RecordHit(uid, isHeavy, src)
    ComboTracker[uid] += 1

    -- v12: aktifin combo lock saat combo >= 2
    if ComboTracker[uid] >= 2 then
        local avg = GetAvgInterval(uid)
        if avg and avg < 0.6 then
            -- combo cepet, lock agresif
            ActivateComboLock(uid, math.min(ComboTracker[uid] + 2, CFG.ComboLockMax))
        end
    end

    return ComboTracker[uid]
end

local function GetMultiFire(uid, isHeavy)
    if not CFG.MultiFireEnabled then return 1 end
    local combo = ComboTracker[uid] or 0
    local base  = CFG.MultiFireBase

    if isHeavy then
        base = base + CFG.M2PreFireExtra
    end

    if combo >= 5 then base = CFG.MultiFireMax
    elseif combo >= 3 then base = base + 2
    elseif combo >= 1 then base = base + 1
    end

    -- avg interval pendek = fire lebih banyak
    local avg = GetAvgInterval(uid)
    if avg and avg < 0.25 then
        base = math.min(CFG.MultiFireMax, base + 1)
    end

    return math.min(CFG.MultiFireMax, base)
end

-- ─── CORE PARRY ───────────────────────────────────────────
local function RawParry()
    pcall(function()
        if CFG.ForceAll then
            pcall(function() DSR:Fire("EndRagdoll")   end)
            pcall(function() DSR:Fire("EndKnockback") end)
            -- CancelAction TIDAK dipanggil, ini yang bikin bug attack sendiri
        end
        task.wait(0.01)
        DSR:Fire("BeginBlock")
        task.wait(CFG.TapWindow)
        DSR:Fire("BeginParry")
        task.wait(0.032)
        DSR:Fire("EndBlock")
    end)
end

local function FireParry(src, isHeavy, force, uid)
    if not CanFire(force) then return false end

    local cd      = GetCooldown(isHeavy)
    Firing        = true
    FiringAt      = os.clock()
    NextParry     = os.clock() + cd

    local lead    = GetLead()
    local mfCount = GetMultiFire(uid, isHeavy)

    task.spawn(function()
        pcall(function()
            if lead > 0.005 then task.wait(lead) end

            if isHeavy and CFG.MultiFireEnabled then
                for i = 1, mfCount do
                    if IsSelfAttacking() then break end
                    RawParry()
                    if i < mfCount then
                        task.wait(CFG.MultiFireDelay)
                    end
                end
            else
                if not IsSelfAttacking() then RawParry() end
            end
        end)
        task.wait(0.04)
        Firing = false
    end)

    return true
end

-- v12: Immediate M2 fire — bypass normal cooldown untuk M2
local function FireM2Immediate(uid)
    if not CFG.M2PreFireEnabled then return end
    -- reset firing state paksa untuk M2
    if Firing and os.clock() - FiringAt > 0.1 then
        Firing = false
    end
    NextParry = 0   -- bypass cooldown untuk M2
    FireParry("M2Imm", true, true, uid)
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

-- ─── ANGLE PREDICTOR ──────────────────────────────────────
local function GetSwingArcBonus(er)
    if not CFG.AnglePredict or not Root or not er then return 0 end
    local toMe    = (Root.Position - er.Position)
    local dist    = toMe.Magnitude
    if dist < 0.1 then return 0 end
    local dirN     = toMe / dist
    local faceDot  = er.CFrame.LookVector:Dot(dirN)
    local sideDot  = math.abs(er.CFrame.RightVector:Dot(dirN))
    local bonus = 0
    if faceDot > 0.5  then bonus += 14 end
    if sideDot > 0.4  then bonus += 10 end
    if faceDot > 0.78 then bonus += 8  end
    return bonus
end

-- ─── VELOCITY BONUS ───────────────────────────────────────
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
    local approachDot = dirN:Dot(vel.Unit)
    local bonus = 0
    if approachDot > 0.25 then bonus += math.floor(approachDot * 30) end
    if math.abs(vel.Unit.Y) > 0.35 and approachDot > 0.1 then bonus += 12 end
    return math.min(bonus, 42)
end

-- v12: velocity pre-fire — fire dari vel spike aja tanpa nunggu anim
local function CheckVelPreFire(uid, er, p)
    if not CFG.VelPreFire or not Root or not er then return end
    local vel  = er.Velocity
    local prev = PrevVel[uid] or vel
    local acc  = (vel - prev).Magnitude

    if acc >= CFG.VelPreFireThresh then
        local toMe = (Root.Position - er.Position)
        if toMe.Magnitude < 0.1 then return end
        local dot = toMe.Unit:Dot(vel.Unit)
        if dot > 0.3 then
            local now = os.clock()
            local last = LastVelSpike[uid] or 0
            if now - last > 0.15 then
                LastVelSpike[uid] = now
                FireParry("VelSpike", false, true, uid)
            end
        end
    end
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

    local sc=0; local hvy=false; local rsn=""
    local uid = p.UserId

    -- Distance (0-15)
    sc += math.floor((1 - d/CFG.Range) * 15)

    -- Attr (0-80)
    local hasAttr,isHAttr,attrN = ScanAttrs(ec,eh)
    if isHAttr then
        sc+=80; hvy=true; rsn="HvyAttr:"..attrN
    elseif hasAttr then
        sc+=50; rsn="Attr:"..tostring(attrN)
    end

    -- Anim (0-75)
    local anim = eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok2,tracks = pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok2 and tracks then
            for _,t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n=t.Animation.Name; local pos=t.TimePosition
                    if IsM2Anim(n) then
                        hvy=true
                        if pos<=CFG.PreFireThreshold then sc+=75;rsn="M2E:"..n
                        elseif pos<0.25 then sc+=60;rsn="M2M:"..n
                        else sc+=35;rsn="M2L:"..n end
                        break
                    elseif IsM1Anim(n) then
                        if pos<=CFG.PreFireThreshold then sc+=65;rsn="M1E:"..n
                        elseif pos<0.18 then sc+=50;rsn="M1M:"..n
                        else sc+=22;rsn="M1L:"..n end
                        break
                    end
                end
            end
        end
    end

    if HeavyAlert[uid] then sc+=30; hvy=true end

    -- Combo (0-50)
    local combo = ComboTracker[uid] or 0
    if combo > 0 then
        sc += math.min(combo * 12, 50)
        rsn = rsn=="" and ("Combo:"..combo) or rsn
    end

    -- Avg interval bonus (cepet = score lebih tinggi)
    local avg = GetAvgInterval(uid)
    if avg and avg < 0.4 then
        sc += math.floor((1 - avg/0.4) * 20)
    end

    sc += GetSwingArcBonus(er)
    sc += GetVelBonus(uid, er)

    if d < 8 then
        local toMe = (Root.Position - er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector) > 0.62 then sc+=15 end
    end

    return math.min(sc,130), hvy, rsn~="" and rsn or "Multi"
end

-- ─── PRIORITY QUEUE ───────────────────────────────────────
local function BuildQueue()
    local q={}
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP then
            local sc,hv,r=Score(p)
            if sc>=DynThreshold then
                table.insert(q,{player=p,score=sc,heavy=hv,reason=r})
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

    -- v12: tick combo lock untuk semua player
    for _,p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            if er and Root and Dist(Root,er) <= CFG.Range then
                local uid = p.UserId
                -- combo lock fire
                if ComboLockActive[uid] and TickComboLock(uid) then
                    if now >= NextParry then
                        FireParry("ComboLock", false, true, uid)
                    end
                end
                -- vel pre-fire
                CheckVelPreFire(uid, er, p)
            end
        end
    end

    if now < NextParry then return end

    local q = BuildQueue()
    if #q > 0 then
        local top = q[1]
        local uid = top.player.UserId
        if top.heavy then
            HeavyAlert[uid]=true
            task.delay(3,function() HeavyAlert[uid]=nil end)
        end
        local fired = FireParry(
            string.format("[%d]%s/%s",top.score,top.reason,top.player.Name),
            top.heavy,true,uid
        )
        if fired then
            UpdateThreshold(false)   -- hit detected, recover threshold
        end
    end
end)

-- ─── REALTIME WATCHERS ────────────────────────────────────
local function WatchChar(p,char)
    if not char then return end
    local er  = char:FindFirstChild("HumanoidRootPart")
    local eh  = char:FindFirstChildWhichIsA("Humanoid")
    local uid = p.UserId

    -- Attr watcher
    local function watchA(obj,attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not ON then return end
                if os.clock()<NextParry then return end
                if IsSelfAttacking() then return end
                local v=obj:GetAttribute(attr)
                if not(v==true or(type(v)=="string" and
                    (v:lower():find("attack") or v:lower():find("heavy")))) then return end
                if not er or not Root then return end
                if Dist(Root,er)>CFG.Range then return end
                local isHvy=IsHeavyAttr(attr)
                if isHvy then
                    HeavyAlert[uid]=true
                    task.delay(3,function() HeavyAlert[uid]=nil end)
                    -- v12: M2 pre-fire bypass
                    if not M2Detected[uid] then
                        M2Detected[uid]=true
                        task.delay(2,function() M2Detected[uid]=nil end)
                        FireM2Immediate(uid)
                        return
                    end
                end
                FireParry("WAttr:"..attr,isHvy,true,uid)
            end)
        end)
    end

    for _,a in ipairs(ALL_ATTR) do
        watchA(char,a)
        if eh then watchA(eh,a) end
    end

    -- Anim watcher
    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not ON then return end
                if not track then return end
                if IsSelfAttacking() then return end
                local ok2,n=pcall(function() return track.Animation.Name end)
                if not ok2 or not n then return end
                local isH=IsM2Anim(n); local isM=IsM1Anim(n)
                if not isH and not isM then return end
                if not er or not Root then return end
                if Dist(Root,er)>CFG.Range then return end

                local now=os.clock()
                local cacheK=string.format("%d_%s",uid,n)
                local lastFire=LastAnimFire[cacheK] or 0
                if now-lastFire < 0.22 then return end
                LastAnimFire[cacheK]=now

                UpdateCombo(uid,isH,n)

                if isH then
                    HeavyAlert[uid]=true
                    task.delay(3,function() HeavyAlert[uid]=nil end)
                    FireM2Immediate(uid)
                else
                    FireParry("AnimPlay:"..n,false,true,uid)
                end
            end)
        end)
    end

    if eh then
        local an=eh:FindFirstChildOfClass("Animator")
        if an then watchAnim(an)
        else eh.ChildAdded:Connect(function(c)
            if c:IsA("Animator") then watchAnim(c) end
        end) end
    end

    -- Tool equip (enemy only)
    char.ChildAdded:Connect(function(c)
        if not c:IsA("Tool") then return end
        if CFG.ToolSelfGuard and char==LP.Character then return end
        if not ON or not er or not Root then return end
        if Dist(Root,er)>CFG.Range then return end
        FireParry("ToolEq:"..c.Name,false,false,uid)
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
    local uid=p.UserId
    Watched[uid]=nil; PrevVel[uid]=nil; HeavyAlert[uid]=nil
    ComboTracker[uid]=nil; LastHitTime[uid]=nil; HitHistory[uid]=nil
    AttackTypeSeq[uid]=nil; ComboLockActive[uid]=nil
    ComboLockCount[uid]=nil; M2Detected[uid]=nil
    LastVelSpike[uid]=nil
end)

-- ─── OPTIONAL PACKETS ─────────────────────────────────────
local function pktHook(pkt,src,heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        NextParry=0; Firing=false
        if heavy then
            HeavyAlert["pkt"..src]=true
            task.delay(3,function() HeavyAlert["pkt"..src]=nil end)
            FireM2Immediate(nil)
        else
            FireParry("Pkt:"..src,false,true)
        end
    end)
end
pktHook(M2Pkt,"M2",true)
pktHook(HeavyAtk,"Heavy",true)
pktHook(ChargeAtk,"Charge",true)
pktHook(RedSig,"RedSig",true)
pktHook(ComboPkt,"Combo",false)

-- ─── FALLBACK EVENTS ──────────────────────────────────────
GotHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    MissCount+=1
    UpdateThreshold(true)   -- v12: update threshold saat kena hit

    if Root then
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er=p.Character:FindFirstChild("HumanoidRootPart")
                if er and Dist(Root,er)<=CFG.Range then
                    local uid=p.UserId
                    UpdateCombo(uid,false,"GotHit")
                    -- v12: aktivasi combo lock agresif saat kena hit
                    ActivateComboLock(uid, CFG.ComboLockMax)
                end
            end
        end
    end
    FireParry("GotHit",false,true)
end)

BlockHit.OnClientEvent:Connect(function()
    NextParry=0; Firing=false
    FireParry("BlockHit",false,true)
end)

CTChanged.OnClientEvent:Connect(function(t)
    if t then NextParry=0; Firing=false end
end)

ParryOK.OnClientEvent:Connect(function()
    ParryCount+=1
end)

-- ─── RESPAWN ──────────────────────────────────────────────
LP.CharacterAdded:Connect(function(c)
    Char=c; Hum=c:WaitForChild("Humanoid"); Root=c:WaitForChild("HumanoidRootPart")
    NextParry=0; Firing=false; FiringAt=0; LastHeartbeat=0
    Watched={}; PrevAnims={}; HeavyAlert={}; ComboTracker={}
    LastHitTime={}; HitHistory={}; LastAnimFire={}
    ComboLockActive={}; ComboLockCount={}; ComboLockUntil={}
    M2Detected={}; LastVelSpike={}; AttackTypeSeq={}
    DynThreshold=CFG.ScoreThreshold; ConsecMiss=0
    task.wait(0.8); WatchAll()
end)

-- ─── TOGGLE ───────────────────────────────────────────────
UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==CFG.ToggleKey then
        ON=not ON; NextParry=0; Firing=false
        Notify(ON and "✅ v12 ON" or "❌ v12 OFF")
    end
end)

-- ─── INIT ─────────────────────────────────────────────────
Notify("⚔️ Auto Parry v12 GODMODE", 2)
