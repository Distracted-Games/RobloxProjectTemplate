--!strict
--[[
    Contains default configuration constants for the ProfileStore system.
    These values dictate the timing and thresholds for session locking,
    auto-saving, and error handling.
]]

export type Constants = {
    -- (Seconds) Time between when changes to a profile are saved to the DataStore
	AUTO_SAVE_PERIOD: number,
	-- (Seconds) Time between successive profile reads when handling a session conflict
	LOAD_REPEAT_PERIOD: number,
	-- (Seconds) Time between first and second profile read when handling a session conflict
	FIRST_LOAD_REPEAT: number,
	-- (Seconds) Time until a session conflict is resolved with the waiting server stealing the session
	SESSION_STEAL: number,
	-- (Seconds) If a profile hasn't had updates for this long, quickly assume an active session belongs to a crashed server
	ASSUME_DEAD: number,
	-- (Seconds) If a session can't be started for a profile for this long, stop repeating calls to the DataStore
	START_SESSION_TIMEOUT: number,
	
	-- Assume critical state if this many issues happen in a short amount of time
	CRITICAL_STATE_ERROR_COUNT: number,
	-- (Seconds) Individual issue expiration
	CRITICAL_STATE_ERROR_EXPIRE: number,
	-- (Seconds) Critical state expiration
	CRITICAL_STATE_EXPIRE: number,
	
	-- Max messages saved in a profile that were sent using "ProfileStore:MessageAsync()"
	MAX_MESSAGE_QUEUE: number,
}

local Constants: Constants = {
    AUTO_SAVE_PERIOD = 300,
	LOAD_REPEAT_PERIOD = 10,
	FIRST_LOAD_REPEAT = 5,
	SESSION_STEAL = 40,
	ASSUME_DEAD = 630,
	START_SESSION_TIMEOUT = 120,

	CRITICAL_STATE_ERROR_COUNT = 5,
	CRITICAL_STATE_ERROR_EXPIRE = 120,
	CRITICAL_STATE_EXPIRE = 120,

	MAX_MESSAGE_QUEUE = 1000,
}

return table.freeze(Constants)
