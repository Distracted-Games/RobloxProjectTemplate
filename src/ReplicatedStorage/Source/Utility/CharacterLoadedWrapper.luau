--!strict

--[[
	Provides an API to use when referencing a Player's character to make sure it
	is "Fully loaded", which is defined as:
		1) Character is a descendant of workspace (or a custom character container when
		   configured)
		2) Character has a PrimaryPart set
		3) Character contains a child which is a Humanoid
		4) The Humanoid's RootPart property is not nil
		5) The Humanoid's Health is above 0

	This differs from Player.CharacterAdded and Player.CharacterAppearanceLoaded
	which fire before a character is parented to workspace and does not
	guarantee these other conditions.

	This loaded event won't be necessary once the Player.CharacterAdded is moved
	to the end of the event call stack, per
	https://devforum.roblox.com/t/avatar-loading-event-ordering-improvements/269607

	`IsLoaded` is the single source of truth for that definition. While a character is
	loading, it is re-evaluated whenever something it depends on changes, and `Loaded`
	fires the moment it returns true. A character that doesn't finish loading within
	LOAD_TIMEOUT_SECONDS is abandoned, and so is any load still in flight when the player's
	next character arrives.

	`Loaded` does not fire for a character that is already loaded when the wrapper is
	created; check `IsLoaded()` after constructing it, or use `ObserveLoaded()` /
	`GetLoadedAsync()` to handle both existing and future loaded characters.

	This wrapper provides a died event when the first of the following happens:
		1) Humanoid's .Died event fires
		2) Character is removed

	We need this because there are some cases where a character can be removed
	without the humanoid dying, such as if :LoadCharacterAsync() is called before a
	character dies. Cleanup code often needs to run when a character's "lifespan"
	is over, whether it be because the humanoid died or because the character is
	removed. To avoid having to connect to both events in multiple places, this
	wrapper moves both events into one.

	Note on `Died` ordering:
	`Died` passes the specific `character: Model` that died or was removed.
	Listeners are tracked per-character so that cleanup code tied to a character's
	lifespan always runs, even if deferred events or custom character swaps cause a
	new character to begin loading before the previous character's removal event fires.
	If a consumer only cares about events for the currently active character, it should
	verify that `character == player.Character`.
--]]

const Players = game:GetService("Players")

const Connections = require("./Connections")
const LeanPromise = require("../Libs/LeanPromise")
const Logger = require("./Logger")
const Signal = require("../Libs/Signal")

-- Does the game place player characters in a `PlayerCharacters` folder instead of `Workspace`?
const USING_PLAYER_CHARACTERS_FOLDER = false
-- How long a character may take to satisfy every loaded condition before it is abandoned.
const LOAD_TIMEOUT_SECONDS = 10
-- Rejection reasons for characters destroyed or killed mid-load. These are routine (e.g. respawn,
-- void, reset), so they are not logged as abnormal failures.
const DESTROYED_REASON = "Character was destroyed before it finished loading."
const DIED_REASON = "Character died before it finished loading."

type Promise<T> = LeanPromise.Promise<T>

local logger = Logger.new({
	Debug = false,
	Prefix = script.Name,
})

