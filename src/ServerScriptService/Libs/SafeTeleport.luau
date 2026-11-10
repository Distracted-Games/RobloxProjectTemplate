--!strict
--[[
    This script handles teleporting a player to another place within the
    experience via TeleportService.

    The teleport function itself is handled using a protected call with a set
    number of retry attempts. The script also fires a remote event which will
    handle the UI when the player initiates the teleport, informing them they
    are being teleported.

    The specific code here is a module script to handle calling the SafeTeleport
    function, replacing the need to call TeleportService:TeleportAsync funciton.
    You can call SafeTeleport to perform teleports from anywhere in your
    experience to reduce failed teleports.
]]

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const TeleportService = game:GetService("TeleportService")

const Logger = require("../../ReplicatedStorage/Source/Utility/Logger")
const Network = require("../../ReplicatedStorage/Source/Libs/Network")

-- SafeTeleport Constants
const SHORT_ATTEMPT_LIMIT = 3 -- How many time to try teleporting within pcall
const ATTEMPT_LIMIT = 5 -- How many total failed teleport attempts to make before no longer trying
const RETRY_DELAY = 1 -- The time (in seconds) between reattempting to teleport after a failed result
const FLOOD_DELAY = 15 -- If too many attempts have been made to the server recently, how long to wait (in seconds)

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

local totalAttempts = {} :: { [Player]: number }

local function safeTeleportWithRetry(
	player: Player,
	placeId: number,
	options: TeleportOptions?
): (boolean?, TeleportAsyncResult?)
	local attemptIndex = 0
	local success: boolean
	local errorMessage: any

	repeat
		success, errorMessage =
			pcall(TeleportService.TeleportAsync, TeleportService, placeId, { player :: any }, options)

		attemptIndex += 1
		if not success then
			task.wait(RETRY_DELAY)
		end
	until success or attemptIndex == SHORT_ATTEMPT_LIMIT

	if not success then
		logger:warn(tostring(errorMessage))
		if totalAttempts[player] then
			totalAttempts[player] += 1
		else
			totalAttempts[player] = 1
		end
	end

	return success, errorMessage :: TeleportAsyncResult?
end

local function handleFailedTeleport(
	player: Instance,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	targetPlaceId: number,
	teleportOptions: Instance
)
	if teleportResult == Enum.TeleportResult.Flooded then
		task.wait(FLOOD_DELAY) -- Too many attempts made recently, wait to make another
	elseif teleportResult == Enum.TeleportResult.Failure then
		task.wait(RETRY_DELAY) -- Teleport attempt just failed, wait to retry
	end

	if not player:IsA("Player") then
		return
	end

	Network.fireClient(
		Network.RemoteEvents.TeleportFailed,
		player,
		`Invalid teleport {teleportResult.Name}: {errorMessage}`
	)

	if totalAttempts[player] and totalAttempts[player] < ATTEMPT_LIMIT then
		logger:debug(`Teleport attempts: {totalAttempts[player]}/{ATTEMPT_LIMIT}`)
		-- Retry teleport again
		safeTeleportWithRetry(player, targetPlaceId, teleportOptions :: TeleportOptions)
	else
		-- Fire event to show the player the teleport failed
		Network.fireClient(
			Network.RemoteEvents.TeleportFailed,
			player,
			`Invalid teleport {teleportResult.Name}: {errorMessage}`
		)
		-- If the teleport is invalid, report the error instead of retrying inifinitely
		logger:warn(`Invalid teleport {teleportResult.Name}: {errorMessage}`)
		totalAttempts[player] = nil
	end
end

TeleportService.TeleportInitFailed:Connect(handleFailedTeleport)

local SafeTeleport = {}

-- Call this function in any script instead of using `TeleportService:TeleportAsync`
function SafeTeleport.Teleport(player: Player, placeID: number, options: TeleportOptions?)
	if RunService:IsStudio() then
		logger:warn(`SafeTeleport.Teleport skipped in Roblox Studio for {player.Name} (placeId: {placeID}).`)
		return
	end

	-- Fire event to show Teleport UI, informing the player they are being teleported
	Network.fireClient(Network.RemoteEvents.Teleporting, player, placeID)
	logger:debug(`Teleporting {player.Name} to placeId: {placeID}`)
	safeTeleportWithRetry(player, placeID, options)
end

Players.PlayerRemoving:Connect(function(player: Player)
    totalAttempts[player] = nil
end)

return SafeTeleport
