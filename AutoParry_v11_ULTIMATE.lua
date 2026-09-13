-- ================================================================
--  Auto Aim v4.3 CLEAN
--  * Lock expire      -> NETRAL (no switch)
--  * Target mati      -> NETRAL (no switch)
--  * Musuh keluar     -> NETRAL (no switch)
--  * Gua mati         -> NETRAL (no switch)
--  * Player X hit gua -> SWITCH ke player X (siapapun)
--  * Parry only DEPAN/KIRI/KANAN (bukan belakang)
--  * Lock duration 30s, refresh tiap trigger
-- ================================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

-- ================================================================
--  PACKETS
-- ================================================================
local Shared           = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Shared")
local Packets          = require(Shared:WaitForChild("Packets"))

local GotHit           = Packets.GotHitScreenEffect
local CombatTagChanged = Packets.CombatTagChanged

local HitConfirm = nil
local HIT_PACKET_NAMES = {
    "HitConfirm", "DealDamage", "HitEffect", "AttackHit",
    "DamageDone", "HitTarget", "OnHit", "AttackConnected",
    "HitSuccess", "DamageDealt", "MeleeHit", "HitRegistered",
}
for _, name in ipairs(HIT_PACKET_NAMES) do
    if Packets[name] then
        HitConfirm = Packets[name]
        print("[AA] HitConfirm packet found: " .. name)
        break
    end
end
if not HitConfirm then
    print("[AA] HitConfirm packet not found -- using proximity fallback")
end

-- ================================================================
--  CONFIG
-- ================================================================
local CFG = {
    AUTO_AIM            = true,
    AIM_RANGE           = 80,

    LOCK_DURATION       = 30,

    MAX_TORQUE          = 1e6,
    RESPONSIVENESS      = 35,

    PREDICT_ENABLED     = true,
    PREDICT_FACTOR      = 0.10,

    STICK_TO_TARGET     = true,
    STICKY_RANGE_MULT   = 1.6,

    PROXIMITY_HIT_RANGE = 12,

    PARRY_ENABLED       = true,
    PARRY_FRONT_ANGLE   = 130,

    USERNAME_MODE       = "none",
    USERNAME_LIST       = {},

    BLOCKED_STATES = {
        "State_Ragdolled",
        "State_Safe",
        "State_Dead",
        "State_Downed",
        "State_Gripped",
        "State_Carried",
        "State_Stunned",
    },

    TOGGLE_KEY          = Enum.KeyCode.RightControl,
    SWITCH_KEY          = Enum.KeyCode.RightShift,
    DEBUG               = false,
}

-- ================================================================
--  STATE
-- ================================================================
local State = {
    CurrentTarget    = nil,
    LockExpireTime   = 0,
    InCombat         = false,
    PrevTargetPos    = nil,
    TargetVelocity   = Vector3.zero,
    LastVelUpdate    = 0,
    Candidates       = {},
    AlignOri         = nil,
    Att0             = nil,
    ConstraintPart   = nil,
    IsAttacking      = false,
}

-- ================================================================
--  UTILS
-- ================================================================
local function Log(...) if CFG.DEBUG then print("[AA]", ...) end end

local function Notify(txt, dur)
    pcall(function()
        game.StarterGui:SetCore("SendNotification", {
            Title    = "[AA] Auto Aim v4.3",
            Text     = txt,
            Duration = dur or 2,
        })
    end)
end

local function EnsureCamera()
    if Camera.CameraType ~= Enum.CameraType.Custom then
        Camera.CameraType = Enum.CameraType.Custom
    end
end

local function GetRoot()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function GetChar() return LocalPlayer.Character end

local function IsBlocked()
    local c = GetChar(); if not c then return true end
    for _, s in ipairs(CFG.BLOCKED_STATES) do
        if c:GetAttribute(s) == true then return true end
    end
    return false
end

local function IsInList(p)
    local n = p.Name:lower()
    for _, u in ipairs(CFG.USERNAME_LIST) do
        if u:lower() == n then return true end
    end
    return false
end

local function IsAllowed(p)
    if CFG.USERNAME_MODE == "whitelist" then return IsInList(p) end
    if CFG.USERNAME_MODE == "blacklist" then return not IsInList(p) end
    return true
end

local function LockIsExpired()
    return os.clock() > State.LockExpireTime
end

local function RefreshLock()
    State.LockExpireTime = os.clock() + CFG.LOCK_DURATION
    Log("Lock refreshed -- expires in", CFG.LOCK_DURATION, "sec")
