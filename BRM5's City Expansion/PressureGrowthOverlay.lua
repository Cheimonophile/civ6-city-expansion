-- Citizen-management overlay: while the player is in the manage-citizens
-- screen for a city, paint a hex on every nearby unowned plot the player is
-- pressuring, labelled with approximate turns until the plot flips. UI
-- context runs in a separate Lua VM from CityExpansion.lua, so the threshold
-- formula and the pressure-state serialization shape are mirrored here —
-- keep PRESSURE_STATE_KEY, the terrain modifiers, and the (de)serializer in
-- sync between the two files.
include("InstanceManager")

local PRESSURE_STATE_KEY = "BRM5_PressureState_v1"

-- Mirror of CityExpansion.lua: a player may only expand into a plot if
-- they have a city within EXPANSION_BUFFER hexes of it, or no other
-- player does. Keep in sync with the gameplay file.
local EXPANSION_BUFFER = 3

local m_PurchasePlot     = UILens.CreateLensLayerHash("Purchase_Plot")
local m_LabelIM          -- InstanceManager, set in OnInit
local m_DrawnPlots       = {}
local m_ActiveInstances  = {}
local m_bLoadScreenClose = false

-- ===========================================================================
-- Pressure mirror — keep in sync with CityExpansion.lua
-- ===========================================================================
local function TerrainIndex (name)
	local row = GameInfo.Terrains[name]
	return row and row.Index or -1
end
local g_TERRAIN_TUNDRA = TerrainIndex("TERRAIN_TUNDRA")
local g_TERRAIN_DESERT = TerrainIndex("TERRAIN_DESERT")
local g_TERRAIN_SNOW   = TerrainIndex("TERRAIN_SNOW")

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

local function Deserialize (s)
	if s == nil or s == "" then return {} end
	local f = loadstring("return " .. s)
	if f == nil then return {} end
	local ok, val = pcall(f)
	if not ok or type(val) ~= "table" then return {} end
	return val
end

-- True iff `plot` is owned by playerID's city `cityID`. Civ VI's
-- Plot:GetOwningCityID is the canonical answer when available; otherwise
-- fall back to "the player's closest city to this plot is the target city".
local function PlotBelongsToCity (plot, playerID, cityID, cityX, cityY)
	if plot:GetOwner() ~= playerID then return false end
	local ok, owningID = pcall(function () return plot:GetOwningCityID() end)
	if ok and owningID ~= nil and owningID >= 0 then
		return owningID == cityID
	end
	local pPlayer = Players[playerID]
	if pPlayer == nil then return false end
	local px, py = plot:GetX(), plot:GetY()
	local thisDist = Map.GetPlotDistance(px, py, cityX, cityY)
	for _, vCity in pPlayer:GetCities():Members() do
		if vCity:GetID() ~= cityID then
			if Map.GetPlotDistance(px, py, vCity:GetX(), vCity:GetY()) < thisDist then
				return false
			end
		end
	end
	return true
end

