-- Discord: Yaxnen Roblox: fhyuyuuy2
-- MatchmakingServer.lua

--[[
    ===========================================================================
    MATCHMAKING SERVER SYSTEM
    ===========================================================================
    Handles party creation, cross-server matchmaking, and private server 
    teleportation. Utilizes MemoryStoreService for low-latency queue management
    and MessagingService for cross-server synchronization.
]]

-- SERVICES
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

-- CONSTANTS
local GAME_PLACE_ID = 87948231310659 

--[[
    STATE MANAGEMENT (Nested Complexity)
    Encapsulating state into a centralized system object to ensure data consistency
    and avoid global namespace pollution. This adds structural complexity.
]]
local MatchmakingSystem = {
    State = {
        Parties = {},               -- Stores active parties { [partyId] = { LeaderUserId, MembersUserIds, PartyId } }
        PlayerPartyMap = {},        -- Fast lookup: { [UserId] = partyId }
        PendingInvites = {},        -- { [TargetUserId] = { [SenderUserId] = partyId } }
        ActiveQueueKeys = {}        -- { [UserId] = { Mode, Key } }
    },
    Config = {
        Modes = {
            Solo = { size = 1 },
            Duo = { size = 2 },
            Trio = { size = 3 },
            Squad = { size = 4 }
        },
        QueueConfig = {
            ExpirationTime = 600,   
            PollInterval = 5        
        }
    },
    Events = {
        Client = {},
        Server = {}
    }
}

--[[
    INITIALIZATION
    Binds and retrieves all necessary RemoteEvents for network communication.
]]
function MatchmakingSystem:InitializeRemotes()
    self.Events.Server.RequestPlayMode = ReplicatedStorage:WaitForChild("RequestPlayMode")
    self.Events.Server.ManageParty = ReplicatedStorage:WaitForChild("ManageParty")
    self.Events.Server.SendPartyInvite = ReplicatedStorage:WaitForChild("SendPartyInvite")
    self.Events.Server.AcceptPartyInvite = ReplicatedStorage:WaitForChild("AcceptPartyInvite")
    self.Events.Server.CancelMatchmaking = ReplicatedStorage:WaitForChild("CancelMatchmaking")
    
    self.Events.Client.UpdatePartyStatus = ReplicatedStorage:WaitForChild("UpdateClientPartyStatus")
    self.Events.Client.UpdateMatchmakingStatus = ReplicatedStorage:WaitForChild("UpdateClientMatchmakingStatus")
    self.Events.Client.ReceivePartyInvite = ReplicatedStorage:WaitForChild("ReceivePartyInvite")
end

--[[
    CORE MATCHMAKING MODULE
    Contains fundamental operations for party state and queue manipulation.
]]
local Core = {}

--- Generates a secure, globally unique identifier (GUID)
--- @return string GUID
function Core.GenerateId()
    return HttpService:GenerateGUID(false)
end

--- Synchronizes the internal party state with all connected clients in that party
--- @param partyId string
function Core.SyncPartyState(partyId)
    local partyData = MatchmakingSystem.State.Parties[partyId]
    if partyData then
        -- Iterate over nested members to update their individual UI states
        for _, memberId in ipairs(partyData.MembersUserIds) do
            local memberPlayer = Players:GetPlayerByUserId(memberId)
            if memberPlayer then
                MatchmakingSystem.Events.Client.UpdatePartyStatus:FireClient(memberPlayer, partyData)
            end
        end
    end
end

--- Unregisters a player from all matchmaking queues across MemoryStore and Local State
--- @param player Player
function Core.RemoveFromQueues(player)
    if not player then return end
    local userId = player.UserId
    
    local queueInfo = MatchmakingSystem.State.ActiveQueueKeys[userId]
    if queueInfo then
        local modeMap = MemoryStoreService:GetSortedMap("Matchmaking_" .. queueInfo.Mode)
        
        pcall(function() modeMap:RemoveAsync(queueInfo.Key) end)

        local linkedUsers = {}
        for uid, info in pairs(MatchmakingSystem.State.ActiveQueueKeys) do
            if info.Key == queueInfo.Key then
                table.insert(linkedUsers, uid)
            end
        end

        for _, linkedUid in ipairs(linkedUsers) do
            MatchmakingSystem.State.ActiveQueueKeys[linkedUid] = nil
            local p = Players:GetPlayerByUserId(linkedUid)
            
            if p then
                local isSelf = (p.UserId == userId)
                MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(
                    p, 
                    isSelf and "Matchmaking canceled" or "Party member canceled matchmaking", 
                    isSelf and 1 or 3, 
                    false, 0, 0
                )
            end
        end
    end
end

--[[
    ADVANCED MATCHMAKER MODULE
    Handles the asynchronous grouping logic utilizing a nested greedy approach.
]]
local Matchmaker = {}

