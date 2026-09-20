local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "ARSENAL V.1",
    Icon = 0,
    LoadingTitle = "otewee bantai...",
    LoadingSubtitle = "BY ZENOOSYNC | V1",
    ShowText = "",
    Theme = "Default",
    ToggleUIKeybind = "K",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "Zenoosyncv1",
        FileName = ""
    },
    Discord = {
        Enabled = false,
        Invite = "noinvitelink",
        RememberJoins = true
    },
    KeySystem = false
})

-- ══════════════════════════════════════════════════════════════
--  SECTION 2: SERVICES & CORE VARIABLES
-- ══════════════════════════════════════════════════════════════

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local TeamsService     = game:GetService("Teams")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- ══════════════════════════════════════════════════════════════
--  SECTION 3: CONNECTION MANAGER (pooled)
-- ══════════════════════════════════════════════════════════════

local Connections = {}

local function TrackConnection(key, conn)
    if Connections[key] then
        pcall(function() Connections[key]:Disconnect() end)
    end
    Connections[key] = conn
end

local function KillConnection(key)
    if Connections[key] then
        pcall(function() Connections[key]:Disconnect() end)
        Connections[key] = nil
    end
end

local function KillAllConnections()
    for _, conn in pairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 4: DRAWING MANAGER (pooled)
-- ══════════════════════════════════════════════════════════════

local DrawingObjects = {}

local function SafeCreateDrawing(drawType, props)
    local ok, obj = pcall(Drawing.new, drawType)
    if not ok or not obj then return nil end
    for k, v in pairs(props or {}) do
        pcall(function() obj[k] = v end)
    end
    table.insert(DrawingObjects, obj)
    return obj
end

local function DestroyAllDrawings()
    for _, obj in ipairs(DrawingObjects) do
        pcall(function() obj:Remove() end)
    end
    table.clear(DrawingObjects)
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 5: UTILITY FUNCTIONS
-- ══════════════════════════════════════════════════════════════

-- Cache for IsAlive — avoids repeated FindFirstChild per frame
local _aliveCache = {}
local _aliveCacheFrame = 0

local function IsAlive(player)
    if not player or not player.Parent then return false end
    local char = player.Character
    if not char or not char.Parent then return false end
    if not char:IsDescendantOf(Workspace) then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if char:FindFirstChildOfClass("ForceField") then return false end
    if hum:GetState() == Enum.HumanoidStateType.Dead then return false end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    return true
end

local function GetBodyPart(character, partName)
    if not character then return nil end
    if partName == "Torso" then
        return character:FindFirstChild("UpperTorso")
            or character:FindFirstChild("Torso")
    end
    return character:FindFirstChild(partName)
        or character:FindFirstChild("HumanoidRootPart")
end

local function IsR15(character)
    return character:FindFirstChild("UpperTorso") ~= nil
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 5B: DEATH POSITION FREEZE (Anti-Downward Track)
--  Caches last valid aim position to prevent camera tracking ragdolls
-- ══════════════════════════════════════════════════════════════

local _lastValidPos = {}     -- player -> {pos=Vector3, time=number}
local _deathCooldown = {}    -- player -> number (tick of death detection)

local function IsPositionSane(player, newPos)
    local cached = _lastValidPos[player]
    if not cached then return true end
    local deltaY = newPos.Y - cached.pos.Y
    local deltaTime = tick() - cached.time
    -- If position drops more than 15 studs in under 0.15s => ragdoll fling
    if deltaY < -15 and deltaTime < 0.15 then
        return false
    end
    -- If position is underground
    if newPos.Y < -50 then
        return false
    end
    return true
end

local function CacheValidPosition(player, pos)
    _lastValidPos[player] = { pos = pos, time = tick() }
end

local function GetFrozenPosition(player)
    local cached = _lastValidPos[player]
    if cached then return cached.pos end
    return nil
end

local function ClearFrozenPosition(player)
    _lastValidPos[player] = nil
    _deathCooldown[player] = nil
end

local function SetDeathCooldown(player)
    _deathCooldown[player] = tick()
end

local function IsInDeathCooldown(player)
    local t = _deathCooldown[player]
    if not t then return false end
    return (tick() - t) < 0.25
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 6: SMART GAME MODE & TEAM DETECTION (v5.0)
--  Throttled detection, team change hooks, robust FFA heuristic
-- ══════════════════════════════════════════════════════════════

local GameMode = {
    IsFFA         = false,
    TeamSize      = 1,   -- Fitur Baru: Deteksi kapasitas tim (1=Solo/FFA, 2=Duos, 4=Squads, dst)
    LastCheck     = 0,
    CheckInterval = 0.5, -- Dioptimasi dari 0.1 ke 0.5 detik agar tidak membuat lag / fps drop
}

function GameMode:DetectMode()
    local now = tick()
    if now - self.LastCheck < self.CheckInterval then return end
    self.LastCheck = now

    local teams = TeamsService:GetTeams()
    local players = Players:GetPlayers()
    local totalPlayers = #players

    -- Jika tidak ada tim di game, otomatis FFA
    if #teams == 0 or totalPlayers < 2 then
        self.IsFFA = true
        self.TeamSize = 1
        return
    end

    local teamCounts = {}
    local withTeam = 0
    local withoutTeam = 0
    local maxInOneTeam = 0

    for _, player in ipairs(players) do
        if player.Team then
            teamCounts[player.Team] = (teamCounts[player.Team] or 0) + 1
            
            -- Lacak jumlah pemain terbanyak dalam satu tim
            if teamCounts[player.Team] > maxInOneTeam then
                maxInOneTeam = teamCounts[player.Team]
            end
            
            withTeam = withTeam + 1
        else
            withoutTeam = withoutTeam + 1
        end
    end

    local distinctTeams = 0
    for _ in pairs(teamCounts) do 
        distinctTeams = distinctTeams + 1 
    end

    -- 🎯 Heuristik Pintar (Smart Detection):
    if withoutTeam >= withTeam and totalPlayers > 1 then
        -- 1. Lebih banyak player tanpa tim dibanding yang punya tim -> Mode FFA (Contoh: Da Hood)
        self.IsFFA = true
    elseif distinctTeams > 1 and maxInOneTeam <= 1 then
        -- 2. Tiap player punya tim sendiri-sendiri -> Mode FFA / Solos (Contoh: Bedwars Solo)
        self.IsFFA = true
    elseif distinctTeams <= 1 and totalPlayers > 1 then
        -- 3. Cuma ada 1 tim aktif untuk semua orang -> Mode FFA (Contoh: Game Deathmatch tanpa tim)
        self.IsFFA = true
    else
        self.IsFFA = false
    end

    -- 👥 Deteksi ukuran tim (Solo = 1, Duos = 2, Trios = 3, Squads = 4)
    if self.IsFFA then
        self.TeamSize = 1
    else
        -- Ukuran tim diambil dari jumlah anggota tim yang paling banyak saat itu
        self.TeamSize = maxInOneTeam
    end
end

function GameMode:IsEnemy(player)
    -- 1. Pengecekan Dasar: Jangan pernah menargetkan diri sendiri!
    if player == LocalPlayer then return false end

    self:DetectMode()

    -- ⚔️ Pengecekan Musuh Pintar (FFA Mode)
    if self.IsFFA then 
        -- Jika mode FFA, SEMUA ORANG selain diri sendiri adalah musuh
        return true 
    end
    
    -- 🛡️ Pengecekan Musuh Pintar (Team Mode)
    -- Jika LocalPlayer (kita) belum masuk tim, amannya anggap semua orang musuh
    if not LocalPlayer.Team then return true end
    
    -- Jika player target tidak punya tim di mode Team, anggap dia musuh (karena bukan di tim kita)
    if not player.Team then return true end 

    -- Jika nama tim atau warna tim berbeda, berarti dia musuh
    if LocalPlayer.Team ~= player.Team or LocalPlayer.TeamColor ~= player.TeamColor then 
        return true 
    end
    
    -- Jika lolos semua pengecekan di atas, berarti dia adalah teman satu tim
    return false
end

function GameMode:GetTeamDisplayColor(player)
    -- Berikan warna berbeda (Hijau) jika ESP/Render me-render diri sendiri
    if player == LocalPlayer then
        return Color3.fromRGB(50, 255, 50) 
    end

    self:DetectMode()
    
    if self.IsFFA then
        return Color3.fromRGB(255, 85, 35) -- Oranye/Merah Terang untuk semua musuh FFA
    elseif self:IsEnemy(player) then
        return Color3.fromRGB(255, 40, 40) -- Merah untuk musuh (beda tim)
    else
        return Color3.fromRGB(40, 180, 255) -- Biru untuk teman satu tim (Team Mode)
    end
end
-- ══════════════════════════════════════════════════════════════
--  SECTION 7: OPTIMIZED VISIBILITY CHECK
--  Cached filter, throttled rebuild, multi-point
-- ══════════════════════════════════════════════════════════════

local VisibilityParams = RaycastParams.new()
VisibilityParams.FilterType = Enum.RaycastFilterType.Exclude
VisibilityParams.IgnoreWater = true

local _visFilterTime = 0
local _visFilter = {}

