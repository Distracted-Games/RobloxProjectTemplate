--!strict

--[[
	- Maintains a view registry (`RegisterView(name, viewInstance)`)
	- Implements a LIFO navigation stack:
		- `OpenWindow(name, payload)`: Pushes the window to the stack, transitions it to `Open`, and
		   manages backdrop/focus.
		- `CloseWindow(name)`: Closes the specific window and removes it from the stack.
		- `PopWindow()`: Closes the topmost active modal window.
		- `CloseAll()`: Clears the stack and returns to active gameplay.
	- Binds universal back/escape inputs (`Enum.KeyCode.Escape`, `Enum.KeyCode.ButtonB`) to `PopWindow()`.
	- Manages a shared modal backdrop that dims the screen behind the topmost
	  modal and dismisses on backdrop click.
]]

const Lighting = game:GetService("Lighting")
const Players = game:GetService("Players")
const TweenService = game:GetService("TweenService")

const ConfirmDialogView = require("./Views/ConfirmDialogView")
const InputController = require("../Controllers/InputController")
const LeanPromise = require("../Libs/LeanPromise")
const Logger = require("../Utility/Logger")

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

const FOCUS_FOV_DELTA = 10
const FOCUS_TWEEN_INFO = TweenInfo.new(0.4)
const FOCUS_BLUR_SIZE = 10

export type IView = {
	Open: (self: any, payload: any) -> (),
	Close: (self: any) -> (),
	GetRootFrame: ((self: any) -> Frame?)?,
	IsOpen: ((self:any) -> boolean)?,
	Confirm: ((self: any) -> ())?,
}

export type IEphemeralView = {
	Mount: (self: any, parent: Instance) -> (),
	Open: (self: any, payload: any?) -> (),
	Close: (self: any) -> (),
	Destroy: (self: any) -> (),
	GetRootFrame: (self: any) -> Frame?,
	IsOpen: ((self:any) -> boolean)?,
	Confirm: ((self: any) -> ())?,
}

type Promise<T> = LeanPromise.Promise<T>

const UIWindowController = {}

local registeredViews: { [string]: IView } = {}
local ephemeralViews: { [string]: IEphemeralView } = {}
local navigationStack: { string } = {}
local activeTweens: { [Instance]: Tween } = {}

local UIFocusBlur: BlurEffect? = nil
local backdropGui: ScreenGui? = nil

local camera = assert(workspace.CurrentCamera, "Failed to get the CurrentCamera")
local DEFAULT_FOV = camera.FieldOfView

local focusEnabled = false

local function tweenFocusProperty(instance: Instance, properties: { [string]: any })
	if activeTweens[instance] then
		activeTweens[instance]:Cancel()
	end

	local tween = TweenService:Create(instance, FOCUS_TWEEN_INFO, properties)
	activeTweens[instance] = tween
	tween:Play()

	tween.Completed:Once(function()
		if activeTweens[instance] == tween then
			activeTweens[instance] = nil
		end
	end)
end

local function enableFocusEffects()
	if focusEnabled then
		return
	end

	if not backdropGui then
		return
	end
	if not UIFocusBlur then
		return
	end

	focusEnabled = true

	InputController.PushContext("UserInterface")

	backdropGui.Enabled = true

	tweenFocusProperty(camera, { FieldOfView = DEFAULT_FOV - FOCUS_FOV_DELTA })
	tweenFocusProperty(UIFocusBlur, { Size = FOCUS_BLUR_SIZE })
end

local function disableFocusEffects()
	if not focusEnabled then
		return
	end

	if not backdropGui then
		return
	end
	if not UIFocusBlur then
		return
	end

	InputController.PopContext("UserInterface")

	backdropGui.Enabled = false

	tweenFocusProperty(camera, { FieldOfView = DEFAULT_FOV })
	tweenFocusProperty(UIFocusBlur, { Size = 0 })

	focusEnabled = false
end

function UIWindowController.RegisterView(name: string, viewInstance: IView)
	if registeredViews[name] then
		logger:warn(`There is already a view registered with the name '{name}'. It will be overwritten.`)
	end

	registeredViews[name] = viewInstance
end

