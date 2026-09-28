--!strict
const Players = game:GetService("Players")

const Logger = require("../Utility/Logger")
const Signal = require("../Libs/Signal")

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

type RegisteredContext = {
	Context: InputContext,
	Actions: { [string]: InputAction },
}

const player = assert(Players.LocalPlayer, "Failed to find LocalPlayer")

local InputController = {}

InputController.OnActionPressed = Signal.new() :: Signal.Signal<string, string>
InputController.OnActionReleased = Signal.new() :: Signal.Signal<string, string>
InputController.OnActionChanged = Signal.new() :: Signal.Signal<string, boolean, string>

local registeredContexts: { [string]: RegisteredContext } = {}
local contextStack : { string } = {}

local function registerContext(context: InputContext)
	local name = context.Name
	if registeredContexts[name] then
		logger:warn(`There is already an InputContext registered with the name '{name}'. It will be overwritten.`)
	end

	registeredContexts[name] = {
		Context = context,
		Actions = {},
	}

	for _, child in context:GetChildren() do
		if not child:IsA("InputAction") then
			continue
		end

		registeredContexts[name].Actions[child.Name] = child
	end
end

function InputController.SetContextEnabled(contextName: string, isEnabled: boolean)
	if not registeredContexts[contextName] then
		logger:warn(`No InputContext is registered by the name '{contextName}'`)
		return
	end

	registeredContexts[contextName].Context.Enabled = isEnabled
end

function InputController.IsContextActive(contextName: string): boolean
	if not registeredContexts[contextName] then
		logger:warn(`No InputContext is registered by the name '{contextName}'`)
		return false
	end

	return registeredContexts[contextName].Context.Enabled
end

--[[
	Adds an InputContext to the context stack and enables it.
	InputContext priority is set directly on the InputContext Instance.
]]
function InputController.PushContext(contextName: string)
	if not registeredContexts[contextName] then
		logger:warn(`No InputContext is registered by the name '{contextName}'`)
		return
	end

	if table.find(contextStack, contextName) then
		logger:debug(`{contextName} InputContext is already in the context stack`)
		return
	end

	table.insert(contextStack, contextName)
	table.sort(contextStack, function(a, b)
		return registeredContexts[a].Context.Priority < registeredContexts[b].Context.Priority
	end)

	InputController.SetContextEnabled(contextName, true)
end

function InputController.PopContext(contextName: string)
	if not registeredContexts[contextName] then
		logger:warn(`No InputContext is registered by the name '{contextName}'`)
		return
	end

	local foundIndex = table.find(contextStack, contextName)
	if not foundIndex then
		logger:warn(`Failed to pop context: '{contextName}' is not in context stack`)
		return
	end

	table.remove(contextStack, foundIndex)
	InputController.SetContextEnabled(contextName, false)
end

function InputController.GetActionState(actionName: string, contextName: string?): boolean
	if contextName then
		local context = registeredContexts[contextName]
		if not context then
			logger:warn(`No InputContext is registered by the name '{contextName}'`)
			return false
		end

		local action = context.Actions[actionName]
		if not action then
			logger:warn(`No InputAction is registered by the name '{actionName}'`)
			return false
		end

		return action:GetState()
	end

	for i = #contextStack, 1, -1 do
		local context = contextStack[i]
		local action = registeredContexts[context].Actions[actionName]
		if action then
			return action:GetState()
		end
	end

	logger:warn(`No InputAction is registered by the name '{actionName}'`)
	return false
end

function InputController.Setup()
	local inputsFolder = player:WaitForChild("Inputs")
	
	-- Populate InputContext and InputAction instances
	for _, context in inputsFolder:GetChildren() do
		if not context:IsA("InputContext") then
			continue
		end

		registerContext(context)
	end
end

function InputController.Start()
	for contextName, context in registeredContexts do
		if context.Context.Enabled then
			InputController.PushContext(contextName)
		end

		for actionName, action in context.Actions do
			action.Pressed:Connect(function()
				InputController.OnActionPressed:Fire(actionName, contextName)
			end)
			action.Released:Connect(function()
				InputController.OnActionReleased:Fire(actionName, contextName)
			end)
			action.StateChanged:Connect(function(newState: boolean)
				InputController.OnActionChanged:Fire(actionName, newState, contextName)
			end)
		end
	end
end

return InputController
