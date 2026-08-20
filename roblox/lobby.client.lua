--!nonstrict
-- Lobby: vyber kontinentu -> teleport do Place s prislusnou arenou.
--
-- Varianta A z TERRAIN_PLAN.md: kazde pohori je vlastni Place v jednom
-- Experience. Dokud nejsou Place publikovane, maji v Mountains.lua placeId = 0
-- a tlacitko jen rekne, co doplnit.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local Mountains = require(ReplicatedStorage:WaitForChild("Mountains"))
local player = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "LobbyMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
bg.BackgroundTransparency = 0.15
bg.BorderSizePixel = 0
bg.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 60)
title.Position = UDim2.fromOffset(0, 48)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 40
title.TextColor3 = Color3.fromRGB(240, 240, 235)
title.Text = "MountainsSimulator"
title.Parent = bg

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, 0, 0, 28)
subtitle.Position = UDim2.fromOffset(0, 106)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 18
subtitle.TextColor3 = Color3.fromRGB(170, 180, 190)
subtitle.Text = "Vyber pohori - pet kontinentu, realny teren"
subtitle.Parent = bg

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 24)
status.Position = UDim2.new(0, 0, 1, -56)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Code
status.TextSize = 15
status.TextColor3 = Color3.fromRGB(200, 160, 120)
status.Text = ""
status.Parent = bg

local list = Instance.new("Frame")
list.Size = UDim2.new(1, -160, 1, -260)
list.Position = UDim2.fromOffset(80, 160)
list.BackgroundTransparency = 1
list.Parent = bg

local layout = Instance.new("UIGridLayout")
layout.CellSize = UDim2.fromOffset(300, 96)
layout.CellPadding = UDim2.fromOffset(16, 16)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = list

-- Beskydy jsou testovaci vyrez, ne jedno z peti pohori - do lobby nepatri.
local HIDDEN = { beskydy = true }

for _, key in ipairs(Mountains.order) do
	if not HIDDEN[key] then
		local m = Mountains.get(key)

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(300, 96)
		btn.BackgroundColor3 = Color3.fromRGB(38, 46, 56)
		btn.AutoButtonColor = true
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 22
		btn.TextColor3 = Color3.fromRGB(240, 240, 235)
		btn.Text = m.name
		btn.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = btn

		local info = Instance.new("TextLabel")
		info.Size = UDim2.new(1, -20, 0, 40)
		info.Position = UDim2.fromOffset(10, 50)
		info.BackgroundTransparency = 1
		info.Font = Enum.Font.Gotham
		info.TextSize = 14
		info.TextColor3 = Color3.fromRGB(165, 180, 195)
		info.TextXAlignment = Enum.TextXAlignment.Left
		info.Text = string.format("%s\n%s - %d m", m.continent, m.peak, m.peakElevationM)
		info.Parent = btn

		btn.Activated:Connect(function()
			if m.placeId and m.placeId > 0 then
				status.Text = "Teleport do " .. m.name .. "..."
				TeleportService:Teleport(m.placeId, player)
			else
				status.Text = string.format(
					"%s zatim nema Place. Publikuj arenu a doplň placeId do Mountains.lua.", m.name)
			end
		end)
	end
end
