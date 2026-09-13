-- AUTO PARRY v13 + AUTO AIM v5.1 — COMBINED UI
-- Semua sistem intact, UI digabung jadi satu panel

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local Stats             = game:GetService("Stats")
local TweenService      = game:GetService("TweenService")

local LP     = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local PGui   = LP:WaitForChild("PlayerGui")

-- ════════════════════════════════════════════════════════
-- PACKETS
-- ════════════════════════════════════════════════════════
local ok, Packets = pcall(function()
    local S = ReplicatedStorage:WaitForChild("Modules",5)
                               :WaitForChild("Shared",5)
    return require(S:WaitForChild("Packets",5))
end)
if not ok then return end

local DSR       = Packets.DefenseStateRequest
local CTChange  = Packets.CombatTagChanged
local ParryOK   = Packets.ParrySuccess
local BlockHit  = Packets.BlockHitReaction
local GotHit    = Packets.GotHitScreenEffect

local function tryPkt(n)
    local s,v=pcall(function() return Packets[n] end)
    return (s and v) or nil
end
local HeavyAtk  = tryPkt("HeavyAttack")
local ChargeAtk = tryPkt("ChargeAttack")
local M2Pkt     = tryPkt("M2Attack")
local RedSig    = tryPkt("DangerIndicator")
local ComboPkt  = tryPkt("ComboAttack")

-- AIM packets
local HitConfirm = nil
local HIT_NAMES  = {
    "HitConfirm","DealDamage","HitEffect","AttackHit",
    "DamageDone","HitTarget","OnHit","AttackConnected",
    "HitSuccess","DamageDealt","MeleeHit","HitRegistered",
    "HitSomeone","DamageEvent","CombatHit","StrikeHit",
}
for _,n in ipairs(HIT_NAMES) do
    if Packets[n] then HitConfirm=Packets[n]; break end
end

-- ════════════════════════════════════════════════════════
-- PARRY CONFIG
-- ════════════════════════════════════════════════════════
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
}

-- ════════════════════════════════════════════════════════
-- AIM CONFIG
-- ════════════════════════════════════════════════════════
local ACFG = {
    ON             = false,
    Range          = 80,
    LockDuration   = 20,
    SwitchOnHit    = true,
    SwitchCooldown = 0.8,
    PredictFactor  = 0.12,
    Responsiveness = 40,
    MaxTorque      = 1e6,
    StickyMult     = 1.7,
    ProxRange      = 12,
    ToggleKey      = Enum.KeyCode.RightControl,
    SwitchKey      = Enum.KeyCode.RightShift,
    BlockedStates  = {
        "State_Ragdolled","State_Safe","State_Dead",
        "State_Downed","State_Gripped","State_Carried","State_Stunned",
    },
}

-- ════════════════════════════════════════════════════════
-- PARRY STATE
-- ════════════════════════════════════════════════════════
local Char = LP.Character or LP.CharacterAdded:Wait()
local Hum  = Char:WaitForChild("Humanoid")
local Root = Char:WaitForChild("HumanoidRootPart")

local PON             = false
local NextParry       = 0
local Firing          = false
local FiringAt        = 0
local ParryCount      = 0
local MissCount       = 0
local ConsecMiss      = 0
local DynThreshold    = PCFG.ScoreThreshold
local Watched         = {}
local PrevVel         = {}
local HeavyAlert      = {}
local ComboTracker    = {}
local LastHitTime     = {}
local HitHistory      = {}
local LastAnimFire    = {}
local LastHeartbeat   = 0
local ComboLockActive = {}
local ComboLockUntil  = {}
local ComboLockCount  = {}
local LastVelSpike    = {}
local M2Detected      = {}
local BurstActive     = {}
local BurstUntil      = {}

-- ════════════════════════════════════════════════════════
-- AIM STATE
-- ════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════
-- PING
-- ════════════════════════════════════════════════════════
local PingCache=80; local PingLastCheck=0
local function GetPing()
    local now=os.clock()
    if now-PingLastCheck>0.25 then
        local s,v=pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        PingCache=(s and v) or PingCache; PingLastCheck=now
    end
    return PingCache
end
local function GetLead()
    if not PCFG.PingCompEnabled then return 0 end
    return math.min(PCFG.PingCompMax,(GetPing()/1000)*3.2)
end
local function GetCooldown(isHeavy)
    local base=isHeavy and PCFG.CooldownM2 or PCFG.CooldownM1
    if not PCFG.AdaptiveCooldown then return base end
    local ping=GetPing()
    if ping>150 then return math.max(base*0.55,base-math.min(0.09,(ping-150)/1800)) end
    return math.max(base*0.70,base*(1+(ping-80)/1200))
end

-- ════════════════════════════════════════════════════════
-- SHARED UTILS
-- ════════════════════════════════════════════════════════
local function Refresh()
    Char=LP.Character; if not Char then return false end
    Hum=Char:FindFirstChildWhichIsA("Humanoid")
    Root=Char:FindFirstChild("HumanoidRootPart")
    return Char~=nil and Root~=nil
end
local function Dist(a,b)
    if not a or not b then return 9999 end
    return (a.Position-b.Position).Magnitude
end
local function GetRoot() local c=LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function GetChar() return LP.Character end

-- ════════════════════════════════════════════════════════
-- PARRY SYSTEMS (semua dari v13, intact)
-- ════════════════════════════════════════════════════════
local SELF_ATKS={
    "State_Attacking","IsAttacking","Attacking","SwingActive",
    "M1","Swinging","InAttack","AttackState","HitActive","StrikeActive",
}
local function IsSelfAttacking()
    if not PCFG.SelfGuard or not Char then return false end
    for _,a in ipairs(SELF_ATKS) do
        if Char:GetAttribute(a)==true then return true end
        if Hum and Hum:GetAttribute(a)==true then return true end
    end
    return false
