-- ════════════════════════════════════════════════════════════════
--  Auto Aim v4.2
--  Upgrade dari v4.1:
--  • Lock expire → TIDAK auto switch, cuma unlock doang
--  • LOCK_DURATION naik jadi 30s
--  • Parry hanya dari DEPAN, KANAN, KIRI (bukan belakang)
--  • Semua sistem lama tetap utuh
-- ════════════════════════════════════════════════════════════════

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera      = workspace.CurrentCamera

-- ════════════════════════════════════════════════════════════
--  PACKETS
-- ════════════════════════════════════════════════════════════
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
        print("🎯 HitConfirm packet found:", name)
        break
    end
end
if not HitConfirm then
    print("🎯 HitConfirm packet not found — using proximity fallback")
end

-- ════════════════════════════════════════════════════════════
--  CONFIG
-- ════════════════════════════════════════════════════════════
local CFG = {
    AUTO_AIM           = true,
    AIM_RANGE          = 80,

    -- ─── DURASI LOCK ───────────────────────────────────────
    LOCK_DURATION      = 30,      -- ✅ UPGRADE: dari 15 → 30 detik

    -- ─── EXPIRE BEHAVIOR ───────────────────────────────────
    -- false = kalau habis, cuma unlock, TIDAK pindah target
    AUTO_SWITCH_ON_EXPIRE = false, -- ✅ UPGRADE: default v4.1 = true, sekarang false

    -- AlignOrientation
    MAX_TORQUE         = 1e6,
    RESPONSIVENESS     = 35,

    -- Prediction
    PREDICT_ENABLED    = true,
    PREDICT_FACTOR     = 0.10,

    -- Sticky target
    STICK_TO_TARGET    = true,
    STICKY_RANGE_MULT  = 1.6,

    -- Proximity hit detection fallback
    PROXIMITY_HIT_RANGE = 12,

    -- ─── PARRY DIRECTION ───────────────────────────────────
    -- ✅ UPGRADE: parry hanya dari DEPAN, KANAN, KIRI
    -- Belakang diblokir supaya ga suspicious
    PARRY_ENABLED      = true,
    PARRY_FRONT_ANGLE  = 130,  -- derajat total dari depan yang diterima
                               -- 130° = ±65° dari hadapan lo
                               -- Kiri & kanan masuk, belakang keluar
    -- Penjelasan:
    -- dot > cos(65°) ≈ 0.42  → FRONT ZONE (aman, parry)
    -- dot < -0.42             → BACK ZONE  (skip, jangan parry)
    -- antara -0.42 dan 0.42  → SIDE ZONE  (parry)
    -- Jadi: front + left + right = parry | back = skip

    -- Username filter
    USERNAME_MODE      = "none",
    USERNAME_LIST      = {},

    -- State blocks
    BLOCKED_STATES = {
        "State_Ragdolled",
        "State_Safe",
        "State_Dead",
        "State_Downed",
        "State_Gripped",
        "State_Carried",
        "State_Stunned",
    },

    TOGGLE_KEY         = Enum.KeyCode.RightControl,
    SWITCH_KEY         = Enum.KeyCode.RightShift,
    DEBUG              = false,
}

-- ════════════════════════════════════════════════════════════
--  STATE
-- ════════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════════
--  UTILS
-- ════════════════════════════════════════════════════════════
local function Log(...) if CFG.DEBUG then print("🎯", ...) end end

