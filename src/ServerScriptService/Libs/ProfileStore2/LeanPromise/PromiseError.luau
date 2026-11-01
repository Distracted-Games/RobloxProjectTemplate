--!strict
--[[
	Defines a rich error object for handling Promise rejections.
]]

const ERROR_KIND_ENUM = table.freeze({
	ExecutionError = "ExecutionError" :: "ExecutionError",
	AlreadyCancelled = "AlreadyCancelled" :: "AlreadyCancelled",
	NotResolvedInTime = "NotResolvedInTime" :: "NotResolvedInTime",
	TimedOut = "TimedOut" :: "TimedOut",
})

export type ErrorKind = "ExecutionError" | "AlreadyCancelled" | "NotResolvedInTime" | "TimedOut" | string

export type PromiseErrorOptions = {
	error: any,
	trace: string?,
	context: string?,
	kind: ErrorKind,
}

export type PromiseErrorExtendOptions = {
	error: any?,
	trace: string?,
	context: string?,
	kind: ErrorKind?,
}

const PromiseError = {}
PromiseError.__index = PromiseError

type PromiseErrorData = {
	error: string,
	trace: string?,
	context: string?,
	kind: ErrorKind,
	parent: PromiseError?,
	createdTick: number,
}

export type PromiseError = setmetatable<PromiseErrorData, typeof(PromiseError)>

function PromiseError.new(options: PromiseErrorOptions, parent: PromiseError?): PromiseError
	const defaultText = "[This error has no error text.]"
	const errorText = if options.error ~= nil then tostring(options.error) else defaultText

	const self = setmetatable({}, PromiseError) :: PromiseError
	self.error = errorText
	self.trace = options.trace
	self.context = options.context
	self.kind = options.kind
	self.parent = parent
	self.createdTick = os.clock()

	return self
end

function PromiseError.is(value: any): boolean
	return typeof(value) == "table" and getmetatable(value) == PromiseError
end

function PromiseError.isKind(value: any, kind: ErrorKind): boolean
	return PromiseError.is(value) and (value :: PromiseError).kind == kind
end

function PromiseError.extend(self: PromiseError, options: PromiseErrorExtendOptions?): PromiseError
	const opts: PromiseErrorExtendOptions = options or {}
	return PromiseError.new({
		error = if opts.error ~= nil then opts.error else self.error,
		trace = opts.trace,
		context = opts.context,
		kind = opts.kind or self.kind,
	}, self)
end

function PromiseError.getErrorChain(self: PromiseError): { PromiseError }
	const errorChain: { PromiseError } = { self }
	local current: PromiseError = self
	while current.parent do
		table.insert(errorChain, current.parent)
		current = current.parent
	end

	return errorChain
end

function PromiseError.__tostring(self: PromiseError): string
	const errorStrings = { `--- Promise Error ({self.kind}) ---` }
	for _, err in PromiseError.getErrorChain(self) do
		const parts: { string } = {}
		if err.trace then
			table.insert(parts, err.trace)
		else
			table.insert(parts, err.error)
		end
		if err.context then
			table.insert(parts, err.context)
		end
		table.insert(errorStrings, table.concat(parts, "\n"))
	end

	return table.concat(errorStrings, "\n\n")
end

return table.freeze({
	Kind = ERROR_KIND_ENUM,
	new = PromiseError.new,
	is = PromiseError.is,
	isKind = PromiseError.isKind,
})