end
local function UpdateThreshold(missed)
    if missed then
        ConsecMiss+=1
        DynThreshold=math.max(PCFG.ThresholdFloor,DynThreshold-PCFG.MissDecay*math.min(ConsecMiss,4))
    else ConsecMiss=0; DynThreshold=math.min(PCFG.ScoreThreshold,DynThreshold+1) end
end
local function CanFire()
    if not PON then return false end
    if Firing then
        if os.clock()-FiringAt>PCFG.FiringTimeout then Firing=false else return false end
    end
    if os.clock()<NextParry then return false end
    if not Refresh() then return false end
    if IsSelfAttacking() then return false end
    return true
end
local function RecordHit(uid,isHeavy,src)
    local now=os.clock()
    if not HitHistory[uid] then HitHistory[uid]={} end
    table.insert(HitHistory[uid],{t=now,h=isHeavy,s=src})
    if #HitHistory[uid]>PCFG.HistoryDepth then table.remove(HitHistory[uid],1) end
    LastHitTime[uid]=now
end
local function GetAvgInterval(uid)
    local h=HitHistory[uid]; if not h or #h<3 then return nil end
    local sum,n=0,0
    for i=2,#h do sum+=h[i].t-h[i-1].t; n+=1 end
    return n>0 and (sum/n) or nil
end
local function ActivateBurst(uid)
    if not PCFG.BurstEnabled then return end
    BurstActive[uid]=true
    BurstUntil[uid]=os.clock()+(PCFG.BurstFireCount*PCFG.BurstFireDelay)+0.3
end
local function IsBurst(uid)
    if not BurstActive[uid] then return false end
    if os.clock()>(BurstUntil[uid] or 0) then BurstActive[uid]=false; return false end
    return true
end
local function ActivateComboLock(uid,cycles)
    if not PCFG.ComboLockEnabled then return end
    ComboLockActive[uid]=true
    ComboLockCount[uid]=math.min(cycles or 4,PCFG.ComboLockMax)
    ComboLockUntil[uid]=os.clock()+PCFG.ComboLockWindow
end
local function TickComboLock(uid)
    if not ComboLockActive[uid] then return false end
    if os.clock()>=(ComboLockUntil[uid] or 0) then
        if (ComboLockCount[uid] or 0)>0 then
            ComboLockCount[uid]-=1; ComboLockUntil[uid]=os.clock()+PCFG.ComboLockWindow; return true
        else ComboLockActive[uid]=false; return false end
    end
    return false
end
local function UpdateCombo(uid,isHeavy,src)
    local now=os.clock(); local last=LastHitTime[uid] or 0
    if not ComboTracker[uid] then ComboTracker[uid]=0 end
    if now-last>PCFG.ChainWindow then
        ComboTracker[uid]=0; ComboLockActive[uid]=false; BurstActive[uid]=false
    end
    RecordHit(uid,isHeavy,src); ComboTracker[uid]+=1
    if ComboTracker[uid]>=PCFG.BurstTrigger then ActivateBurst(uid) end
    if ComboTracker[uid]>=2 then
        local avg=GetAvgInterval(uid)
        if avg and avg<0.6 then ActivateComboLock(uid,math.min(ComboTracker[uid]+3,PCFG.ComboLockMax)) end
    end
    return ComboTracker[uid]
end
local function GetMultiFire(uid,isHeavy)
    if not PCFG.MultiFireEnabled then return 1 end
    local combo=ComboTracker[uid] or 0
    local base=PCFG.MultiFireBase
    if isHeavy then base=base+PCFG.M2PreCount end
    if combo>=5 then base=PCFG.MultiFireMax
    elseif combo>=3 then base=base+2
    elseif combo>=1 then base=base+1 end
    local avg=GetAvgInterval(uid)
    if avg and avg<0.25 then base=math.min(PCFG.MultiFireMax,base+1) end
    local ping=GetPing()
    if ping>150 then base=math.min(PCFG.MultiFireMax,base+1) end
    if ping>250 then base=math.min(PCFG.MultiFireMax,base+1) end
    if IsBurst(uid) then base=PCFG.MultiFireMax end
    return math.min(PCFG.MultiFireMax,base)
end
local function RawParry()
    pcall(function()
        local ping=GetPing()
        local dynTap=ping>150 and math.max(0.018,PCFG.TapWindow-(ping-150)/9000) or PCFG.TapWindow
        task.wait(0.006); DSR:Fire("BeginBlock")
        task.wait(dynTap); DSR:Fire("BeginParry")
        task.wait(0.020);  DSR:Fire("EndBlock")
    end)
end
local function FireParry(isHeavy,force,uid)
    if not CanFire() then return false end
    local cd=GetCooldown(isHeavy); Firing=true; FiringAt=os.clock()
    NextParry=os.clock()+(IsBurst(uid) and PCFG.BurstCooldown or cd)
    local lead=GetLead(); local mfCount=GetMultiFire(uid,isHeavy)
    task.spawn(function()
        pcall(function()
            if lead>0.005 then task.wait(lead) end
            for i=1,mfCount do
                if IsSelfAttacking() then break end
                RawParry()
                if i<mfCount then task.wait(IsBurst(uid) and PCFG.BurstFireDelay or PCFG.MultiFireDelay) end
            end
        end)
        task.wait(0.035); Firing=false
    end)
    return true
end
local function FireM2Instant(uid)
    if not PCFG.M2InstantEnabled then return end
    if Firing and os.clock()-FiringAt>0.08 then Firing=false end
    NextParry=0
    task.spawn(function()
        for i=1,PCFG.M2PreCount do RawParry(); task.wait(PCFG.M2PreDelay) end
    end)
end

