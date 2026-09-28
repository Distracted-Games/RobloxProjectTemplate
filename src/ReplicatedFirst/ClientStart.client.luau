--!strict
const ReplicatedStorage = game:GetService("ReplicatedStorage")

const ReplicatedSourceFolder = ReplicatedStorage:WaitForChild("Source")
const ModuleLoader = require(ReplicatedSourceFolder:WaitForChild("ModuleLoader"))
const Network = require(ReplicatedSourceFolder:WaitForChild("Libs"):WaitForChild("Network"))

Network.startClientAsync()
ModuleLoader:Init()
