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

-- Expand a city by one tile
function ExpandCity (playerID, cityID)

	-- find the max score plot
	local maxX, maxY, maxScore = nil, nil, 0

	local city = CityManager.GetCity(playerID, cityID)
	local cityPlots = city:GetOwnedPlots()
	for iCityPlot, vCityPlot in ipairs(cityPlots) do
		local cityPlotX, cityPlotY = vCityPlot:GetX(), vCityPlot:GetY()
		local adjacentPlots = Map.GetAdjacentPlots(cityPlotX, cityPlotY)
		for iAdjPlot, vAdjPlot in ipairs(adjacentPlots) do
			local adjPlotIsOcean = vAdjPlot:IsWater() and not vAdjPlot:IsShallowWater()
			local adjPlotIsOwned = vAdjPlot:IsOwned()
			if not adjPlotIsOcean and not adjPlotIsOwned then

				-- calculate raw score
				local score_num = 1
				local score_den = 1
				score_num = score_num + (vAdjPlot:IsFreshWater() and 1 or 0) -- *+1 for fresh water
				score_num = score_num + (vAdjPlot:IsNaturalWonder() and 1 or 0) -- *+1 for natural wonder
				score_num = score_num + (vAdjPlot:GetResourceType() >= 0 and 1 or 0) -- *+1 for resource
				score_den = score_den + (vAdjPlot:IsImpassable() and 1 or 0) -- /+1 for impassable
				local score = score_num / score_den

				-- do distance calculations
				local distance_multiplier = 0
				local playerCities = PlayerManager.GetPlayer(city:GetOwner()):GetCities()
				for iPlayerCity, vPlayerCity in playerCities:Members() do
					distance_multiplier = distance_multiplier + 1 / Map.GetPlotDistance(vAdjPlot:GetX(), vAdjPlot:GetY(), vPlayerCity:GetX(), vPlayerCity:GetY())
				end
				score = score * distance_multiplier -- /+x for distance from city
				print("Score", score)

				-- update the tile
				if score > maxScore then
					maxX, maxY, maxScore = vAdjPlot:GetX(), vAdjPlot:GetY(), score
				end
			end
		end
	end

	-- expand the city to the tile
	print("Expansion", maxX, maxY, maxScore)
	if maxX ~= nil and maxY ~= nil then
		WorldBuilder.CityManager():SetPlotOwner(maxX, maxY, playerID, cityID)
	end
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