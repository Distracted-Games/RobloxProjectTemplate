--!strict
--[[
    ModuleLoader
    @author DistractedGames
    @version 2.0.0

    This module implements a two-pass loading system for ModuleScripts. It's
    designed to run on both the server and the client to create a unified module
    framework.

    The loader operates in two distinct phases or "lifecycles":
    1.  Setup: The loader first requires all modules and calls the `Setup()`
        method on any module that has one. This phase is intended for initialization
        tasks that do not depend on other modules being active, such as setting
        up configuration or registering objects.

    2.  Start: After all modules have been through the Setup phase, the loader
        iterates through them a second time, calling the `Start()` method. This
        phase is for logic that may depend on other modules having completed their
        own setup, such as connecting to events or activating core functionality.

    This approach helps manage dependencies implicitly without needing a complex
    dependency graph.
--]]

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayerScripts = game:GetService("StarterPlayer").StarterPlayerScripts

-- Determine the environment and root directory for modules.
local isServer = RunService:IsServer()
-- On the client, modules are expected to be in a "Source" folder within
-- StarterPlayerScripts to avoid issues with built-in Roblox player modules.
local rootDirectory = if isServer then ServerScriptService else StarterPlayerScripts
local moduleDirectory = if isServer
	then rootDirectory :: ServerScriptService
	else (rootDirectory :: StarterPlayerScripts):WaitForChild("Source") :: Folder

-- Configuration for the loader's behavior.
local config = {
	ATTEMPT_LIMIT = 3, -- How many times to try running a lifecycle method before failing.
	RETRY_DELAY = 1, -- Seconds to wait between failed attempts.
	Debug = false, -- When true, prints detailed logs for each step.
}

--[[
    Logs a formatted message to the output.
    Uses `warn` for warnings and `print` for debug messages.
    The log includes the calling function's name and line for easier debugging.
    @param message The core message to log.
    @param isWarning If true, formats the message as a warning.
]]
local function log(message: string, isWarning: boolean?)
	local prefix = "[ModuleLoader] "
	local source, line, funcName = debug.info(2, "sln")
	local formattedSource = `{string.match(source, "@(.*)")}`
	local logHeader = `{prefix} [{funcName or formattedSource}:{line}]`

	if isWarning then
		warn(`{logHeader} {message}`)
	elseif config.Debug then
		print(`{logHeader} {message}`)
	end
end

--[[
	Executes a module's lifecycle method (e.g., Setup or Start) within a protected call.
	It will retry the function according to the settings in the `config` table.
	@param methodName The name of the lifecycle method being called (for logging).
	@param methodFunc The actual function to execute.
	@param moduleName The name of the module (for logging).
	@return boolean: Whether the execution was ultimately successful.
	@return any: The result or error from the function execution.
]]
local function processLifeCycleMethod(methodName: string, methodFunc: () -> any?, moduleName: string): (boolean, any?)
	assert(
		type(methodFunc) == "function",
		`Lifecycle method '{methodName}' on module '{moduleName}' is not a function, got {typeof(methodFunc)}.`
	)

	local success, result
	for attempt = 1, config.ATTEMPT_LIMIT do
		success, result = pcall(methodFunc)
		if success then
			return true, result -- Successful execution, exit the loop.
		end

		-- Log the failure for this attempt.
		local err = tostring(result)
		log(
			`Module '{moduleName}' failed on lifecycle '{methodName}' (Attempt {attempt}/{config.ATTEMPT_LIMIT}):\n{err}`,
			true
		)

		-- Wait before retyring, but not after the final attempt.
		if attempt < config.ATTEMPT_LIMIT then
			task.wait(config.RETRY_DELAY)
		end
	end

	-- All attemps failed.
	return false, result
end

--[[
	Performs a single pass over all modules, executing a specific lifecycle method.
	@param methodName The name of the method to find and execute (e.g., "Setup", "Start").
]]
local function runLifecyclePass(methodName: string)
	log(`Starting '{methodName}' lifecycle pass...`)

	for _, moduleScript in moduleDirectory:GetDescendants() do
		if not moduleScript:IsA("ModuleScript") then
			continue
		end

		-- Safely require the module. The result is cached by Luau, so subsequent
		-- require calls in the next pass will be fast.
		local success, module = pcall(require, moduleScript)
		if not success then
			log(`Failed to require module '{moduleScript.Name}': {tostring(module)}`, true)
			continue
		end

		-- A module might not return a table or have the target method.
		-- This is valid, so we skip it.
		if type(module) ~= "table" or not module[methodName] then
			continue
		end

		log(`Running '{methodName}' for module: {moduleScript.Name}`)
		local methodFunc = module[methodName]

		-- Process the module's lifecycle method with retry logic.
		local wasSuccessful, result = processLifeCycleMethod(methodName, methodFunc, moduleScript.Name)

		if not wasSuccessful then
			log(
				`Module '{moduleScript.Name}' failed all attempts for lifecycle '{methodName}'. Final error:\n{tostring(
					result
				)}`,
				true
			)
            -- Depending on project needs, we might need to halt everything if a critical module fails.
            -- For now, we just log the final failure and continue.
        else
            log(`Module '{moduleScript.Name}' completed lifecycle '{methodName}' successfully.`)
		end

        -- Yield to prevent script exhaustion errors on projects with many modules.
        task.wait()
	end
    log(`Finished '{methodName}' lifecycle pass.`)
end

--[[
	The main entry point for the module loader.
	Executes the Setup and Start lifecycle passes in sequence.
--]]
return function()
    -- 'Setup' is for initial configuration and dependency-free preparations.
    runLifecyclePass("Setup")
	-- 'Start' is for activating functionality, which may depend on other modules being set up.
    runLifecyclePass("Start")

    log("All modules have been loaded and started.")
end
