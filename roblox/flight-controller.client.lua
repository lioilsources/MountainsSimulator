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

-- Ktera arena je v tomhle Place zapisuje server (ArenaSetup) do atributu.
-- Cekame na nej: tichy fallback by pri zavodu o replikaci prepocital cely
-- svet konstantami cizi areny (spatny vyskomer, spatne POI, spatny strop).
local arenaKey = workspace:GetAttribute("ArenaKey")
while not arenaKey do
	workspace:GetAttributeChangedSignal("ArenaKey"):Wait()
	arenaKey = workspace:GetAttribute("ArenaKey")
end
local arena = Mountains.get(arenaKey) or Mountains.get(Mountains.order[1])

-- === konstanty (DoggioWars, rychlosti v m/s) ==============================
local SCALE      = 3      -- studu na metr letu
-- Rychlostni obalka je zamerne obri (rozhodnuti 2026-08-20): plyn je volic
-- od kochani po nadzvukovy slalom, zadny realismus. DoggioWars mel strop
-- 40 m/s - naladeny na ostrovy o 340 m, ne na 50km pohori.
local SPEED_MAX  = 350    -- m/s; setrvaly plyn tesne nad Mach 1
local SPEED_MIN  = 5      -- 18 km/h - kochani
local SPEED_ABS  = 450    -- tvrdy strop (Mach 1.3 ve strmhlavu s boostem)
local MACH1      = 343
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
-- Kdyz ma arena hlavni vrchol (prvni "major" POI - u Everestu Everest),
-- startujeme ~2800 studu jizne od nej, kousek nad jeho vyskou, nosem primo
-- na nej. Zadne doletavani pres pul areny.
local function spawnPoint()
	for _, p in ipairs(arena.pois or {}) do
		if p.major then
			return p.pos + Vector3.new(0, 350, 2800), p
		end
	end
	local top = arena.regionPosition.Y + arena.regionSize.Y / 2
	return Vector3.new(
		arena.regionPosition.X,
		top + 120,
		arena.regionPosition.Z + arena.regionSize.Z * 0.35
	), nil
end

local function resetFlight()
	local at, peak = spawnPoint()
	pos = at
	if peak then
		local d = peak.pos - pos
		-- Roblox forward je -Z: yaw z vektoru na vrchol.
		yaw = math.atan2(-d.X, -d.Z)
	else
		yaw = 0
	end
	pitch, roll = -0.05, 0
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
hintLabel.Text = "W/S plyn - mys smer - Space/Shift nos - RMB boost - M mapa - V kamera - R respawn"
hintLabel.TextTransparency = 0.35


-- === kompas a POI ========================================================
-- Kurz 0 = sever (-Z, horni okraj heightmapy). POI prichazeji z Mountains.lua
-- uz prepocitane do studu, vcetne prichyceni na lokalni vrchol DEM.
local COMPASS_FOV = 120  -- stupnu viditelnych na pasce
local GOLD = Color3.fromRGB(240, 200, 90)
local GREY = Color3.fromRGB(200, 205, 215)
local pois = arena.pois or {}

local function headingDeg()
	return math.deg(-yaw) % 360
end

local function angleDiffDeg(a, b)
	return (a - b + 180) % 360 - 180
end

local compass = Instance.new("Frame")
compass.Size = UDim2.fromOffset(560, 48)
compass.Position = UDim2.new(0.5, 0, 0, 8)
compass.AnchorPoint = Vector2.new(0.5, 0)
compass.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
compass.BackgroundTransparency = 0.45
compass.BorderSizePixel = 0
compass.ClipsDescendants = true
compass.Parent = gui

local centerMark = Instance.new("Frame")
centerMark.Size = UDim2.fromOffset(2, 10)
centerMark.Position = UDim2.new(0.5, -1, 0, 0)
centerMark.BackgroundColor3 = Color3.fromRGB(255, 240, 180)
centerMark.BorderSizePixel = 0
centerMark.Parent = compass