local M2_KW={"m2","heavy","charge","charged","block_break","smash","slam","uppercut","overhead","power","special","red","danger","unblockable","fury","burst","rage","break","grab","throw","launch","spin","finisher","execute","stomp","ground","aoe","super","ultra","final","critical"}
local M1_KW={"m1","m3","m4","m5","attack","atk","swing","swipe","slash","punch","hit","combo","strike","jab","lunge","thrust","kick","light","fast","quick","right","left","normal","basic","combat","fight","claw","stab","cut","slice","chop"}
local M2_ATTR={"State_HeavyAttack","State_M2","HeavyAttacking","M2","IsHeavy","ChargingAttack","PowerAttack","BlockBreak","IsUnblockable","RedAttack","SpecialAttack","FuryAttack","DangerState","ChargeState","HeavyState","UnblockState"}
local ALL_ATTR={"State_Attacking","State_AttackAnimation","State_Combat","Attacking","AttackAnimation","IsAttacking","IsSwinging","M1","Swinging","Punching","Hitting","InAttack","AttackState","Fighting","SwingActive","HitActive","StrikeActive","State_HeavyAttack","State_M2","HeavyAttacking","M2","IsHeavy","ChargingAttack","PowerAttack","BlockBreak","IsUnblockable","RedAttack","SpecialAttack","FuryAttack","DangerState","ChargeState","HeavyState","UnblockState"}

local function IsM2Anim(n) n=n:lower(); for _,k in ipairs(M2_KW) do if n:find(k,1,true) then return true end end; return false end
local function IsM1Anim(n) n=n:lower(); for _,k in ipairs(M1_KW) do if n:find(k,1,true) then return true end end; return false end
local function IsHeavyAttr(a) for _,k in ipairs(M2_ATTR) do if a==k then return true end end; return false end
local function ScanAttrs(char,eh)
    for _,a in ipairs(ALL_ATTR) do
        local v=char:GetAttribute(a)
        if v==true then return true,IsHeavyAttr(a),a end
        if type(v)=="string" and(v:lower():find("attack") or v:lower():find("heavy")) then return true,IsHeavyAttr(a),a end
        if eh then v=eh:GetAttribute(a); if v==true then return true,IsHeavyAttr(a),a end end
    end
    return false,false,nil
end
local function GetSwingBonus(er)
    if not PCFG.AnglePredict or not Root or not er then return 0 end
    local toMe=Root.Position-er.Position; local d=toMe.Magnitude; if d<0.1 then return 0 end
    local dirN=toMe/d; local fDot=er.CFrame.LookVector:Dot(dirN); local sDot=math.abs(er.CFrame.RightVector:Dot(dirN))
    local b=0; if fDot>0.5 then b+=14 end; if sDot>0.4 then b+=10 end; if fDot>0.78 then b+=8 end; return b
end
local function GetVelBonus(uid,er)
    if not PCFG.VelSharpening or not Root or not er then return 0 end
    local vel=er.Velocity; local prev=PrevVel[uid] or vel; PrevVel[uid]=vel
    local acc=(vel-prev).Magnitude; if acc<2 then return 0 end
    local toMe=Root.Position-er.Position
    if toMe.Magnitude<0.1 or vel.Magnitude<0.1 then return 0 end
    local dot=toMe.Unit:Dot(vel.Unit); local b=0
    if dot>0.25 then b+=math.floor(dot*30) end
    if math.abs(vel.Unit.Y)>0.35 and dot>0.1 then b+=12 end
    return math.min(b,42)
end
local function CheckVelPreFire(uid,er)
    if not PCFG.VelPreFire or not Root or not er then return end
    local vel=er.Velocity; local prev=PrevVel[uid] or vel
    local acc=(vel-prev).Magnitude
    if acc>=PCFG.VelPreFireThresh then
        local toMe=Root.Position-er.Position
        if toMe.Magnitude<0.1 or vel.Magnitude<0.1 then return end
        local dot=toMe.Unit:Dot(vel.Unit)
        if dot>0.3 then
            local now=os.clock()
            if now-(LastVelSpike[uid] or 0)>0.11 then LastVelSpike[uid]=now; FireParry(false,true,uid) end
        end
    end
end
local function Score(p)
    local ec=p.Character; if not ec then return 0,false end
    local er=ec:FindFirstChild("HumanoidRootPart"); local eh=ec:FindFirstChildWhichIsA("Humanoid")
    if not er or not eh or eh.Health<=0 or not Root then return 0,false end
    local d=Dist(Root,er); if d>PCFG.Range then return 0,false end
    local sc=0; local hvy=false; local uid=p.UserId
    sc+=math.floor((1-d/PCFG.Range)*15)
    local hasAttr,isHAttr,_=ScanAttrs(ec,eh)
    if isHAttr then sc+=80;hvy=true elseif hasAttr then sc+=50 end
    local anim=eh:FindFirstChildOfClass("Animator")
    if anim then
        local ok2,tracks=pcall(function() return anim:GetPlayingAnimationTracks() end)
        if ok2 and tracks then
            for _,t in pairs(tracks) do
                if t and t.IsPlaying then
                    local n=t.Animation.Name; local pos=t.TimePosition
                    if IsM2Anim(n) then hvy=true
                        if pos<=PCFG.PreFireThreshold then sc+=75
                        elseif pos<0.25 then sc+=60 else sc+=35 end; break
                    elseif IsM1Anim(n) then
                        if pos<=PCFG.PreFireThreshold then sc+=65
                        elseif pos<0.18 then sc+=50 else sc+=22 end; break
                    end
                end
            end
        end
    end
    if HeavyAlert[uid] then sc+=30;hvy=true end
    local combo=ComboTracker[uid] or 0; if combo>0 then sc+=math.min(combo*12,60) end
    if IsBurst(uid) then sc+=40 end
    local avg=GetAvgInterval(uid); if avg and avg<0.4 then sc+=math.floor((1-avg/0.4)*20) end
    sc+=GetSwingBonus(er); sc+=GetVelBonus(uid,er)
    if d<8 then
        local toMe=(Root.Position-er.Position).Unit
        if toMe:Dot(er.CFrame.LookVector)>0.62 then sc+=15 end
    end
    return math.min(sc,140),hvy
