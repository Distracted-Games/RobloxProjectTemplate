--!strict
const Debris = game:GetService("Debris")
const SoundService = game:GetService("SoundService")

const Logger = require("../Utility/Logger")

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

local audioDeviceOutput: AudioDeviceOutput? = nil
local audioPlayer: AudioPlayer? = nil
local audioListener: AudioListener? = nil
local camera: Camera? = nil

local AudioController = {}

--[[
	Plays a given AudioPlayer sound directly to the client's AudioDeviceOutput.
	Accepts an optional volume number to adjust volume of the played sound
	directly in the AudioPlayer.

	This function automatically handles wiring and clone removal when playing is complete.
]]
function AudioController.PlaySoundToOutput(soundPlayer: AudioPlayer, volume: number?)
	if not audioDeviceOutput then
		logger:warn(`Failed to play sound from '{soundPlayer:GetFullName()}': Missing AudioDeviceOutput`)
		return
	end

	local player = soundPlayer:Clone()
	
	if volume then
		player.Volume = volume
	end

	local wire = Instance.new("Wire")
	wire.SourceInstance = player
	wire.TargetInstance = audioDeviceOutput
	wire.Parent = player

	player:Play()

	while player.IsPlaying do
		task.wait()
	end

	Debris:AddItem(player)
end

function AudioController.Setup()
	audioDeviceOutput = SoundService:FindFirstChildOfClass("AudioDeviceOutput")
	audioPlayer = SoundService:FindFirstChild("MainAudioPlayer") :: AudioPlayer?
	audioListener = SoundService:FindFirstChildOfClass("AudioListener")
	camera = workspace.CurrentCamera

	if audioListener and audioDeviceOutput then
		local listener = audioListener:Clone()
		listener.Parent = camera

		local wire = Instance.new("Wire")
		wire.SourceInstance = listener
		wire.TargetInstance = audioDeviceOutput
		wire.Parent = listener
	end
end

function AudioController.Start()
	-- Start playing background music, if any
	if (audioPlayer and audioPlayer:IsA("AudioPlayer")) and audioPlayer.Asset ~= nil then
		audioPlayer:Play()
		audioPlayer.Looping = true
	end
end

return AudioController
