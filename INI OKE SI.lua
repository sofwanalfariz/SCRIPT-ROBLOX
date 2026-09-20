--[[
╔═══════════════════════════════════════════════════════════════╗
║       Cryziie's Arsenal Script — Ultra v5.0                   ║
║                                                               ║
║  ULTRA AIMBOT v5.0:                                           ║
║  • Kalman-Inspired Adaptive Prediction Engine                 ║
║  • Strafe Pattern Detection (anti-AD-spam wiggle)             ║
║  • Jump Arc Prediction (parabolic mid-air tracking)           ║
║  • Spring-Damper Smooth Aim (fully customizable)              ║
║  • Assist Mode — User Override with AimStrength               ║
║  • Hold-to-Aim Keybind (RMB Hold / Toggle / Always On)        ║
║  • 4 Target Priority Modes (Crosshair/HP/Distance/Threat)     ║
║  • Auto-Switch on Kill (instant next target)                  ║
║  • Humanization Layer (Perlin Noise micro-offsets)             ║
║  • Dynamic FOV (scope-aware, auto-expand on idle)             ║
║  • Sticky Visibility Strength (customizable wall-track)       ║
║  • Target Info HUD (name, HP, dist, visibility)               ║
║  • Smart FFA / Team auto-detection (per-frame)                ║
║  • Multi-point wall check (configurable body parts)           ║
║  • Full Advanced Settings Tab (prediction, smoothing, limits) ║
║  • Save & Load Profiles via Rayfield ConfigurationSaving      ║
║                                                               ║
║  SMART ESP:                                                   ║
║  • 6 individual toggles (Highlight, Name, Dist, Tracer, etc.) ║
║  • Skeleton ESP (R6 + R15 auto-detect)                        ║
║  • Respawn-smart tracking (CharacterAdded hooks)              ║
║  • Periodic cache refresh                                     ║
║  • Smart team coloring (FFA Orange, Team Red/Blue)            ║
║                                                               ║
║  MOVEMENT:                                                    ║
║  • Infinite Jump / NoClip / Speed / Jump Power                ║
╚═══════════════════════════════════════════════════════════════╝
]]

-- ══════════════════════════════════════════════════════════════
--  SECTION 1: RAYFIELD UI SETUP
--  ConfigurationSaving enabled — all flags auto-persist
-- ══════════════════════════════════════════════════════════════

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "Cryziie's Arsenal Ultra v5.0",
    Icon = 0,
    LoadingTitle = "Loading Ultra Arsenal Suite v5.0...",
    LoadingSubtitle = "Presented by: Cryziie | Ultra Edition",
    ShowText = "taking suggestions dm @Cryziie on discord",
    Theme = "Default",
    ToggleUIKeybind = "K",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "CryziieUltra",
        FileName = "CryziieUltra_v5"
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
    return (tick() - t) < 0.15
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 6: SMART GAME MODE & TEAM DETECTION (v5.0)
--  Throttled detection, team change hooks, robust FFA heuristic
-- ══════════════════════════════════════════════════════════════

local GameMode = {
    IsFFA         = false,
    LastCheck     = 0,
    CheckInterval = 0.1,
}

function GameMode:DetectMode()
    local now = tick()
    if now - self.LastCheck < self.CheckInterval then return end
    self.LastCheck = now

    local teams = TeamsService:GetTeams()
    if #teams == 0 then
        self.IsFFA = true
        return
    end

    local teamCounts = {}
    local withTeam, withoutTeam, total = 0, 0, 0

    for _, player in ipairs(Players:GetPlayers()) do
        total = total + 1
        if player.Team then
            teamCounts[player.Team] = (teamCounts[player.Team] or 0) + 1
            withTeam = withTeam + 1
        else
            withoutTeam = withoutTeam + 1
        end
    end

    local distinctTeams = 0
    for _ in pairs(teamCounts) do distinctTeams = distinctTeams + 1 end

    self.IsFFA = (distinctTeams <= 1 or withoutTeam > withTeam or total < 2)
end