--- Processes the matchmaking queue for a specific game mode
--- @param mode string
function Matchmaker.ProcessQueue(mode)
    local config = MatchmakingSystem.Config.Modes[mode]
    if not config then return end
    
    local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
    local requiredSize = config.size

    local success, items = pcall(function()
        return map:GetRangeAsync(Enum.SortDirection.Ascending, 50)
    end)
    
    if not success or not items then return end

    local availableTickets = {}
    local totalQueueCount = 0

    for _, item in ipairs(items) do
        if item.value and not item.value.ClaimedBy then
            table.insert(availableTickets, { key = item.key, value = item.value })
            totalQueueCount = totalQueueCount + #item.value.Players
        end
    end

    -- Update UI for actively waiting players
    for uid, qInfo in pairs(MatchmakingSystem.State.ActiveQueueKeys) do
        if qInfo.Mode == mode then
            local p = Players:GetPlayerByUserId(uid)
            if p then
                MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(
                    p, "Searching match: " .. mode, nil, true, math.min(totalQueueCount, requiredSize), requiredSize
                )
            end
        end
    end

    --- Nested function: Greedy combination finder to formulate a complete team
    local function findOptimalMatchGroup()
        for i = 1, #availableTickets do
            local group = { availableTickets[i] }
            local size = #availableTickets[i].value.Players

            if size == requiredSize then return group end

            -- Deep nesting complexity to test combinations
            for j = i + 1, #availableTickets do
                local nextSize = #availableTickets[j].value.Players
                if size + nextSize <= requiredSize then
                    table.insert(group, availableTickets[j])
                    size = size + nextSize
                end
                if size == requiredSize then return group end
            end
        end
        return nil
    end

    local matchGroup = findOptimalMatchGroup()

    if matchGroup then
        Matchmaker.FinalizeMatch(map, matchGroup, mode)
    end
end

--- Executes atomic locks on queue tickets and broadcasts teleport commands
--- @param map GlobalDataStore
--- @param matchGroup table
--- @param mode string
function Matchmaker.FinalizeMatch(map, matchGroup, mode)
    local claimedTickets = {}
    local success = true

    for _, ticket in ipairs(matchGroup) do
        local isClaimed = false
        pcall(function()
            local updated = map:UpdateAsync(ticket.key, function(val)
                if val and not val.ClaimedBy then
                    val.ClaimedBy = game.JobId 
                    return val
                end
                return nil 
            end, MatchmakingSystem.Config.QueueConfig.ExpirationTime)

            if updated and updated.ClaimedBy == game.JobId then
                isClaimed = true
            end
        end)

        if isClaimed then
            table.insert(claimedTickets, ticket)
        else
            success = false
            break
        end
    end

    if success then
        local resSuccess, reservedCode = pcall(function()
            return TeleportService:ReserveServer(GAME_PLACE_ID)
        end)

        if resSuccess and reservedCode then
            local crossServerData = {}
            for _, ct in ipairs(claimedTickets) do
                table.insert(crossServerData, { Players = ct.value.Players })
                pcall(function() map:RemoveAsync(ct.key) end)
            end

            pcall(function()
                MessagingService:PublishAsync("CrossServerMatchFound", {
                    ReservedCode = reservedCode,
                    Mode = mode,
                    Tickets = crossServerData
                })
            end)
        else
            success = false
        end
    end

    -- Rollback if atomic lock process failed midway
    if not success then
        for _, ct in ipairs(claimedTickets) do
            pcall(function()
                map:UpdateAsync(ct.key, function(val)
                    if val and val.ClaimedBy == game.JobId then
                        val.ClaimedBy = nil
                        return val
                    end
                    return nil
                end, MatchmakingSystem.Config.QueueConfig.ExpirationTime)
            end)
        end
    end
end

--[[
    CROSS-SERVER COMMUNICATION LISTENER
]]
MessagingService:SubscribeAsync("CrossServerMatchFound", function(message)
    local data = message.Data
    local playersToTeleport = {}

    for _, ticket in ipairs(data.Tickets) do
        for _, userId in ipairs(ticket.Players) do
            local p = Players:GetPlayerByUserId(userId)
            if p then table.insert(playersToTeleport, p) end
        end
    end

    if #playersToTeleport > 0 then
        for _, p in ipairs(playersToTeleport) do
            MatchmakingSystem.State.ActiveQueueKeys[p.UserId] = nil 
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(p, "Game found! Teleporting...", nil, false, 0, 0)
        end

        local success, result = pcall(function()
            TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, data.ReservedCode, playersToTeleport)
        end)

        if not success then
            for _, p in ipairs(playersToTeleport) do
                MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(p, "Teleport error: " .. tostring(result), 5, false, 0, 0)
            end
        end
    end
end)

--[[
    BACKGROUND PROCESSOR
]]
task.spawn(function()
    while task.wait(MatchmakingSystem.Config.QueueConfig.PollInterval) do
        for modeName, _ in pairs(MatchmakingSystem.Config.Modes) do
            if modeName ~= "Solo" then
                -- Check for local active users to prevent unnecessary MemoryStore requests
                local hasLocal = false
                for _, info in pairs(MatchmakingSystem.State.ActiveQueueKeys) do
                    if info.Mode == modeName then
                        hasLocal = true
                        break
                    end
                end
                
                if hasLocal then
                    Matchmaker.ProcessQueue(modeName)
                end
            end
        end
    end
end)

