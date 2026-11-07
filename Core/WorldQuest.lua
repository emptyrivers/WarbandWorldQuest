local _, ns = ...

local Util = ns.Util
local RewardTypes = ns.RewardTypes

-- ID, resetTime, map, x, y
local WorldQuest = {
	nameCache = {},
	positionCache = {},
	eligibilityCache = {},
	lockedNameCache = {},
}
WorldQuest.__index = WorldQuest

function WorldQuest:Create(info)
	local o = {
		ID = info.questID,
		map = info.mapID,
		x = info.x,
		y = info.y,
	}

	setmetatable(o, self)

	if not HaveQuestRewardData(o.ID) then
		C_TaskQuest.RequestPreloadRewardData(o.ID)
		Util:Debug("Reward data is not available", o.ID, o:GetName(), C_TaskQuest.GetQuestTimeLeftSeconds(o.ID))
		return
	end

	o:UpdateFirstCompletionBonus()

	return o
end

function WorldQuest:UpdateResetTime()
	local secondsLeft = C_TaskQuest.GetQuestTimeLeftSeconds(self.ID)
	local estimated

	-- locked Special Assignments have no time left, but end at one of the next two half-week boundaries
	if secondsLeft == nil and self:IsPlayerLocked() then
		local secondsToReset = C_DateAndTime.GetSecondsUntilWeeklyReset()

		secondsLeft = secondsToReset > 302400 and secondsToReset or secondsToReset + 302400
		estimated = true
	end

	if secondsLeft == nil then
		return false
	end

	self.resetTime = GetServerTime() + secondsLeft
	self.isResetTimeEstimated = estimated

	return true
end

