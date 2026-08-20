--!nonstrict
-- Nastavi jednu arenu (jedno pohori = jeden Place, varianta A z TERRAIN_PLAN.md).
--
-- Vybrane pohori se cte z atributu ArenaKey na Workspace, aby stejny build
-- slouzil vsem petce; kdyz atribut chybi, vezme se DEFAULT_ARENA.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local Mountains = require(ReplicatedStorage:WaitForChild("Mountains"))

local DEFAULT_ARENA = "beskydy"

local arenaKey = workspace:GetAttribute("ArenaKey")
if not arenaKey or not Mountains.get(arenaKey) then
	arenaKey = DEFAULT_ARENA
	workspace:SetAttribute("ArenaKey", arenaKey)
end
local arena = Mountains.get(arenaKey)

-- === atmosfera per pohori ================================================
-- Hustsi opar tam, kde je arena velka a vzduch suchy; ciste nebe nad savanou.
local SKIES = {
	montblanc   = { fog = 6000,  fogColor = Color3.fromRGB(190, 205, 220), density = 0.32, clock = 15.5 },
	everest     = { fog = 9000,  fogColor = Color3.fromRGB(205, 215, 230), density = 0.22, clock = 8.5 },
	kilimanjaro = { fog = 12000, fogColor = Color3.fromRGB(215, 205, 180), density = 0.15, clock = 13.0 },
	aconcagua   = { fog = 4500,  fogColor = Color3.fromRGB(200, 180, 160), density = 0.48, clock = 17.0 },
	longspeak   = { fog = 8000,  fogColor = Color3.fromRGB(195, 210, 225), density = 0.28, clock = 10.0 },
	beskydy     = { fog = 5000,  fogColor = Color3.fromRGB(185, 195, 200), density = 0.40, clock = 9.0 },
}

local sky = SKIES[arenaKey] or SKIES.beskydy
Lighting.FogEnd = sky.fog
Lighting.FogStart = sky.fog * 0.15
Lighting.FogColor = sky.fogColor
Lighting.ClockTime = sky.clock
Lighting.Brightness = 2.5
Lighting.EnvironmentDiffuseScale = 0.4
Lighting.GlobalShadows = true

local atmos = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
atmos.Density = sky.density
atmos.Haze = 1.2
atmos.Glare = 0.2
atmos.Color = sky.fogColor
atmos.Decay = sky.fogColor
atmos.Parent = Lighting

-- === kontrola importu ====================================================
-- Teren se importuje rucne v Terrain Editoru a je to jedine misto, kde se
-- muze rozejit s konstantami v Mountains.lua - vyskomer, mapa i POI pak
-- prepocitavaji svet spatne. Proto teren skutecne ZMERIME: raycast na
-- hlavni vrchol a porovnani s ocekavanou vyskou.
task.spawn(function()
	task.wait(3)

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { workspace.Terrain }

	local top = arena.regionPosition.Y + arena.regionSize.Y / 2
	local probeX, probeZ = arena.regionPosition.X, arena.regionPosition.Z
	local expected
	for _, p in ipairs(arena.pois or {}) do
		if p.major then
			probeX, probeZ, expected = p.pos.X, p.pos.Z, p.pos.Y
			break
		end
	end

	local origin = Vector3.new(probeX, top + 5000, probeZ)
	local hit = workspace:Raycast(origin, Vector3.new(0, -(top + 10000), 0), rp)

	if not hit then
		warn(string.format(
			"[MountainsSimulator] arena %s: WORKSPACE NEMA TEREN.\n" ..
			"  Naimportuj %s v Terrain Editoru -> Import:\n" ..
			"    Size     %d, %d, %d\n" ..
			"    Position %d, %d, %d\n" ..
			"  Detaily v roblox/IMPORT.md.",
			arenaKey, arena.heightmap,
			arena.regionSize.X, arena.regionSize.Y, arena.regionSize.Z,
			arena.regionPosition.X, arena.regionPosition.Y, arena.regionPosition.Z))
		return
	end

	local actual = hit.Position.Y
	if expected and math.abs(actual - expected) > expected * 0.08 + 40 then
		warn(string.format(
			"[MountainsSimulator] arena %s: NESOULAD MERITKA TERENU.\n" ..
			"  Vrchol ma byt %d studu vysoko, teren tam ma %d studu.\n" ..
			"  Vyskomer, mapa a POI pocitaji s importem Size Y=%d, Position Y=%d -\n" ..
			"  teren je naimportovany s jinymi cisly. Oprava:\n" ..
			"    1. Terrain Editor -> Edit -> Clear (smaz soucasny teren)\n" ..
			"    2. Import %s: Size %d, %d, %d; Position %d, %d, %d\n" ..
			"  Presna cisla jsou i v roblox/IMPORT.md.",
			arenaKey, expected, actual,
			arena.regionSize.Y, arena.regionPosition.Y,
			arena.heightmap,
			arena.regionSize.X, arena.regionSize.Y, arena.regionSize.Z,
			arena.regionPosition.X, arena.regionPosition.Y, arena.regionPosition.Z))
	elseif expected then
		print(string.format(
			"[MountainsSimulator] arena %s: meritko sedi (vrchol %d studu, cekano %d)",
			arenaKey, actual, expected))
	else
		print(string.format("[MountainsSimulator] arena %s: teren nalezen (%d studu)", arenaKey, actual))
	end
end)

-- Hrac je jen nositel kamery, letadlo ridi klient - postava nesmi spadnout.
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(char)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.PlatformStand = true
		end
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			root.Anchored = true
		end
	end)
end)

print(string.format("[MountainsSimulator] %s (%s) - %s, %d m; arena %d x %d studu, prevyseni %.2fx",
	arena.name, arena.continent, arena.peak, arena.peakElevationM,
	arena.regionSize.X, arena.regionSize.Z, arena.verticalExaggeration))