local function Notify(txt, dur)
    pcall(function()
        game.StarterGui:SetCore("SendNotification",{
            Title="🎯 Auto Aim v4.2", Text=txt, Duration=dur or 2
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
    Log("Lock refreshed — expires in", CFG.LOCK_DURATION, "sec")
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

-- ════════════════════════════════════════════════════════════
--  ✅ UPGRADE: PARRY DIRECTION FILTER
--  Cek apakah attacker ada di DEPAN / SAMPING lo
--  Kalau dari belakang → return false → skip parry
-- ════════════════════════════════════════════════════════════
local function IsParryableDirection(attackerRootPos)
    if not CFG.PARRY_ENABLED then return true end
    local root = GetRoot(); if not root then return false end

    -- Forward vector karakter lo (dari CFrame)
    local myForward = root.CFrame.LookVector

    -- Arah dari lo ke attacker
    local toAttacker = (attackerRootPos - root.Position)
    toAttacker = Vector3.new(toAttacker.X, 0, toAttacker.Z)
    if toAttacker.Magnitude < 0.01 then return true end
    toAttacker = toAttacker.Unit

    -- Dot product: 1 = tepat depan, -1 = tepat belakang
    local dot = myForward:Dot(toAttacker)

    -- cos(65°) ≈ 0.4226 — threshold batas belakang
    -- Kalau dot < -0.4226 = attacker ada DI BELAKANG lo → skip
    local backThreshold = -math.cos(math.rad(CFG.PARRY_FRONT_ANGLE / 2))

    if dot < backThreshold then
        Log("Parry blocked — attacker dari belakang | dot:", dot)
        return false
    end

    Log("Parry allowed | dot:", dot)
    return true
end

-- ════════════════════════════════════════════════════════════
--  ALIGN ORIENTATION CONSTRAINT
-- ════════════════════════════════════════════════════════════
local function SetupConstraint()
    local root = GetRoot(); if not root then return end

    pcall(function()
        if State.AlignOri      then State.AlignOri:Destroy()      end
        if State.Att0          then State.Att0:Destroy()           end
        if State.ConstraintPart then State.ConstraintPart:Destroy() end
    end)

    local att0 = Instance.new("Attachment")
    att0.Name  = "_AA_Att0"
    att0.Parent= root
    State.Att0 = att0

    local ao = Instance.new("AlignOrientation")
    ao.Name                = "_AA_AO"
    ao.Mode                = Enum.OrientationAlignmentMode.OneAttachment
    ao.Attachment0         = att0
    ao.MaxTorque           = CFG.MAX_TORQUE
    ao.MaxAngularVelocity  = math.huge
    ao.Responsiveness      = CFG.RESPONSIVENESS
    ao.RigidityEnabled     = false
    ao.PrimaryAxisOnly     = false
    ao.Parent              = root
    State.AlignOri         = ao

    Log("Constraint ready")
end

local function DestroyConstraint()
    pcall(function()
        if State.AlignOri       then State.AlignOri:Destroy();       State.AlignOri = nil       end
        if State.Att0           then State.Att0:Destroy();           State.Att0 = nil           end
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
    right = right.Unit
    local newUp = right:Cross(dir).Unit

    State.AlignOri.CFrame = CFrame.fromMatrix(Vector3.zero, right, newUp)
end

-- ════════════════════════════════════════════════════════════
--  VELOCITY PREDICTION
-- ════════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════════
--  TARGET SELECTION
-- ════════════════════════════════════════════════════════════
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
                table.insert(State.Candidates, {p=p, score=score, dist=dist})
                if score < bestScore then bestScore = score; best = p end
            end
        end
    end
    table.sort(State.Candidates, function(a,b) return a.score < b.score end)
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
                Notify("🔄 → "..nx.p.Name)
            end
            return
        end
    end
end

-- ════════════════════════════════════════════════════════════
--  LOCK / UNLOCK
-- ════════════════════════════════════════════════════════════
local function LockOn(t, reason)
    if not t then return end
    local isNew = (t ~= State.CurrentTarget)
    State.CurrentTarget  = t
    State.PrevTargetPos  = nil
    State.TargetVelocity = Vector3.zero
    RefreshLock()
    if isNew then
        SetupConstraint()
        Notify("🎯 "..t.Name.." ["..reason.."]")
        Log("Locked:", t.Name, "via", reason)
    else
        Log("Lock refreshed:", t.Name, "via", reason)
    end
end

local function UnlockAll(reason)
    State.CurrentTarget  = nil
    State.PrevTargetPos  = nil
    State.TargetVelocity = Vector3.zero
    DestroyConstraint()
    Log("Unlocked:", reason)
end

-- ════════════════════════════════════════════════════════════
--  TRIGGER: LO KENA HIT
-- ════════════════════════════════════════════════════════════
GotHit.OnClientEvent:Connect(function(attackerInfo)
    if not CFG.AUTO_AIM then return end
    State.InCombat = true

    -- ✅ Cek parry direction dulu sebelum lock
    -- Coba ambil posisi attacker dari packet (kalau ada)
    local attackerPos = nil
    if attackerInfo and typeof(attackerInfo) == "Instance" then
        if attackerInfo:IsA("Player") and attackerInfo.Character then
            local ar = attackerInfo.Character:FindFirstChild("HumanoidRootPart")
            if ar then attackerPos = ar.Position end
        end
    end

    -- Kalau ada info posisi attacker, filter arah
    if attackerPos then
        if not IsParryableDirection(attackerPos) then
            Log("GotHit dari belakang — skip parry/lock")
            return
        end
    end
    -- Kalau ga ada info posisi (packet ga kirim), tetap lock (safe default)

    local best = GetBestTarget(true)
    if best then
        LockOn(best, "kena hit")
    end
end)

-- ════════════════════════════════════════════════════════════
--  TRIGGER: LO NGEHIT ORANG (packet)
-- ════════════════════════════════════════════════════════════
if HitConfirm then
    HitConfirm.OnClientEvent:Connect(function(targetPlayer, ...)
        if not CFG.AUTO_AIM then return end
        State.InCombat = true
        if targetPlayer and typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player") then
            if targetPlayer ~= LocalPlayer then
                LockOn(targetPlayer, "lo ngehit")
                return
            end
        end
        local best = GetBestTarget(true)
        if best then LockOn(best, "lo ngehit") end
    end)
end

-- ════════════════════════════════════════════════════════════
--  TRIGGER: PROXIMITY FALLBACK
-- ════════════════════════════════════════════════════════════
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
                        closest = p
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

-- ════════════════════════════════════════════════════════════
--  COMBAT TAG
-- ════════════════════════════════════════════════════════════
CombatTagChanged.OnClientEvent:Connect(function(tagged)
    if not tagged then
        State.InCombat = false
        Log("CombatTag removed — waiting for timeout")
    else
        State.InCombat = true
        if State.CurrentTarget then
            RefreshLock()
        end
    end
end)

-- ════════════════════════════════════════════════════════════
--  MAIN LOOP
-- ════════════════════════════════════════════════════════════
RunService.Heartbeat:Connect(function(dt)
    EnsureCamera()
    if not CFG.AUTO_AIM then return end

    ProximityHitCheck()

    -- ✅ UPGRADE: lock expire → TIDAK auto switch, cuma unlock
    if State.CurrentTarget and LockIsExpired() then
        local expiredName = State.CurrentTarget.Name
        UnlockAll("lock expired ("..expiredName..")")
        -- ❌ DIHAPUS: auto switch ke candidate lain
        -- Sekarang cukup unlock, tunggu trigger baru
        Notify("🔓 Lock expired: "..expiredName, 2)
        return
    end

    -- validate target
    if State.CurrentTarget and not IsTargetValid(State.CurrentTarget) then
        local deadName = State.CurrentTarget.Name
        UnlockAll("target invalid: "..deadName)
        -- ✅ Auto switch tetap jalan kalau target MATI/keluar range
        -- Ini beda dari expire — ini karena target emang udah ga valid
        -- Kalau mau disable ini juga, comment block di bawah
        GetBestTarget(true)
        if #State.Candidates > 0 then
            LockOn(State.Candidates[1].p, "auto switch (invalid)")
        end
        return
    end

    if not State.CurrentTarget then return end

    local ec = State.CurrentTarget.Character; if not ec then return end
    local er = ec:FindFirstChild("HumanoidRootPart"); if not er then return end

    UpdateVelocity(er.Position)
    local aimPos = PredictPos(er.Position, dt)
    SetAimDir(aimPos)
end)

-- ════════════════════════════════════════════════════════════
--  INPUT
-- ════════════════════════════════════════════════════════════
UIS.InputBegan:Connect(function(i, g)
    if g then return end
    if i.KeyCode == CFG.TOGGLE_KEY then
        CFG.AUTO_AIM = not CFG.AUTO_AIM
        if not CFG.AUTO_AIM then UnlockAll("toggled off") end
        Notify(CFG.AUTO_AIM and "🎯 ON" or "🎯 OFF")
    end
    if i.KeyCode == CFG.SWITCH_KEY then
        if CFG.AUTO_AIM then
            GetBestTarget(true)
            SwitchNext()
        end
    end
end)

-- ════════════════════════════════════════════════════════════
--  CLEANUP
-- ════════════════════════════════════════════════════════════
Players.PlayerRemoving:Connect(function(p)
    if State.CurrentTarget == p then
        UnlockAll("player left")
        -- player left = switch masih boleh
        GetBestTarget(true)
        if #State.Candidates > 0 then LockOn(State.Candidates[1].p, "auto switch") end
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

-- ════════════════════════════════════════════════════════════
--  INIT
-- ════════════════════════════════════════════════════════════
EnsureCamera()
Notify(string.format(
    "✅ v4.2 | Lock %ds | NoAutoSwitch | Parry±%d° | RCtrl=Toggle RShift=Switch",
    CFG.LOCK_DURATION,
    CFG.PARRY_FRONT_ANGLE / 2
), 5)
Log("v4.2 loaded | Duration:", CFG.LOCK_DURATION, "| Range:", CFG.AIM_RANGE)