-- BFS through the selected city's own owned plots and collect every unowned
-- non-deep-water neighbour as the city's frontier. For each frontier plot,
-- project turns until this player's pressure (current accumulated + per-turn
-- rate from all the player's cities) clears the plot's threshold. Plots
-- with no state entry are treated as zero pressure so the overlay populates
-- immediately on a freshly founded city.
local function BuildPlotTurnsMap (playerID, cityID)
	local pCity = CityManager.GetCity(playerID, cityID)
	if pCity == nil then return {} end
	local cityX, cityY = pCity:GetX(), pCity:GetY()

	local centerIdx = Map.GetPlotIndex(cityX, cityY)
	local visited   = { [centerIdx] = true }
	local queue     = { Map.GetPlot(cityX, cityY) }
	local head      = 1
	local frontier  = {}

	while head <= #queue do
		local plot = queue[head]; head = head + 1
		for _, adj in ipairs(Map.GetAdjacentPlots(plot:GetX(), plot:GetY())) do
			local adjIdx = Map.GetPlotIndex(adj:GetX(), adj:GetY())
			if not visited[adjIdx] then
				visited[adjIdx] = true
				if PlotBelongsToCity(adj, playerID, cityID, cityX, cityY) then
					queue[#queue + 1] = adj
				elseif not adj:IsOwned()
					and not (adj:IsWater() and not adj:IsShallowWater()) then
					frontier[adjIdx] = adj
				end
			end
		end
	end

	local state = ExposedMembers.BRM5_PressureState
	if state == nil then
		state = Deserialize(Game:GetProperty(PRESSURE_STATE_KEY))
	end
	local pPlayer = Players[playerID]
	if pPlayer == nil then return {} end

	local cities = {}
	for _, vCity in pPlayer:GetCities():Members() do
		cities[#cities + 1] = { x = vCity:GetX(), y = vCity:GetY(), pop = vCity:GetPopulation() }
	end

	local result = {}
	for plotIdx, plot in pairs(frontier) do
		if IsExpansionAllowed(plot, playerID) then
			local px, py    = plot:GetX(), plot:GetY()
			local plotState = state[plotIdx] or {}

			local current = plotState[playerID] or 0
			local rate    = 0
			for _, c in ipairs(cities) do
				local cd = Map.GetPlotDistance(c.x, c.y, px, py)
				if cd < 1 then cd = 1 end
				rate = rate + (c.pop / DistanceDivisor(cd))
			end
			if rate > 0 then
				local remaining = Threshold(plot) - current
				if remaining < 0 then remaining = 0 end
				result[plotIdx] = math.ceil(remaining / rate)
			end
		end
	end

	return result
end

-- ===========================================================================
-- Overlay rendering
-- ===========================================================================
local function ClearOverlay ()
	for plotIdx, _ in pairs(m_DrawnPlots) do
		UILens.ClearHex(m_PurchasePlot, plotIdx)
	end
	m_DrawnPlots = {}

	for _, inst in ipairs(m_ActiveInstances) do
		inst.Anchor:SetHide(true)
		m_LabelIM:ReleaseInstance(inst)
	end
	m_ActiveInstances = {}
end

local function ShowOverlayForCity (pCity)
	ClearOverlay()
	if pCity == nil then return end

	local iPlayer = pCity:GetOwner()
	if iPlayer ~= Game.GetLocalPlayer() then return end

	local plotMap = BuildPlotTurnsMap(iPlayer, pCity:GetID())

	for plotIdx, turns in pairs(plotMap) do
		UILens.SetLayerGrowthHex(m_PurchasePlot, iPlayer, plotIdx, 1, "GrowthHexBG")
		m_DrawnPlots[plotIdx] = true

		local inst = m_LabelIM:GetInstance()
		local plotX, plotY = Map.GetPlotLocation(plotIdx)
		local worldX, worldY, worldZ = UI.GridToWorld(plotX, plotY)
		inst.Anchor:SetWorldPositionVal(worldX, worldY + 15, worldZ)
		inst.TurnsLabel:SetText(tostring(turns))

		inst.Anchor:SetHide(false)
		inst.LabelAlpha:SetToBeginning()
		inst.LabelAlpha:Play()

		m_ActiveInstances[#m_ActiveInstances + 1] = inst
	end
end

local function OnInterfaceModeChanged (eOldMode, eNewMode)
	if eOldMode == InterfaceModeTypes.CITY_MANAGEMENT then
		ClearOverlay()
	end
	if eNewMode == InterfaceModeTypes.CITY_MANAGEMENT then
		ShowOverlayForCity(UI.GetHeadSelectedCity())
	end
end

local function OnTurnRefresh ()
	if UI.GetInterfaceMode() == InterfaceModeTypes.CITY_MANAGEMENT then
		ShowOverlayForCity(UI.GetHeadSelectedCity())
	end
end

-- ===========================================================================
-- Lifecycle
-- ===========================================================================
function OnInit (bIsReload)
	if not ContextPtr:LookUpControl("/InGame/WorldViewControls") then
		Events.LoadScreenClose.Add(OnInit)
		m_bLoadScreenClose = true
		return
	end

	m_LabelIM = InstanceManager:new("PressureLabelInstance", "Anchor", Controls.PressureOverlayContainer)

	Events.InterfaceModeChanged.Add(OnInterfaceModeChanged)
	Events.LocalPlayerTurnBegin.Add(OnTurnRefresh)
	Events.LocalPlayerTurnEnd.Add(OnTurnRefresh)

	local pWorldView = ContextPtr:LookUpControl("/InGame/WorldViewControls")
	ContextPtr:ChangeParent(pWorldView)

	if bIsReload and UI.GetInterfaceMode() == InterfaceModeTypes.CITY_MANAGEMENT then
		ShowOverlayForCity(UI.GetHeadSelectedCity())
	end
end

function OnShutdown ()
	if m_bLoadScreenClose then
		Events.LoadScreenClose.Remove(OnInit)
	end
	Events.InterfaceModeChanged.Remove(OnInterfaceModeChanged)
	Events.LocalPlayerTurnBegin.Remove(OnTurnRefresh)
	Events.LocalPlayerTurnEnd.Remove(OnTurnRefresh)
end

function Initialize ()
	ContextPtr:SetInitHandler(OnInit)
	ContextPtr:SetShutdown(OnShutdown)
	ContextPtr:SetHide(false)
end
Initialize()
