--!strict
local ConfirmDialogView = {}
ConfirmDialogView.__index = ConfirmDialogView

export type ConfirmPayload = {
	Message: string,
	OnDecision: (confirmed: boolean) -> (),
}

type ConfirmDialogViewData = {
	_instance: Frame,
	_messageLabel: TextLabel,
	_onDecision: ((confirmed: boolean) -> ())?,
	_handleDecision: (self: ConfirmDialogView, result: boolean) -> (),

	Open: (self: ConfirmDialogView, payload: any?) -> (),
	IsOpen: (self: ConfirmDialogView) -> boolean,
	GetRootFrame: (self: ConfirmDialogView) -> Frame,
	Close: (self: ConfirmDialogView) -> (),
	Confirm: (self: ConfirmDialogView) -> (),
}

export type ConfirmDialogView = setmetatable<ConfirmDialogViewData, typeof(ConfirmDialogView)>

function ConfirmDialogView.new(frame: Frame): ConfirmDialogView
	local self = setmetatable({}, ConfirmDialogView) :: ConfirmDialogView

	self._instance = frame
	self._messageLabel = frame:WaitForChild("MessageFrame"):WaitForChild("Message") :: TextLabel
	self._onDecision = nil

	local confirmButton = frame:WaitForChild("Confirm") :: GuiButton
	local declineButton = frame:WaitForChild("Decline") :: GuiButton

	confirmButton.Activated:Connect(function()
		self:_handleDecision(true)
	end)
	declineButton.Activated:Connect(function()
		self:_handleDecision(false)
	end)

	return self
end

function ConfirmDialogView._handleDecision(self: ConfirmDialogView, result: boolean)
	local callback = self._onDecision
	self._onDecision = nil
	if callback then
		callback(result)
	end
end

function ConfirmDialogView.Confirm(self: ConfirmDialogView)
	self:_handleDecision(true)
end

function ConfirmDialogView.Open(self: ConfirmDialogView, payload: any?)
	local confirmPayload = payload :: ConfirmPayload?
	if confirmPayload then
		self._messageLabel.Text = confirmPayload.Message
		self._onDecision = confirmPayload.OnDecision
	end
	
	self._instance.Visible = true -- TODO: Enhance with effects like Tween
end

function ConfirmDialogView.IsOpen(self: ConfirmDialogView): boolean
	return self._instance.Visible -- If we do a tween, we may need to adjust this
end

function ConfirmDialogView.GetRootFrame(self: ConfirmDialogView)
	return self._instance
end

function ConfirmDialogView.Close(self: ConfirmDialogView)
	-- If window was closed externally (e.g. not via confirm/decline buttons),
	-- resolve as false (declined) if still pending
	if self._onDecision then
		self:_handleDecision(false)
	end
	self._instance.Visible = false -- TODO: Enhance with effects like Tween
end

return ConfirmDialogView
