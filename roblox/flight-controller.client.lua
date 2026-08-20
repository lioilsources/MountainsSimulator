--!nonstrict
-- MountainsSimulator - letovy model nad realnym terenem.
--
-- Jadro (mouse-flight, perzistentni plyn, dive/climb fyzika, boost, skimming)
-- je prevzate z DoggioWars (mods/dw_core/vehicle.lua -> roblox port), aby
-- "feel" letu zustal stejny. Vypusteny jsou zbrane, HP a destrukce terenu;
-- pribyl vyskomer v realnych metrech nad morem.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mountains = require(ReplicatedStorage:WaitForChild("Mountains"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local terrain = workspace.Terrain

-- Ktera arena je v tomhle Place. Server ji zapise do atributu, jinak fallback.
local arenaKey = workspace:GetAttribute("ArenaKey") or "beskydy"
local arena = Mountains.get(arenaKey) or Mountains.get(Mountains.order[1])

-- === konstanty (DoggioWars, rychlosti v m/s) ==============================
local SCALE      = 3      -- studu na metr letu; 40 m/s -> 120 studu/s
local SPEED_MAX  = 40
local SPEED_MIN  = 5
local SPEED_BOOST = 60
local THROTTLE_UP, THROTTLE_DOWN = 8, 10
local TURN_SPEED = 1.5
local PITCH_RATE = 1.2
local PITCH_MAX  = 0.6
local BANK_MAX   = math.pi * 0.7
local ROLL_SPEED = 1.8
local LOOK_CLAMP = 1.25
local MOUSE_SENS = 0.0022
local DIVE_START = math.rad(26)   -- od kolika stupnu dolu zrychluje strmhlav
local OVERSPEED_DECAY = 12
local BOOST_COST, BOOST_TIME = 25, 2
local PROX_RANGE = 6 * SCALE      -- skimming: teren do 6 m nabiji boost
local CRASH_SPEED = 15

-- === stav ================================================================
local aimYaw, aimPitch = 0, -0.1
local yaw, pitch, roll = 0, 0, 0
local speed = 20
local boostMeter, boostTime = 50, 0
local pos = Vector3.zero
local proxTimer, crashCooldown = 0, 0
local firstPerson = false
local alive = false

local function wrapAngle(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

-- === letadlo =============================================================
local RED   = Color3.fromRGB(200, 60, 50)
local WHITE = Color3.fromRGB(235, 230, 220)
local DARK  = Color3.fromRGB(45, 45, 58)

local plane = Instance.new("Model")
plane.Name = "Plane"

local function makePart(size, offset, color)
	local p = Instance.new("Part")
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = plane
	p:SetAttribute("Offset", offset)
	return p
end

local hull    = makePart(Vector3.new(3, 2.4, 12), CFrame.new(0, 0, 0), RED)
local wing    = makePart(Vector3.new(16, 0.5, 3), CFrame.new(0, 0.2, 0.5), WHITE)
local tailFin = makePart(Vector3.new(0.4, 2.6, 2.4), CFrame.new(0, 1.4, 5), RED)
local tailPln = makePart(Vector3.new(6, 0.4, 1.8), CFrame.new(0, 0.6, 5), WHITE)
local nose    = makePart(Vector3.new(1.6, 1.6, 2), CFrame.new(0, 0, -6.5), DARK)
plane.PrimaryPart = hull
plane.Parent = workspace

local exhaustAtt = Instance.new("Attachment")
exhaustAtt.Position = Vector3.new(0, 0, 6)
exhaustAtt.Parent = hull
local exhaust = Instance.new("ParticleEmitter")
exhaust.Rate = 0
exhaust.Lifetime = NumberRange.new(0.25)
exhaust.Speed = NumberRange.new(12)
exhaust.Size = NumberSequence.new(1.6)
exhaust.Transparency = NumberSequence.new(0.35, 1)
exhaust.Color = ColorSequence.new(Color3.fromRGB(255, 190, 120))
exhaust.Parent = exhaustAtt

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { plane }

-- Postava hrace je jen nositel kamery; letadlo je samostatny model.
local function adoptCharacter(char)
	rayParams.FilterDescendantsInstances = { plane, char }
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = 1
			d.CanCollide = false
			d.Massless = true
		elseif d:IsA("Decal") then
			d.Transparency = 1
		end
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		for _, s in ipairs(hum:GetPlayingAnimationTracks()) do s:Stop() end
	end
end

-- === spawn ===============================================================
-- Startujeme nad arenou, vysoko nad nejvyssim bodem, nosem k jejimu stredu.
local function spawnPoint()
	local top = arena.regionPosition.Y + arena.regionSize.Y / 2
	return Vector3.new(
		arena.regionPosition.X,
		top + 120,
		arena.regionPosition.Z + arena.regionSize.Z * 0.35
	)
end

local function resetFlight()
	pos = spawnPoint()
	-- Roblox ma forward -Z: spawn je na +Z od stredu, takze yaw 0 miri dovnitr.
	yaw, pitch, roll = 0, -0.05, 0
	aimYaw, aimPitch = yaw, pitch
	speed = 25
	boostMeter, boostTime = 50, 0
	alive = true
end

-- === HUD =================================================================
local gui = Instance.new("ScreenGui")
gui.Name = "FlightHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local function newLabel(size, position, textSize, anchor)
	local l = Instance.new("TextLabel")
	l.Size = size
	l.Position = position
	l.AnchorPoint = anchor or Vector2.zero
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	l.TextSize = textSize
	l.TextColor3 = Color3.fromRGB(235, 235, 225)
	l.TextStrokeTransparency = 0.4
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = gui
	return l
end

local crosshair = Instance.new("Frame")
crosshair.Size = UDim2.fromOffset(6, 6)
crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
crosshair.BackgroundColor3 = Color3.fromRGB(255, 240, 180)
crosshair.BorderSizePixel = 0
crosshair.Parent = gui
local cc = Instance.new("UICorner")
cc.CornerRadius = UDim.new(1, 0)
cc.Parent = crosshair

local titleLabel = newLabel(UDim2.fromOffset(420, 26), UDim2.fromOffset(18, 14), 20)
titleLabel.Text = string.format("%s - %s (%d m)", arena.name, arena.peak, arena.peakElevationM)

local altLabel = newLabel(UDim2.fromOffset(420, 24), UDim2.fromOffset(18, 40), 18)
local spdLabel = newLabel(UDim2.fromOffset(420, 24), UDim2.fromOffset(18, 62), 18)
local bstLabel = newLabel(UDim2.fromOffset(420, 24), UDim2.fromOffset(18, 84), 18)
local hintLabel = newLabel(UDim2.fromOffset(600, 22), UDim2.new(0, 18, 1, -30), 15)
hintLabel.Text = "W/S plyn - mys smer - Space/Shift nos - RMB boost - V kamera - R respawn"
hintLabel.TextTransparency = 0.35

-- === vstup ===============================================================
UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
UserInputService.MouseIconEnabled = false

local keys = {}
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keys[input.KeyCode] = true
		if input.KeyCode == Enum.KeyCode.V then
			firstPerson = not firstPerson
		elseif input.KeyCode == Enum.KeyCode.R then
			resetFlight()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		if boostTime <= 0 and boostMeter >= BOOST_COST then
			boostMeter = boostMeter - (BOOST_COST)
			boostTime = BOOST_TIME
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		keys[input.KeyCode] = nil
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		aimYaw = wrapAngle(aimYaw - input.Delta.X * MOUSE_SENS)
		aimPitch = math.clamp(aimPitch - input.Delta.Y * MOUSE_SENS, -LOOK_CLAMP, LOOK_CLAMP)
	end
end)

-- === letova smycka =======================================================
local function step(dt)
	if not alive then return end
	dt = math.min(dt, 0.1)

	-- plyn: rychlost drzi tam, kam ji hrac nastavi
	if keys[Enum.KeyCode.W] then speed = speed + THROTTLE_UP * dt end
	if keys[Enum.KeyCode.S] then speed = speed - THROTTLE_DOWN * dt end

	-- vyboceni zamerovace klavesami (A/D) vedle mysi
	if keys[Enum.KeyCode.A] then aimYaw = wrapAngle(aimYaw + TURN_SPEED * 0.6 * dt) end
	if keys[Enum.KeyCode.D] then aimYaw = wrapAngle(aimYaw - TURN_SPEED * 0.6 * dt) end
	if keys[Enum.KeyCode.Space] then aimPitch = math.min(aimPitch + PITCH_RATE * dt, LOOK_CLAMP) end
	if keys[Enum.KeyCode.LeftShift] then aimPitch = math.max(aimPitch - PITCH_RATE * dt, -LOOK_CLAMP) end

	-- letadlo se dotaci k zamerovaci nejkratsi cestou
	local dYaw = wrapAngle(aimYaw - yaw)
	local turn = math.clamp(dYaw, -TURN_SPEED * dt, TURN_SPEED * dt)
	yaw = wrapAngle(yaw + turn)

	local targetPitch = math.clamp(aimPitch, -PITCH_MAX, PITCH_MAX)
	pitch = pitch + (math.clamp(targetPitch - pitch, -PITCH_RATE * dt, PITCH_RATE * dt))

	-- automaticky naklon do zatacky
	local targetRoll = math.clamp(-dYaw * 1.5, -BANK_MAX, BANK_MAX)
	roll = roll + (math.clamp(targetRoll - roll, -ROLL_SPEED * dt, ROLL_SPEED * dt))

	-- strmhlav zrychluje, stoupani krvaci rychlost; plny plyn vykryje 70 %
	local topSpeed = SPEED_MAX
	if boostTime > 0 then
		boostTime = boostTime - (dt)
		topSpeed = SPEED_BOOST
		speed = math.max(speed, SPEED_BOOST)
	end
	if pitch < -DIVE_START then
		speed = speed + ((-pitch - DIVE_START) * 24 * dt)
	elseif pitch > 0 then
		local bleed = pitch * 18 * dt
		if keys[Enum.KeyCode.W] then bleed = bleed * 0.3 end
		speed = speed - (bleed)
	end
	if speed > topSpeed then
		speed = math.max(topSpeed, speed - OVERSPEED_DECAY * dt)
	end
	speed = math.clamp(speed, SPEED_MIN, SPEED_MAX * 1.5)

	-- posun
	local orient = CFrame.fromEulerAnglesYXZ(pitch, yaw, roll)
	local forward = orient.LookVector
	pos = pos + (forward * (speed * SCALE * dt))

	-- teren: skimming nabiji boost, naraz sebere rychlost
	local hit = workspace:Raycast(pos, forward * (PROX_RANGE + speed * SCALE * dt), rayParams)
	local down = workspace:Raycast(pos, Vector3.new(0, -PROX_RANGE, 0), rayParams)
	crashCooldown = math.max(0, crashCooldown - dt)

	if hit and hit.Distance < 4 and crashCooldown <= 0 then
		if speed > CRASH_SPEED then
			speed = SPEED_MIN
			crashCooldown = 1.5
		end
		-- vytlacime nos ven z terenu, at se letadlo nezakousne
		pos = pos + (hit.Normal * (5 - hit.Distance))
		pitch = math.max(pitch, 0.15)
	elseif (hit or down) and speed > 30 then
		proxTimer = proxTimer + (dt)
		if proxTimer >= 0.2 then
			proxTimer = 0
			boostMeter = math.min(100, boostMeter + 1.6)
		end
	else
		proxTimer = 0
	end

	-- drz hrace nad arenou: mimo hranice ho stoc zpatky ke stredu
	local half = arena.regionSize * 0.5
	if math.abs(pos.X - arena.regionPosition.X) > half.X + 2000
		or math.abs(pos.Z - arena.regionPosition.Z) > half.Z + 2000 then
		local toCenter = Vector3.new(arena.regionPosition.X - pos.X, 0, arena.regionPosition.Z - pos.Z)
		aimYaw = math.atan2(-toCenter.X, -toCenter.Z)
	end
	local ceiling = arena.regionPosition.Y + arena.regionSize.Y / 2 + 1500
	if pos.Y > ceiling then
		pos = Vector3.new(pos.X, ceiling, pos.Z)
		aimPitch = math.min(aimPitch, 0)
	end

	-- vykresleni
	plane:PivotTo(CFrame.new(pos) * orient)
	for _, p in ipairs(plane:GetChildren()) do
		if p:IsA("BasePart") and p ~= hull then
			p.CFrame = hull.CFrame * p:GetAttribute("Offset")
		end
	end
	exhaust.Rate = (boostTime > 0) and 90 or (speed > SPEED_MAX * 0.8 and 25 or 0)

	local char = player.Character
	if char and char.PrimaryPart then
		char:PivotTo(CFrame.new(pos))
	end

	-- kamera
	if firstPerson then
		camera.CFrame = CFrame.new(pos) * orient * CFrame.new(0, 1.2, -4)
	else
		local lean = CFrame.Angles(0, 0, roll * 0.35)
		camera.CFrame = CFrame.new(pos) * CFrame.fromEulerAnglesYXZ(pitch * 0.6, yaw, 0)
			* lean * CFrame.new(0, 7, 34)
		camera.CFrame = CFrame.lookAt(camera.CFrame.Position, pos + forward * 40)
	end

	-- HUD: vyska nad morem z merítka areny, ne ze studu
	local altM = Mountains.studsToMeters(arena, pos.Y - (arena.regionPosition.Y - arena.regionSize.Y / 2))
	local groundM = down and Mountains.studsToMeters(arena,
		down.Position.Y - (arena.regionPosition.Y - arena.regionSize.Y / 2)) or nil
	altLabel.Text = string.format("ALT  %5d m n.m.%s", math.floor(altM),
		groundM and string.format("   (%d m nad zemi)", math.max(0, math.floor(altM - groundM))) or "")
	spdLabel.Text = string.format("SPD  %5.0f km/h", speed * 3.6)
	bstLabel.Text = string.format("BST  %3d%%%s", math.floor(boostMeter), boostTime > 0 and "  BOOST" or "")

	crosshair.Position = UDim2.fromScale(0.5, 0.5)
end

player.CharacterAdded:Connect(function(char)
	char:WaitForChild("HumanoidRootPart")
	adoptCharacter(char)
	resetFlight()
end)
if player.Character then
	adoptCharacter(player.Character)
end

camera.CameraType = Enum.CameraType.Scriptable
resetFlight()
RunService.RenderStepped:Connect(step)