local function RebuildVisibilityFilter()
    local now = tick()
    if now - _visFilterTime < 0.1 then return end
    _visFilterTime = now
    local filter = {Camera}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then filter[#filter + 1] = p.Character end
    end
    VisibilityParams.FilterDescendantsInstances = filter
end

local function IsVisibleAdvanced(targetChar, targetPos)
    if not targetChar or not targetChar.Parent then return false end
    RebuildVisibilityFilter()
    local origin = Camera.CFrame.Position

    local checkPoints = { targetPos }
    local head = targetChar:FindFirstChild("Head")
    if head then checkPoints[#checkPoints + 1] = head.Position end
    local torso = targetChar:FindFirstChild("UpperTorso") or targetChar:FindFirstChild("Torso")
    if torso then checkPoints[#checkPoints + 1] = torso.Position end
    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if hrp and hrp.Position ~= targetPos then checkPoints[#checkPoints + 1] = hrp.Position end

    for _, point in ipairs(checkPoints) do
        local direction = point - origin
        local dist = direction.Magnitude
        if dist < 1 then return true end
        local result = Workspace:Raycast(origin, direction, VisibilityParams)
        if not result or (origin - result.Position).Magnitude >= dist * 0.95 then
            return true
        end
    end
    return false
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 8: PREDICTION ENGINE v6.0 (ULTIMATE SMART TRACKING)
--  Ping Compensation, 3D Strafe Detection, Dynamic Gravity, Anti-Dodge
-- ══════════════════════════════════════════════════════════════

local PredictionData = {}
local Players = game:GetService("Players")

-- Configurable prediction parameters (Tuned for Real-time Precision)
local PredictionConfig = {
    VelocitySmoothing    = 18,   -- Lebih responsif untuk tracking
    AccelSmoothing       = 12,   -- Prediksi akselerasi lebih tajam
    AccelCap             = 1000, -- Batas akselerasi
    VelocityCap          = 800,  -- Batas kecepatan
    PingCompensation     = true, -- 🔥 Fitur Baru: Hitung latensi/ping player
    LookAheadMultiplier  = 1.5,  -- Base multiplier untuk DeltaTime
    LookAheadMax         = 0.5,  -- Maksimum lookahead detik (Diperbesar untuk ping)
    ConfidenceGainRate   = 5,    
    ConfidenceLossRate   = 8,    
    StrafeSensitivity    = 2,    -- 🔥 Lebih sensitif mendeteksi zig-zag (A-D spam)
    StrafeWindow         = 0.6,  -- Jendela waktu analisis zig-zag
    StrafeDampen         = 0.15, -- Mengurangi overshoot drastis saat musuh zig-zag
    JumpArcEnabled       = true, -- Pakai prediksi parabola
    JumpThreshold        = 10,   -- Y velocity minimal untuk terbaca melayang
    DirectionReactFast   = 3.5,  -- Reaksi instan saat musuh belok mendadak / putar balik
    DirectionReactMed    = 2.0,  -- Reaksi sedang saat musuh belok melengkung (Curved dodge)
    EarlyBeta            = 0.95, -- Kecepatan adaptasi di beberapa frame pertama
    EarlySamples         = 5,    
}

-- 🌐 Fungsi Cerdas: Ambil gravitasi aktual game (Bukan hardcode 196.2)
local function GetGravity()
    return workspace.Gravity or 196.2
end

-- 📡 Fungsi Cerdas: Ambil Ping Player secara Real-time (Ping Compensation)
local function GetPing()
    local ping = 0.05 -- Default 50ms (Jika gagal)
    pcall(function()
        local lp = Players.LocalPlayer
        if lp and lp:GetNetworkPing() then
            ping = lp:GetNetworkPing()
        else
            -- Alternatif server stats jika GetNetworkPing belum di-load
            local stats = game:GetService("Stats"):FindFirstChild("Network")
            if stats and stats:FindFirstChild("ServerStatsItem") then
                ping = stats:ServerStatsItem("Data Ping"):GetValue() / 1000
            end
        end
    end)
    return math.clamp(ping, 0.01, 0.3) -- Batasi hitungan dari 10ms sampai max 300ms
end

local function UpdatePrediction(player, worldPos, dt)
    dt = math.max(dt, 0.0001)
    local d = PredictionData[player]
    local cfg = PredictionConfig

    if not d then
        PredictionData[player] = {
            lastPos = worldPos, velocity = Vector3.zero, acceleration = Vector3.zero,
            smoothVelocity = Vector3.zero, predictedPos = worldPos, prevVelocity = Vector3.zero,
            sampleCount = 0, confidence = 0, lastDir = Vector3.zero,
            strafeHistory = {}, strafing = false, strafeCenter = worldPos,
            airborne = false, jumpTime = 0,
        }
        return
    end

    -- Hitung kecepatan aktual (Raw Velocity)
    local rawVelocity = (worldPos - d.lastPos) / dt
    if cfg.VelocityCap > 0 and rawVelocity.Magnitude > cfg.VelocityCap then
        rawVelocity = rawVelocity.Unit * cfg.VelocityCap
    end

    -- Update Kalman Confidence (Seberapa akurat / meleset prediksi di frame sebelumnya)
    local predErr = (worldPos - d.predictedPos).Magnitude
    if predErr < 1.5 then
        d.confidence = math.min(d.confidence + dt * cfg.ConfidenceGainRate, 1)
    elseif predErr < 6 then
        d.confidence = math.clamp(d.confidence - dt * 2, 0.2, 1)
    else
        d.confidence = math.max(d.confidence - dt * cfg.ConfidenceLossRate, 0)
    end

    -- Adaptive Beta (Dynamic Smoothing Engine)
    local baseBeta = math.clamp(1 - math.exp(-cfg.VelocitySmoothing * dt), 0.05, 0.95)
    local beta

    d.sampleCount = math.min(d.sampleCount + 1, 40)
    if d.sampleCount < cfg.EarlySamples then
        beta = cfg.EarlyBeta
    else
        beta = baseBeta * (1.2 - d.confidence * 0.5)
        beta = math.clamp(beta, 0.05, 0.98)
    end

    -- 🔥 REAKSI BELOKAN / DIRECTION CHANGE (Mendeteksi Anti-Aim / Dodge 3D)
    local curDir = rawVelocity.Magnitude > 0.1 and rawVelocity.Unit or d.lastDir
    if d.velocity.Magnitude > 2 and rawVelocity.Magnitude > 2 then
        local dot = d.lastDir:Dot(curDir)
        if dot < 0.1 then       -- Musuh belok tajam 90 derajat atau balik arah (Jumpscare)
            beta = math.clamp(beta * cfg.DirectionReactFast, 0.4, 0.98)
        elseif dot < 0.5 then   -- Musuh lari melengkung
            beta = math.clamp(beta * cfg.DirectionReactMed, 0.2, 0.95)
        end
    end
    d.lastDir = curDir

    -- Terapkan perubahan pada Velocity
    d.prevVelocity = d.velocity
    d.velocity = d.velocity:Lerp(rawVelocity, beta)

    -- Terapkan perubahan pada Acceleration (Centripetal force untuk Curved Paths)
    local rawAccel = (d.velocity - d.prevVelocity) / dt
    if rawAccel.Magnitude > cfg.AccelCap then rawAccel = rawAccel.Unit * cfg.AccelCap end
    local accelBeta = math.clamp(1 - math.exp(-cfg.AccelSmoothing * dt), 0.05, 0.7)
    d.acceleration = d.acceleration:Lerp(rawAccel, accelBeta)

    -- Smooth velocity khusus untuk peredam pusat zig-zag (Strafe Center)
    local smoothBeta = math.clamp(1 - math.exp(-6 * dt), 0.02, 0.5)
    d.smoothVelocity = d.smoothVelocity:Lerp(d.velocity, smoothBeta)

    -- 🔥 STRAFE DETECTION 3D PINTAR (Menggunakan Sumbu Tegak Lurus)
    local now = tick()
    local horizVel = Vector3.new(d.velocity.X, 0, d.velocity.Z)
    if horizVel.Magnitude > 2 then
        local moveDir = horizVel.Unit
        local rightDir = Vector3.new(0, 1, 0):Cross(moveDir) -- Mendapatkan vektor sisi (kiri/kanan badan)
        local strafeAccel = rawAccel:Dot(rightDir)           -- Menghitung daya tolak menyamping
        
        -- Deteksi sentakan A-D mendadak ke kiri atau kanan (Thresold: 40 magnitude)
        local sign = strafeAccel > 40 and 1 or (strafeAccel < -40 and -1 or 0)
        if sign ~= 0 then
            if #d.strafeHistory == 0 or d.strafeHistory[#d.strafeHistory].sign ~= sign then
                d.strafeHistory[#d.strafeHistory + 1] = { sign = sign, time = now }
            end
        end
    end
    
    -- Buang data zig-zag yang sudah lawas/kadaluarsa
    while #d.strafeHistory > 0 and (now - d.strafeHistory[1].time) > cfg.StrafeWindow do
        table.remove(d.strafeHistory, 1)
    end
    
    d.strafing = #d.strafeHistory >= cfg.StrafeSensitivity
    if d.strafing then
        d.strafeCenter = d.strafeCenter:Lerp(worldPos, math.clamp(dt * 6, 0.05, 0.4))
    end

    -- ✈️ AIRBORNE DETECTION (Deteksi Jatuh / Lompat Presisi)
    local yVel = d.velocity.Y
    local wasAir = d.airborne
    d.airborne = yVel > cfg.JumpThreshold or yVel < -cfg.JumpThreshold
    if d.airborne and not wasAir then d.jumpTime = 0 end
    if d.airborne then d.jumpTime = d.jumpTime + dt end

    d.lastPos = worldPos
end

local function PredictPosition(player, worldPos, dt)
    local d = PredictionData[player]
    if not d or d.sampleCount < 2 then return worldPos end
    local cfg = PredictionConfig

    -- 📡 PING COMPENSATION: Tambahkan latensi jaringan murni ke waktu lookahead
    local pingOffset = cfg.PingCompensation and GetPing() or 0
    local lookAhead = math.clamp((dt * cfg.LookAheadMultiplier) + pingOffset, 0, cfg.LookAheadMax)
    
    local predicted

    if d.strafing then
        -- 🛑 Anti-Strafe: Jika musuh panik A-D spam, tarik paksa aim ke "Center Mass" dari rute mereka
        local centerBlend = d.strafeCenter:Lerp(worldPos, 0.6)
        predicted = centerBlend + d.smoothVelocity * (lookAhead * cfg.StrafeDampen)
    elseif cfg.JumpArcEnabled and d.airborne and d.jumpTime < 1.5 then
        -- 🚀 Jump Arc Dinamis (Bebas dari hardcoded gravitasi)
        local t = lookAhead
        local gravity = GetGravity()
        predicted = worldPos + d.velocity * t + Vector3.new(0, -gravity, 0) * (0.5 * t * t)
    else
        -- 🎯 Standar Prediksi Linear 2nd-Order (Termasuk pergerakan kurva/membelok karena ada Acceleration)
        predicted = worldPos + d.velocity * lookAhead + d.acceleration * (0.5 * lookAhead * lookAhead)
    end

    d.predictedPos = predicted

    -- Terakhir, campur prediksi berdasarkan rasio Confidence Engine
    local blend = math.clamp(d.confidence * 0.8 + 0.2, 0.2, 1.0)
    return worldPos:Lerp(predicted, blend)
end

local function ClearPrediction(player) PredictionData[player] = nil end
local function ClearAllPredictions() table.clear(PredictionData) end

-- ══════════════════════════════════════════════════════════════
--  SECTION 9: DRAWING OVERLAYS + TARGET HUD
-- ══════════════════════════════════════════════════════════════

local FOVCircle = SafeCreateDrawing("Circle", {
    Color = Color3.fromRGB(255, 255, 0), Thickness = 1.5, NumSides = 60,
    Radius = 120, Filled = false, Visible = false, Transparency = 0.3
})

local AimTracer = SafeCreateDrawing("Line", {
    Color = Color3.fromRGB(255, 50, 50), Thickness = 1.5,
    Visible = false, Transparency = 0.3
})

local HUDTargetName = SafeCreateDrawing("Text", {
    Size = 14, Font = 2, Center = false, Outline = true,
    OutlineColor = Color3.new(0, 0, 0), Visible = false, Color = Color3.fromRGB(255, 255, 255)
})
local HUDTargetHP = SafeCreateDrawing("Text", {
    Size = 12, Font = 2, Center = false, Outline = true, OutlineColor = Color3.new(0, 0, 0), Visible = false,
})
local HUDTargetDist = SafeCreateDrawing("Text", {
    Size = 12, Font = 2, Center = false, Outline = true, OutlineColor = Color3.new(0, 0, 0), Visible = false,
    Color = Color3.fromRGB(200, 200, 200)
})
local HUDTargetVis = SafeCreateDrawing("Text", {
    Size = 11, Font = 2, Center = false, Outline = true, OutlineColor = Color3.new(0, 0, 0), Visible = false,
})
local HUDHPBarBg = SafeCreateDrawing("Line", {
    Thickness = 5, Color = Color3.fromRGB(30, 30, 30), Visible = false
})
local HUDHPBarFill = SafeCreateDrawing("Line", { Thickness = 3, Visible = false })

local function GetHPColor(frac)
    if frac > 0.5 then
        return Color3.fromRGB(math.floor(255 * (1 - frac) * 2), 255, 50)
    else
        return Color3.fromRGB(255, math.floor(255 * frac * 2), 50)
    end
end

local function HideTargetHUD()
    if HUDTargetName then HUDTargetName.Visible = false end
    if HUDTargetHP then HUDTargetHP.Visible = false end
    if HUDTargetDist then HUDTargetDist.Visible = false end
    if HUDTargetVis then HUDTargetVis.Visible = false end
    if HUDHPBarBg then HUDHPBarBg.Visible = false end
    if HUDHPBarFill then HUDHPBarFill.Visible = false end
end

local function UpdateTargetHUD(info, isVisible)
    local cx = Camera.ViewportSize.X / 2 + 25
    local cy = Camera.ViewportSize.Y / 2 + 25
    if HUDTargetName then
        HUDTargetName.Text = "TARGET: " .. (info.name or "Unknown")
        HUDTargetName.Position = Vector2.new(cx, cy)
        HUDTargetName.Visible = true
    end
    local hpFrac = math.clamp(info.health / math.max(info.maxHealth, 1), 0, 1)
    local hpColor = GetHPColor(hpFrac)
    if HUDTargetHP then
        HUDTargetHP.Text = string.format("HP: %d / %d", math.floor(info.health), math.floor(info.maxHealth))
        HUDTargetHP.Position = Vector2.new(cx, cy + 18)
        HUDTargetHP.Color = hpColor
        HUDTargetHP.Visible = true
    end
    if HUDTargetDist then
        HUDTargetDist.Text = string.format("%.0f studs", info.dist3D)
        HUDTargetDist.Position = Vector2.new(cx, cy + 33)
        HUDTargetDist.Visible = true
    end
    if HUDTargetVis then
        HUDTargetVis.Text = isVisible and "VISIBLE" or "OCCLUDED"
        HUDTargetVis.Color = isVisible and Color3.fromRGB(80, 255, 80) or Color3.fromRGB(255, 100, 100)
        HUDTargetVis.Position = Vector2.new(cx, cy + 48)
        HUDTargetVis.Visible = true
    end
    local barW, barY = 100, cy + 66
    if HUDHPBarBg then
        HUDHPBarBg.From = Vector2.new(cx, barY)
        HUDHPBarBg.To = Vector2.new(cx + barW, barY)
        HUDHPBarBg.Visible = true
    end
    if HUDHPBarFill then
        HUDHPBarFill.From = Vector2.new(cx, barY)
        HUDHPBarFill.To = Vector2.new(cx + barW * hpFrac, barY)
        HUDHPBarFill.Color = hpColor
        HUDHPBarFill.Visible = true
    end
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 10: AIMBOT SYSTEM (PRESET ARCHITECTURE & BALLISTIC ENGINE)
--  Drop-in replacement for Section 10 & Section 10B
-- ══════════════════════════════════════════════════════════════

local Presets = {
    ["Low"] = {
        FOVRadius        = 200,
        Smoothing        = 13.0,
        AimStrength      = 0.38,
        MaxAngularSpeed  = 380,
        PredictionScale  = 0.85,
        Humanize         = true,
        HumanizeStrength = 2.8,
        TriggerStrength  = 0.28,
        AutoSwitchSpeed  = 12.0,
    },
    ["Standard"] = {
        FOVRadius        = 250,
        Smoothing        = 7.5,
        AimStrength      = 0.65,
        MaxAngularSpeed  = 680,
        PredictionScale  = 1.00,
        Humanize         = true,
        HumanizeStrength = 1.4,
        TriggerStrength  = 0.48,
        AutoSwitchSpeed  = 22.0,
    },
    ["Natural"] = {
        FOVRadius        = 300,
        Smoothing        = 9.5,
        AimStrength      = 0.52,
        MaxAngularSpeed  = 520,
        PredictionScale  = 1.00,
        Humanize         = true,
        HumanizeStrength = 2.1,
        TriggerStrength  = 0.38,
        AutoSwitchSpeed  = 16.0,
    },
    ["Pro"] = {
        FOVRadius        = 240,
        Smoothing        = 3.2,
        AimStrength      = 0.92,
        MaxAngularSpeed  = 1400,
        PredictionScale  = 1.15,
        Humanize         = false,
        HumanizeStrength = 0.0,
        TriggerStrength  = 0.80,
        AutoSwitchSpeed  = 35.0,
    },
}

local TriggerAssist = nil -- Forward declaration

local Aimbot = {
    -- Core Options
    Enabled             = false,
    CurrentPreset       = "Standard",
    AimPart             = "Head",
    TeamCheck           = true,
    VisCheck            = false,
    Prediction          = true,
    ShowFOV             = false,
    SnapMode            = false,
    AimKeyMode          = "Always On", -- "Always On", "Hold RMB", "Toggle RMB"
    AimKeyActive        = false,

    -- Auto-Target Engine
    AutoSwitch          = true,
    AutoTarget360       = true,
    MaxDistance         = 2000,
    MinDistance         = 0,

    -- Preset-Managed Active Variables
    FOVRadius           = 250,
    BaseFOVRadius       = 250,
    CurrentFOVRadius    = 250,
    Smoothing           = 7.5,
    AimStrength         = 0.65,
    MaxAngularSpeed     = 680,
    PredictionScale     = 1.0,
    Humanize            = true,
    HumanizeStrength    = 1.4,

    -- Ballistic & Physics Constants
    BulletSpeed         = 3000, -- Kecepatan rata-rata peluru untuk kalkulasi lead-time
    GravityConstant     = 196.2,

    -- Internal Tracking States
    LockedPlayer        = nil,
    LockedInfo          = nil,
    OccludedTime        = 0,
    LockAge             = 0,
    IgnoredNames        = {},
    HumanizeSeed        = math.random(1, 1e5),
    LastScreenCenter    = Vector2.zero,
}

-- Menerapkan konfigurasi preset secara otomatis
function Aimbot:ApplyPreset(presetName)
    local cfg = Presets[presetName] or Presets["Standard"]
    self.CurrentPreset    = presetName
    self.BaseFOVRadius    = cfg.FOVRadius
    self.CurrentFOVRadius = cfg.FOVRadius
    self.Smoothing        = cfg.Smoothing
    self.AimStrength      = cfg.AimStrength
    self.MaxAngularSpeed  = cfg.MaxAngularSpeed
    self.PredictionScale  = cfg.PredictionScale
    self.Humanize         = cfg.Humanize
    self.HumanizeStrength = cfg.HumanizeStrength

    if TriggerAssist then
        TriggerAssist.Strength = cfg.TriggerStrength
    end
end

function Aimbot:GetTargetInfo(player)
    if not IsAlive(player) then return nil end
    if IsInDeathCooldown and IsInDeathCooldown(player) then return nil end

    local char = player.Character
    local aimPart = GetBodyPart(char, self.AimPart)
    if not aimPart or not aimPart.Parent then return nil end

    local worldPos = aimPart.Position

    -- Anti-ragdoll & Desync Position Sanitizer
    if IsPositionSane and not IsPositionSane(player, worldPos) then
        local frozen = GetFrozenPosition and GetFrozenPosition(player)
        if frozen then worldPos = frozen else return nil end
    elseif CacheValidPosition then
        CacheValidPosition(player, worldPos)
    end

    local screenPos3, onScreen = Camera:WorldToViewportPoint(worldPos)
    local screenPos = Vector2.new(screenPos3.X, screenPos3.Y)
    local camPos = Camera.CFrame.Position
    local dist3D = (worldPos - camPos).Magnitude
    local hum = char:FindFirstChildOfClass("Humanoid")

    return {
        player    = player,
        character = char,
        aimPart   = aimPart,
        name      = player.DisplayName or player.Name,
        health    = hum and hum.Health or 100,
        maxHealth = hum and hum.MaxHealth or 100,
        worldPos  = worldPos,
        screenPos = screenPos,
        depth     = screenPos3.Z,
        onScreen  = onScreen,
        dist3D    = dist3D
    }
end

-- Evaluasi Vektor Ancaman (Threat Vector) & Pinalti Sudut yang Akurat
function Aimbot:CalculateTargetScore(info, center)
    local screenDelta = (info.screenPos - center).Magnitude
    local camCF = Camera.CFrame
    local toTarget = (info.worldPos - camCF.Position).Unit
    local lookDot = camCF.LookVector:Dot(toTarget) -- 1 = tengah crosshair, -1 = tepat di belakang

    local anglePenalty = (1 - lookDot) * 160.0
    local distPenalty  = (info.dist3D / 50.0) * 8.0
    local hpFactor     = (info.health / math.max(info.maxHealth, 1)) * 25.0

    -- Bonus Prioritas Musuh yang Berlari Menyerang
    local threatBonus = 0
    local eRoot = info.character:FindFirstChild("HumanoidRootPart")
    if eRoot and eRoot.AssemblyLinearVelocity.Magnitude > 1 then
        local velUnit = eRoot.AssemblyLinearVelocity.Unit
        local toLocal = (camCF.Position - info.worldPos).Unit
        local approachDot = velUnit:Dot(toLocal)
        if approachDot > 0.3 then
            threatBonus = approachDot * 35.0
        end
    end

    return (screenDelta + anglePenalty + distPenalty + hpFactor) - threatBonus
end

function Aimbot:IsLockValid(dt)
    local p = self.LockedPlayer
    if not p or not p.Parent then return false end

    local char = p.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead then
        return false
    end

    if not IsAlive(p) then return false end
    if IsInDeathCooldown and IsInDeathCooldown(p) then return false end
    if self.TeamCheck and not GameMode:IsEnemy(p) then return false end
    if table.find(self.IgnoredNames, p.Name) then return false end

    local info = self:GetTargetInfo(p)
    if not info or info.dist3D > self.MaxDistance or info.dist3D < self.MinDistance then
        return false
    end

    local center = self.LastScreenCenter
    local screenDelta = (info.screenPos - center).Magnitude
    if not self.AutoTarget360 and screenDelta > (self.CurrentFOVRadius * 1.8) then
        return false
    end

    -- Pengecekan Raycast Dinding
    if self.VisCheck then
        if not IsVisibleAdvanced(info.character, info.worldPos) then
            self.OccludedTime = self.OccludedTime + dt
            if self.OccludedTime > 0.25 then return false end
        else
            self.OccludedTime = 0
        end
    end

    return true
end

function Aimbot:AcquireTarget()
    local center = self.LastScreenCenter
    local bestTarget = nil
    local bestScore = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer or not IsAlive(player) then continue end
        if IsInDeathCooldown and IsInDeathCooldown(player) then continue end
        if self.TeamCheck and not GameMode:IsEnemy(player) then continue end
        if table.find(self.IgnoredNames, player.Name) then continue end

        local info = self:GetTargetInfo(player)
        if not info then continue end
        if info.dist3D > self.MaxDistance or info.dist3D < self.MinDistance then continue end

        local inFOV = info.onScreen and info.depth > 0 and (info.screenPos - center).Magnitude <= self.CurrentFOVRadius

        if inFOV or self.AutoTarget360 then
            if self.VisCheck and not IsVisibleAdvanced(info.character, info.worldPos) then
                continue
            end

            local score = self:CalculateTargetScore(info, center)
            if not inFOV then
                score = score + 250.0 -- Pinalti target di luar viewport
            end

            if score < bestScore then
                bestScore = score
                bestTarget = player
            end
        end
    end

    self.LockedPlayer = bestTarget
    self.OccludedTime = 0
    self.LockAge = 0
end

function Aimbot:Unlock(reason)
    if reason == "dead" and self.LockedPlayer then
        if SetDeathCooldown then SetDeathCooldown(self.LockedPlayer) end
        if ClearPrediction then ClearPrediction(self.LockedPlayer) end
    end
    self.LockedPlayer = nil
    self.LockedInfo   = nil
    self.OccludedTime = 0
    self.LockAge      = 0
end

-- Prediksi Balistik & Kinematika Orde 2 (P = P0 + V*t + 0.5*A*t^2)
function Aimbot:GetSharpenedPosition(info, dt)
    local targetPos = info.worldPos
    if not self.Prediction then return targetPos end

    local char = info.character
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return targetPos end

    -- Deteksi Ping Jaringan Otomatis
    local ping = 0.04
    pcall(function() ping = LocalPlayer:GetNetworkPing() end)
    ping = math.clamp(ping or 0.04, 0.015, 0.25)

    -- Dynamic Lead-Time: Latensi + Waktu Tempuh Peluru
    local leadTime = (ping + (info.dist3D / math.max(self.BulletSpeed, 100))) * self.PredictionScale
    local vel = root.AssemblyLinearVelocity
    local accel = Vector3.zero

    if PredictionData and PredictionData[info.player] then
        accel = PredictionData[info.player].acceleration or Vector3.zero
    end

    local predicted = targetPos + (vel * leadTime) + (accel * (0.5 * leadTime * leadTime))

    -- Kompensasi Gravitasi Lompat/Jatuh
    local hum = char:FindFirstChildOfClass("Humanoid")
    local isAirborne = hum and (hum:GetState() == Enum.HumanoidStateType.Freefall or hum:GetState() == Enum.HumanoidStateType.Jumping)
    if isAirborne then
        predicted = predicted + Vector3.new(0, -0.5 * self.GravityConstant * (leadTime ^ 2), 0)
    end

    -- Strict Overshoot Clamp (Mencegah flick acak saat musuh berhenti tiba-tiba)
    local maxRadius = math.clamp(info.dist3D * 0.12, 1.5, 9.0)
    if (predicted - targetPos).Magnitude > maxRadius then
        predicted = targetPos + ((predicted - targetPos).Unit * maxRadius)
    end

    return predicted
end

function Aimbot:SmoothAim(targetPos, dt)
    if self.SnapMode then
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPos)
        return
    end

    local camPos = Camera.CFrame.Position
    local targetVector = targetPos - camPos
    if targetVector.Magnitude < 0.05 then return end

    -- Humanisasi Organik (Perlin Noise Micro-Offset)
    if self.Humanize and self.HumanizeStrength > 0 then
        local t = tick() * 3.2
        local nx = math.noise(t, self.HumanizeSeed, 0) * self.HumanizeStrength
        local ny = math.noise(self.HumanizeSeed, t, 0) * self.HumanizeStrength
        local radAngle = math.rad(Camera.FieldOfView * 0.5)
        local pixelSize = (2 * targetVector.Magnitude * math.tan(radAngle)) / Camera.ViewportSize.Y
        targetPos = targetPos + (Camera.CFrame.RightVector * (nx * pixelSize)) + (Camera.CFrame.UpVector * (ny * pixelSize))
    end

    -- Exponential Damper
    local tension = 160.0 / math.max(self.Smoothing, 0.4)
    local alpha = math.clamp(1 - math.exp(-tension * dt), 0.01, 1) * self.AimStrength

    -- Ramp-up halus di awal penguncian
    if self.LockAge < 0.12 then
        local r = self.LockAge / 0.12
        alpha = alpha * (r * r)
    end

    -- Angular Velocity Clamping
    local targetCF = CFrame.new(camPos, targetPos)
    local currentLook = Camera.CFrame.LookVector
    local targetLook  = targetCF.LookVector
    local angle = math.acos(math.clamp(currentLook:Dot(targetLook), -1, 1))

    local maxTurnAngle = math.rad(self.MaxAngularSpeed) * dt
    if angle > 1e-4 and (angle * alpha) > maxTurnAngle then
        alpha = maxTurnAngle / angle
    end

    Camera.CFrame = Camera.CFrame:Lerp(targetCF, math.clamp(alpha, 0.001, 1))
end

function Aimbot:Update(dt)
    self.LastScreenCenter = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)

    -- Dynamic FOV Scaling berdasarkan Zoom Kamera
    local fovFactor = Camera.FieldOfView / 70.0
    self.CurrentFOVRadius = self.BaseFOVRadius * fovFactor

    if FOVCircle then
        FOVCircle.Position = self.LastScreenCenter
        FOVCircle.Radius   = self.CurrentFOVRadius
        FOVCircle.Visible  = self.Enabled and self.ShowFOV
    end

    if not self.Enabled then return end

    local isAiming = (self.AimKeyMode == "Always On") or self.AimKeyActive
    if not isAiming then
        if self.LockedPlayer then self:Unlock() end
        return
    end

    if self.LockedPlayer then
        if not self:IsLockValid(dt) then
            local dead = self.LockedPlayer and not IsAlive(self.LockedPlayer)
            self:Unlock(dead and "dead" or nil)
            if self.AutoSwitch then
                self:AcquireTarget()
            end
        end
    end

    if not self.LockedPlayer then
        self:AcquireTarget()
    end

    if self.LockedPlayer then
        self.LockAge = self.LockAge + dt
        local info = self:GetTargetInfo(self.LockedPlayer)
        if info then
            self.LockedInfo = info
            if UpdatePrediction then UpdatePrediction(self.LockedPlayer, info.worldPos, dt) end
            local aimPos = self:GetSharpenedPosition(info, dt)
            self:SmoothAim(aimPos, dt)
        else
            self:Unlock()
        end
    end
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 10B: OPTIMIZED TRIGGER ASSIST (CLICK-TO-TRACK)
-- ══════════════════════════════════════════════════════════════

TriggerAssist = {
    Enabled       = false,
    Strength      = 0.48,
    Smoothing     = 6.0,
    MaxDistance   = 800,
    _active       = false,
    _target       = nil,
    _clickTime    = 0,
}

function TriggerAssist:FindTarget()
    local center = Aimbot.LastScreenCenter
    local best, bestDist = nil, math.huge
    local maxSearchRadius = Aimbot.CurrentFOVRadius * 1.3

    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer or not IsAlive(p) then continue end
        if Aimbot.TeamCheck and not GameMode:IsEnemy(p) then continue end

        local info = Aimbot:GetTargetInfo(p)
        if not info or not info.onScreen or info.depth <= 0 then continue end
        if info.dist3D > self.MaxDistance then continue end

        local sd = (info.screenPos - center).Magnitude
        if sd <= maxSearchRadius and sd < bestDist then
            bestDist = sd
            best = p
        end
    end
    return best
end

function TriggerAssist:Update(dt)
    if not self.Enabled or not self._active then return end
    if Aimbot.Enabled and Aimbot.LockedPlayer then return end

    if not self._target or not IsAlive(self._target) then
        self._target = self:FindTarget()
        self._clickTime = tick()
    end

    if not self._target then return end
    local info = Aimbot:GetTargetInfo(self._target)
    if not info then
        self._target = nil
        return
    end

    local aimPos = Aimbot:GetSharpenedPosition(info, dt)
    local camPos = Camera.CFrame.Position
    local targetCF = CFrame.new(camPos, aimPos)

    local speed = 140.0 / math.max(self.Smoothing, 0.5)
    local alpha = math.clamp(1 - math.exp(-speed * dt), 0.01, 0.85) * self.Strength

    Camera.CFrame = Camera.CFrame:Lerp(targetCF, alpha)
end

-- Default Initialization
Aimbot:ApplyPreset("Standard")

-- ══════════════════════════════════════════════════════════════
--  SECTION 11: SMART ESP SYSTEM
-- ══════════════════════════════════════════════════════════════

local ESP = {
    Enabled = false, ShowHighlight = true, ShowName = true, ShowDistance = true,
    ShowTracer = true, ShowHealthBar = true, ShowSkeleton = false, TeamCheck = true,
}

local ESPCache = {}

local function HidePlayerESP(cache)
    if cache.Highlight then pcall(function() cache.Highlight.Enabled = false end) end
    if cache.Text then cache.Text.Visible = false end
    if cache.DistText then cache.DistText.Visible = false end
    if cache.Tracer then cache.Tracer.Visible = false end
    if cache.HealthBg then cache.HealthBg.Visible = false end
    if cache.HealthBar then cache.HealthBar.Visible = false end
    if cache.Bones then for _, b in ipairs(cache.Bones) do b.Visible = false end end
end

local function CleanPlayerESP(player)
    local cache = ESPCache[player]
    if not cache then return end
    if cache.Highlight then pcall(function() cache.Highlight:Destroy() end) end
    if cache.Text then pcall(function() cache.Text:Remove() end) end
    if cache.DistText then pcall(function() cache.DistText:Remove() end) end
    if cache.Tracer then pcall(function() cache.Tracer:Remove() end) end
    if cache.HealthBg then pcall(function() cache.HealthBg:Remove() end) end
    if cache.HealthBar then pcall(function() cache.HealthBar:Remove() end) end
    if cache.Bones then for _, b in ipairs(cache.Bones) do pcall(function() b:Remove() end) end end
    ESPCache[player] = nil
end

local function CleanAllESP()
    for p in pairs(ESPCache) do CleanPlayerESP(p) end
    table.clear(ESPCache)
end

local function GetESPCache(player)
    if ESPCache[player] then return ESPCache[player] end
    local c = {}
    c.Highlight = nil
    c.Text = SafeCreateDrawing("Text", { Size = 14, Font = 2, Center = true, Outline = true, OutlineColor = Color3.new(0,0,0), Visible = false })
    c.DistText = SafeCreateDrawing("Text", { Size = 12, Font = 2, Center = true, Outline = true, OutlineColor = Color3.new(0,0,0), Visible = false })
    c.Tracer = SafeCreateDrawing("Line", { Thickness = 1.5, Visible = false, Transparency = 0.5 })
    c.HealthBg = SafeCreateDrawing("Line", { Thickness = 4, Color = Color3.fromRGB(40,40,40), Visible = false })
    c.HealthBar = SafeCreateDrawing("Line", { Thickness = 2, Visible = false })
    c.Bones = {}
    for i = 1, 15 do c.Bones[i] = SafeCreateDrawing("Line", { Thickness = 1.5, Visible = false, Transparency = 0.8 }) end
    ESPCache[player] = c
    return c
end

local function DrawBone(obj, p1, p2, color)
    if not p1 or not p2 then obj.Visible = false return end
    local a, v1 = Camera:WorldToViewportPoint(p1.Position)
    local b, v2 = Camera:WorldToViewportPoint(p2.Position)
    if v1 or v2 then
        obj.From = Vector2.new(a.X, a.Y)
        obj.To = Vector2.new(b.X, b.Y)
        obj.Color = color
        obj.Visible = true
    else
        obj.Visible = false
    end
end

local function UpdateSkeleton(cache, char, color)
    if not cache.Bones then return end
    if IsR15(char) then
        local parts = {}
        for _, n in ipairs({"Head","UpperTorso","LowerTorso","LeftUpperArm","LeftLowerArm","LeftHand","RightUpperArm","RightLowerArm","RightHand","LeftUpperLeg","LeftLowerLeg","LeftFoot","RightUpperLeg","RightLowerLeg","RightFoot"}) do
            parts[n] = char:FindFirstChild(n)
        end
        DrawBone(cache.Bones[1], parts.Head, parts.UpperTorso, color)
        DrawBone(cache.Bones[2], parts.UpperTorso, parts.LowerTorso, color)
        DrawBone(cache.Bones[3], parts.UpperTorso, parts.LeftUpperArm, color)
        DrawBone(cache.Bones[4], parts.LeftUpperArm, parts.LeftLowerArm, color)
        DrawBone(cache.Bones[5], parts.LeftLowerArm, parts.LeftHand, color)
        DrawBone(cache.Bones[6], parts.UpperTorso, parts.RightUpperArm, color)
        DrawBone(cache.Bones[7], parts.RightUpperArm, parts.RightLowerArm, color)
        DrawBone(cache.Bones[8], parts.RightLowerArm, parts.RightHand, color)
        DrawBone(cache.Bones[9], parts.LowerTorso, parts.LeftUpperLeg, color)
        DrawBone(cache.Bones[10], parts.LeftUpperLeg, parts.LeftLowerLeg, color)
        DrawBone(cache.Bones[11], parts.LeftLowerLeg, parts.LeftFoot, color)
        DrawBone(cache.Bones[12], parts.LowerTorso, parts.RightUpperLeg, color)
        DrawBone(cache.Bones[13], parts.RightUpperLeg, parts.RightLowerLeg, color)
        DrawBone(cache.Bones[14], parts.RightLowerLeg, parts.RightFoot, color)
        if cache.Bones[15] then cache.Bones[15].Visible = false end
    else
        local h = char:FindFirstChild("Head")
        local t = char:FindFirstChild("Torso")
        DrawBone(cache.Bones[1], h, t, color)
        DrawBone(cache.Bones[2], t, char:FindFirstChild("Left Arm"), color)
        DrawBone(cache.Bones[3], t, char:FindFirstChild("Right Arm"), color)
        DrawBone(cache.Bones[4], t, char:FindFirstChild("Left Leg"), color)
        DrawBone(cache.Bones[5], t, char:FindFirstChild("Right Leg"), color)
        for i = 6, 15 do if cache.Bones[i] then cache.Bones[i].Visible = false end end
    end
end

-- ESP throttle: only update every N frames to save CPU
local _espFrameCounter = 0
local ESP_UPDATE_RATE = 2 -- Update every 2 frames

local function UpdateAllESP()
    if not ESP.Enabled then return end
    _espFrameCounter = _espFrameCounter + 1
    if _espFrameCounter % ESP_UPDATE_RATE ~= 0 then return end

    local active = {}
    local vpX, vpY = Camera.ViewportSize.X, Camera.ViewportSize.Y

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer or not IsAlive(player) then continue end
        if ESP.TeamCheck and not GameMode:IsEnemy(player) then continue end
        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then continue end

        local sp3, onScreen = Camera:WorldToViewportPoint(root.Position)
        if not onScreen then
            local cache = ESPCache[player]
            if cache then HidePlayerESP(cache) end
            continue
        end

        active[player] = true
        local cache = GetESPCache(player)
        local sx, sy = sp3.X, sp3.Y
        local col = GameMode:GetTeamDisplayColor(player)

        if ESP.ShowHighlight then
            if not cache.Highlight or not cache.Highlight.Parent then
                local hl = Instance.new("Highlight")
                hl.Name = "ESPHighlight"
                hl.FillColor = col; hl.FillTransparency = 0.6
                hl.OutlineColor = col; hl.OutlineTransparency = 0
                hl.Adornee = char; hl.Parent = char
                cache.Highlight = hl
            else
                cache.Highlight.Enabled = true
                cache.Highlight.FillColor = col
                cache.Highlight.OutlineColor = col
                if cache.Highlight.Adornee ~= char then
                    cache.Highlight.Adornee = char; cache.Highlight.Parent = char
                end
            end
        else
            if cache.Highlight then pcall(function() cache.Highlight.Enabled = false end) end
        end

        if ESP.ShowName and cache.Text then
            cache.Text.Text = string.format("%s [%d HP]", player.DisplayName or player.Name, math.floor(hum.Health))
            cache.Text.Position = Vector2.new(sx, sy - 50)
            cache.Text.Color = col; cache.Text.Visible = true
        elseif cache.Text then cache.Text.Visible = false end

        if ESP.ShowDistance and cache.DistText then
            local mr = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            local d = mr and math.floor((mr.Position - root.Position).Magnitude) or 0
            cache.DistText.Text = string.format("[%d studs]", d)
            cache.DistText.Position = Vector2.new(sx, sy - 35)
            cache.DistText.Color = col; cache.DistText.Visible = true
        elseif cache.DistText then cache.DistText.Visible = false end

        if ESP.ShowTracer and cache.Tracer then
            cache.Tracer.From = Vector2.new(vpX / 2, vpY)
            cache.Tracer.To = Vector2.new(sx, sy)
            cache.Tracer.Color = col; cache.Tracer.Visible = true
        elseif cache.Tracer then cache.Tracer.Visible = false end

        if ESP.ShowHealthBar and cache.HealthBg and cache.HealthBar then
            local bw, by = 40, sy - 22
            local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            cache.HealthBg.From = Vector2.new(sx - bw/2, by)
            cache.HealthBg.To = Vector2.new(sx + bw/2, by); cache.HealthBg.Visible = true
            cache.HealthBar.From = Vector2.new(sx - bw/2, by)
            cache.HealthBar.To = Vector2.new(sx - bw/2 + bw * frac, by)
            cache.HealthBar.Color = GetHPColor(frac); cache.HealthBar.Visible = true
        else
            if cache.HealthBg then cache.HealthBg.Visible = false end
            if cache.HealthBar then cache.HealthBar.Visible = false end
        end

        if ESP.ShowSkeleton then UpdateSkeleton(cache, char, col)
        elseif cache.Bones then for _, b in ipairs(cache.Bones) do b.Visible = false end end
    end

    for p, cache in pairs(ESPCache) do
        if not active[p] then HidePlayerESP(cache) end
    end
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 12: RESPAWN-SMART PLAYER TRACKING
-- ══════════════════════════════════════════════════════════════

local function HookPlayerRespawn(player)
    if player == LocalPlayer then return end
    local ck = "CharAdded_" .. player.UserId
    TrackConnection(ck, player.CharacterAdded:Connect(function()
        task.wait(0.2)
        CleanPlayerESP(player)
        ClearPrediction(player)
        ClearFrozenPosition(player)
        if Aimbot.LockedPlayer == player then Aimbot:Unlock("dead") end
    end))
    local dk = "CharRemoving_" .. player.UserId
    TrackConnection(dk, player.CharacterRemoving:Connect(function()
        local cache = ESPCache[player]
        if cache then HidePlayerESP(cache) end
        ClearPrediction(player)
        ClearFrozenPosition(player)
        if Aimbot.LockedPlayer == player then Aimbot:Unlock("dead") end
    end))
end

for _, p in ipairs(Players:GetPlayers()) do HookPlayerRespawn(p) end
TrackConnection("PlayerAdded", Players.PlayerAdded:Connect(function(p) HookPlayerRespawn(p) end))
TrackConnection("PlayerRemoving", Players.PlayerRemoving:Connect(function(p)
    CleanPlayerESP(p); ClearPrediction(p); ClearFrozenPosition(p)
    KillConnection("CharAdded_" .. p.UserId); KillConnection("CharRemoving_" .. p.UserId)
    if Aimbot.LockedPlayer == p then Aimbot:Unlock("dead") end
end))

TrackConnection("TeamChanged", LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
    GameMode.LastCheck = 0; GameMode:DetectMode(); Aimbot:Unlock(); CleanAllESP()
end))
TrackConnection("LocalCharAdded", LocalPlayer.CharacterAdded:Connect(function()
    GameMode.LastCheck = 0; GameMode:DetectMode(); ClearAllPredictions(); Aimbot:Unlock()
end))

-- ══════════════════════════════════════════════════════════════
--  SECTION 13: PERIODIC REFRESH
-- ══════════════════════════════════════════════════════════════

local _refreshCounter = 0

local function PeriodicRefresh()
    _refreshCounter = _refreshCounter + 1
    if _refreshCounter < 300 then return end -- Every ~5 sec at 60fps
    _refreshCounter = 0
    GameMode.LastCheck = 0; GameMode:DetectMode()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and not Connections["CharAdded_" .. p.UserId] then
            HookPlayerRespawn(p)
        end
    end
    for p in pairs(ESPCache) do
        if not p or not p.Parent then CleanPlayerESP(p) end
    end
    for p in pairs(PredictionData) do
        if not p or not p.Parent then PredictionData[p] = nil end
    end
    for p in pairs(_lastValidPos) do
        if not p or not p.Parent then _lastValidPos[p] = nil end
    end
    for p in pairs(_deathCooldown) do
        if not p or not p.Parent then _deathCooldown[p] = nil end
    end
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 14: INPUT HANDLING
-- ══════════════════════════════════════════════════════════════

TrackConnection("AimKeyDown", UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        if Aimbot.AimKeyMode == "Hold (RMB)" then
            Aimbot.AimKeyActive = true
        elseif Aimbot.AimKeyMode == "Toggle (RMB)" then
            Aimbot.AimKeyActive = not Aimbot.AimKeyActive
            if not Aimbot.AimKeyActive then Aimbot:Unlock() end
        end
    end
end))

TrackConnection("AimKeyUp", UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        if Aimbot.AimKeyMode == "Hold (RMB)" then Aimbot.AimKeyActive = false end
    end
end))