end

local function IsTargetValid(t)
    if not t or not t.Parent then return false end
    local c = t.Character; if not c then return false end
    local h = c:FindFirstChild("Humanoid")
    if not h or h.Health <= 0 then return false end
    local r = c:FindFirstChild("HumanoidRootPart"); if not r then return false end
    local myR = GetRoot(); if not myR then return false end
    local dist = (myR.Position - r.Position).Magnitude
    return dist <= CFG.AIM_RANGE * CFG.STICKY_RANGE_MULT
end

-- ================================================================
--  PARRY DIRECTION FILTER
--  dot < threshold = attacker dari belakang -> skip
-- ================================================================
local function IsParryableDirection(attackerRootPos)
    if not CFG.PARRY_ENABLED then return true end
    local root = GetRoot(); if not root then return false end

    local myForward  = root.CFrame.LookVector
    local toAttacker = (attackerRootPos - root.Position)
    toAttacker = Vector3.new(toAttacker.X, 0, toAttacker.Z)
    if toAttacker.Magnitude < 0.01 then return true end
    toAttacker = toAttacker.Unit

    local dot           = myForward:Dot(toAttacker)
    local backThreshold = -math.cos(math.rad(CFG.PARRY_FRONT_ANGLE / 2))

    if dot < backThreshold then
        Log("Parry blocked -- attacker dari belakang | dot:", dot)
        return false
    end
    Log("Parry allowed | dot:", dot)
    return true
end

-- ================================================================
--  ALIGN ORIENTATION CONSTRAINT
-- ================================================================
local function SetupConstraint()
    local root = GetRoot(); if not root then return end

    pcall(function()
        if State.AlignOri       then State.AlignOri:Destroy()       end
        if State.Att0           then State.Att0:Destroy()           end
        if State.ConstraintPart then State.ConstraintPart:Destroy() end
    end)

    local att0  = Instance.new("Attachment")
    att0.Name   = "_AA_Att0"
    att0.Parent = root
    State.Att0  = att0

    local ao              = Instance.new("AlignOrientation")
    ao.Name               = "_AA_AO"
    ao.Mode               = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0        = att0
    ao.MaxTorque          = CFG.MAX_TORQUE
    ao.MaxAngularVelocity = math.huge
    ao.Responsiveness     = CFG.RESPONSIVENESS
    ao.RigidityEnabled    = false
    ao.PrimaryAxisOnly    = false
    ao.Parent             = root
    State.AlignOri        = ao

    Log("Constraint ready")
end

local function DestroyConstraint()
    pcall(function()
        if State.AlignOri       then State.AlignOri:Destroy();       State.AlignOri       = nil end
        if State.Att0           then State.Att0:Destroy();           State.Att0           = nil end
        if State.ConstraintPart then State.ConstraintPart:Destroy(); State.ConstraintPart = nil end
    end)
end

local function SetAimDir(targetPos)
    if not State.AlignOri then return end
    if IsBlocked() then return end
    local root = GetRoot(); if not root then return end

    local dir = targetPos - root.Position
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 0.05 then return end
    dir = dir.Unit

    local up    = Vector3.new(0, 1, 0)
    local right = dir:Cross(up)
    if right.Magnitude < 0.01 then return end
    right       = right.Unit
    local newUp = right:Cross(dir).Unit

    State.AlignOri.CFrame = CFrame.fromMatrix(Vector3.zero, right, newUp)
end

-- ================================================================
--  VELOCITY PREDICTION
-- ================================================================
local function UpdateVelocity(pos)
    local now = os.clock()
    local dt  = now - State.LastVelUpdate
    if State.PrevTargetPos and dt > 0 and dt < 0.3 then
        local raw = (pos - State.PrevTargetPos) / dt
        State.TargetVelocity = State.TargetVelocity:Lerp(raw, 0.3)
    end
    State.PrevTargetPos = pos
    State.LastVelUpdate = now
end

local function PredictPos(pos, dt)
    if not CFG.PREDICT_ENABLED then return pos end
    local hv = Vector3.new(State.TargetVelocity.X, 0, State.TargetVelocity.Z)
    return pos + hv * CFG.PREDICT_FACTOR * dt * 60
end

