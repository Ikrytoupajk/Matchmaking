-- Discord: Yaxnen Roblox: fhyuyuuy2
-- MatchmakingServer

-- SERVICES & CONSTANTS

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

-- Target place ID for game instances
local GAME_PLACE_ID = 87948231310659 

-- REMOTE EVENTS SETUP

local requestPlayModeEvent = ReplicatedStorage:WaitForChild("RequestPlayMode")
local managePartyEvent = ReplicatedStorage:WaitForChild("ManageParty")
local updateClientPartyStatusEvent = ReplicatedStorage:WaitForChild("UpdateClientPartyStatus")
local updateClientMatchmakingStatusEvent = ReplicatedStorage:WaitForChild("UpdateClientMatchmakingStatus")
local sendPartyInviteEvent = ReplicatedStorage:WaitForChild("SendPartyInvite")
local acceptPartyInviteEvent = ReplicatedStorage:WaitForChild("AcceptPartyInvite")
local receivePartyInviteEvent = ReplicatedStorage:WaitForChild("ReceivePartyInvite")
local cancelMatchmakingEvent = ReplicatedStorage:WaitForChild("CancelMatchmaking")

-- DATA STORAGE & STATE MANAGEMENT

local parties = {}              -- Stores party details
local playerPartyMap = {}       -- Fast lookup map
local pendingInvites = {}       -- Active invites
local activeQueueKeys = {}      -- Tracks active queue tickets

-- Game mode configurations and required player counts
local MODE_CONFIG = {
	Solo = {size = 1},
	Duo = {size = 2},
	Trio = {size = 3},
	Squad = {size = 4}
}

-- HELPER FUNCTIONS

--- Generates a unique Identifier (GUID) for a newly created party
local function generatePartyId()
	return HttpService:GenerateGUID(false)
end

--- Synchronizes and sends updated party state to all online party members
local function updatePartyForMembers(partyId)
	local partyData = parties[partyId]
	if partyData then
		for _, memberId in ipairs(partyData.MembersUserIds) do
			local memberPlayer = Players:GetPlayerByUserId(memberId)
			if memberPlayer then
				updateClientPartyStatusEvent:FireClient(memberPlayer, partyData)
			end
		end
	end
end

--- Cancels matchmaking for a player (and their entire party if queued together),

--- removes their entry from MemoryStore, and updates client UI.
local function removePlayerFromAllQueues(player)
	if not player then return end

	local qInfo = activeQueueKeys[player.UserId]
	if qInfo then
		-- Remove ticket from MemoryStore SortedMap
		local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. qInfo.Mode)
		pcall(function() map:RemoveAsync(qInfo.Key) end)

		-- Identify all local players associated with this queue ticket
		local usersToClean = {}
		for uid, info in pairs(activeQueueKeys) do
			if info.Key == qInfo.Key then
				table.insert(usersToClean, uid)
			end
		end

		-- Clear state and notify clients
		for _, uid in ipairs(usersToClean) do
			activeQueueKeys[uid] = nil
			local p = Players:GetPlayerByUserId(uid)
			if p then
				if p.UserId == player.UserId then
					updateClientMatchmakingStatusEvent:FireClient(p, "Matchmaking canceled", 1, false, 0, 0)
				else
					updateClientMatchmakingStatusEvent:FireClient(p, "Party member canceled matchmaking", 3, false, 0, 0)
				end
			end
		end
	end
end

-- CROSS-SERVER TELEPORT HANDLER

