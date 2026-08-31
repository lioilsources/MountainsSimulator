--!nonstrict
-- Rozsazuje po terenu postavicky z UGC tovarny (UGCFactory, domena
-- `characters`). Model se do Robloxu dostane pres Open Cloud jako Asset,
-- tenhle skript uz jen resi, kde se objevi a co dela.
--
-- Biom se bere z nadmorske vysky, ne z pozice: kazda arena ma jine meritko
-- i jinou zakladnu, takze "1500 m" znamena v Beskydech jinou Y souradnici
-- nez na Everestu. Prevod dela Mountains.studsToMeters.
--
-- Animace se pres Open Cloud nahrat nedaji, takze KeyframeSequence se
-- uploadne rucne jednou (kostra je pro vsechny postavy stejna) a sem se
-- zapise jen animationId. Viz FANTASYCHARACTER_PLAN.md 6.1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InsertService = game:GetService("InsertService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Mountains = require(ReplicatedStorage:WaitForChild("Mountains"))

local Spawner = {}

-- === ladici konstanty ====================================================

-- Strop soubeznych NPC. Kazde je Model s Humanoidem, takze cena je v
-- replikaci, ne v renderu; StreamingEnabled odstini jen to, co hrac nevidi.
local MAX_NPC = 250
-- Dal nez tohle od nejblizsiho hrace nema smysl drzet nic ziveho.
local DESPAWN_STUDS = 400
-- Blize uz NPC utika. Hrac je letadlo, takze "blizko" je dost daleko.
local FLEE_STUDS = 120
local SPAWN_INTERVAL = 2
local SPAWN_PER_TICK = 4
-- Kolem hrace, ne po cele arene: arena ma 16k studu a spawnovat na druhem
-- konci znamena platit za nekoho, kdo tam nikdy nedoletí.
local SPAWN_RING_MIN, SPAWN_RING_MAX = 150, 380

-- === biomova pasma =======================================================
-- Prah je horni hranice pasma v metrech nad morem; posledni je bez stropu.
local BANDS = {
	{ maxElevationM = 1500, biome = "meadow" },
	{ maxElevationM = 2500, biome = "forest" },
	{ maxElevationM = math.huge, biome = "rock" },
}

function Spawner.biomeAt(arena, y)
	local metres = Mountains.studsToMeters(arena, y)
	for _, band in ipairs(BANDS) do
		if metres <= band.maxElevationM then
			return band.biome, metres
		end
	end
	return "rock", metres
end

-- === katalog postav ======================================================
-- Zdroj je bud ModuleScript FantasyCharacters v ReplicatedStorage (build ho
-- muze zapect), nebo HTTP z backendu. Kdyz neni ani jedno, skript se tise
-- vypne: prazdna arena je lepsi nez arena plna chyb v Output.
local CATALOG_URL = script:GetAttribute("CatalogUrl")

local function loadCatalog()
	local module = ReplicatedStorage:FindFirstChild("FantasyCharacters")
	if module and module:IsA("ModuleScript") then
		local ok, data = pcall(require, module)
		if ok and type(data) == "table" then
			return data
		end
	end
	if CATALOG_URL then
		local ok, body = pcall(function()
			return HttpService:GetAsync(CATALOG_URL)
		end)
		if ok then
			local parsed, data = pcall(HttpService.JSONDecode, HttpService, body)
			if parsed and type(data) == "table" then
				return data
			end
		end
	end
	return nil
end

-- Katalog je seznam polozek { assetId, biomes = {...}, animations = {...} }.
-- Polozka bez biomu patri vsude - lepsi nez ji zahodit.
function Spawner.pickFor(catalog, biome, rng)
	local fits = {}
	for _, entry in ipairs(catalog) do
		local list = entry.biomes
		if not list or #list == 0 then
			fits[#fits + 1] = entry
		else
			for _, b in ipairs(list) do
				if b == biome then
					fits[#fits + 1] = entry
					break
				end
			end
		end
	end
	if #fits == 0 then
		return nil
	end
	return fits[rng:NextInteger(1, #fits)]
end

-- === teren ===============================================================

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }

-- Vraci bod na terenu pod x,z, nebo nil kdyz tam teren neni (neimportovany
-- kus mapy, diry mezi ostrovy).
local function groundAt(arena, x, z)
	local top = arena.regionPosition.Y + arena.regionSize.Y / 2
	local hit = workspace:Raycast(
		Vector3.new(x, top + 500, z),
		Vector3.new(0, -(arena.regionSize.Y + 1000), 0),
		terrainParams
	)
	if not hit then
		return nil
	end
	return hit.Position
end

-- === zivotni cyklus NPC ==================================================

local active = {}
local activeCount = 0
local rng = Random.new()
local arena

-- Vraci pozici nejblizsiho hrace a vzdalenost. Pozice je potreba: utikat
-- se da jen smerem OD nekoho, samotna vzdalenost na to nestaci.
local function nearestPlayer(pos)
	local bestPos, bestDist
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (root.Position - pos).Magnitude
			if not bestDist or d < bestDist then
				bestPos, bestDist = root.Position, d
			end
		end
	end
	return bestPos, bestDist
end

local function playAnimation(npc, animationId)
	if not animationId or animationId == "" then
		return
	end
	local humanoid = npc.model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if npc.track and npc.trackId == animationId then
		return
	end
	if npc.track then
		npc.track:Stop()
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animationId
	npc.track = animator:LoadAnimation(anim)
	npc.trackId = animationId
	npc.track.Looped = true
	npc.track:Play()
end

local function despawn(npc)
	if npc.model and npc.model.Parent then
		npc.model:Destroy()
	end
	active[npc] = nil
	activeCount = activeCount - 1
end

local function spawnOne(arena, catalog)
	local player = Players:GetPlayers()[rng:NextInteger(1, math.max(#Players:GetPlayers(), 1))]
	local char = player and player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local angle = rng:NextNumber() * math.pi * 2
	local radius = rng:NextNumber(SPAWN_RING_MIN, SPAWN_RING_MAX)
	local x = root.Position.X + math.cos(angle) * radius
	local z = root.Position.Z + math.sin(angle) * radius

	local ground = groundAt(arena, x, z)
	if not ground then
		return
	end

	local biome = Spawner.biomeAt(arena, ground.Y)
	local entry = Spawner.pickFor(catalog, biome, rng)
	if not entry or not entry.assetId then
		return
	end

	-- LoadAsset saha na sit a muze selhat (moderace, vypadek) - spadnout
	-- kvuli tomu nesmi cely spawner
	local ok, container = pcall(function()
		return InsertService:LoadAsset(entry.assetId)
	end)
	if not ok or not container then
		return
	end
	local model = container:FindFirstChildWhichIsA("Model")
	if not model then
		container:Destroy()
		return
	end
	model.Parent = workspace
	container:Destroy()
	model:PivotTo(CFrame.new(ground + Vector3.new(0, 3, 0)))

	local npc = {
		model = model,
		entry = entry,
		biome = biome,
		state = "",
		nextDecision = 0,
	}
	active[npc] = true
	activeCount = activeCount + 1
	playAnimation(npc, entry.animations and entry.animations.idle)
end

local function stepNpc(npc, now)
	local model = npc.model
	if not model or not model.Parent then
		despawn(npc)
		return
	end
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not root then
		despawn(npc)
		return
	end
	local pos = root.Position
	local playerPos, dist = nearestPlayer(pos)
	if not dist or dist > DESPAWN_STUDS then
		despawn(npc)
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local anims = npc.entry.animations or {}

	if dist < FLEE_STUDS then
		if npc.state ~= "flee" then
			npc.state = "flee"
			playAnimation(npc, anims.run or anims.walk)
		end
		-- pryc od hrace, ale po terenu: cil se sundá raycastem, jinak by
		-- MoveTo mirilo do vzduchu a Humanoid by se zasekl na miste
		local away = pos - playerPos
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude < 0.1 then
			away = Vector3.new(1, 0, 0)
		end
		local target = pos + away.Unit * 60
		humanoid:MoveTo(groundAt(arena, target.X, target.Z) or target)
		return
	end

	if now < npc.nextDecision then
		return
	end
	npc.nextDecision = now + rng:NextNumber(3, 8)
	if rng:NextNumber() < 0.4 then
		if npc.state ~= "idle" then
			npc.state = "idle"
			playAnimation(npc, anims.idle)
		end
		humanoid:MoveTo(pos)
	else
		if npc.state ~= "wander" then
			npc.state = "wander"
			playAnimation(npc, anims.walk or anims.idle)
		end
		local dir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
		if dir.Magnitude < 0.1 then
			dir = Vector3.new(1, 0, 0)
		end
		local target = pos + dir.Unit * 40
		humanoid:MoveTo(groundAt(arena, target.X, target.Z) or target)
	end
end

-- === start ===============================================================

-- Bezi jen na serveru; ale modul se vraci vzdy, aby sla cista logika
-- (pasma, vyber postavy) otestovat headless podle CLAUDE.md.
if RunService:IsServer() then

local arenaKey = workspace:GetAttribute("ArenaKey") or "beskydy"
arena = Mountains.get(arenaKey)
local catalog = loadCatalog()

if not arena then
	warn("[fantasy] neznama arena " .. tostring(arenaKey))
elseif not catalog or #catalog == 0 then
	print("[fantasy] zadny katalog postav - spawner spi. "
		.. "Ceka se na ModuleScript FantasyCharacters nebo atribut CatalogUrl.")
else
	print(string.format("[fantasy] %d postav, arena %s, strop %d NPC",
		#catalog, arenaKey, MAX_NPC))

	task.spawn(function()
		while true do
			task.wait(SPAWN_INTERVAL)
			if #Players:GetPlayers() > 0 then
				local budget = math.min(SPAWN_PER_TICK, MAX_NPC - activeCount)
				for _ = 1, math.max(budget, 0) do
					spawnOne(arena, catalog)
				end
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for npc in pairs(active) do
			stepNpc(npc, now)
		end
	end)
end

end

return Spawner
