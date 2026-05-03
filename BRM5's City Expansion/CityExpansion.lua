-- LuaScript1
-- Author: Ben
-- DateCreated: 9/19/2023 7:13:55 PM
--------------------------------------------------------------

-- Mod Data Storage
CityMaxPopulations = {}

-- "Nearby" radius (in hexes) for the cross-player buffer rule. A candidate
-- frontier plot is rejected if some other player has a city within this many
-- hexes AND we don't.
EXPANSION_BUFFER = 3

function IsPlotNearPlayer (plot, playerID)
	local pPlayer = PlayerManager.GetPlayer(playerID)
	if pPlayer == nil or not pPlayer:IsAlive() then return false end
	local pX, pY = plot:GetX(), plot:GetY()
	for _, vCity in pPlayer:GetCities():Members() do
		if Map.GetPlotDistance(pX, pY, vCity:GetX(), vCity:GetY()) <= EXPANSION_BUFFER then
			return true
		end
	end
	return false
end

-- Allowed iff we're nearby OR no foreign player is nearby.
function IsExpansionAllowed (plot, expandingPlayerID)
	if IsPlotNearPlayer(plot, expandingPlayerID) then return true end
	for _, otherID in ipairs(PlayerManager.GetAliveIDs()) do
		if otherID ~= expandingPlayerID and IsPlotNearPlayer(plot, otherID) then
			return false
		end
	end
	return true
end

-- get a city's permanent id
function getCityPermanentID (playerID, cityID)
	local city = CityManager.GetCity(playerID, cityID)
	local cityX, cityY = city:GetX(), city:GetY()
	local cityPermanentID = tostring(cityX)..":"..tostring(cityY)
	return cityPermanentID
end

-- BFS from the city center through any plot owned by this player. Returns
-- the list of unowned non-ocean plots bordering that walk that pass the
-- cross-player buffer rule (see IsExpansionAllowed).
function GetCityFrontierPlots (playerID, cityID)
	local city = CityManager.GetCity(playerID, cityID)
	local cityX, cityY = city:GetX(), city:GetY()

	local visited = { [Map.GetPlotIndex(cityX, cityY)] = true }
	local queue = { Map.GetPlot(cityX, cityY) }
	local head = 1
	local frontier = {}

	while head <= #queue do
		local plot = queue[head]
		head = head + 1
		for _, adj in ipairs(Map.GetAdjacentPlots(plot:GetX(), plot:GetY())) do
			local adjIdx = Map.GetPlotIndex(adj:GetX(), adj:GetY())
			if not visited[adjIdx] then
				visited[adjIdx] = true
				if adj:GetOwner() == playerID then
					queue[#queue + 1] = adj
				elseif not adj:IsOwned()
					and not (adj:IsWater() and not adj:IsShallowWater())
					and IsExpansionAllowed(adj, playerID) then
					frontier[#frontier + 1] = adj
				end
			end
		end
	end

	return frontier
end

-- Score a candidate frontier plot. Higher = more desirable.
function ScoreFrontierPlot (plot, playerID)
	local num = 1
		+ (plot:IsFreshWater() and 1 or 0)
		+ (plot:IsNaturalWonder() and 1 or 0)
		+ (plot:GetResourceType() >= 0 and 1 or 0)
	local den = 1 + (plot:IsImpassable() and 1 or 0)
	local score = num / den

	for _, pCity in PlayerManager.GetPlayer(playerID):GetCities():Members() do
		local d = Map.GetPlotDistance(plot:GetX(), plot:GetY(), pCity:GetX(), pCity:GetY())
		score = score * (1 + 1 / d)
	end
	return score
end

-- Expand a city by one tile. Picks the highest-scoring frontier plot and
-- claims it for this city. Sidesteps city:GetOwnedPlots(), which doesn't
-- reliably reflect tiles claimed via SetOwner / SetPlotOwner.
function ExpandCity (playerID, cityID)
	local frontier = GetCityFrontierPlots(playerID, cityID)

	local bestPlot, bestScore = nil, 0
	for _, plot in ipairs(frontier) do
		local score = ScoreFrontierPlot(plot, playerID)
		if score > bestScore then
			bestPlot, bestScore = plot, score
		end
	end

	if bestPlot ~= nil then
		local x, y = bestPlot:GetX(), bestPlot:GetY()
		WorldBuilder.CityManager():SetPlotOwner(x, y, playerID, cityID)
		Map.GetPlot(x, y):SetOwner(playerID, cityID)

		-- SetOwner doesn't refresh the city's workable-plot list. Try a few
		-- known-plausible nudges; pcall so non-existent methods are silent.
		local pCitizens = CityManager.GetCity(playerID, cityID):GetCitizens()
		local plotIndex = Map.GetPlotIndex(x, y)
		pcall(function() pCitizens:SetWorkingPlot(plotIndex, false) end)
		pcall(function() pCitizens:SetCitizenCount(pCitizens:GetCitizenCount()) end)
		pcall(function() pCitizens:DoVerifyWorkingPlots() end)
	end
	print("Expansion", bestPlot and bestPlot:GetX(), bestPlot and bestPlot:GetY(), bestScore, "frontier:", #frontier)
end


-- Catch the city's tracked max pop up to its current population, running 2
-- expansions per pop step. Idempotent: a no-op if already in sync.
--
-- Founding pop is assumed to be 1, so a fresh city seen at pop N expands for
-- (N - 1) pops worth — covers Hic Sunt Dracones and other founding bonuses
-- regardless of whether the bonus arrives before or after CityAddedToMap.
--
-- Edge case: cities first seen at pop > 1 due to capture or mid-save load
-- will get free catch-up expansion. Acceptable for now.
function CatchUpExpansion (playerID, cityID)
	local cityPermanentID = getCityPermanentID(playerID, cityID)
	local currentPop = CityManager.GetCity(playerID, cityID):GetPopulation()
	if CityMaxPopulations[cityPermanentID] == nil then
		CityMaxPopulations[cityPermanentID] = 1
	end
	while CityMaxPopulations[cityPermanentID] < currentPop do
		ExpandCity(playerID, cityID)
		ExpandCity(playerID, cityID)
		CityMaxPopulations[cityPermanentID] = CityMaxPopulations[cityPermanentID] + 1
	end
end

Events.CityPopulationChanged.Add(function (playerID, cityID, cityPopulation)
	CatchUpExpansion(playerID, cityID)
end)

Events.CityAddedToMap.Add(function (playerID, cityID, iX, iY)
	CatchUpExpansion(playerID, cityID)
end)




-- TODO: Claim adjacent tiles on improvement construction ???


-- Claim all adjacent coast tiles on owning tile next to coast
Events.CityTileOwnershipChanged.Add(function (owner, cityID)
	print("BRM5:CityTileOwnershipChanged")

	-- TODO: If tile is ocean, unclaim tile


	-- TODO: If tile is land, Claim adjacent unclaimed coast tiles
end)