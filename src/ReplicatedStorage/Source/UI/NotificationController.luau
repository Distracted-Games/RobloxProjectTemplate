--!strict

const Players = game:GetService("Players")

const Network = require("../Libs/Network")
const NotificationView = require("./Views/NotificationView")
const Signal = require("../Libs/Signal")

const NotificationController = {}

const player = assert(Players.LocalPlayer, "Failed to find Local Player")

local notificationGroup: CanvasGroup? = nil

NotificationController.Show = Signal.new() :: Signal.Signal<string, number?>

function NotificationController.Setup()
	local notificationGui = player:WaitForChild("PlayerGui"):WaitForChild("Notifications")
	notificationGroup = notificationGui:WaitForChild("NotificationGroup") :: CanvasGroup

	local view = NotificationView.new(notificationGroup)

	-- Client triggered notification
	NotificationController.Show:Connect(function(message: string, duration: number?)
		view:ShowMessage(message, duration)
	end)

	-- Server triggered notification
	Network.connectEvent(Network.RemoteEvents.SendNotification, function(message: string, duration: number?)
		view:ShowMessage(message, duration)
	end)
end

return NotificationController