function GameMode:IsEnemy(player)
    self:DetectMode()
    if self.IsFFA then return true end
    if not LocalPlayer.Team then return true end
    if not player.Team then return false end
    if LocalPlayer.Team ~= player.Team then return true end
    if LocalPlayer.TeamColor ~= player.TeamColor then return true end
    return false
end

function GameMode:GetTeamDisplayColor(player)
    self:DetectMode()
    if self.IsFFA then
        return Color3.fromRGB(255, 85, 35)
    elseif self:IsEnemy(player) then
        return Color3.fromRGB(255, 40, 40)
    else
        return Color3.fromRGB(40, 180, 255)
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
--  SECTION 8: PREDICTION ENGINE v5.0
--  Kalman-adaptive, strafe detection, jump arc, NO teleport cap
-- ══════════════════════════════════════════════════════════════

local PredictionData = {}
local ROBLOX_GRAVITY = 196.2

-- Configurable prediction parameters (exposed to UI)
local PredictionConfig = {
    VelocitySmoothing    = 15,   -- Base EMA speed for velocity (higher = snappier)
    AccelSmoothing       = 8,    -- Base EMA speed for acceleration
    AccelCap             = 800,  -- Max acceleration magnitude
    VelocityCap          = 600,  -- Max velocity magnitude (0 = unlimited)
    LookAheadMultiplier  = 4,    -- dt * this = look-ahead time
    LookAheadMax         = 0.2,  -- Max look-ahead seconds
    ConfidenceGainRate   = 4,    -- How fast confidence builds
    ConfidenceLossRate   = 6,    -- How fast confidence drops on bad prediction
    StrafeSensitivity    = 3,    -- Zero-crossings needed to detect strafe
    StrafeWindow         = 0.8,  -- Seconds of history for strafe detection
    StrafeDampen         = 0.25, -- Velocity multiplier during strafe
    JumpArcEnabled       = true, -- Use parabolic jump prediction
    JumpThreshold        = 12,   -- Y velocity threshold for airborne
    DirectionReactFast   = 2.5,  -- Beta multiplier on sharp direction change
    DirectionReactMed    = 1.6,  -- Beta multiplier on medium direction change
    EarlyBeta            = 0.85, -- Beta for first few samples
    EarlySamples         = 3,    -- How many samples before normal filtering
}

