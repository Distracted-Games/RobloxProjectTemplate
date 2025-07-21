local config = {
    Debug = false,
}

--[[
    Logs a formatted message to the output.
    Uses `warn` for warnings and `print` for debug messages.
    The log includes the calling function's name and line for easier debugging.
    @param message The core message to log.
    @param isWarning If true, formats the message as a warning.
]]
local function log(message: string, isWarning: boolean?)
	local prefix = "[ModuleLoader] "
    local source, line, funcName = debug.info(2, "sln")
    local formattedSource = `{string.match(source, "@(.*)")}`
    local logHeader = `{prefix} [{funcName or formattedSource}:{line}]`

	if isWarning then
		warn(`{logHeader} {message}`)
	elseif config.Debug then
		print(`{logHeader} {message}`)
	end
end

return true