local function getHumanoid(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

local function isDescendantOfParent(character: Model, parent: Instance?): boolean
	return parent ~= nil and character:IsDescendantOf(parent)
end

local CharacterLoadedWrapper = {}
CharacterLoadedWrapper.__index = CharacterLoadedWrapper

type CharacterLoadedWrapperData = {
	Loaded: Signal.Signal<Model>,
	Died: Signal.Signal<Model>,
	_player: Player,
	_characterParent: (Folder | Workspace)?,
	_destroyed: boolean,
	_connections: Connections.Connections,
	_loadPromise: Promise<Model>?,
	_deathListeners: { [Model]: Connections.Connections },
	_pendingLoadedRejections: { (reason: string) -> () },

	GetCharacter: (self: CharacterLoadedWrapper) -> Model?,
	GetLoadedAsync: (self: CharacterLoadedWrapper, timeoutSeconds: number?) -> Promise<Model>,
	ObserveLoaded: (
		self: CharacterLoadedWrapper,
		callback: (character: Model) -> ()
	) -> Signal.Connection,
	IsLoaded: (self: CharacterLoadedWrapper, optionalCharacter: Model?) -> boolean,
	Destroy: (self: CharacterLoadedWrapper) -> (),
	_getCharacterParent: (self: CharacterLoadedWrapper) -> (Folder | Workspace)?,
	_onCharacterAdded: (self: CharacterLoadedWrapper, character: Model) -> (),
	_promiseLoaded: (self: CharacterLoadedWrapper, character: Model) -> Promise<Model>,
	_listenForDeath: (self: CharacterLoadedWrapper, character: Model) -> (),
}

export type CharacterLoadedWrapper =
	setmetatable<CharacterLoadedWrapperData, typeof(CharacterLoadedWrapper)>

function CharacterLoadedWrapper.new(
	player: Player,
	characterParent: (Folder | Workspace)?
): CharacterLoadedWrapper
	const self = setmetatable({}, CharacterLoadedWrapper) :: CharacterLoadedWrapper
	self.Loaded = Signal.new() :: Signal.Signal<Model>
	self.Died = Signal.new() :: Signal.Signal<Model>
	self._player = player
	self._characterParent = characterParent
	self._destroyed = false
	self._connections = Connections.new()
	self._loadPromise = nil
	self._deathListeners = {}
	self._pendingLoadedRejections = {}

	-- Connect before inspecting the current character so a respawn can't slip in between.
	-- Clean up automatically if the player leaves the game (covering server destruction and client removal).
	self._connections:Add(
		player.CharacterAdded:Connect(function(character: Model)
			self:_onCharacterAdded(character)
		end),
		player.Destroying:Connect(function()
			self:Destroy()
		end),
		player.AncestryChanged:Connect(function()
			if not player:IsDescendantOf(Players) then
				self:Destroy()
			end
		end)
	)

	const existingCharacter = player.Character
	if existingCharacter then
		if self:IsLoaded(existingCharacter) then
			-- Already loaded: avoid firing `Loaded`, but still report when it dies.
			self:_listenForDeath(existingCharacter)
		else
			self:_onCharacterAdded(existingCharacter)
		end
	end

	return self
end

function CharacterLoadedWrapper._getCharacterParent(self: CharacterLoadedWrapper): (Folder | Workspace)?
	if self._characterParent then
		return self._characterParent
	end

	if USING_PLAYER_CHARACTERS_FOLDER then
		const folder = workspace:FindFirstChild("PlayerCharacters")
		return if folder and folder:IsA("Folder") then folder else nil
	end

	return workspace
end

--[[
	Returns the player's currently loaded character Model, or nil if the character
	is dead, unparented, destroyed, or still in the process of loading.
]]
function CharacterLoadedWrapper.GetCharacter(self: CharacterLoadedWrapper): Model?
	if self._destroyed then
		return nil
	end

	const character = self._player.Character
	return if character and self:IsLoaded(character) then character else nil
end

--[[
	Returns a Promise that resolves with the player's next fully loaded character.
	If the character is already loaded, it resolves immediately with that character.
	Rejects if the wrapper is destroyed or if the optional timeout expires.
]]
function CharacterLoadedWrapper.GetLoadedAsync(
	self: CharacterLoadedWrapper,
	timeoutSeconds: number?
): Promise<Model>
	if self._destroyed then
		return LeanPromise.reject("CharacterLoadedWrapper was destroyed")
	end

	const currentCharacter = self:GetCharacter()
	if currentCharacter then
		return LeanPromise.resolve(currentCharacter)
	end

	if timeoutSeconds ~= nil and timeoutSeconds <= 0 then
		return LeanPromise.reject(`Timed out after {timeoutSeconds}s waiting for character to load`) :: Promise<Model>
	end

	return LeanPromise.new(function(resolve, reject, onCancel)
		local loadedConn: Signal.Connection? = nil
		local timeoutThread: thread? = nil
		local rejectOnDestroy: ((reason: string) -> ())? = nil

		local function cleanup()
			if loadedConn then
				loadedConn:Disconnect()
				loadedConn = nil
			end
			if
				timeoutThread
				and coroutine.running() ~= timeoutThread
				and coroutine.status(timeoutThread) == "suspended"
			then
				task.cancel(timeoutThread)
			end
			timeoutThread = nil

			if rejectOnDestroy then
				const index = table.find(self._pendingLoadedRejections, rejectOnDestroy)
				if index then
					table.remove(self._pendingLoadedRejections, index)
				end
				rejectOnDestroy = nil
			end
		end

		onCancel(cleanup)

		rejectOnDestroy = function(reason: string)
			cleanup()
			reject(reason)
		end
		table.insert(self._pendingLoadedRejections, rejectOnDestroy)

		loadedConn = self.Loaded:Connect(function(loadedCharacter: Model)
			cleanup()
			resolve(loadedCharacter)
		end)

		if timeoutSeconds ~= nil then
			timeoutThread = task.delay(timeoutSeconds, function()
				cleanup()
				reject(`Timed out after {timeoutSeconds}s waiting for character to load`)
			end)
		end
	end)
end

--[[
	Observes character loading. If a character is already loaded, `callback` is
	invoked immediately via `task.spawn`. Additionally connects `callback` to
	the `Loaded` signal for subsequent respawns.
	@return A Signal.Connection to disconnect the listener.
]]
function CharacterLoadedWrapper.ObserveLoaded(
	self: CharacterLoadedWrapper,
	callback: (character: Model) -> ()
): Signal.Connection
	const connection = self.Loaded:Connect(callback)

	const currentCharacter = self:GetCharacter()
	if currentCharacter then
		task.spawn(callback, currentCharacter)
	end

	return connection
end

function CharacterLoadedWrapper.IsLoaded(self: CharacterLoadedWrapper, optionalCharacter: Model?): boolean
	-- Character can be passed in to check if a specific character model is the
	-- currently loaded character model. Stale references from previous lives return false.
	if optionalCharacter and optionalCharacter ~= self._player.Character then
		return false
	end

	const character = optionalCharacter or self._player.Character
	if not character then
		return false
	end

	const parent = self:_getCharacterParent()
	if not isDescendantOfParent(character, parent) then
		return false
	end
	if character.PrimaryPart == nil then
		return false
	end

	const humanoid = getHumanoid(character)
	if not humanoid then
		return false
	end

	return humanoid.RootPart ~= nil and humanoid.Health > 0
end

function CharacterLoadedWrapper._onCharacterAdded(self: CharacterLoadedWrapper, character: Model)
	if self._destroyed then
		return
	end

	-- Only the newest character can become the loaded one, so abandon any load still in flight.
	const previousLoad = self._loadPromise
	if previousLoad then
		previousLoad:cancel()
	end

	const loadPromise = self:_promiseLoaded(character)
	self._loadPromise = loadPromise

	loadPromise
		:andThen(function(loadedCharacter: Model)
			if self._loadPromise == loadPromise then
				self._loadPromise = nil
			end
			if self._destroyed then
				return
			end

			self:_listenForDeath(loadedCharacter)
			self.Loaded:Fire(loadedCharacter)
		end)
		:catch(function(reason: any)
			if self._loadPromise == loadPromise then
				self._loadPromise = nil
			end
			if reason ~= DESTROYED_REASON and reason ~= DIED_REASON then
				logger:warn(`Failed to finish loading {character.Name}: {tostring(reason)}`)
			end
		end)
end

--[[
	Resolves once `IsLoaded(character)` is true, re-evaluating it whenever one of its inputs
	changes. Rejects if the character is destroyed, dies, or LOAD_TIMEOUT_SECONDS elapses first.
	Cancelling the Promise disconnects everything it created.
]]
function CharacterLoadedWrapper._promiseLoaded(self: CharacterLoadedWrapper, character: Model): Promise<Model>
	if self:IsLoaded(character) then
		return LeanPromise.resolve(character)
	end

	return LeanPromise.new(function(resolve, reject, onCancel)
		const connections = Connections.new()
		local watchedHumanoid: Humanoid? = nil
		local timeoutThread: thread? = nil
		local wasParented = isDescendantOfParent(character, self:_getCharacterParent())

		local function cleanup()
			connections:DisconnectAll()

			-- The timeout callback also calls this from `timeoutThread`; cancelling the running
			-- thread would stop it before it can reject.
			if
				timeoutThread
				and coroutine.running() ~= timeoutThread
				and coroutine.status(timeoutThread) == "suspended"
			then
				task.cancel(timeoutThread)
			end
			timeoutThread = nil
		end

		onCancel(cleanup)

		local function check()
			-- Start watching the Humanoid as soon as it exists; its RootPart and Health are
			-- part of the loaded definition. GetPropertyChangedSignal doesn't fire for
			-- RootPart, so we rely on .Changed.
			const humanoid = getHumanoid(character)
			if humanoid and humanoid ~= watchedHumanoid then
				watchedHumanoid = humanoid
				connections:Add(
					humanoid.Changed:Connect(check),
					humanoid.Died:Connect(function()
						cleanup()
						reject(DIED_REASON)
					end)
				)
			end

			if humanoid and humanoid.Health <= 0 then
				cleanup()
				reject(DIED_REASON)
				return
			end

			if not self:IsLoaded(character) then
				return
			end

			cleanup()
			resolve(character)
		end

		local function onAncestryChanged()
			const parent = self:_getCharacterParent()
			if isDescendantOfParent(character, parent) then
				wasParented = true
				check()
			elseif wasParented then
				cleanup()
				reject(DESTROYED_REASON)
			end
		end

		connections:Add(
			character.AncestryChanged:Connect(onAncestryChanged),
			character:GetPropertyChangedSignal("PrimaryPart"):Connect(check),
			character.ChildAdded:Connect(check),
			character.Destroying:Connect(function()
				cleanup()
				reject(DESTROYED_REASON)
			end)
		)

		timeoutThread = task.delay(LOAD_TIMEOUT_SECONDS, function()
			cleanup()
			reject(`Timed out after {LOAD_TIMEOUT_SECONDS}s waiting for {character.Name} to load.`)
		end)

		-- Picks up a Humanoid that already exists.
		check()
	end)
end

function CharacterLoadedWrapper._listenForDeath(self: CharacterLoadedWrapper, character: Model)
	if self._deathListeners[character] then
		return
	end

	const humanoid = getHumanoid(character)
	if not humanoid then
		return
	end

	const listeners = Connections.new()
	self._deathListeners[character] = listeners

	local function onDied()
		-- Debounce to prevent deferred events from letting .Died event fire more than once,
		-- such as if the humanoid dies and the character is destroyed in the same compute cycle.
		-- With deferred events, that would fire both events on the next cycle, even if the
		-- connections are disconnected within the response to the event.
		if self._deathListeners[character] ~= listeners then
			return
		end
		self._deathListeners[character] = nil

		listeners:DisconnectAll()
		self.Died:Fire(character)
	end

	-- .Destroying event would be preferred, but :LoadCharacterAsync() just removes
	-- the character instead of destroying it. As long as that is the case, we
	-- can't use .Destroying to cover all edge cases.
	listeners:Add(
		humanoid.Died:Connect(onDied),
		character.AncestryChanged:Connect(function()
			const parent = self:_getCharacterParent()
			if not isDescendantOfParent(character, parent) then
				onDied()
			end
		end)
	)
end

function CharacterLoadedWrapper.Destroy(self: CharacterLoadedWrapper)
	if self._destroyed then
		return
	end
	self._destroyed = true

	const loadPromise = self._loadPromise
	if loadPromise then
		loadPromise:cancel()
		self._loadPromise = nil
	end

	const pendingRejections = table.clone(self._pendingLoadedRejections)
	table.clear(self._pendingLoadedRejections)
	for _, rejectFunc in pendingRejections do
		rejectFunc("CharacterLoadedWrapper was destroyed")
	end

	for _, listeners in self._deathListeners do
		listeners:DisconnectAll()
	end
	table.clear(self._deathListeners)

	self._connections:DisconnectAll()
	self.Loaded:Destroy()
	self.Died:Destroy()
end

return CharacterLoadedWrapper
