-- =========================================================================
-- BRM5 City Expansion: pressure-based tile acquisition.
--
-- Each unowned plot adjacent to a player's territory accumulates pressure
-- from that civ's cities each turn (pop / hex distance). Once a player's
-- accumulated pressure on a plot reaches the plot's terrain-modified
-- threshold, the plot flips to that player's most populous bordering city.
--
-- Pressure state is keyed [plotIndex][playerID] = pressure and persists via
-- Game:SetProperty. PressureGrowthOverlay.lua runs in a separate Lua VM and
-- reads the same property to project turns-to-claim — keep PRESSURE_STATE_KEY
-- and the serialization format in sync between the two files.
-- =========================================================================

PRESSURE_STATE_KEY = "BRM5_PressureState_v1"

-- "Polite" buffer rule (ported from the pre-pressure expansion): a player
-- may only expand into a plot if either they already have a city within
-- this many hexes of the plot, or no other player does. Keep in sync with
-- PressureGrowthOverlay.lua so the overlay projection matches.
local EXPANSION_BUFFER = 3

local g_lastTurnProcessed = -1

-- ---- terrain index lookup -----------------------------------------------
local function TerrainIndex (name)
	local row = GameInfo.Terrains[name]
	return row and row.Index or -1
end
local g_TERRAIN_TUNDRA = TerrainIndex("TERRAIN_TUNDRA")
local g_TERRAIN_DESERT = TerrainIndex("TERRAIN_DESERT")
local g_TERRAIN_SNOW   = TerrainIndex("TERRAIN_SNOW")

-- ---- base pressure (matches first-plot culture cost @ game speed) -------
local function ComputeBasePressure ()
	local row  = GameInfo.GlobalParameters["CULTURE_COST_FIRST_PLOT"]
	local base = (row and tonumber(row.Value)) or 10
	local speed = GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()]
	local mult  = (speed and speed.CostMultiplier) or 100
	return 6 * base * mult / 100
end
local g_BasePressure = ComputeBasePressure()

local function DistanceDivisor (d)
	return 2 * d * (d + 1) / 2
end

local function Threshold (plot)
	local m = 1.0
	if plot:IsImpassable()                                 then m = m * 2.0  end
	if plot:IsHills()                                      then m = m * 1.2  end
	if not plot:IsHills() and not plot:IsMountain()        then m = m * 0.75 end
	if plot:IsFreshWater()                                 then m = m * 0.75 end
	if plot:GetResourceType() >= 0 or plot:IsNaturalWonder() then m = m * 0.5  end
	local t = plot:GetTerrainType()
	if t == g_TERRAIN_TUNDRA                               then m = m * 1.2  end
	if t == g_TERRAIN_DESERT                               then m = m * 1.2  end
	if t == g_TERRAIN_SNOW                                 then m = m * 1.4  end
	return g_BasePressure * m
end

