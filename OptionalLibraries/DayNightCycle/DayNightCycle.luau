--!strict
--[[
    DayNightCycle
    @author DistractedGames
    @version 2.0.1

    Manages the in-game day/night cycle, driven by a configurable real-world
    duration. It provides a robust event system to trigger actions at specific
    times of day (e.g., "Dawn", "Sunset").

    This module is designed to be managed by the ModuleLoader framework,
    utilizing the Start() lifecycle method, though can be adjusted to fit the
    project's structure.
--]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Assumes use of Logger module
local Logger = require(ReplicatedStorage.Source.Utility.Logger.Logger)

local logger = Logger.new({
	Debug = false, -- Toggles verbose logging for this module.
	Prefix = "DayNightCycle",
})

local DayNightCycle = {}

--[[
	Type definition for the module's configuration.
	- DayLengthInMinutes: Real-world minutes for a full 24-hour game day.
	- StartTimeOfDay: Optional specific start time in hours (0-24). If nil, uses current lighting.
	- TimeEvents: A dictionary mapping event names to game hours (0-24).
]]
export type DayNightCycleConfig = {
	DayLengthInMinutes: number,
	StartTimeOfDay: number?,
	TimeEvents: { [string]: number },
}

-- Default configuration, can be customized before Start() is called.
local config: DayNightCycleConfig = {
	DayLengthInMinutes = 180, -- A 3 hour day/night cycle.
	StartTimeOfDay = nil, -- Uses existing Lighting time by default.
	TimeEvents = {
		Dawn = 6.0, -- 6:00 AM
		Sunrise = 7.0, -- 7:00 AM
		Midday = 12.0, -- 12:00 PM
		Sunset = 18.0, -- 6:00 PM
		Dusk = 19.0, -- 7:00 PM
		Midnight = 0.0, -- 12:00 AM
	},
}

local connection: RBXScriptConnection?
local isRunning = false
local lastHourTriggered = -1
local triggeredEvents: { [string]: boolean } = {}
local timeRatio = 0
local cycleStartTime = 0

-- Constants
local MINUTES_IN_DAY = 1440 -- 24 hours * 60 minutes
local HOURS_IN_DAY = 24

-- Events
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
if not remotesFolder.Parent then
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

DayNightCycle.Events = Instance.new("BindableEvent")
DayNightCycle.Events.Name = "DayNightEvents"
DayNightCycle.Events.Parent = remotesFolder

--[[
	Converts minutes after midnight to a 24-hour format.
	@param minutes The number of minutes past midnight.
	@return The time in hours (0-24).
]]
local function minutesToHours(minutes: number): number
	return minutes / 60
end

--[[
	Checks and fires time-based events based on the current hour.
	Resets triggered events daily at midnight.
	@param currentHour The current in-game hour.
]]
local function checkTimeEvents(currentHour: number)
	if currentHour < lastHourTriggered then
		-- Midnight has passed, reset all triggered events for the new day.
		triggeredEvents = {}
		logger.log("A new day has begun. Resetting daily time events.")
	end
	lastHourTriggered = currentHour

	for eventName, eventHour in config.TimeEvents do
		local hourDifference = math.abs(currentHour - eventHour)

		-- Handle midnight (0.0) being approached from hour 23.
		if eventHour == 0 and currentHour > 23 then
			hourDifference = HOURS_IN_DAY - currentHour
		end

		-- Trigger if we are close to the event time and it hasn't fired yet today.
		if hourDifference < 0.1 and not triggeredEvents[eventName] then
			triggeredEvents[eventName] = true
			DayNightCycle.Events:Fire(eventName, eventHour)
			logger.log(`Time event triggered: '{eventName}' at {string.format("%.1f", eventHour)}h.`)
		end
	end
end

--[[
	Core update function connected to Heartbeat. Calculates and sets the
	new time of day.
]]
local function onHeartbeat()
	local elapsed = time() - cycleStartTime
	local totalMinutes = (elapsed * timeRatio) % MINUTES_IN_DAY

	Lighting:SetMinutesAfterMidnight(totalMinutes)

	local currentHour = minutesToHours(totalMinutes)
	checkTimeEvents(currentHour)
end

--[[
	[Public Method]
	Starts the day/night cycle. Connects the update function to RunService.Heartbeat.
	Calling it again will have no effect.
]]
function DayNightCycle.StartCycle()
	if isRunning then
		logger.log("StartCycle called but the cycle is already running.", true)
		return
	end
	isRunning = true

	-- Initialize time calculations
	local dayInSeconds = config.DayLengthInMinutes * 60
	timeRatio = MINUTES_IN_DAY / dayInSeconds
	cycleStartTime = time()

	-- Determine where the cycle should start (in minutes)
    local startMinutes =  Lighting:GetMinutesAfterMidnight()
	if config.StartTimeOfDay then
        -- Use the configured start time instead.
		startMinutes = config.StartTimeOfDay * 60
	end

    -- Apply the time to lighting (ensures sync) and offset the internal timer.
    Lighting:SetMinutesAfterMidnight(startMinutes)
    cycleStartTime -= (startMinutes / timeRatio)

	-- Connect to the game loop with a throttled update
	connection = RunService.Heartbeat:Connect(onHeartbeat)

	logger.log(`Day/Night cycle started. Game day lasts {config.DayLengthInMinutes} real-world minutes.`)
end

--[[
	[Public Method]
	Stops the day/night cycle.
]]
function DayNightCycle.StopCycle()
	if not isRunning then
		return
	end
	isRunning = false

	if connection then
		connection:Disconnect()
		connection = nil
	end

	logger.log("Day/Night cycle stopped.")
end

--[[
    [Public Method]
    Adds or updated a custom time event.
    @param eventName The unique name for the event.
    @param eventHour The hour (0-24) to trigger the event.
]]
function DayNightCycle.AddTimeEvent(eventName: string, eventHour: number)
	assert(typeof(eventName) == "string", "eventName must be a string")
	assert(
		typeof(eventHour) == "number" and eventHour >= 0 and eventHour < 24,
		"eventHour must be a number between 0 and 23.99"
	)

    config.TimeEvents[eventName] = eventHour
    logger.log(`Added time event: {eventName} at {string.format("%.1f", eventHour)}h.`)
end

--[[
	[Public Method]
	Removes a time event.
	@param eventName The name of the event to remove.
	@return True if the event was found and removed, false otherwise.
--]]
function DayNightCycle.RemoveTimeEvent(eventName: string): boolean
	if config.TimeEvents[eventName] then
		config.TimeEvents[eventName] = nil
		logger.log(`Removed time event: '{eventName}'.`)
		return true
	end
	logger.log(`Attempted to remove non-existent event: '{eventName}'.`, true)
	return false
end

--[[
    [Public Method]
    Returns the current in-game time.
    @return The current time in hours (0-24).
]]
function DayNightCycle.GetCurrentTime(): number
    return minutesToHours(Lighting:GetMinutesAfterMidnight())
end

--[[
    ModuleLoader Lifecycle: Start
    Starts the actual day/night cycle. This runs after all modules have been
    through their Setup phase.
    If not using the ModuleLoader, be sure to call DayNightCycle.StartCycle from
    somewhere else.
]]
function DayNightCycle.Start()
    logger.log(`Starting Day/Night Cycle...`)
    DayNightCycle.StartCycle()
end

return table.freeze(DayNightCycle)
