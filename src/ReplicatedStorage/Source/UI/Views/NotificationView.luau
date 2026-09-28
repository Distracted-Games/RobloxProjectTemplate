--!strict
local TweenService = game:GetService("TweenService")

local NotificationView = {}
NotificationView.__index = NotificationView

local TWEEN_SPEED = 0.5
local DEFAULT_MESSAGE_DURATION = 2

type NotificationViewData = {
	_messageLabel: TextLabel,
	_messageQueue: { string },
	_isShowing: boolean,
	_tweenVisible: Tween,
	_tweenHidden: Tween,
	_processQueue: (self: NotificationView, duration: number?) -> (),
	HideMessage: (self: NotificationView) -> (),
	ShowMessage: (self: NotificationView, message: string, duration: number?) -> (),
}

export type NotificationView = setmetatable<NotificationViewData, typeof(NotificationView)>

local tweenInfo = TweenInfo.new(TWEEN_SPEED)

function NotificationView.new(canvasGroup: CanvasGroup): NotificationView
	local self = setmetatable({}, NotificationView) :: NotificationView

	local messageLabel = canvasGroup:FindFirstChildOfClass("TextLabel")
	assert(messageLabel, `Failed to find a TextLabel child of {canvasGroup:GetFullName()}`)

	self._messageLabel = messageLabel
	self._messageQueue = {}
	self._isShowing = false

	self._tweenVisible = TweenService:Create(canvasGroup, tweenInfo, { GroupTransparency = 0 })
	self._tweenHidden = TweenService:Create(canvasGroup, tweenInfo, { GroupTransparency = 1 })

	return self
end

function NotificationView._processQueue(self: NotificationView, duration: number?)
	if self._isShowing then
		return
	end

	local message = table.remove(self._messageQueue, 1)
	if not message then
		return
	end

	self._isShowing = true
	self._messageLabel.Text = message

	self._tweenVisible:Play()

	self._tweenVisible.Completed:Once(function()
		task.delay(duration or DEFAULT_MESSAGE_DURATION, function()
			self:HideMessage()
		end)
	end)
end

function NotificationView.HideMessage(self: NotificationView)
	self._tweenHidden:Play()

	self._tweenHidden.Completed:Once(function()
		self._isShowing = false

		if #self._messageQueue > 0 then
			self:_processQueue()
		end
	end)
end

function NotificationView.ShowMessage(self: NotificationView, message: string, duration: number?)
	table.insert(self._messageQueue, message)
	
	if not self._isShowing then
		self:_processQueue(duration)
	end
end

return NotificationView