-- LMB Trigger Assist input handlers
TrackConnection("TriggerDown", UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if TriggerAssist.Enabled then
            TriggerAssist._active = true
            TriggerAssist._target = TriggerAssist:FindTarget()
            TriggerAssist._pulseStart = tick()
        end
    end
end))

TrackConnection("TriggerUp", UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        TriggerAssist._active = false
        TriggerAssist._target = nil
    end
end))

-- ══════════════════════════════════════════════════════════════
--  SECTION 15: MAIN RENDER LOOP
-- ══════════════════════════════════════════════════════════════

TrackConnection("MainLoop", RunService.RenderStepped:Connect(function(dt)
    Camera = Workspace.CurrentCamera
    if not Camera then return end
    Aimbot:Update(dt)
    TriggerAssist:Update(dt)
    UpdateAllESP()
    PeriodicRefresh()
end))

-- ══════════════════════════════════════════════════════════════
--  TAB 1: MOVEMENT
-- ══════════════════════════════════════════════════════════════

local MovementTab = Window:CreateTab("Movement", nil)

local InfJumpEnabled = false
MovementTab:CreateToggle({
    Name = "Infinite Jump", CurrentValue = false, Flag = "InfJumpToggle",
    Callback = function(Value)
        InfJumpEnabled = Value
        if not Value then KillConnection("InfJump") return end
        TrackConnection("InfJump", UserInputService.InputBegan:Connect(function(input, gpe)
            if gpe or not InfJumpEnabled then return end
            if input.KeyCode == Enum.KeyCode.Space then
                local char = LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if hum and root and hum:GetState() ~= Enum.HumanoidStateType.Dead then
                    hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, hum.JumpPower, root.AssemblyLinearVelocity.Z)
                end
            end
        end))
    end,
})

