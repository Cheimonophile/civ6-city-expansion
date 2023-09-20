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


-- claim a tile for a city every time the city expandss
Events.CityPopulationChanged.Add(function (playerID, cityID, cityPopulation)
	print("BRM5:OnCityPopulationChanged", playerID, cityID, cityPopulation)

	-- Get City Coordinate ID
	local cityPermanentID = getCityPermanentID(playerID, cityID)

	print(cityPermanentID)
end)


-- add a city to the populations table
Events.CityAddedToMap.Add(function (playerID, cityID, iX, iY)
	local cityPermanentID = getCityPermanentID(playerID, cityID)
	local cityPop = CityManager.GetCity(playerID, cityID):GetPopulation()
	print("CityAddedToMap", cityPermanentID, cityPop)
	print("City Population Before", CityMaxPopulations[cityPermanentID])
	CityMaxPopulations[cityPermanentID] = 1
	print("City Population After", CityMaxPopulations[cityPermanentID])
end)




-- TODO: Claim adjacent tiles on improvement construction ???


-- Claim all adjacent coast tiles on owning tile next to coast
Events.CityTileOwnershipChanged.Add(function (owner, cityID)
	print("BRM5:CityTileOwnershipChanged")

	-- TODO: If tile is ocean, unclaim tile


	-- TODO: If tile is land, Claim adjacent unclaimed coast tiles


	return nil
end)