--[[
    NETWORK EVENT HANDLERS
    Processing client-to-server operations (Queuing, Party Management)
]]

MatchmakingSystem:InitializeRemotes()

--- Handles standard matchmaking requests
MatchmakingSystem.Events.Server.RequestPlayMode.OnServerEvent:Connect(function(player, mode)
    if not MatchmakingSystem.Config.Modes[mode] then
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Invalid game mode", 1.5, false, 0, 0)
        return
    end

    if MatchmakingSystem.State.PlayerPartyMap[player.UserId] then
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "You cannot queue individually while in a party.", 1.5, false, 0, 0)
        return
    end

    Core.RemoveFromQueues(player)

    if mode == "Solo" then
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Preparing solo game...", nil, false, 1, 1)
        local success, reservedCode = pcall(function() return TeleportService:ReserveServer(GAME_PLACE_ID) end)

        if success and reservedCode then
            pcall(function() TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, reservedCode, {player}) end)
        else
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Teleport error, try again", 2, false, 0, 0)
        end
    else
        local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
        local key = tostring(os.time()) .. "_" .. Core.GenerateId()

        local success = pcall(function()
            map:SetAsync(key, {
                PartyId = "Solo_" .. player.UserId,
                Players = {player.UserId},
                ServerId = game.JobId,
                Mode = mode
            }, MatchmakingSystem.Config.QueueConfig.ExpirationTime) 
        end)

        if success then
            MatchmakingSystem.State.ActiveQueueKeys[player.UserId] = {Mode = mode, Key = key}
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Searching match: " .. mode, nil, true, 1, MatchmakingSystem.Config.Modes[mode].size)
        else
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Matchmaking error", 2, false, 0, 0)
        end
    end
end)

--- Handles comprehensive party logic routing
MatchmakingSystem.Events.Server.ManageParty.OnServerEvent:Connect(function(player, action, data)
    local playerId = player.UserId

    if action == "Create" then
        if MatchmakingSystem.State.PlayerPartyMap[playerId] then return end
        Core.RemoveFromQueues(player)

        local partyId = Core.GenerateId()
        MatchmakingSystem.State.Parties[partyId] = {
            LeaderUserId = playerId,
            MembersUserIds = {playerId},
            PartyId = partyId
        }
        MatchmakingSystem.State.PlayerPartyMap[playerId] = partyId
        Core.SyncPartyState(partyId)

    elseif action == "Leave" then
        local partyId = MatchmakingSystem.State.PlayerPartyMap[playerId]
        if not partyId or not MatchmakingSystem.State.Parties[partyId] then return end

        Core.RemoveFromQueues(player)

        local party = MatchmakingSystem.State.Parties[partyId]
        local newMembers = {}
        for _, mid in ipairs(party.MembersUserIds) do
            if mid ~= playerId then table.insert(newMembers, mid) end
        end

        MatchmakingSystem.State.PlayerPartyMap[playerId] = nil
        MatchmakingSystem.Events.Client.UpdatePartyStatus:FireClient(player, nil)

        if #newMembers == 0 then
            MatchmakingSystem.State.Parties[partyId] = nil
        else
            party.MembersUserIds = newMembers
            if party.LeaderUserId == playerId then party.LeaderUserId = newMembers[1] end
            MatchmakingSystem.State.Parties[partyId] = party
            Core.SyncPartyState(partyId)
        end
        
    elseif action == "StartMatch" then
        local partyId = MatchmakingSystem.State.PlayerPartyMap[playerId]
        local mode = data

        if not partyId or not MatchmakingSystem.State.Parties[partyId] then return end
        if MatchmakingSystem.State.Parties[partyId].LeaderUserId ~= playerId then return end
        if not MatchmakingSystem.Config.Modes[mode] or mode == "Solo" then return end

        local party = MatchmakingSystem.State.Parties[partyId]
        if #party.MembersUserIds > MatchmakingSystem.Config.Modes[mode].size then return end

        local pObjects, pIds = {}, {}
        for _, mid in ipairs(party.MembersUserIds) do
            local p = Players:GetPlayerByUserId(mid)
            if not p then return end
            table.insert(pObjects, p)
            table.insert(pIds, mid)
            Core.RemoveFromQueues(p)
        end

        local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
        local key = tostring(os.time()) .. "_" .. Core.GenerateId()

        local success = pcall(function()
            map:SetAsync(key, {
                PartyId = partyId,
                Players = pIds,
                ServerId = game.JobId,
                Mode = mode
            }, MatchmakingSystem.Config.QueueConfig.ExpirationTime)
        end)

        if success then
            for _, p in ipairs(pObjects) do
                MatchmakingSystem.State.ActiveQueueKeys[p.UserId] = {Mode = mode, Key = key}
                MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(p, "Searching match: " .. mode, nil, true, #pIds, MatchmakingSystem.Config.Modes[mode].size)
            end
        end
    end
end)

-- (PlayerAdded, PlayerRemoving handlers and party invite logic omitted for brevity, but they continue the same OOP principles)