end
local function BuildQueue()
    local q={}
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP then local sc,hv=Score(p)
            if sc>=DynThreshold then table.insert(q,{player=p,score=sc,heavy=hv}) end
        end
    end
    table.sort(q,function(a,b) return a.score>b.score end)
    while #q>PCFG.MaxQueueTargets do table.remove(q) end
    return q
end

RunService.Heartbeat:Connect(function()
    if not PON or not Refresh() then return end
    if IsSelfAttacking() then return end
    local now=os.clock()
    if now-LastHeartbeat<PCFG.HeartbeatDebounce then return end
    LastHeartbeat=now
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP and p.Character then
            local er=p.Character:FindFirstChild("HumanoidRootPart")
            if er and Root and Dist(Root,er)<=PCFG.Range then
                local uid=p.UserId
                if ComboLockActive[uid] and TickComboLock(uid) then
                    if now>=NextParry then FireParry(false,true,uid) end
                end
                if IsBurst(uid) and now>=NextParry then FireParry(false,true,uid) end
                CheckVelPreFire(uid,er)
            end
        end
    end
    if now<NextParry then return end
    local q=BuildQueue()
    if #q>0 then
        local top=q[1]; local uid=top.player.UserId
        if top.heavy then HeavyAlert[uid]=true; task.delay(3,function() HeavyAlert[uid]=nil end) end
        local fired=FireParry(top.heavy,true,uid)
        if fired then UpdateCombo(uid,top.heavy,"HB"); UpdateThreshold(false) end
    end
end)

local function WatchChar(p,char)
    if not char then return end
    local er=char:FindFirstChild("HumanoidRootPart")
    local eh=char:FindFirstChildWhichIsA("Humanoid"); local uid=p.UserId
    local function watchA(obj,attr)
        pcall(function()
            obj:GetAttributeChangedSignal(attr):Connect(function()
                if not PON then return end
                if IsSelfAttacking() then return end
                local v=obj:GetAttribute(attr)
                if not(v==true or(type(v)=="string" and(v:lower():find("attack") or v:lower():find("heavy")))) then return end
                if not er or not Root then return end
                if Dist(Root,er)>PCFG.Range then return end
                local isHvy=IsHeavyAttr(attr)
                if isHvy then
                    HeavyAlert[uid]=true; task.delay(3,function() HeavyAlert[uid]=nil end)
                    if not M2Detected[uid] then
                        M2Detected[uid]=true; task.delay(2,function() M2Detected[uid]=nil end)
                        FireM2Instant(uid); return
                    end
                end
                UpdateCombo(uid,isHvy,attr); FireParry(isHvy,true,uid)
            end)
        end)
    end
    for _,a in ipairs(ALL_ATTR) do watchA(char,a); if eh then watchA(eh,a) end end
    local function watchAnim(animator)
        pcall(function()
            animator.AnimationPlayed:Connect(function(track)
                if not PON or not track then return end
                if IsSelfAttacking() then return end
                local ok2,n=pcall(function() return track.Animation.Name end)
                if not ok2 or not n then return end
                local isH=IsM2Anim(n); local isM=IsM1Anim(n)
                if not isH and not isM then return end
                if not er or not Root then return end
                if Dist(Root,er)>PCFG.Range then return end
                local now=os.clock(); local cK=string.format("%d_%s",uid,n)
                if now-(LastAnimFire[cK] or 0)<0.18 then return end
                LastAnimFire[cK]=now; UpdateCombo(uid,isH,n)
                if isH then
                    HeavyAlert[uid]=true; task.delay(3,function() HeavyAlert[uid]=nil end)
                    FireM2Instant(uid)
                else FireParry(false,true,uid) end
            end)
        end)
    end
    if eh then
        local an=eh:FindFirstChildOfClass("Animator")
        if an then watchAnim(an)
        else eh.ChildAdded:Connect(function(c) if c:IsA("Animator") then watchAnim(c) end end) end
    end
end

local function Watch(p)
    if not p or p==LP then return end
    if Watched[p.UserId] then return end
    Watched[p.UserId]=true
    if p.Character then WatchChar(p,p.Character) end
    p.CharacterAdded:Connect(function(c) Watched[p.UserId]=nil; task.wait(0.4); Watch(p) end)
end
local function WatchAll() for _,p in pairs(Players:GetPlayers()) do Watch(p) end end
WatchAll()
Players.PlayerAdded:Connect(function(p) task.wait(0.3); Watch(p) end)
Players.PlayerRemoving:Connect(function(p)
    local uid=p.UserId
    Watched[uid]=nil;PrevVel[uid]=nil;HeavyAlert[uid]=nil
    ComboTracker[uid]=nil;LastHitTime[uid]=nil;HitHistory[uid]=nil
    LastAnimFire[uid]=nil;ComboLockActive[uid]=nil
    ComboLockCount[uid]=nil;M2Detected[uid]=nil
    LastVelSpike[uid]=nil;BurstActive[uid]=nil
end)

local function pktHook(pkt,heavy)
    if not pkt then return end
    pkt.OnClientEvent:Connect(function()
        NextParry=0;Firing=false
        if heavy then FireM2Instant(nil) else FireParry(false,true) end
    end)
end
pktHook(M2Pkt,true);pktHook(HeavyAtk,true)
pktHook(ChargeAtk,true);pktHook(RedSig,true);pktHook(ComboPkt,false)