-- ---- (de)serialization: numbers + 2-level nested tables ------------------
local function Serialize (state)
	local parts = { "{" }
	for plotIdx, players in pairs(state) do
		parts[#parts + 1] = "[" .. plotIdx .. "]={"
		for playerID, pressure in pairs(players) do
			parts[#parts + 1] = "[" .. playerID .. "]=" .. tostring(pressure) .. ","
		end
		parts[#parts + 1] = "},"
	end
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

local function Deserialize (s)
	if s == nil or s == "" then return {} end
	local f = loadstring("return " .. s)
	if f == nil then return {} end
	local ok, val = pcall(f)
	if not ok or type(val) ~= "table" then return {} end
	return val
end

-- State lives on ExposedMembers so the UI Lua VM (PressureGrowthOverlay.lua)
-- can read it directly without re-deserializing each frame. Game:SetProperty
-- is the save-persistence channel: hydrate from it on first access; mirror
-- the serialized form back to it after every mutation.

local function LoadState ()
	if ExposedMembers.BRM5_PressureState == nil then
		ExposedMembers.BRM5_PressureState = Deserialize(Game:GetProperty(PRESSURE_STATE_KEY))
	end
	return ExposedMembers.BRM5_PressureState
end

local function SaveState ()
	local s = ExposedMembers.BRM5_PressureState
	if s ~= nil then
		Game:SetProperty(PRESSURE_STATE_KEY, Serialize(s))
	end
end

local function PlayerHasCityWithin (plot, playerID, dist)
	local pPlayer = Players[playerID]
	if pPlayer == nil or not pPlayer:IsAlive() then return false end
	local px, py = plot:GetX(), plot:GetY()
	for _, vCity in pPlayer:GetCities():Members() do
		if Map.GetPlotDistance(px, py, vCity:GetX(), vCity:GetY()) <= dist then
			return true
		end
	end
	return false
end

local function IsExpansionAllowed (plot, expandingPlayerID)
	if PlayerHasCityWithin(plot, expandingPlayerID, EXPANSION_BUFFER) then
		return true
	end
	for _, otherID in ipairs(PlayerManager.GetAliveIDs()) do
		if otherID ~= expandingPlayerID
			and PlayerHasCityWithin(plot, otherID, EXPANSION_BUFFER) then
			return false
		end
	end
	return true
end

-- Resolve which of the owning player's cities owns this plot. Civ VI exposes
-- Plot:GetOwningCityID in some builds; fall back to nearest-city otherwise.
local function GetOwningCityID (plot)
	local owner = plot:GetOwner()
	if owner == nil or owner < 0 then return nil end
	local ok, cityID = pcall(function () return plot:GetOwningCityID() end)
	if ok and cityID ~= nil and cityID >= 0 then return cityID end
	local pPlayer = Players[owner]
	if pPlayer == nil then return nil end
	local px, py = plot:GetX(), plot:GetY()
	local bestID, bestDist = nil, math.huge
	for _, vCity in pPlayer:GetCities():Members() do
		local d = Map.GetPlotDistance(vCity:GetX(), vCity:GetY(), px, py)
		if d < bestDist then bestDist = d; bestID = vCity:GetID() end
	end
	return bestID
end

-- Tile-transfer primitive (unchanged from the previous BFS-based version).
-- WorldBuilder + Plot:SetOwner are belt-and-suspenders; the citizen nudge
-- forces the new tile to show up as workable. city:GetOwnedPlots() does NOT
-- reflect tiles claimed via SetOwner reliably, hence the manual refresh.
function ClaimPlot (playerID, cityID, plot)
	local x, y = plot:GetX(), plot:GetY()
	WorldBuilder.CityManager():SetPlotOwner(x, y, playerID, cityID)
	Map.GetPlot(x, y):SetOwner(playerID, cityID)

	local pCitizens = CityManager.GetCity(playerID, cityID):GetCitizens()
	local plotIndex = Map.GetPlotIndex(x, y)
	pcall(function () pCitizens:SetWorkingPlot(plotIndex, false) end)
	pcall(function () pCitizens:SetCitizenCount(pCitizens:GetCitizenCount()) end)
	pcall(function () pCitizens:DoVerifyWorkingPlots() end)
end

-- Returns { [plotIndex] = { plot=plot, borderingCities = { [playerID] = { [cityID]=true,.. } } } }
local function BuildFrontier ()
	local frontier = {}
	local mapW, mapH = Map.GetGridSize()
	for plotIdx = 0, (mapW * mapH) - 1 do
		local plot = Map.GetPlotByIndex(plotIdx)
		if plot ~= nil and not plot:IsOwned()
			and not (plot:IsWater() and not plot:IsShallowWater()) then
			local borders = nil
			for _, adj in ipairs(Map.GetAdjacentPlots(plot:GetX(), plot:GetY())) do
				local owner = adj:GetOwner()
				if owner ~= nil and owner >= 0 then
					local pPlayer = Players[owner]
					if pPlayer ~= nil and pPlayer:IsAlive() and not pPlayer:IsBarbarian() then
						local cityID = GetOwningCityID(adj)
						if cityID ~= nil then
							local alreadyAdded = borders ~= nil and borders[owner] ~= nil
							if alreadyAdded or IsExpansionAllowed(plot, owner) then
								borders = borders or {}
								borders[owner] = borders[owner] or {}
								borders[owner][cityID] = true
							end
						end
					end
				end
			end
			if borders ~= nil then
				frontier[plotIdx] = { plot = plot, borderingCities = borders }
			end
		end
	end
	return frontier
end

local function ApplyPressureTurn ()
	local state    = LoadState()
	local frontier = BuildFrontier()

	-- Drop entries for plots that are no longer frontier (got claimed since
	-- last pass, or otherwise became owned).
	for plotIdx, _ in pairs(state) do
		if frontier[plotIdx] == nil then state[plotIdx] = nil end
	end

	-- Accumulate pressure.
	for plotIdx, info in pairs(frontier) do
		local plot         = info.plot
		local plotX, plotY = plot:GetX(), plot:GetY()
		local plotState    = state[plotIdx] or {}

		for playerID, _ in pairs(info.borderingCities) do
			local pPlayer = Players[playerID]
			if pPlayer ~= nil and pPlayer:IsAlive() then
				local sum = plotState[playerID] or 0
				for _, vCity in pPlayer:GetCities():Members() do
					local d = Map.GetPlotDistance(vCity:GetX(), vCity:GetY(), plotX, plotY)
					if d < 1 then d = 1 end
					sum = sum + (vCity:GetPopulation() / DistanceDivisor(d))
				end
				plotState[playerID] = sum
			end
		end
		state[plotIdx] = plotState
	end

	-- Resolve thresholds.
	local claimed = 0
	for plotIdx, info in pairs(frontier) do
		local plot      = info.plot
		local threshold = Threshold(plot)
		local plotState = state[plotIdx]

		local winnerID, winnerPressure = nil, -1
		for playerID, pressure in pairs(plotState) do
			if pressure >= threshold and info.borderingCities[playerID] ~= nil then
				if pressure > winnerPressure
					or (pressure == winnerPressure and (winnerID == nil or playerID < winnerID)) then
					winnerID, winnerPressure = playerID, pressure
				end
			end
		end

		if winnerID ~= nil then
			local bordering = info.borderingCities[winnerID]
			local bestID, bestPop = nil, -1
			for cityID, _ in pairs(bordering) do
				local c = CityManager.GetCity(winnerID, cityID)
				if c ~= nil then
					local pop = c:GetPopulation()
					if pop > bestPop or (pop == bestPop and (bestID == nil or cityID < bestID)) then
						bestID, bestPop = cityID, pop
					end
				end
			end
			if bestID ~= nil then
				ClaimPlot(winnerID, bestID, plot)
				state[plotIdx] = nil
				claimed = claimed + 1
			end
		end
	end

	SaveState()

	local size = 0
	for _ in pairs(state) do size = size + 1 end
	print("BRM5 pressure: turn=" .. Game.GetCurrentGameTurn()
		.. " frontier_plots=" .. size .. " claimed=" .. claimed)
end

Events.PlayerTurnActivated.Add(function (iPlayer, isFirstTime)
	local now = Game.GetCurrentGameTurn()
	if now > g_lastTurnProcessed then
		g_lastTurnProcessed = now
		ApplyPressureTurn()
	end
end)

print("BRM5 CityExpansion: loaded, base pressure=" .. tostring(g_BasePressure))