-- Subscribes to MessagingService to handle matched games across all server instances
MessagingService:SubscribeAsync("CrossServerMatchFound", function(message)
	local data = message.Data
	local reservedCode = data.ReservedCode
	local tickets = data.Tickets

	local playersToTeleport = {}

	-- Gather all local player instances that are part of the matched tickets
	for _, ticket in ipairs(tickets) do
		for _, userId in ipairs(ticket.Players) do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(playersToTeleport, player)
			end
		end
	end

	-- Process teleportation if local players were found on this server
	if #playersToTeleport > 0 then
		for _, p in ipairs(playersToTeleport) do
			activeQueueKeys[p.UserId] = nil 
			updateClientMatchmakingStatusEvent:FireClient(p, "Game found! Teleporting...", nil, false, 0, 0)
		end

		-- Teleport all matched players to the reserved private server
		local success, result = pcall(function()
			TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, reservedCode, playersToTeleport)
		end)

		if not success then
			warn("Teleport failed: " .. tostring(result))
			for _, p in ipairs(playersToTeleport) do
				updateClientMatchmakingStatusEvent:FireClient(p, "Teleport error: " .. tostring(result), 5, false, 0, 0)
			end
		end
	end
end)

--- Checks if there are any players currently queuing on this specific server instance
local function hasLocalPlayersInQueue(mode)
	for _, info in pairs(activeQueueKeys) do
		if info.Mode == mode then return true end
	end
	return false
end

-- MATCHMAKING LOGIC

-- Searches MemoryStore for queued players and attempts to group them into matches
local function tryMatchmake(mode)
	local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
	local requiredSize = MODE_CONFIG[mode].size

	-- Fetch queued tickets from MemoryStore
	local success, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)

	if not success or not items then return end

	local availableTickets = {}
	local totalPlayers = 0

	-- Filter out tickets that are already claimed by another server instance
	for _, item in ipairs(items) do
		if not item.value.ClaimedBy then
			table.insert(availableTickets, {key = item.key, value = item.value})
			totalPlayers = totalPlayers + #item.value.Players
		end
	end

	-- Update status UI for local players currently waiting in queue
	for uid, qInfo in pairs(activeQueueKeys) do
		if qInfo.Mode == mode then
			local p = Players:GetPlayerByUserId(uid)
			if p then
				local displayPlayers = math.min(totalPlayers, requiredSize)
				updateClientMatchmakingStatusEvent:FireClient(p, "Searching match: " .. mode, nil, true, displayPlayers, requiredSize)
			end
		end
	end

	--- Algorithm to find a combination of queue tickets that equals the required game mode size
	local function findMatch()
		for i = 1, #availableTickets do
			local currentGroup = {availableTickets[i]}
			local currentSize = #availableTickets[i].value.Players

			if currentSize == requiredSize then return currentGroup end

			for j = i + 1, #availableTickets do
				local nextSize = #availableTickets[j].value.Players
				if currentSize + nextSize <= requiredSize then
					table.insert(currentGroup, availableTickets[j])
					currentSize = currentSize + nextSize
				end
				if currentSize == requiredSize then return currentGroup end
			end
		end
		return nil
	end

	local match = findMatch()

	-- Process match if a valid combination of tickets was formed
	if match then
		local claimedTickets = {}
		local allClaimed = true

		-- Atomically claim tickets using UpdateAsync to prevent race conditions with other servers
		for _, ticket in ipairs(match) do
			local claimed = false
			pcall(function()
				local newValue = map:UpdateAsync(ticket.key, function(val)
					if val and not val.ClaimedBy then
						val.ClaimedBy = game.JobId 
						return val
					end
					return nil 
				end, 600)

				if newValue and newValue.ClaimedBy == game.JobId then
					claimed = true
				end
			end)

			if claimed then
				table.insert(claimedTickets, ticket)
			else
				allClaimed = false
				break
			end
		end

		-- If all tickets were successfully claimed, reserve a server and notify all game instances
		if allClaimed then
			local resSuccess, reservedCode = pcall(function()
				return TeleportService:ReserveServer(GAME_PLACE_ID)
			end)

			if resSuccess and reservedCode then
				local ticketsData = {}
				for _, ct in ipairs(claimedTickets) do
					table.insert(ticketsData, {Players = ct.value.Players})
					pcall(function() map:RemoveAsync(ct.key) end)
				end

				-- Broadcast match data across all server instances
				pcall(function()
					MessagingService:PublishAsync("CrossServerMatchFound", {
						ReservedCode = reservedCode,
						Mode = mode,
						Tickets = ticketsData
					})
				end)
			else
				allClaimed = false
			end
		end

		-- Rollback ticket claims if match allocation failed halfway
		if not allClaimed then
			for _, ct in ipairs(claimedTickets) do
				pcall(function()
					map:UpdateAsync(ct.key, function(val)
						if val and val.ClaimedBy == game.JobId then
							val.ClaimedBy = nil
							return val
						end
						return nil
					end, 600)
				end)
			end
		end
	end