local function UpdatePrediction(player, worldPos, dt)
    dt = math.max(dt, 0.0001)
    local d = PredictionData[player]
    local cfg = PredictionConfig

    if not d then
        PredictionData[player] = {
            lastPos = worldPos, velocity = Vector3.zero, acceleration = Vector3.zero,
            smoothVelocity = Vector3.zero, predictedPos = worldPos, prevVelocity = Vector3.zero,
            sampleCount = 0, confidence = 0,
            strafeHistory = {}, strafing = false, strafeCenter = worldPos,
            airborne = false, jumpTime = 0,
        }
        return
    end

    -- Raw velocity
    local rawVelocity = (worldPos - d.lastPos) / dt
    if cfg.VelocityCap > 0 and rawVelocity.Magnitude > cfg.VelocityCap then
        rawVelocity = rawVelocity.Unit * cfg.VelocityCap
    end

    -- Kalman confidence
    local predErr = (worldPos - d.predictedPos).Magnitude
    if predErr < 2 then
        d.confidence = math.min(d.confidence + dt * cfg.ConfidenceGainRate, 1)
    elseif predErr < 8 then
        d.confidence = math.clamp(d.confidence - dt * 1.5, 0.15, 1)
    else
        d.confidence = math.max(d.confidence - dt * cfg.ConfidenceLossRate, 0)
    end

    -- Adaptive beta
    local baseBeta = math.clamp(1 - math.exp(-cfg.VelocitySmoothing * dt), 0.05, 0.9)
    local beta

    d.sampleCount = math.min(d.sampleCount + 1, 30)
    if d.sampleCount < cfg.EarlySamples then
        beta = cfg.EarlyBeta
    else
        beta = baseBeta * (1.2 - d.confidence * 0.6)
        beta = math.clamp(beta, 0.05, 0.95)
    end

    -- Direction change reaction
    if d.velocity.Magnitude > 2 and rawVelocity.Magnitude > 2 then
        local dot = d.velocity.Unit:Dot(rawVelocity.Unit)
        if dot < 0.1 then
            beta = math.clamp(beta * cfg.DirectionReactFast, 0.3, 0.95)
        elseif dot < 0.4 then
            beta = math.clamp(beta * cfg.DirectionReactMed, 0.15, 0.9)
        end
    end

    -- Update velocity
    d.prevVelocity = d.velocity
    d.velocity = d.velocity:Lerp(rawVelocity, beta)

    -- Update acceleration
    local rawAccel = (d.velocity - d.prevVelocity) / dt
    if rawAccel.Magnitude > cfg.AccelCap then rawAccel = rawAccel.Unit * cfg.AccelCap end
    local accelBeta = math.clamp(1 - math.exp(-cfg.AccelSmoothing * dt), 0.05, 0.6)
    d.acceleration = d.acceleration:Lerp(rawAccel, accelBeta)

    -- Smooth velocity for strafe
    local smoothBeta = math.clamp(1 - math.exp(-5 * dt), 0.02, 0.4)
    d.smoothVelocity = d.smoothVelocity:Lerp(d.velocity, smoothBeta)

    -- STRAFE DETECTION
    local now = tick()
    local hx = d.velocity.X
    local sign = hx > 1 and 1 or (hx < -1 and -1 or 0)
    if sign ~= 0 then
        d.strafeHistory[#d.strafeHistory + 1] = { sign = sign, time = now }
    end
    while #d.strafeHistory > 0 and (now - d.strafeHistory[1].time) > cfg.StrafeWindow do
        table.remove(d.strafeHistory, 1)
    end
    local crossings = 0
    for i = 2, #d.strafeHistory do
        if d.strafeHistory[i].sign ~= d.strafeHistory[i - 1].sign then crossings = crossings + 1 end
    end
    d.strafing = crossings >= cfg.StrafeSensitivity
    if d.strafing then
        d.strafeCenter = d.strafeCenter:Lerp(worldPos, math.clamp(dt * 5, 0.05, 0.3))
    end

    -- AIRBORNE DETECTION
    local yVel = d.velocity.Y
    local wasAir = d.airborne
    d.airborne = math.abs(yVel) > cfg.JumpThreshold
    if d.airborne and not wasAir then d.jumpTime = 0 end
    if d.airborne then d.jumpTime = d.jumpTime + dt end

    d.lastPos = worldPos
end

local function PredictPosition(player, worldPos, dt)
    local d = PredictionData[player]
    if not d or d.sampleCount < 2 then return worldPos end
    local cfg = PredictionConfig

    local lookAhead = math.clamp(dt * cfg.LookAheadMultiplier, 0, cfg.LookAheadMax)
    local predicted

    if d.strafing then
        local centerBlend = d.strafeCenter:Lerp(worldPos, 0.7)
        predicted = centerBlend + d.smoothVelocity * (lookAhead * cfg.StrafeDampen)
    elseif cfg.JumpArcEnabled and d.airborne and d.jumpTime < 2 then
        local t = lookAhead
        predicted = worldPos + d.velocity * t + Vector3.new(0, -ROBLOX_GRAVITY, 0) * (0.5 * t * t)
    else
        predicted = worldPos + d.velocity * lookAhead + d.acceleration * (0.5 * lookAhead * lookAhead)
    end

    d.predictedPos = predicted

    local blend = math.clamp(d.confidence * 0.7 + 0.2, 0.2, 0.9)
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
--  SECTION 10: AIMBOT SYSTEM v5.0
--  Fully customizable aim engine
-- ══════════════════════════════════════════════════════════════

local Aimbot = {
    -- Core
    Enabled       = false,
    AimPart       = "Head",
    Smoothing     = 6,
    FOVRadius     = 120,
    BaseFOVRadius = 120,
    MaxDistance    = 100000,
    MinDistance    = 0,
    TeamCheck     = true,
    VisCheck      = false,
    Prediction    = true,
    ShowFOV       = false,
    ShowTracer    = true,
    SnapMode      = false,

    -- Assist
    AimStrength      = 0.65,
    AimKeyMode       = "Always On",
    PriorityMode     = "Crosshair",
    AutoSwitch       = true,
    Humanize         = false,
    HumanizeStrength = 2,
    DynamicFOV       = true,
    StickyVis        = true,
    StickyVisStrength = 0.2,
    ShowTargetHUD    = true,

    -- Smooth aim tuning
    RampUpTime       = 0.15,
    MaxAngularSpeed  = 720,
    UnlockThreshold  = 2.5,
    GracePeriod      = 0.35,
    AutoSwitchRampUp = 0.08,

    -- State (internal)
    LockedPlayer = nil, LockedInfo = nil, OccludedTime = 0,
    LockAge = 0, LastTargetScreenPos = nil, AimKeyActive = false,
    CurrentFOVRadius = 120, IgnoredNames = {},
    HumanizeSeed = math.random(0, 10000), LastTargetVisible = false,

    -- Auto-Target System
    AutoTargetEnabled        = true,
    AutoTargetFullScan       = true,
    AutoTargetMaxRange       = 500,
    AutoTargetFOVPriority    = true,
    AutoTargetSmoothTransition = true,
    AutoTargetTransitionSpeed  = 4,
    AutoTargetScanBehind     = true,
    AutoTargetBehindSpeed    = 2.5,
    AutoTargetCycleDelay     = 0.15,
    _isTransitioningBehind   = false,
    _transitionStartTime     = 0,
}

function Aimbot:GetTargetInfo(player)
    if not IsAlive(player) then return nil end
    if IsInDeathCooldown(player) then return nil end
    local char = player.Character
    local aimPart = GetBodyPart(char, self.AimPart)
    if not aimPart or not aimPart.Parent then return nil end
    local worldPos = aimPart.Position

    -- Anti-ragdoll: validate position is sane before using it
    if not IsPositionSane(player, worldPos) then
        local frozen = GetFrozenPosition(player)
        if frozen then
            worldPos = frozen
        end
    else
        CacheValidPosition(player, worldPos)
    end

    local screenPos3, onScreen = Camera:WorldToViewportPoint(worldPos)
    local screenPos = Vector2.new(screenPos3.X, screenPos3.Y)
    local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local dist3D = myRoot and (worldPos - myRoot.Position).Magnitude or math.huge
    local hum = char:FindFirstChildOfClass("Humanoid")
    return {
        player = player, character = char, name = player.DisplayName or player.Name,
        health = hum and hum.Health or 0, maxHealth = hum and hum.MaxHealth or 100,
        worldPos = worldPos, screenPos = screenPos, depth = screenPos3.Z,
        onScreen = onScreen, dist3D = dist3D
    }
end

function Aimbot:ScoreTarget(info, center)
    local sd = (info.screenPos - center).Magnitude
    if self.PriorityMode == "Lowest HP" then
        return info.health + sd * 0.1
    elseif self.PriorityMode == "Nearest" then
        return info.dist3D + sd * 0.3
    elseif self.PriorityMode == "Threat" then
        local score = sd * 0.5
        local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local eRoot = info.character and info.character:FindFirstChild("HumanoidRootPart")
        if myRoot and eRoot then
            local d2m = (myRoot.Position - eRoot.Position)
            if d2m.Magnitude > 1 then
                score = score - eRoot.CFrame.LookVector:Dot(d2m.Unit) * 120
            end
        end
        return score + (info.health / math.max(info.maxHealth, 1)) * 20
    else
        return sd + (info.health / math.max(info.maxHealth, 1)) * 30 + math.min(info.dist3D * 0.01, 20)
    end
end

function Aimbot:IsLockValid(dt)
    local p = self.LockedPlayer
    if not p or not p.Parent then return false end

    -- Early exit: check humanoid death state before reading any positions
    -- This prevents the 1-2 frame delay where ragdoll position gets read
    local pChar = p.Character
    if pChar then
        local hum = pChar:FindFirstChildOfClass("Humanoid")
        if hum and (hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead) then
            return false
        end
        if not pChar:FindFirstChild("HumanoidRootPart") then
            return false
        end
    end

    if not IsAlive(p) then return false end
    if IsInDeathCooldown(p) then return false end
    if self.TeamCheck and not GameMode:IsEnemy(p) then return false end
    if table.find(self.IgnoredNames, p.Name) then return false end

    local info = self:GetTargetInfo(p)
    if not info then return false end
    if info.dist3D > self.MaxDistance then return false end
    if self.MinDistance > 0 and info.dist3D < self.MinDistance then return false end

    -- User override breakout
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local sd = (info.screenPos - center).Magnitude
    if sd > self.CurrentFOVRadius * self.UnlockThreshold then
        return false
    end

    -- Visibility with grace
    if self.VisCheck then
        if not IsVisibleAdvanced(info.character, info.worldPos) then
            self.OccludedTime = self.OccludedTime + dt
            self.LastTargetVisible = false
            if self.OccludedTime > self.GracePeriod then return false end
        else
            self.OccludedTime = 0
            self.LastTargetVisible = true
        end
    else
        self.LastTargetVisible = true
    end
    return true
end

function Aimbot:AcquireTarget()
    local center
    if self.AutoSwitch and self.LastTargetScreenPos then
        center = self.LastTargetScreenPos
        self.LastTargetScreenPos = nil
    else
        center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
    local fovCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)

    local best, bestScore = nil, math.huge
    local bestBehind, bestBehindScore = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer or not IsAlive(player) then continue end
        if IsInDeathCooldown(player) then continue end
        if self.TeamCheck and not GameMode:IsEnemy(player) then continue end
        if table.find(self.IgnoredNames, player.Name) then continue end
        local info = self:GetTargetInfo(player)
        if not info then continue end
        if info.dist3D > self.MaxDistance then continue end
        if self.MinDistance > 0 and info.dist3D < self.MinDistance then continue end

        -- Phase 1: FOV scan (on-screen, within FOV circle)
        local inFOV = info.onScreen and info.depth > 0
            and (info.screenPos - fovCenter).Magnitude <= self.CurrentFOVRadius

        if inFOV then
            if self.VisCheck and not IsVisibleAdvanced(info.character, info.worldPos) then continue end
            local score = self:ScoreTarget(info, center)
            if score < bestScore then
                bestScore = score
                best = player
            end
        elseif self.AutoTargetEnabled and self.AutoTargetFullScan then
            -- Phase 2: 360° scan (any direction, including behind)
            if self.AutoTargetMaxRange > 0 and info.dist3D > self.AutoTargetMaxRange then continue end
            if self.VisCheck and not IsVisibleAdvanced(info.character, info.worldPos) then continue end

            -- 3D angle-based scoring for off-screen targets
            local dirToTarget = (info.worldPos - Camera.CFrame.Position)
            if dirToTarget.Magnitude > 1 then
                dirToTarget = dirToTarget.Unit
                local dot = Camera.CFrame.LookVector:Dot(dirToTarget)
                local isBehind = dot < 0

                -- Skip behind targets if disabled
                if isBehind and not self.AutoTargetScanBehind then continue end

                local angleFactor = (1 - dot) * 100  -- 0=in-front, 200=behind
                local distFactor = info.dist3D * 0.5
                local hpFactor = (info.health / math.max(info.maxHealth, 1)) * 15
                local score = angleFactor + distFactor + hpFactor

                -- Deprioritize behind targets when FOV priority is on
                if self.AutoTargetFOVPriority and isBehind then
                    score = score + 300
                end

                if score < bestBehindScore then
                    bestBehindScore = score
                    bestBehind = player
                end
            end
        end
    end

    -- Prefer FOV targets; fall back to 360° targets
    if best then
        self.LockedPlayer = best
        self._isTransitioningBehind = false
    elseif bestBehind and self.AutoTargetEnabled then
        self.LockedPlayer = bestBehind
        -- Determine if target is behind for smooth transition
        local bInfo = self:GetTargetInfo(bestBehind)
        if bInfo then
            local dir = (bInfo.worldPos - Camera.CFrame.Position)
            if dir.Magnitude > 1 then
                local dot = Camera.CFrame.LookVector:Dot(dir.Unit)
                self._isTransitioningBehind = dot < 0.2
                self._transitionStartTime = tick()
            end
        end
    else
        self.LockedPlayer = nil
    end

    self.OccludedTime = 0
    self.LockAge = 0
    self.LastTargetVisible = true
