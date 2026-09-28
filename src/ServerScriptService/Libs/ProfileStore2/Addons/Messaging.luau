-- --[[
--     Sends a message to a profile's GlobalUpdates queue.
--     This can be used for cross-server or offline messaging.
-- ]]
-- function ProfileStore.MessageAsync<T>(
--     self: ProfileStore<T>,
--     key: string,
--     message: any
-- ): Promise.Promise<boolean>
--     if typeof(key) ~= "string" or #key == 0 or #key > 50 then
-- 		error(`[ProfileStore]: Invalid 'key' provided to MessageAsync.`, 2)
-- 	end
-- 	if typeof(message) ~= "table" then
-- 		error(`[ProfileStore]: 'message' must be a table.`, 2)
-- 	end

--     return Promise.new(function(resolve, reject)
--         task.spawn(function()
--             local isMock = readMockFlag()
--             local sessionToken = generateSessionToken(self.Name, key, isMock)

--             local releaseQueue = waitForUpdateQueue(sessionToken)

--             local success, result = pcall(function()
--                 local function transformFunction(latestData: ProfileData<T>?): (ProfileData<T>, {number}?, { [string]: any }?)
--                     local data = latestData or { Metadata = {} } :: any -- Create a shell if profile is new
                
--                     if not data.GlobalUpdates then
--                         data.GlobalUpdates = { 0, {} :: any }
--                     end

--                     local updateIndex = data.GlobalUpdates[1] + 1
--                     local updateList = data.GlobalUpdates[2]

--                     data.GlobalUpdates[1] = updateIndex
--                     table.insert(updateList, { updateIndex, message })

--                     -- Enforce max queue size.
--                     while #updateList > Constants.MAX_MESSAGE_QUEUE do
--                         table.remove(updateList, 1)
--                     end

--                     return data, data.UserIds, data.RobloxMetaData
--                 end

--                 local loadedData, _ = self:_updateAsync(key, transformFunction, isMock)
--                 return loadedData
--             end)

--             releaseQueue()

--             if not success then
--                 warn(`[ProfileStore]: MessageAsync failed for key '{key}': {tostring(result)}`)
--                 resolve(false)
--                 return
--             end

--             local loadedData = result
--             if not loadedData then
--                 resolve(false)
--                 return
--             end

--             -- After successfully sending the message, check if the profile is
--             -- active on this server and notify it.
            
--             local activeProfile = ActiveSessionCheck[sessionToken]
--             if activeProfile then
--                 activeProfile:Save() -- Trigger a save to pull in the new message
--             else
--                 -- If active on another server, poke it via MessageingService.
--                 local metaData = loadedData.MetaData or {}
--                 local activeSession = metaData.ActiveSession
--                 if typeof(activeSession) == "table" and typeof(activeSession[3]) == "string" then
--                     MessagingService:PublishAsync(`PS_{activeSession[3]}`, {
--                         LoadCount = metaData.SessionLoadCount or 0,
--                     })
--                 end
--             end

--             resolve(true)
--         end)
--     end)
-- end

return {}