end

-- Background loop to process matchmaking queues every 5 seconds
task.spawn(function()
	while task.wait(5) do
		for mode, _ in pairs(MODE_CONFIG) do
			if mode ~= "Solo" and hasLocalPlayersInQueue(mode) then
				tryMatchmake(mode)
			end
		end
	end
end)

-- CLIENT EVENT HANDLERS

--- Handles direct queue requests from individual players
requestPlayModeEvent.OnServerEvent:Connect(function(player, mode)
	if not MODE_CONFIG[mode] then
		updateClientMatchmakingStatusEvent:FireClient(player, "Invalid game mode", 1.5, false, 0, 0)
		return
	end

	-- Prevent queuing individually if already part of a party
	if playerPartyMap[player.UserId] then
		updateClientMatchmakingStatusEvent:FireClient(player, "You cannot queue individually while in a party. Leave the party.", 1.5, false, 0, 0)
		return
	end

	removePlayerFromAllQueues(player)

	-- Handle Solo mode 
	if mode == "Solo" then
		updateClientMatchmakingStatusEvent:FireClient(player, "Preparing solo game...", nil, false, 1, 1)
		local success, reservedCode = pcall(function()
			return TeleportService:ReserveServer(GAME_PLACE_ID)
		end)

		if success and reservedCode then
			pcall(function()
				TeleportService:TeleportToPrivateServer(GAME_PLACE_ID, reservedCode, {player})
			end)
		else
			updateClientMatchmakingStatusEvent:FireClient(player, "Teleport error, try again", 2, false, 0, 0)
		end
	else
		-- Add individual player to MemoryStore queue for multi-player modes
		local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
		local key = tostring(os.time()) .. "_" .. HttpService:GenerateGUID(false)

		local success = pcall(function()
			map:SetAsync(key, {
				PartyId = "Solo_" .. player.UserId,
				Players = {player.UserId},
				ServerId = game.JobId,
				Mode = mode
			}, 600) 
		end)

		if success then
			activeQueueKeys[player.UserId] = {Mode = mode, Key = key}
			updateClientMatchmakingStatusEvent:FireClient(player, "Searching match: " .. mode, nil, true, 1, MODE_CONFIG[mode].size)
		else
			updateClientMatchmakingStatusEvent:FireClient(player, "Matchmaking error, try again", 2, false, 0, 0)
		end
	end
end)

