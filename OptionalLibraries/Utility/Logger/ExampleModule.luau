--!strict
-- ExampleModule.luau
--[[
    Demonstrates usage of the Logger utility in a basic module

    🧪 How to Use It

    1.  Place Logger.luau ReplicatedStorage/Source/Utility/

    2.  Add ExampleModule.luau to either ServerScriptService/Source or
        StarterPlayerScripts/Source so it gets picked up by ModuleLoader (if using)

    3.  Run your game and observe the output — you’ll see debug and warning
        messages formatted with context
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Source.Utility.Logger)

local logger = Logger.new({
    Debug = true,
    Prefix = "ExampleModule"
})

local ExampleModule = {}

function ExampleModule.Setup()
    logger.log("Running Setup phase")
    -- Simulate setup logic
end

function ExampleModule.Start()
    logger.log("Running Start phase")
    -- Simulate startup logic
    logger.log("Something went wrong during Start", true)
end

return ExampleModule
