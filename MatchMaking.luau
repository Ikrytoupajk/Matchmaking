-- Discord: Yaxnen Roblox: fhyuyuuy2
-- MatchmakingServer.lua

--[[
    ===========================================================================
    MATCHMAKING SERVER SYSTEM
    ===========================================================================
    This script manages party creation, cross-server matchmaking, and 
    teleportation to private servers.
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
    STATE MANAGEMENT
]]
local MatchmakingSystem = {
    State = {
        -- Stores active parties. Key is the Party ID, value is a table containing Leader and Members' UserIds.
        -- This allows centralized management of team compositions.
        Parties = {},               
        -- Fast lookup dictionary mapping a UserId to their Party ID. 
        -- Ensures O(1) complexity when checking if a player is already in a party.
        PlayerPartyMap = {},        
        -- Stores invites that have been sent but not yet accepted or declined.
        PendingInvites = {},        
        -- Maps a UserId to their current queue information (Game Mode and the unique MemoryStore ticket key).
        ActiveQueueKeys = {}        
    },
    Config = {
        -- Game mode configurations. Dictates the required group size to initiate a match.
        Modes = {
            Solo = { size = 1 },
            Duo = { size = 2 },
            Trio = { size = 3 },
            Squad = { size = 4 }
        },
        QueueConfig = {
            -- Ticket lifetime in the queue (in seconds). Prevents "dead" tickets from indefinitely clogging the queue if a server crashes.
            ExpirationTime = 600,   
            -- The interval (in seconds) at which the server will poll the MemoryStore for new matchmaking candidates.
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
]]
function MatchmakingSystem:InitializeRemotes()
    -- Binding Server RemoteEvents to listen for incoming requests from clients.
    self.Events.Server.RequestPlayMode = ReplicatedStorage:WaitForChild("RequestPlayMode")
    self.Events.Server.ManageParty = ReplicatedStorage:WaitForChild("ManageParty")
    self.Events.Server.SendPartyInvite = ReplicatedStorage:WaitForChild("SendPartyInvite")
    self.Events.Server.AcceptPartyInvite = ReplicatedStorage:WaitForChild("AcceptPartyInvite")
    self.Events.Server.CancelMatchmaking = ReplicatedStorage:WaitForChild("CancelMatchmaking")
    
    -- Binding Client RemoteEvents used to dispatch state updates back to the players' UI.
    self.Events.Client.UpdatePartyStatus = ReplicatedStorage:WaitForChild("UpdateClientPartyStatus")
    self.Events.Client.UpdateMatchmakingStatus = ReplicatedStorage:WaitForChild("UpdateClientMatchmakingStatus")
    self.Events.Client.ReceivePartyInvite = ReplicatedStorage:WaitForChild("ReceivePartyInvite")
end

--[[
    CORE MATCHMAKING MODULE
]]
local Core = {}

--- Generates a globally unique identifier (GUID) utilizing HttpService.
function Core.GenerateId()
    -- Passing 'false' strips the curly braces from the generated GUID. 
    -- This ID ensures unique identification for parties and queue tickets, preventing data collisions.
    return HttpService:GenerateGUID(false)
end

--- Synchronizes the server's internal party state with all connected clients in that specific party.
function Core.SyncPartyState(partyId)
    -- Retrieve the party data from the server's local state.
    local partyData = MatchmakingSystem.State.Parties[partyId]
    if partyData then
        -- Iterate through all UserIds in the party to send them the updated data.
        for _, memberId in ipairs(partyData.MembersUserIds) do
            -- Attempt to find the player on the current physical server using their UserId.
            local memberPlayer = Players:GetPlayerByUserId(memberId)
            if memberPlayer then
                -- If the player is on this server, dispatch the updated party data to refresh their UI.
                MatchmakingSystem.Events.Client.UpdatePartyStatus:FireClient(memberPlayer, partyData)
            end
        end
    end
end

--- Removes a player from all matchmaking queues across both the local server state and global MemoryStore.
function Core.RemoveFromQueues(player)
    if not player then return end
    local userId = player.UserId
    
    -- Check if the player is currently in a queue by querying the local state cache.
    local queueInfo = MatchmakingSystem.State.ActiveQueueKeys[userId]
    if queueInfo then
        -- Access the specific SortedMap structure in MemoryStore corresponding to the player's game mode.
        local modeMap = MemoryStoreService:GetSortedMap("Matchmaking_" .. queueInfo.Mode)
        
        -- Asynchronously remove the ticket from the global queue.
        -- Wrapped in a pcall to prevent the server thread from crashing due to unexpected network errors or rate limits.
        pcall(function() modeMap:RemoveAsync(queueInfo.Key) end)

        -- Gather a list of all local users tied to this exact same ticket key (e.g., if a full party was queuing together).
        local linkedUsers = {}
        for uid, info in pairs(MatchmakingSystem.State.ActiveQueueKeys) do
            -- A matching key means these players share the same matchmaking ticket.
            if info.Key == queueInfo.Key then
                table.insert(linkedUsers, uid)
            end
        end

        -- Clear the local state for all linked users and notify their clients about the cancellation.
        for _, linkedUid in ipairs(linkedUsers) do
            -- Remove the queue record from the local dictionary.
            MatchmakingSystem.State.ActiveQueueKeys[linkedUid] = nil
            local p = Players:GetPlayerByUserId(linkedUid)
            
            if p then
                -- Determine if the cancellation was initiated by the player themselves or someone else (like the party leader).
                local isSelf = (p.UserId == userId)
                -- Instruct the client to reset its matchmaking UI, providing the appropriate cancellation reason.
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
]]
local Matchmaker = {}

