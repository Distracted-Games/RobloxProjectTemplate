--!strict
--[[
	Copyright (c) 2019 Eryn L. K.
	https://github.com/evaera/roblox-lua-promise

	This library is a derivative work of the original Promise.lua library by evaera,
	licensed under the MIT License.

	---

	Copyright (c) 2025 Distracted Games

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.
]]

--[[
    This module defines a rich error object for handling Promise rejections.
]]

local PromiseError = {}
PromiseError.__index = PromiseError

export type PromiseError = typeof(setmetatable(
	{} :: {
		error: string,
		trace: string?,
		context: string?,
		kind: string,
		parent: PromiseError?,
		createdTick: number,
		new: (
			options: { error: any, trace: string?, context: string?, kind: string },
			parent: PromiseError?
		) -> PromiseError,
		extend: (self: PromiseError, options: { kind: string? }?) -> PromiseError,
		getErrorChain: (self: PromiseError) -> { PromiseError },
		__tostring: (self: PromiseError) -> string,
	},
	PromiseError
))

-- An enum for the different kinds of errors.
local ErrorKind = {
	ExecutionError = "ExecutionError" :: "ExecutionError",
	AlreadyCancelled = "AlreadyCancelled" :: "AlreadyCancelled",
	NotResolvedInTime = "NotResolvedInTime" :: "NotResolvedInTime",
	TimedOut = "TimedOut" :: "TimedOut",
}
table.freeze(ErrorKind)

function PromiseError.new(
			options: { error: any, trace: string?, context: string?, kind: string },
			parent: PromiseError?
		): PromiseError
	local self = setmetatable({}, PromiseError) :: PromiseError
		self.error = tostring(options.error) or "[This error has no error text.]"
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

function PromiseError.isKind(value: any, kind: string): boolean
    return PromiseError.is(value) and value.kind == kind
end

function PromiseError.extend(self: PromiseError, options: { kind: string? }?): PromiseError
    local opts = options or { kind = nil }
    return PromiseError.new({
        error = self.error,
        trace = self.trace,
        context = self.context,
        kind = opts.kind or self.kind,
    }, self)
end

function PromiseError.getErrorChain(self: PromiseError): { PromiseError }
    local errorChain = { self }
    local current = self
    while current.parent do
        table.insert(errorChain, current.parent)
        current = current.parent
    end

    return errorChain
end

function PromiseError.__tostring(self: PromiseError): string
    local errorStrings = { `--- Promise Error ({self.kind}) ---` }
    for _, err in ipairs(PromiseError.getErrorChain(self)) do
        local parts = {}
        if err.trace then
            table.insert(parts, err.trace)
        end
        if err.context then
            table.insert(parts, err.context)
        end
        table.insert(errorStrings, table.concat(parts, "\n"))
    end
    
    return table.concat(errorStrings, "\n\n")
end

return {
    Kind = ErrorKind,
    new = PromiseError.new,
    is = PromiseError.is,
    isKind = PromiseError.isKind,
}