end

function Aimbot:Unlock(reason)
    -- On kill: don't save dead body's screen pos (prevents poisoned center)
    if reason ~= "dead" and self.LockedInfo then
        self.LastTargetScreenPos = self.LockedInfo.screenPos
    end
    -- On kill: set death cooldown and clear prediction for dead target
    if reason == "dead" and self.LockedPlayer then
        SetDeathCooldown(self.LockedPlayer)
        ClearPrediction(self.LockedPlayer)
    end
    self.LockedPlayer = nil
    self.LockedInfo = nil
    self.OccludedTime = 0
    self.LockAge = 0
    self.LastTargetVisible = false
    self._isTransitioningBehind = false
end

function Aimbot:SmoothAim(targetWorldPos, dt)
    if self.SnapMode then
        Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetWorldPos)
        return
    end

    local camPos = Camera.CFrame.Position

    -- Humanization
    if self.Humanize and self.HumanizeStrength > 0 then
        local t = tick()
        local px = math.noise(t * 2.5, self.HumanizeSeed, 0) * self.HumanizeStrength
        local py = math.noise(self.HumanizeSeed, t * 2.5, 0) * self.HumanizeStrength
        local depth = (targetWorldPos - camPos).Magnitude
        if depth > 1 then
            local fov = math.rad(Camera.FieldOfView)
            local ps = 2 * depth * math.tan(fov / 2) / Camera.ViewportSize.Y
            targetWorldPos = targetWorldPos
                + Camera.CFrame.RightVector * (px * ps)
                + Camera.CFrame.UpVector * (py * ps)
        end
    end

    -- Base smoothing alpha
    local speed = 120 / math.max(self.Smoothing, 0.5)
    local alpha = math.clamp(1 - math.exp(-speed * dt), 0.001, 1)

    -- Ramp-up ease-in
    if self.LockAge < self.RampUpTime then
        local ramp = math.clamp(self.LockAge / self.RampUpTime, 0.05, 1)
        alpha = alpha * (ramp * ramp)
    end

    -- Behind-target smooth transition (prevents jarring 180° snaps)
    if self._isTransitioningBehind and self.AutoTargetSmoothTransition then
        local transAge = tick() - self._transitionStartTime
        local transitionDuration = 1.0 / math.max(self.AutoTargetTransitionSpeed, 0.5)
        if transAge < transitionDuration then
            local tRamp = math.clamp(transAge / transitionDuration, 0.05, 1)
            alpha = alpha * (tRamp * tRamp) * math.clamp(self.AutoTargetBehindSpeed / 5, 0.2, 1)
        else
            self._isTransitioningBehind = false
        end
    end

    -- Sticky vis reduction
    if self.StickyVis and self.OccludedTime > 0 then
        alpha = alpha * self.StickyVisStrength
    end

    -- Aim strength
    alpha = alpha * self.AimStrength

    -- Angular velocity cap
    if (camPos - targetWorldPos).Magnitude < 0.1 then return end
    local targetCF = CFrame.new(camPos, targetWorldPos)
    local dot = Camera.CFrame.LookVector:Dot(targetCF.LookVector)
    local angle = math.acos(math.clamp(dot, -1, 1))
    local maxAng = math.rad(self.MaxAngularSpeed) * dt
    if angle > 0.001 and angle * alpha > maxAng then
        alpha = maxAng / angle
    end

    alpha = math.clamp(alpha, 0.001, 1)
    Camera.CFrame = Camera.CFrame:Lerp(targetCF, alpha)
