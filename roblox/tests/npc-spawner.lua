-- Headless test cisté logiky spawneru: biomova pasma a vyber postavy.
-- Roblox API se nemockuje cele, jen to, co skript pri nacteni potrebuje -
-- zbytek (Raycast, InsertService, Humanoid) se bez bezici hry overit neda.
--   Spusteni: luajit roblox/tests/npc-spawner.lua
--
-- Duvod, proc to jde: CLAUDE.md drzi skripty v Luau bez Luau-only syntaxe,
-- takze je LuaJIT prelozi.

local SCRIPT = (arg and arg[0] or ""):gsub("tests/npc%-spawner%.lua$", "npc-spawner.server.lua")
local MOUNTAINS = (arg and arg[0] or ""):gsub("tests/npc%-spawner%.lua$", "Mountains.lua")

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then passed = passed + 1 else
		failed = failed + 1
		print("  FAIL: " .. msg)
	end
end

-- minimalni Roblox stub: jen aby skript dosel na konec a vratil modul
local services = {}
local function stub(name)
	services[name] = services[name] or setmetatable({}, {
		__index = function(t, k)
			local fn = function() return nil end
			rawset(t, k, fn)
			return fn
		end,
	})
	return services[name]
end

_G.game = { GetService = function(_, name) return stub(name) end }
_G.workspace = {
	Terrain = {},
	GetAttribute = function() return "beskydy" end,
	Raycast = function() return nil end,
}
_G.script = { GetAttribute = function() return nil end }
_G.Instance = { new = function() return {} end }
_G.Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end }
_G.CFrame = { new = function() return {} end }
_G.RaycastParams = { new = function() return {} end }
_G.Enum = { RaycastFilterType = { Include = 1, Exclude = 2 } }
_G.task = { spawn = function() end, wait = function() end }
_G.warn = print
_G.Random = {
	new = function()
		local i = 0
		return {
			NextInteger = function(_, lo, _) return lo end,
			NextNumber = function(_, lo, hi)
				i = i + 1
				if lo then return lo + (hi - lo) * 0.5 end
				return 0.5
			end,
		}
	end,
}

-- ReplicatedStorage:WaitForChild("Mountains") -> pravy modul ze zdrojaku,
-- aby se pasma testovala proti skutecnym meritkum aren, ne proti vymyslu
local mountains = dofile(MOUNTAINS)
services.ReplicatedStorage = {
	WaitForChild = function() return "Mountains" end,
	FindFirstChild = function() return nil end,
}
_G.require = function(what)
	if what == "Mountains" then return mountains end
	return {}
end
services.RunService = { IsServer = function() return false end, Heartbeat = { Connect = function() end } }
services.Players = { GetPlayers = function() return {} end }

local Spawner = dofile(SCRIPT)
check(type(Spawner) == "table", "skript vraci modul")

---------------------------------------------------------------------------
print("scenario: biom se pocita z nadmorske vysky, ne ze studu")
local beskydy = mountains.get("beskydy")
local everest = mountains.get("everest")

-- Y=0 je u kazde areny jina nadmorska vyska (baseElevationM), takze stejna
-- souradnice musi vyjit jinak. Prave kvuli tomu se biom nepocita ze studu.
local bBiome, bMetres = Spawner.biomeAt(beskydy, 0)
local eBiome, eMetres = Spawner.biomeAt(everest, 0)
check(math.abs(bMetres - beskydy.baseElevationM) < 1, "Y=0 je base elevation (beskydy)")
check(math.abs(eMetres - everest.baseElevationM) < 1, "Y=0 je base elevation (everest)")
check(bBiome ~= eBiome or beskydy.baseElevationM == everest.baseElevationM,
	"stejne Y da v jine arene jiny biom (" .. bBiome .. " vs " .. eBiome .. ")")

-- pasma podle planu: louky < 1500 m, skaly > 2500 m
local function biomeAtMetres(arena, metres)
	local y = (metres - arena.baseElevationM) * arena.studsPerMeterY
	return (Spawner.biomeAt(arena, y))
end
check(biomeAtMetres(beskydy, 800) == "meadow", "800 m = louka")
check(biomeAtMetres(beskydy, 2000) == "forest", "2000 m = les")
check(biomeAtMetres(everest, 5000) == "rock", "5000 m = skala")
check(biomeAtMetres(everest, 1500) == "meadow", "hranice 1500 m patri jeste do luk")

---------------------------------------------------------------------------
print("scenario: vyber postavy podle biomu")
local rng = _G.Random.new()
local catalog = {
	{ assetId = 1, biomes = { "meadow" } },
	{ assetId = 2, biomes = { "rock" } },
	{ assetId = 3 },                          -- bez biomu = vsude
	{ assetId = 4, biomes = {} },             -- prazdny seznam taky vsude
}
local meadow = Spawner.pickFor(catalog, "meadow", rng)
check(meadow ~= nil and (meadow.assetId == 1 or meadow.assetId == 3 or meadow.assetId == 4),
	"do luk se nedostane skalni postava")
local rock = Spawner.pickFor(catalog, "rock", rng)
check(rock ~= nil, "skaly maji z ceho vybirat")
check(Spawner.pickFor({ { assetId = 9, biomes = { "rock" } } }, "meadow", rng) == nil,
	"kdyz nic nesedi, vraci nil misto spatne postavy")
check(Spawner.pickFor({}, "meadow", rng) == nil, "prazdny katalog nespadne")

---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