local NoClipEnabled = false
MovementTab:CreateToggle({
    Name = "No Clip", CurrentValue = false, Flag = "NoClipToggle",
    Callback = function(Value)
        NoClipEnabled = Value
        if not Value then
            KillConnection("NoClipLoop")
            local char = LocalPlayer.Character
            if char then for _, p in ipairs(char:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = true end end end
            return
        end
        TrackConnection("NoClipLoop", RunService.Stepped:Connect(function()
            if not NoClipEnabled then return end
            local char = LocalPlayer.Character
            if not char then return end
            for _, p in ipairs(char:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end
        end))
    end,
})

MovementTab:CreateSlider({
    Name = "Walk Speed", Range = {0, 200}, Increment = 1, Suffix = " Speed", CurrentValue = 16, Flag = "WalkSpeedSlider",
    Callback = function(Value)
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = Value end
    end,
})

MovementTab:CreateSlider({
    Name = "Jump Power", Range = {0, 200}, Increment = 1, Suffix = " Power", CurrentValue = 50, Flag = "JumpPowerSlider",
    Callback = function(Value)
        local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.UseJumpPower = true; hum.JumpPower = Value end
    end,
})

-- ══════════════════════════════════════════════════════════════
--  TAB 2: AIMBOT — Core Settings
-- ══════════════════════════════════════════════════════════════

local CombatTab = Window:CreateTab("Aimbot", nil)

CombatTab:CreateToggle({
    Name = "Aimbot", Info = "Ultra v5.0 — fully customizable aimbot engine.",
    CurrentValue = false, Flag = "AimbotToggle",
    Callback = function(V) Aimbot.Enabled = V; if not V then Aimbot:Unlock() end end,
})

CombatTab:CreateDropdown({
    Name = "Aim Activation", Options = {"Always On", "Hold (RMB)", "Toggle (RMB)"},
    CurrentOption = {"Always On"}, MultiSelection = false, Flag = "AimKeyModeDropdown",
    Callback = function(O)
        Aimbot.AimKeyMode = O[1] or O; Aimbot.AimKeyActive = false
        if Aimbot.AimKeyMode ~= "Always On" then Aimbot:Unlock() end
    end,
})

CombatTab:CreateDropdown({
    Name = "Aim Part", Options = {"Head", "HumanoidRootPart", "Torso"},
    CurrentOption = {"Head"}, MultiSelection = false, Flag = "AimPartDropdown",
    Callback = function(O) Aimbot.AimPart = O[1] or O; Aimbot:Unlock() end,
})

CombatTab:CreateDropdown({
    Name = "Target Priority", Options = {"Crosshair", "Lowest HP", "Nearest", "Threat"},
    CurrentOption = {"Crosshair"}, MultiSelection = false, Flag = "PriorityModeDropdown",
    Callback = function(O) Aimbot.PriorityMode = O[1] or O end,
})

CombatTab:CreateDivider()

CombatTab:CreateSlider({
    Name = "Aim Smoothing", Info = "1 = near-instant, 20 = very smooth.",
    Range = {1, 20}, Increment = 1, CurrentValue = 6, Flag = "AimSmoothSlider",
    Callback = function(V) Aimbot.Smoothing = V end,
})

CombatTab:CreateSlider({
    Name = "Aim Strength", Info = "% of aimbot pull. Lower = more user control.",
    Range = {10, 100}, Increment = 5, Suffix = "%", CurrentValue = 65, Flag = "AimStrengthSlider",
    Callback = function(V) Aimbot.AimStrength = V / 100 end,
})

CombatTab:CreateSlider({
    Name = "Aimbot FOV", Range = {30, 800}, Increment = 10, Suffix = " px", CurrentValue = 120, Flag = "AimbotFOVSlider",
    Callback = function(V) Aimbot.FOVRadius = V; Aimbot.BaseFOVRadius = V end,
})

CombatTab:CreateSlider({
    Name = "Max Distance", Range = {50, 100000}, Increment = 50, Suffix = " studs", CurrentValue = 100000, Flag = "AimbotDistSlider",
    Callback = function(V) Aimbot.MaxDistance = V end,
})

CombatTab:CreateSlider({
    Name = "Min Distance", Info = "Ignore targets closer than this (avoid self-lock).",
    Range = {0, 50}, Increment = 1, Suffix = " studs", CurrentValue = 0, Flag = "AimbotMinDistSlider",
    Callback = function(V) Aimbot.MinDistance = V end,
})

CombatTab:CreateDivider()

CombatTab:CreateToggle({ Name = "Snap Mode", Info = "Instant lock-on.", CurrentValue = false, Flag = "SnapModeToggle",
    Callback = function(V) Aimbot.SnapMode = V end })

CombatTab:CreateToggle({ Name = "Smart Team Check", Info = "Auto-detects FFA/team.", CurrentValue = true, Flag = "TeamCheckToggle",
    Callback = function(V) Aimbot.TeamCheck = V; ESP.TeamCheck = V end })

CombatTab:CreateToggle({ Name = "Wall Check", Info = "Multi-point raycast visibility.", CurrentValue = false, Flag = "VisCheckToggle",
    Callback = function(V) Aimbot.VisCheck = V end })

CombatTab:CreateToggle({ Name = "Velocity Prediction", Info = "Kalman-adaptive with strafe & jump arc.", CurrentValue = true, Flag = "PredictionToggle",
    Callback = function(V) Aimbot.Prediction = V end })

CombatTab:CreateToggle({ Name = "Auto-Switch on Kill", CurrentValue = true, Flag = "AutoSwitchToggle",
    Callback = function(V) Aimbot.AutoSwitch = V end })

CombatTab:CreateToggle({ Name = "Sticky Visibility", Info = "Soft aim through walls.", CurrentValue = true, Flag = "StickyVisToggle",
    Callback = function(V) Aimbot.StickyVis = V end })

CombatTab:CreateToggle({ Name = "Dynamic FOV", Info = "Scope-aware FOV scaling.", CurrentValue = true, Flag = "DynamicFOVToggle",
    Callback = function(V) Aimbot.DynamicFOV = V end })

CombatTab:CreateDivider()

CombatTab:CreateToggle({ Name = "Humanization", Info = "Perlin noise micro-offsets.", CurrentValue = false, Flag = "HumanizeToggle",
    Callback = function(V) Aimbot.Humanize = V end })

CombatTab:CreateSlider({
    Name = "Humanize Strength", Range = {1, 8}, Increment = 1, Suffix = " px", CurrentValue = 2, Flag = "HumanizeStrengthSlider",
    Callback = function(V) Aimbot.HumanizeStrength = V end,
})

CombatTab:CreateDivider()

CombatTab:CreateToggle({ Name = "Show FOV Circle", CurrentValue = false, Flag = "ShowFOVToggle",
    Callback = function(V) Aimbot.ShowFOV = V end })

CombatTab:CreateToggle({ Name = "Show Aim Tracer", CurrentValue = true, Flag = "ShowTracerToggle",
    Callback = function(V) Aimbot.ShowTracer = V end })

CombatTab:CreateToggle({ Name = "Show Target HUD", Info = "Target name, HP, dist, visibility.", CurrentValue = true, Flag = "ShowTargetHUDToggle",
    Callback = function(V) Aimbot.ShowTargetHUD = V; if not V then HideTargetHUD() end end })

CombatTab:CreateDivider()

CombatTab:CreateInput({ Name = "Ignore Username", PlaceholderText = "Enter username", RemoveTextAfterFocusLost = true,
    Callback = function(u) if u and u ~= "" and not table.find(Aimbot.IgnoredNames, u) then table.insert(Aimbot.IgnoredNames, u) end end })

CombatTab:CreateInput({ Name = "Remove Ignored", PlaceholderText = "Enter username", RemoveTextAfterFocusLost = true,
    Callback = function(u) for i = #Aimbot.IgnoredNames, 1, -1 do if Aimbot.IgnoredNames[i] == u then table.remove(Aimbot.IgnoredNames, i) break end end end })

CombatTab:CreateDivider()
CombatTab:CreateLabel("Smart Auto-Target System")

CombatTab:CreateToggle({ Name = "Smart Auto-Target", Info = "360° intelligent target acquisition after kill.",
    CurrentValue = true, Flag = "AutoTargetToggle",
    Callback = function(V) Aimbot.AutoTargetEnabled = V end })

CombatTab:CreateToggle({ Name = "360° Full Scan", Info = "Scan all directions including behind you.",
    CurrentValue = true, Flag = "AutoTargetFullScanToggle",
    Callback = function(V) Aimbot.AutoTargetFullScan = V end })

CombatTab:CreateToggle({ Name = "Scan Behind Player", Info = "Allow targeting enemies behind you.",
    CurrentValue = true, Flag = "AutoTargetScanBehindToggle",
    Callback = function(V) Aimbot.AutoTargetScanBehind = V end })

CombatTab:CreateToggle({ Name = "FOV Priority", Info = "Prefer targets already in your field of view.",
    CurrentValue = true, Flag = "AutoTargetFOVPriorityToggle",
    Callback = function(V) Aimbot.AutoTargetFOVPriority = V end })

CombatTab:CreateToggle({ Name = "Smooth Transition", Info = "Smooth camera rotation to new target instead of snapping.",
    CurrentValue = true, Flag = "AutoTargetSmoothToggle",
    Callback = function(V) Aimbot.AutoTargetSmoothTransition = V end })

CombatTab:CreateSlider({
    Name = "Auto-Target Range", Info = "Maximum range for 360° target scan (studs).",
    Range = {50, 2000}, Increment = 50, Suffix = " studs", CurrentValue = 500, Flag = "AutoTargetRangeSlider",
    Callback = function(V) Aimbot.AutoTargetMaxRange = V end,
})

CombatTab:CreateSlider({
    Name = "Transition Speed", Info = "How fast camera moves to new target. Higher = faster.",
    Range = {1, 10}, Increment = 1, CurrentValue = 4, Flag = "AutoTargetTransSpeedSlider",
    Callback = function(V) Aimbot.AutoTargetTransitionSpeed = V end,
})

CombatTab:CreateSlider({
    Name = "Behind Target Speed", Info = "Camera speed when targeting behind (lower = smoother 180° turns).",
    Range = {10, 50}, Increment = 5, Suffix = "x/10", CurrentValue = 25, Flag = "AutoTargetBehindSpeedSlider",
    Callback = function(V) Aimbot.AutoTargetBehindSpeed = V / 10 end,
})

CombatTab:CreateDivider()
CombatTab:CreateLabel("Trigger Assist (Click-to-Track)")

CombatTab:CreateToggle({ Name = "Trigger Assist", Info = "No tracking normally — only aims when you shoot (LMB). Smooth & natural.",
    CurrentValue = false, Flag = "TriggerAssistToggle",
    Callback = function(V) TriggerAssist.Enabled = V end })

CombatTab:CreateToggle({ Name = "Hold Mode", Info = "ON=track while holding LMB. OFF=brief pulse per click.",
    CurrentValue = true, Flag = "TriggerHoldToggle",
    Callback = function(V) TriggerAssist.HoldMode = V end })

CombatTab:CreateToggle({ Name = "Fade Out", Info = "Gradually reduce aim pull (more natural per click).",
    CurrentValue = true, Flag = "TriggerFadeToggle",
    Callback = function(V) TriggerAssist.FadeOut = V end })

CombatTab:CreateToggle({ Name = "Use Prediction", Info = "Use velocity prediction for accurate head tracking.",
    CurrentValue = true, Flag = "TriggerPredToggle",
    Callback = function(V) TriggerAssist.UsePrediction = V end })

CombatTab:CreateSlider({
    Name = "Trigger Strength", Info = "Aim pull intensity. Lower = more subtle & natural.",
    Range = {5, 80}, Increment = 5, Suffix = "%", CurrentValue = 40, Flag = "TriggerStrengthSlider",
    Callback = function(V) TriggerAssist.Strength = V / 100 end,
})

CombatTab:CreateSlider({
    Name = "Trigger Smoothing", Info = "Higher = smoother movement. Lower = snappier.",
    Range = {3, 20}, Increment = 1, CurrentValue = 10, Flag = "TriggerSmoothSlider",
    Callback = function(V) TriggerAssist.Smoothing = V end,
})

CombatTab:CreateSlider({
    Name = "Trigger FOV", Info = "Max screen radius to search for targets.",
    Range = {50, 600}, Increment = 25, Suffix = " px", CurrentValue = 250, Flag = "TriggerFOVSlider",
    Callback = function(V) TriggerAssist.MaxFOV = V end,
})

CombatTab:CreateSlider({
    Name = "Trigger Range", Info = "Max 3D distance for trigger assist.",
    Range = {50, 2000}, Increment = 50, Suffix = " studs", CurrentValue = 500, Flag = "TriggerRangeSlider",
    Callback = function(V) TriggerAssist.MaxDistance = V end,
})

CombatTab:CreateSlider({
    Name = "Pulse Duration", Info = "How long each click's aim pulse lasts (ms).",
    Range = {50, 500}, Increment = 25, Suffix = " ms", CurrentValue = 250, Flag = "TriggerPulseMsSlider",
    Callback = function(V) TriggerAssist.PulseDuration = V / 1000 end,
})

CombatTab:CreateSlider({
    Name = "Max Angular Speed", Info = "Max camera rotation speed (keeps it natural).",
    Range = {100, 800}, Increment = 50, Suffix = " °/s", CurrentValue = 400, Flag = "TriggerAngSpeedSlider",
    Callback = function(V) TriggerAssist.MaxAngSpeed = V end,
})

-- ══════════════════════════════════════════════════════════════
--  TAB 3: ADVANCED AIM SETTINGS
--  Full control over prediction, smoothing, and aim behavior
-- ══════════════════════════════════════════════════════════════

local AdvancedTab = Window:CreateTab("Advanced", nil)

AdvancedTab:CreateLabel("Prediction Engine Tuning")

local SL_VelSmooth = AdvancedTab:CreateSlider({
    Name = "Velocity Smoothing", Info = "EMA speed for velocity filter. Higher = snappier tracking.",
    Range = {5, 30}, Increment = 1, CurrentValue = 15, Flag = "PredVelSmooth",
    Callback = function(V) PredictionConfig.VelocitySmoothing = V end,
})

local SL_AccelSmooth = AdvancedTab:CreateSlider({
    Name = "Accel Smoothing", Info = "EMA speed for acceleration filter.",
    Range = {3, 15}, Increment = 1, CurrentValue = 8, Flag = "PredAccelSmooth",
    Callback = function(V) PredictionConfig.AccelSmoothing = V end,
})

local SL_LookAheadMul = AdvancedTab:CreateSlider({
    Name = "Look-Ahead Multiplier", Info = "Higher = predicts further ahead. Too high = overshoot.",
    Range = {1, 10}, Increment = 1, CurrentValue = 4, Flag = "PredLookAheadMul",
    Callback = function(V) PredictionConfig.LookAheadMultiplier = V end,
})

local SL_LookAheadMax = AdvancedTab:CreateSlider({
    Name = "Look-Ahead Max (ms)", Info = "Maximum prediction time in milliseconds.",
    Range = {50, 500}, Increment = 10, Suffix = " ms", CurrentValue = 200, Flag = "PredLookAheadMax",
    Callback = function(V) PredictionConfig.LookAheadMax = V / 1000 end,
})

local SL_VelCap = AdvancedTab:CreateSlider({
    Name = "Velocity Cap", Info = "Max velocity magnitude (studs/s). 0 = unlimited.",
    Range = {0, 1500}, Increment = 50, Suffix = " s/s", CurrentValue = 600, Flag = "PredVelCap",
    Callback = function(V) PredictionConfig.VelocityCap = V end,
})

local SL_AccelCap = AdvancedTab:CreateSlider({
    Name = "Accel Cap", Info = "Max acceleration magnitude.",
    Range = {200, 2000}, Increment = 50, CurrentValue = 800, Flag = "PredAccelCap",
    Callback = function(V) PredictionConfig.AccelCap = V end,
})

local SL_ConfGain = AdvancedTab:CreateSlider({
    Name = "Confidence Gain", Info = "How fast prediction confidence builds.",
    Range = {1, 10}, Increment = 1, CurrentValue = 4, Flag = "PredConfGain",
    Callback = function(V) PredictionConfig.ConfidenceGainRate = V end,
})

local SL_ConfLoss = AdvancedTab:CreateSlider({
    Name = "Confidence Loss", Info = "How fast confidence drops on bad prediction.",
    Range = {1, 15}, Increment = 1, CurrentValue = 6, Flag = "PredConfLoss",
    Callback = function(V) PredictionConfig.ConfidenceLossRate = V end,
})

AdvancedTab:CreateDivider()
AdvancedTab:CreateLabel("Strafe & Jump Detection")

local SL_StrafeSens = AdvancedTab:CreateSlider({
    Name = "Strafe Sensitivity", Info = "Direction reversals needed to detect AD-spam.",
    Range = {2, 6}, Increment = 1, CurrentValue = 3, Flag = "PredStrafeSens",
    Callback = function(V) PredictionConfig.StrafeSensitivity = V end,
})

local SL_StrafeWin = AdvancedTab:CreateSlider({
    Name = "Strafe Window (ms)", Info = "Time window for strafe detection.",
    Range = {300, 1500}, Increment = 100, Suffix = " ms", CurrentValue = 800, Flag = "PredStrafeWindow",
    Callback = function(V) PredictionConfig.StrafeWindow = V / 1000 end,
})

local SL_StrafeDamp = AdvancedTab:CreateSlider({
    Name = "Strafe Dampen", Info = "Velocity multiplier during strafe (lower = more stable).",
    Range = {5, 80}, Increment = 5, Suffix = "%", CurrentValue = 25, Flag = "PredStrafeDampen",
    Callback = function(V) PredictionConfig.StrafeDampen = V / 100 end,
})

local TG_JumpArc = AdvancedTab:CreateToggle({
    Name = "Jump Arc Prediction", Info = "Parabolic trajectory for airborne targets.",
    CurrentValue = true, Flag = "PredJumpArc",
    Callback = function(V) PredictionConfig.JumpArcEnabled = V end,
})

local SL_JumpThresh = AdvancedTab:CreateSlider({
    Name = "Jump Threshold", Info = "Y velocity to detect airborne (studs/s).",
    Range = {5, 30}, Increment = 1, Suffix = " s/s", CurrentValue = 12, Flag = "PredJumpThresh",
    Callback = function(V) PredictionConfig.JumpThreshold = V end,
})

AdvancedTab:CreateDivider()
AdvancedTab:CreateLabel("Aim Behavior Tuning")

local SL_AimRamp = AdvancedTab:CreateSlider({
    Name = "Ramp-Up Time (ms)", Info = "Ease-in duration when acquiring new target.",
    Range = {0, 500}, Increment = 10, Suffix = " ms", CurrentValue = 150, Flag = "AimRampUp",
    Callback = function(V) Aimbot.RampUpTime = V / 1000 end,
})

local SL_AimMaxAng = AdvancedTab:CreateSlider({
    Name = "Max Angular Speed", Info = "Max camera rotation speed (deg/sec).",
    Range = {180, 2000}, Increment = 30, Suffix = " °/s", CurrentValue = 720, Flag = "AimMaxAngSpeed",
    Callback = function(V) Aimbot.MaxAngularSpeed = V end,
})

local SL_AimUnlock = AdvancedTab:CreateSlider({
    Name = "Unlock Threshold", Info = "FOV multiplier at which lock breaks when user overrides.",
    Range = {15, 50}, Increment = 1, Suffix = "x/10", CurrentValue = 25, Flag = "AimUnlockThresh",
    Callback = function(V) Aimbot.UnlockThreshold = V / 10 end,
})

local SL_AimGrace = AdvancedTab:CreateSlider({
    Name = "Grace Period (ms)", Info = "How long to keep lock when target goes behind wall.",
    Range = {0, 2000}, Increment = 50, Suffix = " ms", CurrentValue = 350, Flag = "AimGracePeriod",
    Callback = function(V) Aimbot.GracePeriod = V / 1000 end,
})

local SL_AimSticky = AdvancedTab:CreateSlider({
    Name = "Sticky Vis Strength", Info = "Aim strength % when target is behind wall.",
    Range = {5, 80}, Increment = 5, Suffix = "%", CurrentValue = 20, Flag = "AimStickyStr",
    Callback = function(V) Aimbot.StickyVisStrength = V / 100 end,
})

local SL_AimAutoSwitch = AdvancedTab:CreateSlider({
    Name = "Auto-Switch Ramp (ms)", Info = "Ramp-up time after auto-switching target.",
    Range = {0, 200}, Increment = 10, Suffix = " ms", CurrentValue = 80, Flag = "AimAutoSwitchRamp",
    Callback = function(V) Aimbot.AutoSwitchRampUp = V / 1000 end,
})

local SL_PredDirFast = AdvancedTab:CreateSlider({
    Name = "Direction React (Fast)", Info = "Beta multiplier on sharp direction change.",
    Range = {10, 40}, Increment = 1, Suffix = "x/10", CurrentValue = 25, Flag = "PredDirFast",
    Callback = function(V) PredictionConfig.DirectionReactFast = V / 10 end,
})

local SL_PredDirMed = AdvancedTab:CreateSlider({
    Name = "Direction React (Med)", Info = "Beta multiplier on medium direction change.",
    Range = {10, 25}, Increment = 1, Suffix = "x/10", CurrentValue = 16, Flag = "PredDirMed",
    Callback = function(V) PredictionConfig.DirectionReactMed = V / 10 end,
})

AdvancedTab:CreateDivider()
AdvancedTab:CreateLabel("Presets & Reset")

local function ApplyPreset(presetName)
    if presetName == "Normal" then
        SL_VelSmooth:Set(15)
        SL_AccelSmooth:Set(8)
        SL_LookAheadMul:Set(4)
        SL_LookAheadMax:Set(200)
        SL_VelCap:Set(600)
        SL_AccelCap:Set(800)
        SL_ConfGain:Set(4)
        SL_ConfLoss:Set(6)
        SL_StrafeSens:Set(3)
        SL_StrafeWin:Set(800)
        SL_StrafeDamp:Set(25)
        TG_JumpArc:Set(true)
        SL_JumpThresh:Set(12)
        SL_AimRamp:Set(150)
        SL_AimMaxAng:Set(720)
        SL_AimUnlock:Set(25)
        SL_AimGrace:Set(350)
        SL_AimSticky:Set(20)
        SL_AimAutoSwitch:Set(80)
        SL_PredDirFast:Set(25)
        SL_PredDirMed:Set(16)
    elseif presetName == "Ringan" then
        SL_VelSmooth:Set(8)
        SL_AccelSmooth:Set(5)
        SL_LookAheadMul:Set(2)
        SL_LookAheadMax:Set(150)
        SL_VelCap:Set(400)
        SL_AccelCap:Set(500)
        SL_ConfGain:Set(3)
        SL_ConfLoss:Set(8)
        SL_StrafeSens:Set(4)
        SL_StrafeWin:Set(1000)
        SL_StrafeDamp:Set(40)
        TG_JumpArc:Set(false)
        SL_JumpThresh:Set(15)
        SL_AimRamp:Set(250)
        SL_AimMaxAng:Set(400)
        SL_AimUnlock:Set(35)
        SL_AimGrace:Set(200)
        SL_AimSticky:Set(10)
        SL_AimAutoSwitch:Set(150)
        SL_PredDirFast:Set(15)
        SL_PredDirMed:Set(12)
    elseif presetName == "Extreme" then
        SL_VelSmooth:Set(25)
        SL_AccelSmooth:Set(12)
        SL_LookAheadMul:Set(6)
        SL_LookAheadMax:Set(300)
        SL_VelCap:Set(1000)
        SL_AccelCap:Set(1500)
        SL_ConfGain:Set(6)
        SL_ConfLoss:Set(4)
        SL_StrafeSens:Set(2)
        SL_StrafeWin:Set(500)
        SL_StrafeDamp:Set(10)
        TG_JumpArc:Set(true)
        SL_JumpThresh:Set(8)
        SL_AimRamp:Set(50)
        SL_AimMaxAng:Set(1200)
        SL_AimUnlock:Set(15)
        SL_AimGrace:Set(600)
        SL_AimSticky:Set(40)
        SL_AimAutoSwitch:Set(20)
        SL_PredDirFast:Set(35)
        SL_PredDirMed:Set(22)
    end
end

AdvancedTab:CreateDropdown({
    Name = "Configuration Presets",
    Options = {"Normal", "Ringan", "Extreme"},
    CurrentOption = {"Normal"},
    MultiSelection = false,
    Flag = "AdvPresetDropdown",
    Callback = function(Option)
        local opt = type(Option) == "table" and Option[1] or Option
        ApplyPreset(opt)
    end,
})

AdvancedTab:CreateButton({
    Name = "Reset All to Default",
    Callback = function()
        ApplyPreset("Normal")
    end,
})

-- ══════════════════════════════════════════════════════════════
--  TAB 4: ESP
-- ══════════════════════════════════════════════════════════════

local ESPTab = Window:CreateTab("ESP", nil)

ESPTab:CreateToggle({ Name = "ESP Master Toggle", Info = "Enable/disable all ESP.", CurrentValue = false, Flag = "ESPToggle",
    Callback = function(V) ESP.Enabled = V; if not V then CleanAllESP() end end })

ESPTab:CreateDivider()

ESPTab:CreateToggle({ Name = "Highlight (Glow)", CurrentValue = true, Flag = "ESPHighlightToggle",
    Callback = function(V) ESP.ShowHighlight = V
        if not V then for _, c in pairs(ESPCache) do if c.Highlight then pcall(function() c.Highlight.Enabled = false end) end end end
    end })

ESPTab:CreateToggle({ Name = "Name + HP", CurrentValue = true, Flag = "ESPNameToggle",
    Callback = function(V) ESP.ShowName = V end })

ESPTab:CreateToggle({ Name = "Distance", CurrentValue = true, Flag = "ESPDistanceToggle",
    Callback = function(V) ESP.ShowDistance = V end })

ESPTab:CreateToggle({ Name = "Tracer Lines", CurrentValue = true, Flag = "ESPTracerToggle",
    Callback = function(V) ESP.ShowTracer = V end })

ESPTab:CreateToggle({ Name = "Health Bar", CurrentValue = true, Flag = "ESPHealthToggle",
    Callback = function(V) ESP.ShowHealthBar = V end })

ESPTab:CreateToggle({ Name = "Skeleton (Bones)", Info = "Auto-detects R6/R15.", CurrentValue = false, Flag = "ESPSkeletonToggle",
    Callback = function(V) ESP.ShowSkeleton = V end })

-- ══════════════════════════════════════════════════════════════
--  CLEANUP
-- ══════════════════════════════════════════════════════════════

pcall(function()
    game:BindToClose(function()
        KillAllConnections(); DestroyAllDrawings(); CleanAllESP(); ClearAllPredictions(); HideTargetHUD()
        table.clear(_lastValidPos); table.clear(_deathCooldown)
    end)
end)