--- Handles party actions: Create, Leave, Kick, StartMatch
managePartyEvent.OnServerEvent:Connect(function(player, action, data)
	local playerId = player.UserId

	-- Party Creation
	if action == "Create" then
		if playerPartyMap[playerId] then
			updateClientPartyStatusEvent:FireClient(player, parties[playerPartyMap[playerId]])
			updateClientMatchmakingStatusEvent:FireClient(player, "You are already in a party", 1, false, 0, 0)
			return
		end
		removePlayerFromAllQueues(player)

		local partyId = generatePartyId()
		parties[partyId] = {
			LeaderUserId = playerId,
			MembersUserIds = {playerId},
			PartyId = partyId
		}
		playerPartyMap[playerId] = partyId
		updatePartyForMembers(partyId)

		-- Leaving a Party
	elseif action == "Leave" then
		local partyId = playerPartyMap[playerId]
		if not partyId or not parties[partyId] then return end

		removePlayerFromAllQueues(player)

		local party = parties[partyId]
		local newMembers = {}
		for _, memberId in ipairs(party.MembersUserIds) do
			if memberId ~= playerId then
				table.insert(newMembers, memberId)
			end
		end

		playerPartyMap[playerId] = nil
		updateClientPartyStatusEvent:FireClient(player, nil)

		-- Disband party if empty, otherwise transfer leadership if leader left
		if #newMembers == 0 then
			parties[partyId] = nil
		else
			party.MembersUserIds = newMembers
			if party.LeaderUserId == playerId then
				party.LeaderUserId = newMembers[1]
			end
			parties[partyId] = party
			updatePartyForMembers(partyId)
		end

		-- Kicking a Player from Party
	elseif action == "Kick" then
		local targetUserId = data
		local partyId = playerPartyMap[playerId]

		if not partyId or not parties[partyId] or parties[partyId].LeaderUserId ~= playerId then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: You are not the party leader", 1.5, false, 0, 0)
			return
		end

		local party = parties[partyId]
		local newMembers = {}
		local kickedPlayer = Players:GetPlayerByUserId(targetUserId)
		local kicked = false

		for _, memberId in ipairs(party.MembersUserIds) do
			if memberId ~= targetUserId then
				table.insert(newMembers, memberId)
			else
				kicked = true
			end
		end

		if kicked then
			party.MembersUserIds = newMembers
			playerPartyMap[targetUserId] = nil
			if kickedPlayer then removePlayerFromAllQueues(kickedPlayer) end

			updateClientMatchmakingStatusEvent:FireClient(player, "Player was kicked from the party", 2, false, 0, 0)
			if kickedPlayer and kickedPlayer.Parent then
				updateClientPartyStatusEvent:FireClient(kickedPlayer, nil)
				updateClientMatchmakingStatusEvent:FireClient(kickedPlayer, "You were kicked from the party", 1, false, 0, 0)
			end

			parties[partyId] = party
			updatePartyForMembers(partyId)
		end

		-- Starting Matchmaking for the entire Party
	elseif action == "StartMatch" then
		local partyId = playerPartyMap[playerId]
		local mode = data

		if not partyId or not parties[partyId] or parties[partyId].LeaderUserId ~= playerId then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: You are not the party leader", 1, false, 0, 0)
			return
		end
		if not mode or not MODE_CONFIG[mode] then
			return
		end

		local party = parties[partyId]
		local partySize = #party.MembersUserIds
		local requiredSize = MODE_CONFIG[mode].size

		-- Validation checks
		if partySize > requiredSize then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: Too many players for " .. mode, 1, false, 0, 0)
			return
		end
		if mode == "Solo" then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: Cannot start solo game in a party", 1, false, 0, 0)
			return
		end

		-- Gather all party member player instances
		local playersInPartyObjects = {}
		local playerIds = {}
		for _, memberId in ipairs(party.MembersUserIds) do
			local memberPlayer = Players:GetPlayerByUserId(memberId)
			if memberPlayer and memberPlayer.Parent then
				table.insert(playersInPartyObjects, memberPlayer)
				table.insert(playerIds, memberId)
				removePlayerFromAllQueues(memberPlayer)
			else
				updateClientMatchmakingStatusEvent:FireClient(player, "Error: A party member is missing", 1, false, 0, 0)
				return
			end
		end

		-- Add the party to MemoryStore queue
		local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
		local key = tostring(os.time()) .. "_" .. HttpService:GenerateGUID(false)

		local success = pcall(function()
			map:SetAsync(key, {
				PartyId = partyId,
				Players = playerIds,
				ServerId = game.JobId,
				Mode = mode
			}, 600)
		end)

		if success then
			for _, pObj in ipairs(playersInPartyObjects) do
				activeQueueKeys[pObj.UserId] = {Mode = mode, Key = key}
				updateClientMatchmakingStatusEvent:FireClient(pObj, "Searching match: " .. mode, nil, true, #playerIds, requiredSize)
			end
		else
			for _, pObj in ipairs(playersInPartyObjects) do
				updateClientMatchmakingStatusEvent:FireClient(pObj, "Matchmaking error, try again", 2, false, 0, 0)
			end
		end
	end
end)

-- PARTY INVITE SYSTEM

--- Sends a party invitation to a specified target player
sendPartyInviteEvent.OnServerEvent:Connect(function(player, targetUserId)
	local partyId = playerPartyMap[player.UserId]
	if not partyId or not parties[partyId] or parties[partyId].LeaderUserId ~= player.UserId then return end

	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer or not targetPlayer.Parent or playerPartyMap[targetUserId] then return end

	if #parties[partyId].MembersUserIds >= MODE_CONFIG.Squad.size then return end

	if not pendingInvites[targetUserId] then pendingInvites[targetUserId] = {} end
	pendingInvites[targetUserId][player.UserId] = partyId

	receivePartyInviteEvent:FireClient(targetPlayer, player.UserId, player.Name)
	updateClientMatchmakingStatusEvent:FireClient(player, "Invitation sent to " .. targetPlayer.Name, 1, false, 0, 0)

	-- Auto-expire invitation after 15 seconds
	task.delay(15, function()
		if pendingInvites[targetUserId] and pendingInvites[targetUserId][player.UserId] == partyId then
			pendingInvites[targetUserId][player.UserId] = nil
		end
	end)
end)

--- Processes invite acceptance and rejection from the invitee
acceptPartyInviteEvent.OnServerEvent:Connect(function(player, senderUserId, accepted)
	local playerId = player.UserId
	local senderPartyId = nil

	if pendingInvites[playerId] and pendingInvites[playerId][senderUserId] then
		senderPartyId = pendingInvites[playerId][senderUserId]
		pendingInvites[playerId][senderUserId] = nil
	end

	if accepted and senderPartyId and parties[senderPartyId] then
		local senderParty = parties[senderPartyId]
		if playerPartyMap[playerId] or #senderParty.MembersUserIds >= MODE_CONFIG.Squad.size then return end

		removePlayerFromAllQueues(player)
		local senderLeader = Players:GetPlayerByUserId(senderParty.LeaderUserId)
		if senderLeader then removePlayerFromAllQueues(senderLeader) end

		table.insert(senderParty.MembersUserIds, playerId)
		playerPartyMap[playerId] = senderPartyId
		parties[senderPartyId] = senderParty

		updatePartyForMembers(senderPartyId)
		updateClientMatchmakingStatusEvent:FireClient(player, "You joined the party", 0.5, false, 0, 0)
	end
end)

--- Cancels matchmaking queue search upon client request
cancelMatchmakingEvent.OnServerEvent:Connect(function(player)
	removePlayerFromAllQueues(player)
end)

-- PLAYER LIFECYCLE HANDLERS

--- Sync party state when player connects to the server
Players.PlayerAdded:Connect(function(player)
	local partyId = playerPartyMap[player.UserId]
	if partyId and parties[partyId] then
		updateClientPartyStatusEvent:FireClient(player, parties[partyId])
	else
		updateClientPartyStatusEvent:FireClient(player, nil)
	end
end)

--- Cleanup queue tickets, invites, and party structure when player leaves
Players.PlayerRemoving:Connect(function(player)
	local playerId = player.UserId
	removePlayerFromAllQueues(player)

	-- Clear pending invites sent by or to the player
	for targetUserId, invitesFromSender in pairs(pendingInvites) do
		if invitesFromSender[playerId] then invitesFromSender[playerId] = nil end
	end
	pendingInvites[playerId] = nil

	-- Handle party restructuring or cleanup on disconnect
	local partyId = playerPartyMap[playerId]
	if partyId and parties[partyId] then
		local party = parties[partyId]
		local newMembers = {}
		for _, memberId in ipairs(party.MembersUserIds) do
			if memberId ~= playerId then table.insert(newMembers, memberId) end
		end
		playerPartyMap[playerId] = nil

		if #newMembers == 0 then
			parties[partyId] = nil
		else
			party.MembersUserIds = newMembers
			if party.LeaderUserId == playerId then party.LeaderUserId = newMembers[1] end
			parties[partyId] = party
			updatePartyForMembers(partyId)
		end
	end
end)
