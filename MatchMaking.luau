-- Discord: Yaxnen Roblox: fhyuyuuy2
-- MatchmakingServer

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

local GAME_PLACE_ID = 87948231310659 

local requestPlayModeEvent = ReplicatedStorage:WaitForChild("RequestPlayMode")
local managePartyEvent = ReplicatedStorage:WaitForChild("ManageParty")
local updateClientPartyStatusEvent = ReplicatedStorage:WaitForChild("UpdateClientPartyStatus")
local updateClientMatchmakingStatusEvent = ReplicatedStorage:WaitForChild("UpdateClientMatchmakingStatus")
local sendPartyInviteEvent = ReplicatedStorage:WaitForChild("SendPartyInvite")
local acceptPartyInviteEvent = ReplicatedStorage:WaitForChild("AcceptPartyInvite")

if not ReplicatedStorage:FindFirstChild("ReceivePartyInvite") then
	local receivePartyInviteEvent = Instance.new("RemoteEvent")
	receivePartyInviteEvent.Name = "ReceivePartyInvite"
	receivePartyInviteEvent.Parent = ReplicatedStorage
end
local receivePartyInviteEvent = ReplicatedStorage:WaitForChild("ReceivePartyInvite")

if not ReplicatedStorage:FindFirstChild("CancelMatchmaking") then
	local cancelMatchmakingEvent = Instance.new("RemoteEvent")
	cancelMatchmakingEvent.Name = "CancelMatchmaking"
	cancelMatchmakingEvent.Parent = ReplicatedStorage
end
local cancelMatchmakingEvent = ReplicatedStorage:WaitForChild("CancelMatchmaking")

local parties = {}
local playerPartyMap = {}
local pendingInvites = {}

local activeQueueKeys = {}

local MODE_CONFIG = {
	Solo = {size = 1},
	Duo = {size = 2},
	Trio = {size = 3},
	Squad = {size = 4}
}

--Party id

local function generatePartyId()
	return HttpService:GenerateGUID(false)
end

--Party status update
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


--exit queue
local function removePlayerFromAllQueues(player)
	if not player then return end

	local qInfo = activeQueueKeys[player.UserId]
	if qInfo then
		local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. qInfo.Mode)
		pcall(function() map:RemoveAsync(qInfo.Key) end)

		local usersToClean = {}
		for uid, info in pairs(activeQueueKeys) do
			if info.Key == qInfo.Key then
				table.insert(usersToClean, uid)
			end
		end

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


--crossserver 
MessagingService:SubscribeAsync("CrossServerMatchFound", function(message)
	local data = message.Data
	local reservedCode = data.ReservedCode
	local tickets = data.Tickets

	local playersToTeleport = {}

	for _, ticket in ipairs(tickets) do
		for _, userId in ipairs(ticket.Players) do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(playersToTeleport, player)
			end
		end
	end
	if #playersToTeleport > 0 then
		for _, p in ipairs(playersToTeleport) do
			activeQueueKeys[p.UserId] = nil 
			updateClientMatchmakingStatusEvent:FireClient(p, "Game found! Teleporting...", nil, false, 0, 0)
		end

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

--queue check
local function hasLocalPlayersInQueue(mode)
	for _, info in pairs(activeQueueKeys) do
		if info.Mode == mode then return true end
	end
	return false
end

--matchmaking

local function tryMatchmake(mode)
	local map = MemoryStoreService:GetSortedMap("Matchmaking_" .. mode)
	local requiredSize = MODE_CONFIG[mode].size

	local success, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)

	if not success or not items then return end

	local availableTickets = {}
	local totalPlayers = 0

	for _, item in ipairs(items) do
		if not item.value.ClaimedBy then
			table.insert(availableTickets, {key = item.key, value = item.value})
			totalPlayers = totalPlayers + #item.value.Players
		end
	end

	for uid, qInfo in pairs(activeQueueKeys) do
		if qInfo.Mode == mode then
			local p = Players:GetPlayerByUserId(uid)
			if p then
				local displayPlayers = math.min(totalPlayers, requiredSize)
				updateClientMatchmakingStatusEvent:FireClient(p, "Searching match: " .. mode, nil, true, displayPlayers, requiredSize)
			end
		end
	end

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

	if match then
		local claimedTickets = {}
		local allClaimed = true

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

task.spawn(function()
	while task.wait(5) do
		for mode, _ in pairs(MODE_CONFIG) do
			if mode ~= "Solo" and hasLocalPlayersInQueue(mode) then
				tryMatchmake(mode)
			end
		end
	end
end)

--game mode request

requestPlayModeEvent.OnServerEvent:Connect(function(player, mode)
	if not MODE_CONFIG[mode] then
		updateClientMatchmakingStatusEvent:FireClient(player, "Invalid game mode", 1.5, false, 0, 0)
		return
	end

	if playerPartyMap[player.UserId] then
		updateClientMatchmakingStatusEvent:FireClient(player, "You cannot queue individually while in a party. Leave the party.", 1.5, false, 0, 0)
		return
	end

	removePlayerFromAllQueues(player)

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

--party manage

managePartyEvent.OnServerEvent:Connect(function(player, action, data)
	local playerId = player.UserId

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

		if partySize > requiredSize then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: Too many players for " .. mode, 1, false, 0, 0)
			return
		end
		if mode == "Solo" then
			updateClientMatchmakingStatusEvent:FireClient(player, "Error: Cannot start solo game in a party", 1, false, 0, 0)
			return
		end

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

--party events
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

	task.delay(15, function()
		if pendingInvites[targetUserId] and pendingInvites[targetUserId][player.UserId] == partyId then
			pendingInvites[targetUserId][player.UserId] = nil
		end
	end)
end)

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

--search cancel

cancelMatchmakingEvent.OnServerEvent:Connect(function(player)
	removePlayerFromAllQueues(player)
end)

--player join

Players.PlayerAdded:Connect(function(player)
	local partyId = playerPartyMap[player.UserId]
	if partyId and parties[partyId] then
		updateClientPartyStatusEvent:FireClient(player, parties[partyId])
	else
		updateClientPartyStatusEvent:FireClient(player, nil)
	end
end)

--player exit

Players.PlayerRemoving:Connect(function(player)
	local playerId = player.UserId
	removePlayerFromAllQueues(player)

	for targetUserId, invitesFromSender in pairs(pendingInvites) do
		if invitesFromSender[playerId] then invitesFromSender[playerId] = nil end
	end
	pendingInvites[playerId] = nil

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