--- Processes the global MemoryStore queue for a specific game mode.
function Matchmaker.ProcessQueue(mode)
    -- Fetch the specific mode settings (e.g., the target team size).
    local config = MatchmakingSystem.Config.Modes[mode]
    if not config then return end
    
    -- Access the global SortedMap designated for this specific game mode.
    local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
    -- Cache the required team size locally for quick reference during calculations.
    local requiredSize = config.size

    -- Attempt to fetch the 50 oldest tickets (ascending order by key, which includes os.time()).
    -- pcall ensures that if MemoryStore fails to respond, the script yields safely instead of breaking.
    local success, items = pcall(function()
        return map:GetRangeAsync(Enum.SortDirection.Ascending, 50)
    end)
    
    -- Abort this polling cycle if the API request failed or returned empty data.
    if not success or not items then return end

    -- Array to hold valid tickets that have not yet been claimed by another server.
    local availableTickets = {}
    -- Tracks the total number of players currently waiting within this fetched batch.
    local totalQueueCount = 0

    -- Iterate through the fetched MemoryStore items.
    for _, item in ipairs(items) do
        -- Verify that the ticket data exists and hasn't been locked by another server's JobId (ClaimedBy).
        if item.value and not item.value.ClaimedBy then
            -- Store the valid ticket for the upcoming group combination logic.
            table.insert(availableTickets, { key = item.key, value = item.value })
            -- Increment the total player count by the number of players inside this specific ticket.
            totalQueueCount = totalQueueCount + #item.value.Players
        end
    end

    -- Broadcast visual progress updates to all local players waiting in this specific mode.
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

    --- Nested function: Greedy algorithm to find the optimal combination of tickets that perfectly fills a team.
    local function findOptimalMatchGroup()
        -- Iterate through every available ticket to use it as a starting baseline.
        for i = 1, #availableTickets do
            -- Initialize a potential match group with the current ticket.
            local group = { availableTickets[i] }
            -- Calculate the initial player count for this group.
            local size = #availableTickets[i].value.Players

            -- If this single ticket already fulfills the required team size, return it immediately.
            if size == requiredSize then return group end

            -- Nested loop to test combinations with subsequent tickets (Greedy approach).
            for j = i + 1, #availableTickets do
                local nextSize = #availableTickets[j].value.Players
                -- If merging the next ticket does not exceed the mode's maximum size, add it to the group.
                if size + nextSize <= requiredSize then
                    table.insert(group, availableTickets[j])
                    size = size + nextSize
                end
                -- The moment the combined group exactly matches the required size, return the successful combination.
                if size == requiredSize then return group end
            end
        end
        -- Return nil if no valid combination could be assembled during this polling cycle.
        return nil
    end

    -- Execute the combination search logic.
    local matchGroup = findOptimalMatchGroup()

    -- If a complete team was successfully assembled, proceed to lock the tickets and execute the teleport.
    if matchGroup then
        Matchmaker.FinalizeMatch(map, matchGroup, mode)
    end
