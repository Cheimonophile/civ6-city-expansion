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
	local cityPlots = CityManager.GetCity(playerID, cityID):GetOwnedPlots()
	print(cityPlots)
	for iCityPlot, vCityPlot in ipairs(cityPlots) do
		print("Plots",iCityPlot,vCityPlot)
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