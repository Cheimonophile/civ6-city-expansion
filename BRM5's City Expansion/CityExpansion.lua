-- LuaScript1
-- Author: Ben
-- DateCreated: 9/19/2023 7:13:55 PM
--------------------------------------------------------------

-- Mod Data Storage
CityMaxPopulations = {}

-- get a city's permanent id
function getCityPermanentID (playerID, cityID)
	local city = CityManager.GetCity(playerID, cityID)
	local cityX, cityY = city:GetX(), city:GetY()
	local cityPermanentID = tostring(cityX)..":"..tostring(cityY)
	return cityPermanentID
end

-- BFS from the city center through any plot owned by this player. Returns
-- the list of unowned non-ocean plots bordering that walk — the city's
-- expansion frontier.
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
				elseif not adj:IsOwned() and not (adj:IsWater() and not adj:IsShallowWater()) then
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


-- claim a tile for a city every time the city expandss
Events.CityPopulationChanged.Add(function (playerID, cityID, cityPopulation)

	-- Get City Coordinate ID
	local cityPermanentID = getCityPermanentID(playerID, cityID)
	local oldCityPop = CityMaxPopulations[cityPermanentID]
	local cityPopDifference = cityPopulation - oldCityPop
	if cityPopDifference > 0 then
		CityMaxPopulations[cityPermanentID] = cityPopulation
		print("Increased "..CityManager.GetCity(playerID, cityID):GetName().." to "..tostring(cityPopulation).." from "..tostring(oldCityPop))
		while cityPopDifference > 0 do
			ExpandCity(playerID, cityID)
			ExpandCity(playerID, cityID)
			cityPopDifference = cityPopDifference - 1
		end
	end
end)


-- add a city population to the population table
Events.CityAddedToMap.Add(function (playerID, cityID, iX, iY)
	local cityPermanentID = getCityPermanentID(playerID, cityID)
	local cityPop = CityManager.GetCity(playerID, cityID):GetPopulation()
	CityMaxPopulations[cityPermanentID] = cityPop
	print("Updated "..CityManager.GetCity(playerID, cityID):GetName().." to "..tostring(cityPop))
end)




-- TODO: Claim adjacent tiles on improvement construction ???


-- Claim all adjacent coast tiles on owning tile next to coast
Events.CityTileOwnershipChanged.Add(function (owner, cityID)
	print("BRM5:CityTileOwnershipChanged")

	-- TODO: If tile is ocean, unclaim tile


	-- TODO: If tile is land, Claim adjacent unclaimed coast tiles
end)