--!strict
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Network = require("../ReplicatedStorage/Source/Libs/Network")
const ModuleLoader = require("../ReplicatedStorage/Source/ModuleLoader")

Network.startServer()
ModuleLoader.Init()

-- Setup Input Action System
const inputTemplate =
	assert(ReplicatedStorage:FindFirstChild("Inputs"), "Failed to find 'Inputs' folder in ReplicatedStorage")

local function setupPlayer(player: Player)
	local playerInputs = inputTemplate:Clone()
	playerInputs.Parent = player
end

Players.PlayerAdded:Connect(setupPlayer)

for _, player in Players:GetPlayers() do
	setupPlayer(player)
end