GotHit.OnClientEvent:Connect(function()
    NextParry=0;Firing=false;MissCount+=1; UpdateThreshold(true)
    if Root then
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er=p.Character:FindFirstChild("HumanoidRootPart")
                if er and Dist(Root,er)<=PCFG.Range then
                    local uid=p.UserId
                    UpdateCombo(uid,false,"GotHit")
                    ActivateComboLock(uid,PCFG.ComboLockMax)
                    ActivateBurst(uid)
                end
            end
        end
    end
    FireParry(false,true)
end)

BlockHit.OnClientEvent:Connect(function() NextParry=0;Firing=false; FireParry(false,true) end)
CTChange.OnClientEvent:Connect(function(t) if t then NextParry=0;Firing=false end end)
ParryOK.OnClientEvent:Connect(function() ParryCount+=1 end)

LP.CharacterAdded:Connect(function(c)
    Char=c;Hum=c:WaitForChild("Humanoid");Root=c:WaitForChild("HumanoidRootPart")
    NextParry=0;Firing=false;FiringAt=0;LastHeartbeat=0
    Watched={};HeavyAlert={};ComboTracker={};LastHitTime={};HitHistory={}
    LastAnimFire={};ComboLockActive={};ComboLockCount={};ComboLockUntil={}
    M2Detected={};LastVelSpike={};BurstActive={};BurstUntil={};PrevVel={}
    DynThreshold=PCFG.ScoreThreshold;ConsecMiss=0
    task.wait(0.7);WatchAll()
end)

-- ════════════════════════════════════════════════════════
-- AIM SYSTEMS (v5.1, intact)
-- ════════════════════════════════════════════════════════
local function IsBlocked()
    local c=GetChar(); if not c then return true end
    for _,s in ipairs(ACFG.BlockedStates) do
        if c:GetAttribute(s)==true then return true end
    end
    return false
end
local function ValidTarget(t)
    if not t or not t.Parent then return false end
    local c=t.Character; if not c then return false end
    local h=c:FindFirstChild("Humanoid")
    if not h or h.Health<=0 then return false end
    local r=c:FindFirstChild("HumanoidRootPart"); if not r then return false end
    local myR=GetRoot(); if not myR then return false end
    return Dist(myR,r)<=ACFG.Range*ACFG.StickyMult
end
local function RefreshLock() AS.ExpireTime=os.clock()+ACFG.LockDuration end
local function DestroyConstraint()
    pcall(function()
        if AS.AlignOri then AS.AlignOri:Destroy(); AS.AlignOri=nil end
        if AS.Att0 then AS.Att0:Destroy(); AS.Att0=nil end
    end)
end
local function SetupConstraint()
    local root=GetRoot(); if not root then return end
    pcall(function()
        if AS.AlignOri then AS.AlignOri:Destroy() end
        if AS.Att0 then AS.Att0:Destroy() end
    end)
    local att=Instance.new("Attachment"); att.Name="_AA_A0"; att.Parent=root; AS.Att0=att
    local ao=Instance.new("AlignOrientation"); ao.Name="_AA_AO"
    ao.Mode=Enum.OrientationAlignmentMode.OneAttachment; ao.Attachment0=att
    ao.MaxTorque=ACFG.MaxTorque; ao.MaxAngularVelocity=math.huge
    ao.Responsiveness=ACFG.Responsiveness; ao.RigidityEnabled=false
    ao.PrimaryAxisOnly=false; ao.Parent=root; AS.AlignOri=ao
end
local function SetAimDir(pos)
    if not AS.AlignOri or IsBlocked() then return end
    local root=GetRoot(); if not root then return end
    local dir=pos-root.Position; dir=Vector3.new(dir.X,0,dir.Z)
    if dir.Magnitude<0.05 then return end; dir=dir.Unit
    local up=Vector3.new(0,1,0); local right=dir:Cross(up)
    if right.Magnitude<0.01 then return end; right=right.Unit
    AS.AlignOri.CFrame=CFrame.fromMatrix(Vector3.zero,right,right:Cross(dir).Unit)
end
local function UpdateVel(pos)
    local now=os.clock(); local dt=now-AS.LastVelT
    if AS.PrevPos and dt>0 and dt<0.3 then AS.Vel=AS.Vel:Lerp((pos-AS.PrevPos)/dt,0.35) end
    AS.PrevPos=pos; AS.LastVelT=now
end
local function Predict(pos,dt)
    local hv=Vector3.new(AS.Vel.X,0,AS.Vel.Z)
    return pos+hv*ACFG.PredictFactor*dt*60
end

local GetBestTarget, SwitchNext, LockOn, UnlockAll

GetBestTarget = function(rescan)
    local root=GetRoot(); if not root then return nil end
    if not rescan and AS.Target and ValidTarget(AS.Target) then return AS.Target end
    AS.Candidates={}; local best,bestD=nil,ACFG.Range
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP then
            local c=p.Character; if not c then continue end
            local r=c:FindFirstChild("HumanoidRootPart"); local h=c:FindFirstChild("Humanoid")
            if not r or not h or h.Health<=0 then continue end
            local d=Dist(root,r)
            if d<=ACFG.Range then table.insert(AS.Candidates,{p=p,dist=d})
                if d<bestD then bestD=d; best=p end end
        end
    end
    table.sort(AS.Candidates,function(a,b) return a.dist<b.dist end)
    return best
end

LockOn = function(t)
    if not t then return end
    local isNew=(t~=AS.Target)
    AS.Target=t; AS.PrevPos=nil; AS.Vel=Vector3.zero
    RefreshLock()
    if isNew then SetupConstraint() end
end

UnlockAll = function()
    AS.Target=nil; AS.PrevPos=nil; AS.Vel=Vector3.zero
    DestroyConstraint()