end

function Aimbot:Update(dt)
    -- Dynamic FOV
    if self.DynamicFOV then
        local scale = Camera.FieldOfView / 70
        local target = self.BaseFOVRadius * scale
        if not self.LockedPlayer then target = target * 1.15 end
        self.CurrentFOVRadius = self.CurrentFOVRadius + (target - self.CurrentFOVRadius) * math.min(dt * 8, 1)
    else
        self.CurrentFOVRadius = self.BaseFOVRadius
    end

    -- FOV circle
    if FOVCircle then
        local c = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
        FOVCircle.Position = c
        FOVCircle.Radius = self.CurrentFOVRadius
        FOVCircle.Visible = self.Enabled and self.ShowFOV
    end

    if not self.Enabled then
        if AimTracer then AimTracer.Visible = false end
        HideTargetHUD()
        return
    end

    local isAiming = (self.AimKeyMode == "Always On") or self.AimKeyActive
    if not isAiming then
        if AimTracer then AimTracer.Visible = false end
        HideTargetHUD()
        return
    end

    -- Validate lock
    if self.LockedPlayer then
        if not self:IsLockValid(dt) then
            local wasDead = self.LockedPlayer and not IsAlive(self.LockedPlayer)
            if self.AutoSwitch then
                if wasDead then
                    self:Unlock("dead")
                else
                    self:Unlock()
                end
                self:AcquireTarget()
                if self.LockedPlayer then
                    self.LockAge = self.AutoSwitchRampUp
                end
            else
                self:Unlock(wasDead and "dead" or nil)
            end
        end
    end

    if not self.LockedPlayer then self:AcquireTarget() end

    -- Aim update
    if self.LockedPlayer then
        self.LockAge = self.LockAge + dt
        local info = self:GetTargetInfo(self.LockedPlayer)
        if info then
            self.LockedInfo = info
            UpdatePrediction(self.LockedPlayer, info.worldPos, dt)
            local aimPos = self.Prediction and PredictPosition(self.LockedPlayer, info.worldPos, dt) or info.worldPos
            if typeof(aimPos) == "Vector3" and aimPos.X == aimPos.X and aimPos.Y == aimPos.Y and aimPos.Z == aimPos.Z then
                self:SmoothAim(aimPos, dt)
            end

            if AimTracer then
                local vp = Camera.ViewportSize
                AimTracer.From = Vector2.new(vp.X / 2, vp.Y)
                AimTracer.To = info.screenPos
                AimTracer.Color = GameMode:GetTeamDisplayColor(self.LockedPlayer)
                AimTracer.Visible = self.ShowTracer
            end
            if self.ShowTargetHUD then
                UpdateTargetHUD(info, self.LastTargetVisible)
            else
                HideTargetHUD()
            end
        else
            local wasDead = self.LockedPlayer and not IsAlive(self.LockedPlayer)
            self:Unlock(wasDead and "dead" or nil)
        end
    else
        self.LockedInfo = nil
        if AimTracer then AimTracer.Visible = false end
        HideTargetHUD()
    end