end

--- Locks assembled tickets atomically and broadcasts teleport commands across servers.
function Matchmaker.FinalizeMatch(map, matchGroup, mode)
    -- Array to keep track of which tickets this server successfully secured.
    local claimedTickets = {}
    -- Flag to track if the entire group was successfully locked without another server interfering.
    local success = true

    -- Iterate over each ticket in the assembled group to attempt an atomic lock.
    for _, ticket in ipairs(matchGroup) do
        local isClaimed = false
        -- pcall wraps the UpdateAsync method, which prevents race conditions between multiple servers.
        pcall(function()
            local updated = map:UpdateAsync(ticket.key, function(val)
                -- If the ticket still exists and hasn't been claimed yet, mark it with this server's JobId.
                if val and not val.ClaimedBy then
                    val.ClaimedBy = game.JobId 
                    return val
                end
                -- If it was claimed by another server in the exact same millisecond, return nil to abort the update.
                return nil 
            end, MatchmakingSystem.Config.QueueConfig.ExpirationTime)

            -- Verify if the update was successful and the ClaimedBy property now matches our server's JobId.
            if updated and updated.ClaimedBy == game.JobId then
                isClaimed = true
            end
        end)

        -- If successfully secured, add to our claimed list; otherwise, break the loop as the assembly is compromised.
        if isClaimed then
            table.insert(claimedTickets, ticket)
        else
            success = false
            break
        end
    end

    -- If the server successfully locked all tickets required for the match:
    if success then
        -- Attempt to reserve a new private server instance via TeleportService.
        local resSuccess, reservedCode = pcall(function()
            return TeleportService:ReserveServer(GAME_PLACE_ID)
        end)

        -- If the server reservation was successful and a valid code was returned:
        if resSuccess and reservedCode then
            -- Prepare the payload to be broadcasted to all other servers.
            local crossServerData = {}
            for _, ct in ipairs(claimedTickets) do
                table.insert(crossServerData, { Players = ct.value.Players })
                -- Since the match is confirmed, safely remove these used tickets from the global MemoryStore queue.
                pcall(function() map:RemoveAsync(ct.key) end)
            end

            -- Publish a message globally via MessagingService to notify all servers about the assembled match.
            -- Servers hosting the affected players will receive this and initiate the teleportation using the ReservedCode.
            pcall(function()
                MessagingService:PublishAsync("CrossServerMatchFound", {
                    ReservedCode = reservedCode,
                    Mode = mode,
                    Tickets = crossServerData
                })
            end)
        else
            -- Flag as failed if TeleportService experienced an outage, triggering the rollback process.
            success = false
        end
    end

    -- ROLLBACK MECHANISM: If locking failed mid-way or server reservation failed, release any tickets we did lock.
    if not success then
        for _, ct in ipairs(claimedTickets) do
            -- Atomically remove our server's JobId lock so other servers can matchmake these players again.
            pcall(function()
                map:UpdateAsync(ct.key, function(val)
                    -- Ensure we only release the lock if it still belongs to our server.
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
-- Subscribing to the global MessagingService channel to listen for successfully assembled matches from ANY server.
MessagingService:SubscribeAsync("CrossServerMatchFound", function(message)
    -- Extract the payload sent by the originating server.
    local data = message.Data
    -- Array to collect player objects who are physically connected to THIS specific server and need teleporting.
    local playersToTeleport = {}

    -- Iterate through all the tickets and their respective players provided in the broadcast.
    for _, ticket in ipairs(data.Tickets) do
        for _, userId in ipairs(ticket.Players) do
            -- Check if a player with this UserId is currently connected to this server instance.
            local p = Players:GetPlayerByUserId(userId)
            -- If found, add their player object to the local teleportation batch.
            if p then table.insert(playersToTeleport, p) end
        end
    end

    -- If this server hosts at least one player involved in the found match:
    if #playersToTeleport > 0 then
        for _, p in ipairs(playersToTeleport) do
            -- Clear their local queue state, as their search has officially concluded.
            MatchmakingSystem.State.ActiveQueueKeys[p.UserId] = nil 
            -- Send a final visual update to the client indicating the teleportation sequence has started.
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(p, "Game found! Teleporting...", nil, false, 0, 0)
        end

        -- Execute a batch teleport for all local participants to the reserved private server.
        local success, result = pcall(function()
            TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, data.ReservedCode, playersToTeleport)
        end)

        -- If the teleport request fails (e.g., due to Roblox network issues), inform the clients about the error.
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
-- Spawn an asynchronous background thread that continuously runs on the server.
task.spawn(function()
    -- Create an infinite loop that yields based on the configured polling interval.
    while task.wait(MatchmakingSystem.Config.QueueConfig.PollInterval) do
        -- Iterate through all game modes defined in the configuration.
        for modeName, _ in pairs(MatchmakingSystem.Config.Modes) do
            -- Solo mode doesn't require MemoryStore queueing or combinations, so it's skipped.
            if modeName ~= "Solo" then
                -- NETWORK OPTIMIZATION: Check if there are any local players actively queuing for this mode.
                -- This prevents the server from making unnecessary, expensive API calls to MemoryStore if it has no vested interest.
                local hasLocal = false
                for _, info in pairs(MatchmakingSystem.State.ActiveQueueKeys) do
                    -- Compare the local queued player's mode against the current loop iteration.
                    if info.Mode == modeName then
                        hasLocal = true
                        -- Break early since finding just one local player justifies processing the queue.
                        break
                    end
                end
                
                -- If a local player is waiting for this mode, trigger the heavy queue processing function.
                if hasLocal then
                    Matchmaker.ProcessQueue(modeName)
                end
            end
        end
    end
end)

--[[
    NETWORK EVENT HANDLERS
]]

-- Initialize and bind RemoteEvents when the script first loads.
MatchmakingSystem:InitializeRemotes()

--- Handler for client requests to initiate matchmaking.
MatchmakingSystem.Events.Server.RequestPlayMode.OnServerEvent:Connect(function(player, mode)
    -- Exploit protection: Validate that the requested game mode actually exists in the server config.
    if not MatchmakingSystem.Config.Modes[mode] then
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Invalid game mode", 1.5, false, 0, 0)
        return
    end

    -- Prevent players from bypassing party rules by trying to queue individually while in a group.
    -- This enforces that only party leaders can route the group via ManageParty.
    if MatchmakingSystem.State.PlayerPartyMap[player.UserId] then
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "You cannot queue individually while in a party.", 1.5, false, 0, 0)
        return
    end

    -- Preemptively remove the player from any existing queues to prevent ghost tickets or bugs.
    Core.RemoveFromQueues(player)

    -- If Solo mode is requested, the complex MemoryStore process is entirely bypassed.
    if mode == "Solo" then
        -- Notify the client that their solo game is immediately preparing.
        MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Preparing solo game...", nil, false, 1, 1)
        
        -- Instantly reserve a private server intended for a single occupant.
        local success, reservedCode = pcall(function() return TeleportService:ReserveServer(GAME_PLACE_ID) end)

        -- If reservation succeeds, teleport the solo player directly.
        if success and reservedCode then
            pcall(function() TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, reservedCode, {player}) end)
        else
            -- Handle potential reservation API failures.
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Teleport error, try again", 2, false, 0, 0)
        end
    else
        -- For multiplayer modes, prepare to interact with the respective MemoryStore SortedMap.
        local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
        -- Generate a unique chronological ticket key. Combining os.time() with a GUID ensures that 
        -- GetRangeAsync(Ascending) naturally retrieves older tickets first (FIFO algorithm) while avoiding collisions.
        local key = tostring(os.time()) .. "_" .. Core.GenerateId()

        -- Push the player's data into the global MemoryStore queue.
        local success = pcall(function()
            map:SetAsync(key, {
                PartyId = "Solo_" .. player.UserId, -- Generate a temporary pseudo-party ID for a solo player entering a multiplayer queue.
                Players = {player.UserId},          -- Array containing the player(s) tied to this specific ticket.
                ServerId = game.JobId,              -- Record the origin server's JobId for debugging or analytics.
                Mode = mode                         -- Explicitly embed the mode inside the ticket data.
            }, MatchmakingSystem.Config.QueueConfig.ExpirationTime) 
        end)

        -- If the MemoryStore insertion was successful and the network didn't fail:
        if success then
            -- Map the player's UserId to this ticket key in the local state, enabling them to cancel the queue later.
            MatchmakingSystem.State.ActiveQueueKeys[player.UserId] = {Mode = mode, Key = key}
            -- Inform the client they are officially queued, providing the current size (1) vs required size.
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Searching match: " .. mode, nil, true, 1, MatchmakingSystem.Config.Modes[mode].size)
        else
            -- If MemoryStore is down or rate limits are exceeded, notify the client.
            MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(player, "Matchmaking error", 2, false, 0, 0)
        end
    end
end)