function UIWindowController.OpenWindow(name: string, payload: any)
	if not registeredViews[name] then
		logger:warn(`Failed to open '{name}' view: No view registered by that name`)
		return
	end

	if table.find(navigationStack, name) ~= nil then
		logger:warn(`'{name}' view is already open and in the stack`)
		return
	end

	table.insert(navigationStack, name)
	registeredViews[name]:Open(payload)
	enableFocusEffects()
end

function UIWindowController.PromptAsync(name: string, message: string): Promise<boolean>
	return LeanPromise.new(function(resolve)
		local payload: ConfirmDialogView.ConfirmPayload = {
			Message = message,
			OnDecision = function(confirmed: boolean)
				-- Pop the dialog off the stack when a decision is made
				UIWindowController.PopWindow()
				resolve(confirmed)
			end
		}

		UIWindowController.OpenWindow(name, payload)
	end) :: Promise<boolean>
end

function UIWindowController.PushEphemeral(view: IEphemeralView, parentContainer: Instance, payload: any?)
	view:Mount(parentContainer)
	local registeredName = `Ephemeral{#navigationStack}`

	table.insert(navigationStack, registeredName)
	ephemeralViews[registeredName] = view

	enableFocusEffects()
	view:Open(payload)
end

function UIWindowController.CloseWindow(name: string)
	if not registeredViews[name] then
		logger:warn(`Failed to close '{name}' view: No view registered by that name`)
		return
	end

	local stackIndex = table.find(navigationStack, name)

	if stackIndex == nil then
		logger:debug(`'{name}' view is already closed or not in the stack`)
		return
	end

	table.remove(navigationStack, stackIndex)
	registeredViews[name]:Close()

	if #navigationStack <= 0 then
		disableFocusEffects()
	end
end

function UIWindowController.PopWindow()
	if #navigationStack <= 0 then
		return
	end

	local poppedView = table.remove(navigationStack)
	if not poppedView then
		logger:debug("No view is currently open")
		return
	end

	-- Check if popped view is ephemeral
	if ephemeralViews[poppedView] ~= nil then
		ephemeralViews[poppedView]:Close()
		ephemeralViews[poppedView]:Destroy()
		ephemeralViews[poppedView] = nil

		if #navigationStack <= 0 then
			disableFocusEffects()
		end

		return
	end
	
	if not registeredViews[poppedView] then
		logger:warn(`Failed to complete PopWindow action: error retriving popped view`)
		return
	end

	registeredViews[poppedView]:Close()

	if #navigationStack <= 0 then
		disableFocusEffects()
	end
end

function UIWindowController.CloseAll()
	if #navigationStack <= 0 then
		return
	end

	for _, view in navigationStack do
		if ephemeralViews[view] then
			ephemeralViews[view]:Close()
			ephemeralViews[view]:Destroy()
			ephemeralViews[view] = nil
		elseif registeredViews[view] then
			registeredViews[view]:Close()
		end
	end

	table.clear(navigationStack)
	disableFocusEffects()
end

function UIWindowController.Setup()
	const player = assert(Players.LocalPlayer, "Failed to find LocalPlayer")
	const playerGui = player:WaitForChild("PlayerGui")

	backdropGui = playerGui:WaitForChild("BackdropGui") :: ScreenGui
	UIFocusBlur = Lighting:WaitForChild("UIFocusBlur") :: BlurEffect

	local backdropFrame = backdropGui:WaitForChild("Backdrop") :: Frame
	backdropFrame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			UIWindowController.CloseAll()
		end
	end)

	local confirmDialogFrame = playerGui:WaitForChild("ConfirmDialog"):WaitForChild("Main") :: Frame
	local confirmDialogView = ConfirmDialogView.new(confirmDialogFrame) :: IView
	UIWindowController.RegisterView("ConfirmDialog", confirmDialogView)

	InputController.OnActionReleased:Connect(function(actionName: string)
		if actionName == "CloseWindow" then
			UIWindowController.PopWindow()
		elseif actionName == "Confirm" then
			local topViewName = navigationStack[#navigationStack]
			if topViewName then
				local activeView = registeredViews[topViewName] or ephemeralViews[topViewName]
				if not (activeView and typeof(activeView.Confirm) == "function") then
					return
				end
				activeView:Confirm()
			end
		end
	end)
end

return UIWindowController