end

-- ══════════════════════════════════════════════════════════════
--  SECTION 10B: TRIGGER ASSIST (Click-to-Track)
--  No tracking normally — only aims when LMB (shoot) is pressed
--  Smooth, natural, stealth-friendly aim correction per click
-- ══════════════════════════════════════════════════════════════

local TriggerAssist = {
    Enabled       = false,
    Strength      = 0.40,    -- Base aim pull (0.1=very subtle, 1.0=full)
    Smoothing     = 10,      -- Higher = smoother/slower correction
    MaxFOV        = 250,     -- Max screen-space search radius (px)
    MaxDistance   = 500,     -- Max 3D distance (studs)
    PulseDuration = 0.25,    -- Aim pulse duration per click (seconds)
    FadeOut       = true,    -- Gradually reduce strength during pulse
    HoldMode      = true,    -- true=track while held, false=pulse per click
    UsePrediction = true,    -- Use prediction engine for head tracking
    MaxAngSpeed   = 400,     -- Max angular speed (deg/s) — keeps it natural
    EaseInTime    = 0.06,    -- Ease-in at start of each pulse (seconds)

    -- Internal state
    _active       = false,
    _target       = nil,
    _pulseStart   = 0,
}

function TriggerAssist:FindTarget()
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local best, bestScore = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer or not IsAlive(player) then continue end
        if IsInDeathCooldown(player) then continue end
        if Aimbot.TeamCheck and not GameMode:IsEnemy(player) then continue end

        local char = player.Character
        local head = char and char:FindFirstChild("Head")
        if not head or not head.Parent then continue end

        local worldPos = head.Position

        -- Anti-ragdoll: use frozen position if insane
        if not IsPositionSane(player, worldPos) then
            local frozen = GetFrozenPosition(player)
            if frozen then worldPos = frozen else continue end
        else
            CacheValidPosition(player, worldPos)
        end

        local sp3, onScreen = Camera:WorldToViewportPoint(worldPos)
        if not onScreen or sp3.Z <= 0 then continue end

        local screenPos = Vector2.new(sp3.X, sp3.Y)
        local screenDist = (screenPos - center).Magnitude
        if screenDist > self.MaxFOV then continue end

        local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local dist3D = myRoot and (worldPos - myRoot.Position).Magnitude or math.huge
        if dist3D > self.MaxDistance then continue end

        -- Vis check (optional, uses Aimbot's setting)
        if Aimbot.VisCheck and not IsVisibleAdvanced(char, worldPos) then continue end

        -- Score: prefer closest to crosshair, slight distance weight
        local score = screenDist + dist3D * 0.03
        if score < bestScore then
            bestScore = score
            best = player
        end
    end

    return best
end

function TriggerAssist:GetHeadWorldPos(player)
    if not player or not IsAlive(player) then return nil end
    local char = player.Character
    local head = char and char:FindFirstChild("Head")
    if not head or not head.Parent then return nil end

    local worldPos = head.Position

    -- Anti-ragdoll
    if not IsPositionSane(player, worldPos) then
        local frozen = GetFrozenPosition(player)
        if frozen then return frozen end
        return nil
    end

    return worldPos
end

function TriggerAssist:Update(dt)
    if not self.Enabled or not self._active then return end

    -- Don't interfere if regular aimbot is actively tracking
    if Aimbot.Enabled and Aimbot.LockedPlayer then return end

    -- Validate current target or re-acquire
    if self._target then
        if not IsAlive(self._target) or IsInDeathCooldown(self._target) then
            self._target = self:FindTarget()
            self._pulseStart = tick()
        end
    end

    if not self._target then return end

    -- Get head position
    local worldPos = self:GetHeadWorldPos(self._target)
    if not worldPos then
        self._target = nil
        return
    end

    -- Apply prediction for accurate tracking
    if self.UsePrediction then
        UpdatePrediction(self._target, worldPos, dt)
        local predicted = PredictPosition(self._target, worldPos, dt)
        if typeof(predicted) == "Vector3" and predicted == predicted then
            worldPos = predicted
        end
    end

    -- Calculate pulse timing
    local elapsed = tick() - self._pulseStart

    -- Per-click pulse mode: expire after duration
    if not self.HoldMode and elapsed > self.PulseDuration then
        return
    end

    -- Calculate aim strength
    local strength = self.Strength

    -- Fade-out over pulse duration (natural decay)
    if self.FadeOut and not self.HoldMode then
        local fade = 1 - math.clamp(elapsed / self.PulseDuration, 0, 1)
        fade = fade * fade  -- Quadratic fade for smooth decay
        strength = strength * fade
        if strength < 0.01 then return end
    end

    -- Smooth aim toward head
    local camPos = Camera.CFrame.Position
    local toTarget = worldPos - camPos
    if toTarget.Magnitude < 0.1 then return end

    local speed = 120 / math.max(self.Smoothing, 0.5)
    local alpha = math.clamp(1 - math.exp(-speed * dt), 0.001, 1)
    alpha = alpha * strength

    -- Ease-in at start of pulse (prevents instant snap on click)
    local pulseAge = math.clamp(elapsed / math.max(self.EaseInTime, 0.01), 0, 1)
    alpha = alpha * (pulseAge * pulseAge)

    -- Angular speed cap — keeps movement natural
    local targetCF = CFrame.new(camPos, worldPos)
    local dot = Camera.CFrame.LookVector:Dot(targetCF.LookVector)
    local angle = math.acos(math.clamp(dot, -1, 1))
    local maxAng = math.rad(self.MaxAngSpeed) * dt
    if angle > 0.001 and angle * alpha > maxAng then
        alpha = maxAng / angle
    end

    alpha = math.clamp(alpha, 0.001, 0.85)
    Camera.CFrame = Camera.CFrame:Lerp(targetCF, alpha)
end

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