--- Handler for all party management actions (Create, Leave, StartMatch).
MatchmakingSystem.Events.Server.ManageParty.OnServerEvent:Connect(function(player, action, data)
    local playerId = player.UserId

    if action == "Create" then
        -- Ignore the request if the player is already mapped to a party to prevent state duplication.
        if MatchmakingSystem.State.PlayerPartyMap[playerId] then return end
        -- Cancel any active solo queues before transitioning the player into a party state.
        Core.RemoveFromQueues(player)

        -- Generate a unique identifier for the newly formed party.
        local partyId = Core.GenerateId()
        -- Construct the party record in the state, automatically assigning the creator as the leader and initial member.
        MatchmakingSystem.State.Parties[partyId] = {
            LeaderUserId = playerId,
            MembersUserIds = {playerId},
            PartyId = partyId
        }
        -- Bind the player to this new party in the O(1) fast lookup dictionary.
        MatchmakingSystem.State.PlayerPartyMap[playerId] = partyId
        -- Sync this new data to the client so their UI updates to show the leader dashboard.
        Core.SyncPartyState(partyId)

    elseif action == "Leave" then
        -- Quickly fetch the Party ID associated with this player.
        local partyId = MatchmakingSystem.State.PlayerPartyMap[playerId]
        -- Defensive check: Abort if the party doesn't exist in server memory (e.g., due to desync).
        if not partyId or not MatchmakingSystem.State.Parties[partyId] then return end

        -- If the player was in a queue while inside the party, remove them from it before they leave.
        Core.RemoveFromQueues(player)

        local party = MatchmakingSystem.State.Parties[partyId]
        local newMembers = {}
        
        -- Rebuild the members array, deliberately omitting the player who is leaving.
        for _, mid in ipairs(party.MembersUserIds) do
            if mid ~= playerId then table.insert(newMembers, mid) end
        end

        -- Erase the player's party binding from the fast lookup dictionary.
        MatchmakingSystem.State.PlayerPartyMap[playerId] = nil
        -- Dispatch a 'nil' payload to the leaving client, which acts as a trigger to hide the party UI.
        MatchmakingSystem.Events.Client.UpdatePartyStatus:FireClient(player, nil)

        -- If the rebuilt array is empty (the last person left the party):
        if #newMembers == 0 then
            -- Completely garbage collect the party object from the server's local memory.
            MatchmakingSystem.State.Parties[partyId] = nil
        else
            -- If members remain, update the array with the reduced roster.
            party.MembersUserIds = newMembers
            -- If the departing player was the leader, automatically transfer leadership to the next player in the array.
            if party.LeaderUserId == playerId then party.LeaderUserId = newMembers[1] end
            -- Save the mutated data back into the global state.
            MatchmakingSystem.State.Parties[partyId] = party
            -- Synchronize the updated state (reduced roster, potential new leader) with the remaining members.
            Core.SyncPartyState(partyId)
        end
        
    elseif action == "StartMatch" then
        -- Retrieve the player's current party ID and the requested game mode.
        local partyId = MatchmakingSystem.State.PlayerPartyMap[playerId]
        local mode = data

        -- Security and Validation Checks before queuing:
        -- 1. Ensure the party actually exists in the server state.
        if not partyId or not MatchmakingSystem.State.Parties[partyId] then return end
        -- 2. Strictly enforce that ONLY the designated party leader can initiate matchmaking. Ignore member requests.
        if MatchmakingSystem.State.Parties[partyId].LeaderUserId ~= playerId then return end
        -- 3. Validate the mode exists and isn't "Solo" (parties cannot queue for solo).
        if not MatchmakingSystem.Config.Modes[mode] or mode == "Solo" then return end

        local party = MatchmakingSystem.State.Parties[partyId]
        -- 4. Ensure the current party size does not exceed the maximum allowed size for the requested mode.
        if #party.MembersUserIds > MatchmakingSystem.Config.Modes[mode].size then return end

        -- Arrays to collect verified player objects and their IDs.
        local pObjects, pIds = {}, {}
        for _, mid in ipairs(party.MembersUserIds) do
            local p = Players:GetPlayerByUserId(mid)
            -- If any member disconnected right as the match started, abort the process for the entire group.
            if not p then return end
            
            -- Cache the object and ID for the upcoming MemoryStore payload.
            table.insert(pObjects, p)
            table.insert(pIds, mid)
            
            -- Scrub each member to ensure they aren't stuck in any old, bugged queues.
            Core.RemoveFromQueues(p)
        end

        -- Prepare to write the group into the global MemoryStore.
        local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
        -- Utilize os.time() + GUID again to enforce proper FIFO sorting for the group ticket.
        local key = tostring(os.time()) .. "_" .. Core.GenerateId()

        -- Push the entire party into the queue as a single, inseparable ticket.
        local success = pcall(function()
            map:SetAsync(key, {
                PartyId = partyId,      -- Link the ticket to the actual Party ID.
                Players = pIds,         -- Store ALL member IDs so the Matchmaker properly calculates occupied slots.
                ServerId = game.JobId,
                Mode = mode
            }, MatchmakingSystem.Config.QueueConfig.ExpirationTime)
        end)

        -- If the party was successfully inserted into the global queue:
        if success then
            -- Sync the local state and UI for every member in the party.
            for _, p in ipairs(pObjects) do
                -- Bind all members to the EXACT SAME ticket key. If one presses cancel, the entire ticket is removed.
                MatchmakingSystem.State.ActiveQueueKeys[p.UserId] = {Mode = mode, Key = key}
                -- Inform the clients about the search status, displaying that N slots (their party size) are already filled.
                MatchmakingSystem.Events.Client.UpdateMatchmakingStatus:FireClient(p, "Searching match: " .. mode, nil, true, #pIds, MatchmakingSystem.Config.Modes[mode].size)
            end
        end
    end
end)
