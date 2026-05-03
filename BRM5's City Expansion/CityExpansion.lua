-- LuaScript1
-- Author: Ben
-- DateCreated: 9/19/2023 7:13:55 PM
--------------------------------------------------------------

-- "Nearby" radius (in hexes) for the cross-player buffer rule. A candidate
-- frontier plot is rejected if some other player has a city within this many
-- hexes AND we don't.
EXPANSION_BUFFER = 3

-- Base population a city needs to claim a tile before terrain/distance
-- adjustments. See PressureCost.
PRESSURE_BASE = 6

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

local function FlatLand (plot)
	return not plot:IsHills() and not plot:IsMountain()
end

local function HasResource (plot)
	return plot:GetResourceType() >= 0
end

-- Population a city must have to absorb this plot, given its hex distance
-- from the city center. Distance multiplier is the (d-1)th triangular
-- number, so ring 1 is free, ring 2 = base, ring 3 = 3*base, etc.
function PressureCost (plot, distance)
	local base = PRESSURE_BASE
	if plot:IsFreshWater() then base = base - 1 end
	if FlatLand(plot) then base = base - 1 end
	if HasResource(plot) or plot:IsNaturalWonder() then base = base - 2 end
	if plot:IsHills() then base = base + 1 end
	if plot:IsImpassable() then base = base * 2 end

	local n = distance - 1
	return base * (n * (n + 1) / 2)
end

-- Claim a single plot for (playerID, cityID) and nudge the citizen manager
-- so the new tile shows up as workable. Sidesteps city:GetOwnedPlots(),
-- which doesn't reliably reflect tiles claimed via SetOwner / SetPlotOwner.
function ClaimPlot (playerID, cityID, plot)
	local x, y = plot:GetX(), plot:GetY()
	WorldBuilder.CityManager():SetPlotOwner(x, y, playerID, cityID)
	Map.GetPlot(x, y):SetOwner(playerID, cityID)

	local pCitizens = CityManager.GetCity(playerID, cityID):GetCitizens()
	local plotIndex = Map.GetPlotIndex(x, y)
	pcall(function() pCitizens:SetWorkingPlot(plotIndex, false) end)
	pcall(function() pCitizens:SetCitizenCount(pCitizens:GetCitizenCount()) end)
	pcall(function() pCitizens:DoVerifyWorkingPlots() end)
end

-- BFS from the city center through owned tiles AND through unowned tiles
-- the given population can afford. Treating affordable plots as traversable
-- means a single pass reaches everything claimable: e.g. an affordable
-- ring-3 plot only becomes "frontier" once we walk through some ring-2
-- plot, but if that ring-2 plot is also affordable the BFS handles it.
function GetExpandablePlots (playerID, cityID, pop)
	local city = CityManager.GetCity(playerID, cityID)
	local cityX, cityY = city:GetX(), city:GetY()

	local visited = { [Map.GetPlotIndex(cityX, cityY)] = true }
	local queue = { Map.GetPlot(cityX, cityY) }
	local head = 1
	local claimable = {}

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
					local d = Map.GetPlotDistance(adj:GetX(), adj:GetY(), cityX, cityY)
					if PressureCost(adj, d) <= pop then
						claimable[#claimable + 1] = adj
						queue[#queue + 1] = adj
					end
				end
			end
		end
	end

	return claimable
end

-- Claim every plot the city's current population can absorb. Idempotent;
-- safe to call on every pop change or city event.
function ExpandCityByPressure (playerID, cityID)
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return end
	local pop = city:GetPopulation()
	local plots = GetExpandablePlots(playerID, cityID, pop)
	for _, plot in ipairs(plots) do
		ClaimPlot(playerID, cityID, plot)
	end
	print("Expansion pop=", pop, "claimed=", #plots)
end

Events.CityPopulationChanged.Add(function (playerID, cityID, cityPopulation)
	ExpandCityByPressure(playerID, cityID)
end)

Events.CityAddedToMap.Add(function (playerID, cityID, iX, iY)
	ExpandCityByPressure(playerID, cityID)
end)




-- TODO: Claim adjacent tiles on improvement construction ???


-- Claim all adjacent coast tiles on owning tile next to coast
Events.CityTileOwnershipChanged.Add(function (owner, cityID)
	print("BRM5:CityTileOwnershipChanged")

	-- TODO: If tile is ocean, unclaim tile


	-- TODO: If tile is land, Claim adjacent unclaimed coast tiles
end)