local CARDINALS = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE",
	[180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

local ticks = {}
for a = 0, 345, 15 do
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Size = UDim2.fromOffset(44, 16)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	local name = CARDINALS[a]
	l.Text = name or tostring(a)
	l.TextSize = name and 16 or 11
	l.TextColor3 = name and Color3.fromRGB(240, 240, 230) or Color3.fromRGB(140, 148, 158)
	l.Visible = false
	l.Parent = compass
	ticks[#ticks + 1] = { angle = a, label = l }
end

local poiMarks = {}
for _, p in ipairs(pois) do
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Size = UDim2.fromOffset(120, 16)
	l.Position = UDim2.new(0.5, 0, 0, 28)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	l.Text = "^ " .. p.name
	l.TextSize = 12
	l.TextColor3 = p.major and GOLD or GREY
	l.TextStrokeTransparency = 0.5
	l.Visible = false
	l.Parent = compass
	poiMarks[#poiMarks + 1] = l
end

local lookLabel = Instance.new("TextLabel")
lookLabel.AnchorPoint = Vector2.new(0.5, 0)
lookLabel.Size = UDim2.fromOffset(560, 20)
lookLabel.Position = UDim2.new(0.5, 0, 0, 58)
lookLabel.BackgroundTransparency = 1
lookLabel.Font = Enum.Font.Code
lookLabel.TextSize = 16
lookLabel.TextColor3 = Color3.fromRGB(235, 235, 225)
lookLabel.TextStrokeTransparency = 0.4
lookLabel.Parent = gui

local function updateCompass()
	local heading = headingDeg()
	for _, t in ipairs(ticks) do
		local d = angleDiffDeg(t.angle, heading)
		if math.abs(d) <= COMPASS_FOV / 2 then
			t.label.Visible = true
			t.label.Position = UDim2.new(0.5 + d / COMPASS_FOV, 0, 0, 10)
		else
			t.label.Visible = false
		end
	end

	local bestPoi, bestAbs, bestDist
	for i, p in ipairs(pois) do
		local dx, dz = p.pos.X - pos.X, p.pos.Z - pos.Z
		local bearing = math.deg(math.atan2(dx, -dz)) % 360
		local d = angleDiffDeg(bearing, heading)
		local mark = poiMarks[i]
		if math.abs(d) <= COMPASS_FOV / 2 then
			mark.Visible = true
			mark.Position = UDim2.new(0.5 + d / COMPASS_FOV, 0, 0, 28)
		else
			mark.Visible = false
		end
		if math.abs(d) <= 10 then
			local distKm = math.sqrt(dx * dx + dz * dz) / arena.studsPerMeterXZ / 1000
			if not bestPoi or math.abs(d) < bestAbs then
				bestPoi, bestAbs, bestDist = p, math.abs(d), distKm
			end
		end
	end
	if bestPoi then
		lookLabel.Text = string.format("%03d  |  %s  %d m - %.1f km",
			math.floor(heading + 0.5) % 360, bestPoi.name, bestPoi.elevM, bestDist)
	else
		lookLabel.Text = string.format("%03d", math.floor(heading + 0.5) % 360)
	end
end

-- === mapa (M) ============================================================
-- Podklad je hruby vyskovy rastr zabaleny v Mountains.lua (hex retezce) --
-- zadne image assety, vse offline. Bunky se stavi az pri prvnim otevreni.
local mapFrame, mapPlayer

local function hypso(v)
	local stops = {
		{ 0.00, 40, 66, 48 }, { 0.30, 88, 104, 60 }, { 0.55, 126, 104, 76 },
		{ 0.78, 158, 148, 138 }, { 1.00, 242, 244, 248 },
	}
	for i = 2, #stops do
		if v <= stops[i][1] then
			local a, b = stops[i - 1], stops[i]
			local t = (v - a[1]) / (b[1] - a[1])
			return Color3.fromRGB(a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t)
		end
	end
	return Color3.fromRGB(242, 244, 248)
end

local function buildMap()
	mapFrame = Instance.new("Frame")
	mapFrame.Size = UDim2.fromScale(0.62, 0.74)
	mapFrame.Position = UDim2.fromScale(0.5, 0.53)
	mapFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	mapFrame.BackgroundColor3 = Color3.fromRGB(12, 15, 20)
	mapFrame.BorderSizePixel = 0
	mapFrame.Visible = false
	mapFrame.Parent = gui

	local grid = arena.map
	if grid then
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = grid.w / grid.h
		ratio.Parent = mapFrame
		for yy = 1, grid.h do
			local row = grid.rows[yy]
			for xx = 1, grid.w do
				local v = tonumber(string.sub(row, xx * 2 - 1, xx * 2), 16) / 255
				local cell = Instance.new("Frame")
				cell.BorderSizePixel = 0
				cell.Size = UDim2.fromScale(1 / grid.w, 1 / grid.h)
				cell.Position = UDim2.fromScale((xx - 1) / grid.w, (yy - 1) / grid.h)
				cell.BackgroundColor3 = hypso(v)
				cell.Parent = mapFrame
			end
		end
	end

	local north = Instance.new("TextLabel")
	north.Size = UDim2.fromOffset(24, 20)
	north.Position = UDim2.new(0.5, -12, 0, 2)
	north.BackgroundTransparency = 1
	north.Font = Enum.Font.Code
	north.Text = "N"
	north.TextSize = 18
	north.TextColor3 = Color3.fromRGB(240, 240, 230)
	north.TextStrokeTransparency = 0.2
	north.Parent = mapFrame

	for _, p in ipairs(pois) do
		local fx = 0.5 + p.pos.X / arena.regionSize.X
		local fy = 0.5 + p.pos.Z / arena.regionSize.Z

		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(p.major and 10 or 7, p.major and 10 or 7)
		dot.Position = UDim2.fromScale(fx, fy)
		dot.BackgroundColor3 = p.major and GOLD or GREY
		dot.BorderSizePixel = 0
		dot.Parent = mapFrame
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot

		local tag = Instance.new("TextLabel")
		tag.AnchorPoint = Vector2.new(0, 0.5)
		tag.Size = UDim2.fromOffset(170, 24)
		tag.Position = UDim2.new(fx, 8, fy, 0)
		tag.BackgroundTransparency = 1
		tag.Font = Enum.Font.Code
		tag.TextXAlignment = Enum.TextXAlignment.Left
		tag.Text = string.format("%s %d", p.name, p.elevM)
		tag.TextSize = p.major and 14 or 12
		tag.TextColor3 = p.major and GOLD or GREY
		tag.TextStrokeTransparency = 0.2
		tag.Parent = mapFrame
	end

	mapPlayer = Instance.new("TextLabel")
	mapPlayer.AnchorPoint = Vector2.new(0.5, 0.5)
	mapPlayer.Size = UDim2.fromOffset(22, 22)
	mapPlayer.BackgroundTransparency = 1
	mapPlayer.Font = Enum.Font.GothamBold
	mapPlayer.Text = "^"
	mapPlayer.TextSize = 20
	mapPlayer.TextColor3 = Color3.fromRGB(255, 90, 70)
	mapPlayer.TextStrokeTransparency = 0.1
	mapPlayer.Parent = mapFrame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 22)
	title.Position = UDim2.new(0, 0, 1, 2)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Code
	title.Text = string.format("%s - %s - M zavre", arena.name, arena.continent)
	title.TextSize = 14
	title.TextColor3 = Color3.fromRGB(170, 180, 190)
	title.Parent = mapFrame
end

local function toggleMap()
	if not mapFrame then
		buildMap()
	end
	mapFrame.Visible = not mapFrame.Visible
end

local function updateMapPlayer()
	if mapFrame and mapFrame.Visible and mapPlayer then
		mapPlayer.Position = UDim2.fromScale(
			0.5 + pos.X / arena.regionSize.X,
			0.5 + pos.Z / arena.regionSize.Z)
		mapPlayer.Rotation = headingDeg()
	end
end

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
		elseif input.KeyCode == Enum.KeyCode.M then
			toggleMap()
		elseif input.KeyCode == Enum.KeyCode.R then
			resetFlight()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		if boostTime <= 0 and boostMeter >= BOOST_COST then
			boostMeter = boostMeter - BOOST_COST
			boostTime = BOOST_TIME
			speed = math.min(speed + 40, SPEED_ABS)
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

	-- plyn: rychlost drzi tam, kam ji hrac nastavi. Akcelerace je umerna
	-- rychlosti (5 -> 350 m/s za ~10 s), jinak by pres tak siroky rozsah
	-- trvalo dorovnani plynu skoro minutu.
	local accel = boostTime > 0 and 3 or 1
	if keys[Enum.KeyCode.W] then speed = speed + math.max(10, speed * 0.45) * accel * dt end
	if keys[Enum.KeyCode.S] then speed = speed - math.max(14, speed * 0.6) * dt end

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

	-- strmhlav zrychluje, stoupani krvaci rychlost; plny plyn vykryje 70 %.
	-- Oboji umerne rychlosti, aby "feel" drzel v cele obalce.
	local topSpeed = SPEED_MAX
	if boostTime > 0 then
		boostTime = boostTime - dt
		topSpeed = SPEED_ABS
	end
	if pitch < -DIVE_START then
		speed = speed + (-pitch - DIVE_START) * (24 + speed * 0.5) * dt
	elseif pitch > 0 then
		local bleed = pitch * (18 + speed * 0.35) * dt
		if keys[Enum.KeyCode.W] then bleed = bleed * 0.3 end
		speed = speed - bleed
	end
	if speed > topSpeed then
		speed = math.max(topSpeed, speed - OVERSPEED_DECAY * dt)
	end
	speed = math.clamp(speed, SPEED_MIN, SPEED_ABS)

	-- posun
	local orient = CFrame.fromEulerAnglesYXZ(pitch, yaw, roll)
	local forward = orient.LookVector
	pos = pos + (forward * (speed * SCALE * dt))

	-- teren: skimming nabiji boost, naraz sebere rychlost. Dolni paprsek je
	-- dlouhy kvuli vyskomeru (m nad zemi); blizkost se bere z jeho delky.
	local hit = workspace:Raycast(pos, forward * (PROX_RANGE + speed * SCALE * dt), rayParams)
	local down = workspace:Raycast(pos, Vector3.new(0, -20000, 0), rayParams)
	local nearGround = down ~= nil and down.Distance < PROX_RANGE
	crashCooldown = math.max(0, crashCooldown - dt)

	if hit and hit.Distance < 4 and crashCooldown <= 0 then
		if speed > CRASH_SPEED then
			speed = SPEED_MIN
			crashCooldown = 1.5
		end
		-- vytlacime nos ven z terenu, at se letadlo nezakousne
		pos = pos + (hit.Normal * (5 - hit.Distance))
		pitch = math.max(pitch, 0.15)
	elseif (hit or nearGround) and speed > 30 then
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
	local aglM = down and down.Distance / arena.studsPerMeterY or nil
	altLabel.Text = string.format("ALT  %5d m n.m.%s", math.floor(altM),
		aglM and string.format("   (%d m nad zemi)", math.floor(aglM)) or "")
	local mach = speed / MACH1
	if mach >= 0.4 then
		spdLabel.Text = string.format("SPD  %5.0f km/h   M %.2f", speed * 3.6, mach)
	else
		spdLabel.Text = string.format("SPD  %5.0f km/h", speed * 3.6)
	end
	bstLabel.Text = string.format("BST  %3d%%%s", math.floor(boostMeter), boostTime > 0 and "  BOOST" or "")

	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	updateCompass()
	updateMapPlayer()
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