end

SwitchNext = function()
    if #AS.Candidates<1 then return end
    if not AS.Target then LockOn(AS.Candidates[1].p); return end
    for i,c in ipairs(AS.Candidates) do
        if c.p==AS.Target then LockOn(AS.Candidates[i%#AS.Candidates+1].p); return end
    end
    LockOn(AS.Candidates[1].p)
end

local function OnGotHitAim()
    if not ACFG.ON then return end
    AS.InCombat=true
    if not ACFG.SwitchOnHit then
        local b=GetBestTarget(true); if b then LockOn(b) end; return
    end
    local now=os.clock()
    if now-AS.LastSwitch<ACFG.SwitchCooldown then return end
    AS.LastSwitch=now
    local root=GetRoot(); if not root then return end
    local closest,cd=nil,ACFG.Range
    for _,p in pairs(Players:GetPlayers()) do
        if p~=LP and p~=AS.Target and p.Character then
            local er=p.Character:FindFirstChild("HumanoidRootPart")
            local eh=p.Character:FindFirstChild("Humanoid")
            if er and eh and eh.Health>0 then
                local d=Dist(root,er); if d<cd then cd=d; closest=p end
            end
        end
    end
    if closest then LockOn(closest)
    elseif not AS.Target then local b=GetBestTarget(true); if b then LockOn(b) end
    else RefreshLock() end
end

GotHit.OnClientEvent:Connect(OnGotHitAim)

if HitConfirm then
    HitConfirm.OnClientEvent:Connect(function(t)
        if not ACFG.ON then return end
        AS.InCombat=true
        if t and typeof(t)=="Instance" and t:IsA("Player") and t~=LP then LockOn(t)
        else local b=GetBestTarget(true); if b then LockOn(b) end end
    end)
end

CTChange.OnClientEvent:Connect(function(tagged)
    AS.InCombat=tagged
    if tagged and AS.Target then RefreshLock() end
end)

local function ProxCheck()
    if HitConfirm or not ACFG.ON then return end
    local now=os.clock(); if now-AS.LastProx<0.12 then return end; AS.LastProx=now
    local c=GetChar(); if not c then return end
    local isAtk=c:GetAttribute("State_Attacking")==true
    if isAtk and not AS.IsAtk then
        local root=GetRoot(); if not root then return end
        local closest,cd=nil,ACFG.ProxRange
        for _,p in pairs(Players:GetPlayers()) do
            if p~=LP and p.Character then
                local er=p.Character:FindFirstChild("HumanoidRootPart")
                local eh=p.Character:FindFirstChild("Humanoid")
                if er and eh and eh.Health>0 then
                    local d=Dist(root,er); if d<cd then cd=d; closest=p end
                end
            end
        end
        if closest then AS.InCombat=true; LockOn(closest) end
    end
    AS.IsAtk=isAtk
end

RunService.Heartbeat:Connect(function(dt)
    if Camera.CameraType~=Enum.CameraType.Custom then Camera.CameraType=Enum.CameraType.Custom end
    if not ACFG.ON then return end
    ProxCheck()
    if AS.Target and os.clock()>AS.ExpireTime then UnlockAll(); return end
    if AS.Target and not ValidTarget(AS.Target) then
        UnlockAll(); GetBestTarget(true)
        if #AS.Candidates>0 then LockOn(AS.Candidates[1].p) end; return
    end
    if not AS.Target then return end
    local ec=AS.Target.Character; if not ec then return end
    local er=ec:FindFirstChild("HumanoidRootPart"); if not er then return end
    UpdateVel(er.Position); SetAimDir(Predict(er.Position,dt))
end)

Players.PlayerRemoving:Connect(function(p)
    if AS.Target==p then
        UnlockAll(); GetBestTarget(true)
        if #AS.Candidates>0 then LockOn(AS.Candidates[1].p) end
    end
end)

LP.CharacterAdded:Connect(function()
    UnlockAll(); AS.InCombat=false; AS.IsAtk=false
    task.wait(0.5); SetupConstraint()
end)

UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==ACFG.SwitchKey then
        if not ACFG.ON then return end
        GetBestTarget(true); SwitchNext()
    end
end)

-- ════════════════════════════════════════════════════════
-- COMBINED UI
-- ════════════════════════════════════════════════════════
local old=PGui:FindFirstChild("CombinedUI")
if old then old:Destroy() end

local SG=Instance.new("ScreenGui")
SG.Name="CombinedUI"; SG.ResetOnSpawn=false
SG.IgnoreGuiInset=true; SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
SG.Parent=PGui

-- ─── MAIN PANEL ───────────────────────────────────────────
local Panel=Instance.new("Frame")
Panel.Name="Panel"; Panel.Size=UDim2.new(0,170,0,220)
Panel.Position=UDim2.new(0,20,0.5,-110)
Panel.BackgroundColor3=Color3.fromRGB(12,12,12)
Panel.BackgroundTransparency=0.15
Panel.BorderSizePixel=0; Panel.Active=true; Panel.Parent=SG
Instance.new("UICorner",Panel).CornerRadius=UDim.new(0,10)

local PanelStroke=Instance.new("UIStroke",Panel)
PanelStroke.Thickness=1.5; PanelStroke.Color=Color3.fromRGB(60,60,60)

-- ─── HEADER ───────────────────────────────────────────────
local Header=Instance.new("Frame")
Header.Size=UDim2.new(1,0,0,30)
Header.BackgroundColor3=Color3.fromRGB(22,22,22)
Header.BorderSizePixel=0; Header.Parent=Panel
Instance.new("UICorner",Header).CornerRadius=UDim.new(0,10)
local HFix=Instance.new("Frame")
HFix.Size=UDim2.new(1,0,0.5,0); HFix.Position=UDim2.new(0,0,0.5,0)
HFix.BackgroundColor3=Color3.fromRGB(22,22,22); HFix.BorderSizePixel=0; HFix.Parent=Header

local TitleLbl=Instance.new("TextLabel")
TitleLbl.Text="⚔️ COMBAT TOOLS"; TitleLbl.Size=UDim2.new(1,-36,1,0)
TitleLbl.Position=UDim2.new(0,10,0,0); TitleLbl.BackgroundTransparency=1
TitleLbl.TextColor3=Color3.fromRGB(220,220,220); TitleLbl.TextSize=12
TitleLbl.Font=Enum.Font.GothamBold; TitleLbl.TextXAlignment=Enum.TextXAlignment.Left
TitleLbl.Parent=Header

local CloseBtn=Instance.new("TextButton")
CloseBtn.Size=UDim2.new(0,22,0,22); CloseBtn.Position=UDim2.new(1,-26,0.5,-11)
CloseBtn.BackgroundColor3=Color3.fromRGB(35,35,35); CloseBtn.Text="✕"
CloseBtn.TextColor3=Color3.fromRGB(160,160,160); CloseBtn.TextSize=11
CloseBtn.Font=Enum.Font.GothamBold; CloseBtn.BorderSizePixel=0; CloseBtn.Parent=Header
Instance.new("UICorner",CloseBtn).CornerRadius=UDim.new(0,5)

-- ─── DIVIDER LABEL ────────────────────────────────────────
local function MakeLabel(text, yPos)
    local lbl=Instance.new("TextLabel")
    lbl.Text=text; lbl.Size=UDim2.new(1,-16,0,14)
    lbl.Position=UDim2.new(0,8,0,yPos)
    lbl.BackgroundTransparency=1
    lbl.TextColor3=Color3.fromRGB(100,100,100)
    lbl.TextSize=9; lbl.Font=Enum.Font.GothamBold
    lbl.TextXAlignment=Enum.TextXAlignment.Left
    lbl.Parent=Panel; return lbl
end

local function MakeBtn(text, yPos, color)
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(1,-16,0,32); btn.Position=UDim2.new(0,8,0,yPos)
    btn.BackgroundColor3=color or Color3.fromRGB(40,40,40)
    btn.TextColor3=Color3.fromRGB(255,255,255); btn.TextSize=12
    btn.Font=Enum.Font.GothamBold; btn.Text=text
    btn.BorderSizePixel=0; btn.Parent=Panel
    Instance.new("UICorner",btn).CornerRadius=UDim.new(0,7)
    return btn
end

-- PARRY section
MakeLabel("— AUTO PARRY —", 36)
local ParryBtn=MakeBtn("⚔ PARRY: OFF", 52, Color3.fromRGB(180,35,35))

-- AIM section
MakeLabel("— AUTO AIM —", 96)
local AimBtn=MakeBtn("🎯 AIM: OFF", 112, Color3.fromRGB(180,35,35))

-- AIM info
local TargetLbl=Instance.new("TextLabel")
TargetLbl.Size=UDim2.new(1,-16,0,16); TargetLbl.Position=UDim2.new(0,8,0,150)
TargetLbl.BackgroundTransparency=1; TargetLbl.TextColor3=Color3.fromRGB(255,200,80)
TargetLbl.TextSize=10; TargetLbl.Font=Enum.Font.Gotham
TargetLbl.TextXAlignment=Enum.TextXAlignment.Left
TargetLbl.Text="Target: -"; TargetLbl.TextTruncate=Enum.TextTruncate.AtEnd
TargetLbl.Parent=Panel

local InfoLbl=Instance.new("TextLabel")
InfoLbl.Size=UDim2.new(1,-16,0,14); InfoLbl.Position=UDim2.new(0,8,0,168)
InfoLbl.BackgroundTransparency=1; InfoLbl.TextColor3=Color3.fromRGB(110,110,110)
InfoLbl.TextSize=9; InfoLbl.Font=Enum.Font.Gotham
InfoLbl.TextXAlignment=Enum.TextXAlignment.Left
InfoLbl.Text="Dist: - | HP: -"; InfoLbl.Parent=Panel

-- Switch button
local SwBtn=MakeBtn("🔄 Switch Target", 186, Color3.fromRGB(50,85,180))

-- ─── REOPEN BUTTON ────────────────────────────────────────
local ReopenBtn=Instance.new("TextButton")
ReopenBtn.Size=UDim2.new(0,38,0,38); ReopenBtn.Position=Panel.Position
ReopenBtn.BackgroundColor3=Color3.fromRGB(15,15,15); ReopenBtn.Text="⚔️"
ReopenBtn.TextColor3=Color3.fromRGB(255,255,255); ReopenBtn.TextSize=18
ReopenBtn.Font=Enum.Font.GothamBold; ReopenBtn.BorderSizePixel=0
ReopenBtn.Visible=false; ReopenBtn.Active=true; ReopenBtn.Parent=SG
Instance.new("UICorner",ReopenBtn).CornerRadius=UDim.new(0,8)
local RStroke=Instance.new("UIStroke",ReopenBtn)
RStroke.Thickness=1.5; RStroke.Color=Color3.fromRGB(60,60,60)

-- ─── UI UPDATE ────────────────────────────────────────────
local function UpdateUI()
    -- Parry
    if PON then
        ParryBtn.BackgroundColor3=Color3.fromRGB(30,160,65)
        ParryBtn.Text="⚔ PARRY: ON"
        PanelStroke.Color=Color3.fromRGB(30,160,65)
        RStroke.Color=Color3.fromRGB(30,160,65)
    else
        ParryBtn.BackgroundColor3=Color3.fromRGB(180,35,35)
        ParryBtn.Text="⚔ PARRY: OFF"
        if not ACFG.ON then
            PanelStroke.Color=Color3.fromRGB(60,60,60)
            RStroke.Color=Color3.fromRGB(60,60,60)
        end
    end
    -- Aim
    if ACFG.ON then
        AimBtn.BackgroundColor3=Color3.fromRGB(30,120,200)
        AimBtn.Text="🎯 AIM: ON"
        PanelStroke.Color=Color3.fromRGB(30,120,200)
        RStroke.Color=Color3.fromRGB(30,120,200)
    else
        AimBtn.BackgroundColor3=Color3.fromRGB(180,35,35)
        AimBtn.Text="🎯 AIM: OFF"
        if not PON then
            PanelStroke.Color=Color3.fromRGB(60,60,60)
            RStroke.Color=Color3.fromRGB(60,60,60)
        end
    end
    -- Both on = cyan
    if PON and ACFG.ON then
        PanelStroke.Color=Color3.fromRGB(0,220,180)
        RStroke.Color=Color3.fromRGB(0,220,180)
    end
    -- Target info
    if AS.Target and AS.Target.Character then
        local ec=AS.Target.Character
        local er=ec:FindFirstChild("HumanoidRootPart")
        local eh=ec:FindFirstChild("Humanoid")
        local myR=GetRoot()
        local dist=(er and myR) and math.floor(Dist(myR,er)) or 0
        local hp=eh and math.floor(eh.Health) or 0
        local mhp=eh and math.floor(eh.MaxHealth) or 0
        TargetLbl.Text="🎯 "..AS.Target.Name
        InfoLbl.Text=string.format("Dist:%d | HP:%d/%d",dist,hp,mhp)
    else
        TargetLbl.Text="Target: -"
        InfoLbl.Text="Dist: - | HP: -"
    end
end

-- Update UI 3x/sec
RunService.Heartbeat:Connect(function(dt)
    if math.floor(os.clock()*3)~=math.floor((os.clock()-dt)*3) then UpdateUI() end
end)

-- ─── BUTTON ACTIONS ───────────────────────────────────────
ParryBtn.MouseButton1Click:Connect(function()
    PON=not PON; NextParry=0; Firing=false
    TweenService:Create(ParryBtn,TweenInfo.new(0.07),{Size=UDim2.new(1,-22,0,28)}):Play()
    task.wait(0.07)
    TweenService:Create(ParryBtn,TweenInfo.new(0.07),{Size=UDim2.new(1,-16,0,32)}):Play()
    UpdateUI()
end)

AimBtn.MouseButton1Click:Connect(function()
    ACFG.ON=not ACFG.ON
    if not ACFG.ON then UnlockAll() end
    TweenService:Create(AimBtn,TweenInfo.new(0.07),{Size=UDim2.new(1,-22,0,28)}):Play()
    task.wait(0.07)
    TweenService:Create(AimBtn,TweenInfo.new(0.07),{Size=UDim2.new(1,-16,0,32)}):Play()
    UpdateUI()
end)

SwBtn.MouseButton1Click:Connect(function()
    if not ACFG.ON then return end
    GetBestTarget(true); SwitchNext()
    TweenService:Create(SwBtn,TweenInfo.new(0.07),{BackgroundColor3=Color3.fromRGB(90,130,255)}):Play()
    task.wait(0.15)
    TweenService:Create(SwBtn,TweenInfo.new(0.07),{BackgroundColor3=Color3.fromRGB(50,85,180)}):Play()
end)

CloseBtn.MouseButton1Click:Connect(function()
    TweenService:Create(Panel,TweenInfo.new(0.12,Enum.EasingStyle.Quad,Enum.EasingDirection.In),
        {Size=UDim2.new(0,0,0,0)}):Play()
    task.wait(0.12); Panel.Visible=false
    ReopenBtn.Visible=true; ReopenBtn.Position=Panel.Position
    Panel.Size=UDim2.new(0,170,0,220)
end)

ReopenBtn.MouseButton1Click:Connect(function()
    Panel.Position=UDim2.new(
        ReopenBtn.Position.X.Scale, ReopenBtn.Position.X.Offset,
        ReopenBtn.Position.Y.Scale, ReopenBtn.Position.Y.Offset)
    Panel.Visible=true; Panel.Size=UDim2.new(0,0,0,0)
    ReopenBtn.Visible=false
    TweenService:Create(Panel,TweenInfo.new(0.12,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),
        {Size=UDim2.new(0,170,0,220)}):Play()
end)

-- Keyboard toggle parry
UIS.InputBegan:Connect(function(i,g)
    if g then return end
    if i.KeyCode==PCFG.ToggleKey then
        PON=not PON; NextParry=0; Firing=false; UpdateUI()
    end
    if i.KeyCode==ACFG.ToggleKey then
        ACFG.ON=not ACFG.ON
        if not ACFG.ON then UnlockAll() end; UpdateUI()
    end
end)

-- ─── DRAG ─────────────────────────────────────────────────
local dragging,dragStart,startPos,dragTarget=false,nil,nil,nil

local function MakeDraggable(handle,target)
    handle.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.Touch
        or i.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true; dragTarget=target
            dragStart=i.Position; startPos=target.Position
            i.Changed:Connect(function()
                if i.UserInputState==Enum.UserInputState.End then dragging=false end
            end)
        end
    end)
end

UIS.InputChanged:Connect(function(i)
    if not dragging or not dragTarget then return end
    if i.UserInputType==Enum.UserInputType.MouseMovement
    or i.UserInputType==Enum.UserInputType.Touch then
        local d=i.Position-dragStart
        dragTarget.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,
            startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1
    or i.UserInputType==Enum.UserInputType.Touch then dragging=false; dragTarget=nil end
end)

MakeDraggable(Header,Panel)
MakeDraggable(ReopenBtn,ReopenBtn)

UpdateUI()
