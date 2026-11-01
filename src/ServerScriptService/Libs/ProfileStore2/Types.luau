--!strict
--[[
	Shared type definitions and domain error kinds across ProfileStore2 modules.
]]

const ERROR_KIND = table.freeze({
	ExecutionError = "ExecutionError" :: "ExecutionError",
	AlreadyCancelled = "AlreadyCancelled" :: "AlreadyCancelled",
	NotResolvedInTime = "NotResolvedInTime" :: "NotResolvedInTime",
	TimedOut = "TimedOut" :: "TimedOut",
	Cancelled = "Cancelled" :: "Cancelled",
	ConnectivityError = "ConnectivityError" :: "ConnectivityError",
	DataStoreError = "DataStoreError" :: "DataStoreError",
	SessionConflict = "SessionConflict" :: "SessionConflict",
})

export type ErrorKind =
	"ExecutionError"
	| "AlreadyCancelled"
	| "NotResolvedInTime"
	| "TimedOut"
	| "Cancelled"
	| "ConnectivityError"
	| "DataStoreError"
	| "SessionConflict"
	| string

export type ErrorKindTable = typeof(ERROR_KIND)

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type LastSaveReason = "Manual" | "External" | "Shutdown"

export type DataStoreState = "NotReady" | "NoInternet" | "NoAccess" | "Access"

export type DictionarySessionLock = {
	PlaceId: number,
	JobId: string,
	UniqueId: string?,
}

export type LegacySessionLock = { any }

export type SessionLock = DictionarySessionLock | LegacySessionLock

export type DictionaryForceLoadLock = {
	PlaceId: number,
	JobId: string,
}

export type ForceLoadLock = DictionaryForceLoadLock | LegacySessionLock

export type SessionInfo = {
	PlaceId: number,
	JobId: string,
}

export type ProfileMetaData = {
	ProfileCreateTime: number,
	SessionLoadCount: number,
	ActiveSession: SessionLock?,
	ForceLoadSession: ForceLoadLock?,
	LastUpdate: number?,
	MetaTags: { [string]: any }?,
}

export type GlobalUpdateEntry = { any }

export type GlobalUpdatesPayload = { any }

export type ProfileData<T> = {
	Data: T,
	MetaData: ProfileMetaData,
	GlobalUpdates: GlobalUpdatesPayload?,
	UserIds: { number },
	RobloxMetaData: { [string]: any },
	WasOverwritten: boolean?,
}

export type LoadProfileParams = {
	Steal: boolean?,
	Cancel: (() -> boolean)?,
}

export type CreateStoreOptions = {
	UseLegacySchema: boolean?,
	Scope: string?,
}

return table.freeze({
	ErrorKind = ERROR_KIND,
})