function WorldQuest:UpdateFirstCompletionBonus(force)
	if not HaveQuestRewardData(self.ID) or not C_QuestLog.QuestContainsFirstTimeRepBonusForPlayer(self.ID) then
		return
	end

	if not force and self.currencies then
		return
	end

	local factionID = select(2, C_TaskQuest.GetQuestInfoByQuestID(self.ID))

	local currencies = {}

	for _, currency in ipairs(C_QuestInfoSystem.GetQuestRewardCurrencies(self.ID) or {}) do
		if currency.questRewardContextFlags == Enum.QuestRewardContextFlags.FirstCompletionBonus and currency.totalRewardAmount > 15 then
			table.insert(currencies, { currency.currencyID, currency.totalRewardAmount })
		end
	end

	if #currencies == 0 then
		local factionCurrency = Util:GetFactionCurrencyID(factionID)
		if factionCurrency ~= nil then
			table.insert(currencies, { factionCurrency, 50 * Util:GetFactionReputationBonusMultiplier(factionID) })
		end
	end

	if #currencies > 0 then
		self.currencies = currencies
	end

	Util:Debug("Updated FirstCompletionBonus:", self.ID, self:GetName(), factionID, #currencies, unpack(currencies[1] or {}))
end

function WorldQuest:IsFirstCompletionBonusClaimed()
	if HaveQuestRewardData(self.ID) then
		return not C_QuestLog.QuestContainsFirstTimeRepBonusForPlayer(self.ID)
	else
		return C_QuestLog.IsQuestFlaggedCompletedOnAccount(self.ID)
	end
end

function WorldQuest:GetName()
	if self.nameCache[self.ID] then
		return self.nameCache[self.ID]
	end

	self.nameCache[self.ID] = C_TaskQuest.GetQuestInfoByQuestID(self.ID)

	return self.nameCache[self.ID] or ""
end

function WorldQuest:GetQuestPOIMapInfo()
	return {
		questID = self.ID,
		mapID = self.map,
		x = self.x,
		y = self.y,
		numObjectives = 1,
	}
end

function WorldQuest:GetPositionOnMap(mapID)
	self.positionCache[self] = self.positionCache[self] or {}

	if self.positionCache[self][mapID] == nil then
		local mapGroup = C_Map.GetMapGroupID(self.map)
		if (mapGroup and mapGroup == C_Map.GetMapGroupID(mapID)) or mapID == self.map then
			self.positionCache[self][mapID] = { self.x, self.y }
		else
			local xMin, xMax, yMin, yMax = C_Map.GetMapRectOnMap(self.map, mapID)

			if xMin == xMax and yMin == yMax then
				self.positionCache[self][mapID] = {}
			else
				local x = xMin + self.x * (xMax - xMin)
				local y = yMin + self.y * (yMax - yMin)

				self.positionCache[self][mapID] = { x, y }
			end
		end
	end

	return self.positionCache[self][mapID]
end

function WorldQuest:IsCompleted()
	return C_QuestLog.IsQuestFlaggedCompleted(self.ID)
end

function WorldQuest:SetTracked(tracked)
	self:SetWarbandTracked(tracked)

	if tracked then
		QuestUtil.TrackWorldQuest(self.ID, Enum.QuestWatchType.Manual)
	else
		QuestUtil.UntrackWorldQuest(self.ID)
	end
end

-- true: tracked by the warband, false: untracked by the warband, nil: never tracked
function WorldQuest:SetWarbandTracked(tracked)
	self.tracked = tracked
end

function WorldQuest:SyncWarbandTracking()
	if self.tracked == nil or not self:IsPlayerEligible() or self:IsCompleted() then
		return
	end

	local isManual = C_QuestLog.GetQuestWatchType(self.ID) == Enum.QuestWatchType.Manual

	if self.tracked and not isManual then
		C_QuestLog.AddWorldQuestWatch(self.ID, Enum.QuestWatchType.Manual)
	elseif not self.tracked and isManual then
		C_QuestLog.RemoveWorldQuestWatch(self.ID)
	end
end

-- same rule as WorldMap_IsWorldQuestEffectivelyTracked
function WorldQuest:IsTracked()
	local watchType = C_QuestLog.GetQuestWatchType(self.ID)

	return watchType == Enum.QuestWatchType.Manual or (watchType == Enum.QuestWatchType.Automatic and C_SuperTrack.GetSuperTrackedQuestID() == self.ID)
end

function WorldQuest:SetInactive(inactive)
	self.inactive = inactive or nil

	if inactive and (self.tracked or self:IsTracked()) then
		self:SetTracked(false)
	end
end

function WorldQuest:IsInactive()
	return self.inactive or false
end

function WorldQuest:MarkPlayerEligibleForQuest(questID)
	self.eligibilityCache[questID] = true
end

function WorldQuest:IsPlayerEligible()
	return self.eligibilityCache[self.ID] ~= nil
end

-- locked Special Assignments are area POIs without a quest ID, so they can only be matched by name
function WorldQuest:IsPlayerLocked()
	return self.lockedNameCache[self:GetName()] ~= nil
end

local mapNames = {}

local function GetMapName(mapID)
	if mapNames[mapID] == nil then
		mapNames[mapID] = (C_Map.GetMapInfo(mapID) or {}).name or ""
	end

	return mapNames[mapID]
end

local function CompareMaps(x, y)
	if x.map == y.map then
		return
	end

	local xName, yName = GetMapName(x.map), GetMapName(y.map)
	if xName ~= yName then
		return xName < yName
	end

	return x.map < y.map
end

-- quests expiring together get reset times a few seconds apart from when they were scanned
local function CompareResetTimes(x, y)
	local xHour, yHour = math.floor(x.resetTime / 3600), math.floor(y.resetTime / 3600)
	if xHour ~= yHour then
		return xHour < yHour
	end
end

local function CompareNames(x, y)
	if x:GetName() ~= y:GetName() then
		return x:GetName() < y:GetName()
	end
end

local sortOrders = {
	ZONE = { CompareMaps, CompareResetTimes, CompareNames },
	TIME_LEFT = { CompareResetTimes, CompareMaps, CompareNames },
	NAME = { CompareNames, CompareMaps, CompareResetTimes },
}

local WorldQuestList = {
	questCache = {},
	mapCache = {},
	questsOnMap = {},
	isScanSessionCompleted = nil,
	childMapsCache = {},
	specialAssignmentCache = {},
}

function WorldQuestList:Load(quests, resetStartTime)
	self.quests = quests
	self.resetStartTime = resetStartTime

	for _, quest in ipairs(self.quests) do
		setmetatable(quest, WorldQuest)
		self:CacheQuest(quest)
	end
end

function WorldQuestList:CacheQuest(quest)
	self.questCache[quest.ID] = quest

	self.mapCache[quest.map] = self.mapCache[quest.map] or {}
	table.insert(self.mapCache[quest.map], quest)

	quest:GetName()
end

function WorldQuestList:GetAllQuests()
	return self.quests
end

function WorldQuestList.CreateComparator(sortOrder)
	local comparators = sortOrders[sortOrder] or sortOrders.TIME_LEFT

	return function(x, y)
		for _, compare in ipairs(comparators) do
			local result = compare(x, y)
			if result ~= nil then
				return result
			end
		end

		return x.ID < y.ID
	end
end

-- param: QuestPOIMapInfo
function WorldQuestList:AddQuest(info)
	local quest = WorldQuest:Create(info)
	if quest == nil then
		return
	end

	if not quest:UpdateResetTime() then
		Util:Debug("Ignored quest due to unknown resetTime", quest.ID, quest:GetName())
		return true
	end

	table.insert(self.quests, quest)
	self:CacheQuest(quest)

	Util:Debug("Found quest", quest.ID, quest:GetName())

	return true
end

function WorldQuestList:IsActiveQuest(questID)
	return self.questCache[questID] ~= nil
end

function WorldQuestList:GetQuest(questID)
	return self.questCache[questID]
end

function WorldQuestList:GetQuestsByMapID(mapID)
	return self.mapCache[mapID]
end

function WorldQuestList:NextResetQuests(excludeTags, excludeMaps)
	excludeTags = excludeTags or {}
	excludeMaps = excludeMaps or {}

	local quests = Util:Filter(self.quests, function(quest)
		return not excludeTags[C_QuestLog.GetQuestTagInfo(quest.ID).worldQuestType] and not excludeMaps[quest.map]
	end)

	if #quests == 0 then
		return {}
	end

	local resetTime = quests[1].resetTime
	quests = Util:Filter(quests, function(quest)
		return math.abs(quest.resetTime - resetTime) < 60
	end)

	table.sort(quests, function(x, y)
		return x.map < y.map
	end)

	return quests, resetTime
end

function WorldQuestList:GetQuestsOnContinent(mapID)
	if self.questsOnMap[mapID] == nil then
		self.questsOnMap[mapID] = {}

		local quests = C_Map.GetMapInfo(mapID).mapType == Enum.UIMapType.Continent and self:GetAllQuests() or {}

		for _, quest in ipairs(quests) do
			local position = quest:GetPositionOnMap(mapID)
			if #position > 0 then
				self.questsOnMap[mapID][position] = quest
			end
		end
	end

	return self.questsOnMap[mapID]
end

function WorldQuestList:RemoveQuests(maps)
	local mapsByID = {}

	for _, map in ipairs(maps) do
		mapsByID[map.mapID] = true
	end

	for i = #self.quests, 1, -1 do
		local quest = self.quests[i]

		if mapsByID[quest.map] then
			self.questCache[quest.ID] = nil
			table.remove(self.quests, i)
		end
	end
end

function WorldQuestList:PopulateQuestsToScan(continents, character)
	self.pendingQuests = self.pendingQuests or {}

	if next(self.pendingQuests) ~= nil then
		return
	end

	local mapsToScan = {}
	local mapsToRemove = {}

	Util:Debug("Populating maps to scan")
	for mapID, shouldScan in pairs(continents) do
		if self.childMapsCache[mapID] == nil then
			self.childMapsCache[mapID] = C_Map.GetMapChildrenInfo(mapID, Enum.UIMapType.Zone, true)
		end

		local maps = shouldScan and mapsToScan or mapsToRemove
		for _, map in ipairs(self.childMapsCache[mapID]) do
			table.insert(maps, map)
		end
	end

	self:RemoveQuests(mapsToRemove)

	self.scannedMaps = mapsToScan
	self:UpdateLockedQuests()

	local mapsWithQuests = {}

	for _, map in ipairs(mapsToScan) do
		local quests = Util:Filter(C_TaskQuest.GetQuestsOnMap(map.mapID) or {}, function(info)
			return info.mapID == map.mapID
				and C_QuestLog.IsWorldQuest(info.questID)
				and C_QuestLog.GetQuestTagInfo(info.questID).worldQuestType ~= Enum.QuestTagType.Prey
		end)

		mapsWithQuests[map.mapID] = #quests > 0

		for _, info in ipairs(quests) do
			local quest = self:GetQuest(info.questID)

			if quest == nil then
				self.pendingQuests[info.questID] = info
			elseif quest.isResetTimeEstimated then
				quest:UpdateResetTime()
			end

			WorldQuest:MarkPlayerEligibleForQuest(info.questID)
		end
	end

	for name, info in pairs(WorldQuest.lockedNameCache) do
		local questID = self:FindSpecialAssignment(name)

		if questID and self:GetQuest(questID) == nil then
			self.pendingQuests[questID] = { questID = questID, mapID = info.mapID, x = info.x, y = info.y }
		end
	end

	-- an estimated reset time may be too late, so expire a Special Assignment once a character who saw it can no longer see it
	for _, quest in ipairs(self.quests) do
		local rewards = character:GetRewards(quest.ID)
		local wasSeen = rewards and (rewards:IsLocked() or rewards:IsEligible())

		if quest.isResetTimeEstimated and wasSeen and mapsWithQuests[quest.map] and not (quest:IsPlayerLocked() or quest:IsPlayerEligible() or quest:IsCompleted()) then
			Util:Debug("Expiring Special Assignment", quest.ID, quest:GetName())
			quest.resetTime = GetServerTime()
		end
	end

	Util:Debug("Scanned maps", #mapsToScan, CountTable(self.pendingQuests))
end

-- locked Special Assignments are not on the map as quests, so look up their quest IDs by name
function WorldQuestList:FindSpecialAssignment(name)
	local cache = self.specialAssignmentCache

	if cache[name] == nil and GetTime() - (self.specialAssignmentsScannedAt or 0) > 60 then
		self.specialAssignmentsScannedAt = GetTime()

		for questID = 80000, 105000 do
			local tag = C_QuestLog.GetQuestTagInfo(questID)
			local questName = tag and tag.worldQuestType == Enum.QuestTagType.Capstone and C_TaskQuest.GetQuestInfoByQuestID(questID)

			if questName then
				cache[questName] = questID
			end
		end
	end

	return cache[name]
end

function WorldQuestList:UpdateLockedQuests()
	if self.scannedMaps == nil then
		return false
	end

	local lockedNames = {}

	for _, map in ipairs(self.scannedMaps) do
		for _, areaPoiID in ipairs(C_AreaPoiInfo.GetAreaPOIForMap(map.mapID) or {}) do
			local info = C_AreaPoiInfo.GetAreaPOIInfo(map.mapID, areaPoiID)
			local atlas = info and info.atlasName

			if atlas and atlas:find("Capstone", 1, true) and atlas:find("Locked", 1, true) then
				local x, y = info.position:GetXY()
				lockedNames[info.name] = { mapID = map.mapID, x = x, y = y }
			end
		end
	end

	local cache = WorldQuest.lockedNameCache
	local changed = CountTable(cache) ~= CountTable(lockedNames)

	for name in pairs(lockedNames) do
		if cache[name] == nil then
			changed = true
		end
	end

	if changed then
		wipe(cache)
		MergeTable(cache, lockedNames)
		Util:Debug("Locked Special Assignments:", CountTable(cache))
	end

	return changed
end

function WorldQuestList:Scan(continents, isNewSession, character)
	if isNewSession then
		self.isScanSessionCompleted = nil
		RewardTypes:Reset()
		Util:Debug("Started new scan session")
	end

	if self.isScanSessionCompleted then
		return
	end

	self:PopulateQuestsToScan(continents, character)

	for questID, info in pairs(self.pendingQuests) do
		if self:AddQuest(info) then
			self.pendingQuests[questID] = nil
		end
	end

	table.sort(self.quests, function(x, y)
		return x.resetTime < y.resetTime
	end)

	if next(self.pendingQuests) == nil and #self.quests > 0 then
		self.isScanSessionCompleted = true
		Util:Debug("Scan session completed", #self.quests)
	end

	return self.isScanSessionCompleted
end

function WorldQuestList:Reset(callback)
	local expiredQuests = {}

	local now = GetServerTime()

	for i = #self.quests, 1, -1 do
		local resetTime = self.quests[i].resetTime

		if resetTime == nil then
			Util:Debug("Removing corrupt quest:", self.quests[i].ID, self.quests[i]:GetName())
			table.remove(self.quests, i)
		elseif now > resetTime then
			table.insert(expiredQuests, 1, self.quests[i])
			table.remove(self.quests, i)
		end
	end

	if callback then
		for _, quest in ipairs(expiredQuests) do
			callback(quest)
		end
	end

	self:UpdateResetStartTime(expiredQuests)

	if #expiredQuests > 0 then
		RewardTypes:Reset()
	end

	return expiredQuests
end

function WorldQuestList:UpdateResetStartTime(quests)
	for _, quest in ipairs(quests) do
		local tag = C_QuestLog.GetQuestTagInfo(quest.ID).worldQuestType

		if self.resetStartTime[tag] == nil or quest.resetTime > self.resetStartTime[tag] then
			self.resetStartTime[tag] = quest.resetTime
			Util:Debug("Updatd resetStartTime:", tag, date("%Y-%m-%d %H:%M", quest.resetTime))
		end
	end
end

function WorldQuestList:GetResetStartTime(excludeTags)
	local resetStartTime = 0

	for tag, time in pairs(self.resetStartTime) do
		if not excludeTags[tag] and (time > resetStartTime) then
			resetStartTime = time
		end
	end

	return resetStartTime
end

ns.WorldQuestList = WorldQuestList