-- ================================================================
--  TARGET SELECTION
-- ================================================================
local function ScoreTarget(p, myRoot)
    if not IsAllowed(p) then return nil end
    local c = p.Character; if not c then return nil end
    local r = c:FindFirstChild("HumanoidRootPart")
    local h = c:FindFirstChild("Humanoid")
    if not r or not h or h.Health <= 0 then return nil end
    local d = (myRoot.Position - r.Position).Magnitude
    if d > CFG.AIM_RANGE then return nil end
    local score = d
    if CFG.USERNAME_MODE == "whitelist" and IsInList(p) then score = score * 0.05 end
    return score, d
end

local function GetBestTarget(forceRescan)
    local root = GetRoot(); if not root then return nil end
    if CFG.STICK_TO_TARGET and not forceRescan and State.CurrentTarget then
        if IsTargetValid(State.CurrentTarget) then return State.CurrentTarget end
    end
    State.Candidates = {}
    local best, bestScore = nil, math.huge
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local score, dist = ScoreTarget(p, root)
            if score then
                table.insert(State.Candidates, {p = p, score = score, dist = dist})
                if score < bestScore then bestScore = score; best = p end
            end
        end
    end
    table.sort(State.Candidates, function(a, b) return a.score < b.score end)
    return best
end

local function SwitchNext()
    if #State.Candidates < 2 then Notify("No other targets"); return end
    for i, c in ipairs(State.Candidates) do
        if c.p == State.CurrentTarget then
            local nx = State.Candidates[i % #State.Candidates + 1]
            if nx then
                State.CurrentTarget  = nx.p
                State.PrevTargetPos  = nil
                State.TargetVelocity = Vector3.zero
                RefreshLock()
                Notify("[SWITCH] -> " .. nx.p.Name)
            end
            return
        end
    end
end

-- ================================================================
--  LOCK / UNLOCK
-- ================================================================
local function UnlockAll(reason)
    State.CurrentTarget  = nil
    State.PrevTargetPos  = nil
    State.TargetVelocity = Vector3.zero
    DestroyConstraint()
    Log("Unlocked:", reason)
end

local function GoNeutral(reason)
    local prevName = State.CurrentTarget and State.CurrentTarget.Name or "none"
    UnlockAll(reason)
    Notify("[UNLOCK] Netral (" .. reason .. "): " .. prevName, 2)
end

local function LockOn(t, reason)
    if not t then return end
    local isNew = (t ~= State.CurrentTarget)
    State.CurrentTarget  = t
    State.PrevTargetPos  = nil
    State.TargetVelocity = Vector3.zero
    RefreshLock()
    if isNew then
        SetupConstraint()
        Notify("[LOCK] " .. t.Name .. " [" .. reason .. "]")
        Log("Locked:", t.Name, "via", reason)
    else
        Log("Lock refreshed:", t.Name, "via", reason)
    end
end

-- ================================================================
--  RESOLVE ATTACKER
-- ================================================================
local function ResolveAttacker(packetArg)
    if packetArg then
        if typeof(packetArg) == "Instance" and packetArg:IsA("Player") then
            if packetArg ~= LocalPlayer and IsAllowed(packetArg) then
                local c = packetArg.Character
                if c then
                    local r = c:FindFirstChild("HumanoidRootPart")
                    local h = c:FindFirstChild("Humanoid")
                    if r and h and h.Health > 0 then
                        return packetArg, r.Position
                    end
                end
            end
        end
    end

    local root = GetRoot(); if not root then return nil, nil end
    local closest, closestDist, closestPos = nil, CFG.PROXIMITY_HIT_RANGE * 2, nil
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and IsAllowed(p) and p.Character then
            local er = p.Character:FindFirstChild("HumanoidRootPart")
            local eh = p.Character:FindFirstChild("Humanoid")
            if er and eh and eh.Health > 0 then
                local d = (root.Position - er.Position).Magnitude
                if d < closestDist then
                    closestDist = d
                    closest     = p
                    closestPos  = er.Position
                end
            end
        end
    end
    return closest, closestPos
end

-- ================================================================
--  TRIGGER: LO KENA HIT
-- ================================================================
GotHit.OnClientEvent:Connect(function(arg1, arg2, arg3)
    if not CFG.AUTO_AIM then return end
    State.InCombat = true

    local attacker, attackerPos = ResolveAttacker(arg1)
    if not attacker then attacker, attackerPos = ResolveAttacker(arg2) end
    if not attacker then attacker, attackerPos = ResolveAttacker(arg3) end

    if attackerPos and not IsParryableDirection(attackerPos) then
        Log("GotHit dari belakang -- skip")
        return
    end

    if attacker then
        LockOn(attacker, "kena hit")
        Log("Switch ke attacker:", attacker.Name)
    else
        local best = GetBestTarget(true)
        if best then LockOn(best, "kena hit (fallback)") end
    end
end)

-- ================================================================
--  TRIGGER: LO NGEHIT ORANG
-- ================================================================
if HitConfirm then
    HitConfirm.OnClientEvent:Connect(function(targetPlayer, ...)
        if not CFG.AUTO_AIM then return end
        State.InCombat = true
        if targetPlayer and typeof(targetPlayer) == "Instance"
            and targetPlayer:IsA("Player")
            and targetPlayer ~= LocalPlayer then
            LockOn(targetPlayer, "lo ngehit")
            return
        end
        local best = GetBestTarget(true)
        if best then LockOn(best, "lo ngehit (fallback)") end
    end)
end

-- ================================================================
--  PROXIMITY FALLBACK
-- ================================================================
local lastProximityCheck = 0
local function ProximityHitCheck()
    if HitConfirm then return end
    if not CFG.AUTO_AIM then return end
    local now = os.clock()
    if now - lastProximityCheck < 0.1 then return end
    lastProximityCheck = now

    local char = GetChar(); if not char then return end
    local isAttacking = char:GetAttribute("State_Attacking") == true

    if isAttacking and not State.IsAttacking then
        local root = GetRoot(); if not root then return end
        local closest, closestDist = nil, CFG.PROXIMITY_HIT_RANGE
        for _, p in pairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local er = p.Character:FindFirstChild("HumanoidRootPart")
                local eh = p.Character:FindFirstChild("Humanoid")
                if er and eh and eh.Health > 0 then
                    local d = (root.Position - er.Position).Magnitude
                    if d < closestDist and IsAllowed(p) then
                        closestDist = d
                        closest     = p
                    end
                end
            end
        end
        if closest then
            State.InCombat = true
            LockOn(closest, "proximity hit")
        end
    end
    State.IsAttacking = isAttacking
end

-- ================================================================
--  COMBAT TAG
-- ================================================================
CombatTagChanged.OnClientEvent:Connect(function(tagged)
    if not tagged then
        State.InCombat = false
        Log("CombatTag removed -- waiting for timeout")
    else
        State.InCombat = true
        if State.CurrentTarget then RefreshLock() end
    end
end)

-- ================================================================
--  MAIN LOOP
-- ================================================================
RunService.Heartbeat:Connect(function(dt)
    EnsureCamera()
    if not CFG.AUTO_AIM then return end

    ProximityHitCheck()

    if State.CurrentTarget and LockIsExpired() then
        GoNeutral("lock expired")
        return
    end

    if State.CurrentTarget and not IsTargetValid(State.CurrentTarget) then
        GoNeutral("target invalid")
        return
    end

    if not State.CurrentTarget then return end

    local ec = State.CurrentTarget.Character; if not ec then return end
    local er = ec:FindFirstChild("HumanoidRootPart"); if not er then return end

    UpdateVelocity(er.Position)
    local aimPos = PredictPos(er.Position, dt)
    SetAimDir(aimPos)
end)

-- ================================================================
--  INPUT
-- ================================================================
UIS.InputBegan:Connect(function(i, g)
    if g then return end
    if i.KeyCode == CFG.TOGGLE_KEY then
        CFG.AUTO_AIM = not CFG.AUTO_AIM
        if not CFG.AUTO_AIM then GoNeutral("toggled off") end
        Notify(CFG.AUTO_AIM and "[AA] ON" or "[AA] OFF")
    end
    if i.KeyCode == CFG.SWITCH_KEY then
        if CFG.AUTO_AIM then
            GetBestTarget(true)
            SwitchNext()
        end
    end
end)

-- ================================================================
--  CLEANUP
-- ================================================================
Players.PlayerRemoving:Connect(function(p)
    if State.CurrentTarget == p then
        GoNeutral("player left")
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    UnlockAll("respawn")
    State.InCombat    = false
    State.IsAttacking = false
    EnsureCamera()
    task.wait(0.5)
    Log("Char ready")
end)

-- ================================================================
--  INIT
-- ================================================================
EnsureCamera()
Notify(string.format(
    "[OK] v4.3 | Lock %ds | HitSwitch | Parry+-%dd | RCtrl=Toggle RShift=Switch",
    CFG.LOCK_DURATION,
    CFG.PARRY_FRONT_ANGLE / 2
), 5)
Log("v4.3 CLEAN loaded | Duration:", CFG.LOCK_DURATION, "| Range:", CFG.AIM_RANGE)
