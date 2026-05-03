-- Citizen-management overlay: while the player is in the manage-citizens
-- screen for a city, paint a hex on every plot that city will absorb under
-- pressure-based expansion, labelled with approximate turns. UI context runs
-- in a separate Lua VM from CityExpansion.lua, so the pressure math is
-- mirrored here. Keep these constants and helpers in sync.
include("InstanceManager")

local EXPANSION_BUFFER = 3
local PRESSURE_BASE    = 6
local LOOK_AHEAD_POPS  = 5

local m_PurchasePlot   = UILens.CreateLensLayerHash("Purchase_Plot")
local m_LabelIM        -- InstanceManager, set in OnInit
local m_DrawnPlots     = {}
local m_ActiveInstances = {}
local m_bLoadScreenClose = false

-- ===========================================================================
-- Pressure logic — keep in sync with CityExpansion.lua
-- ===========================================================================
local function FlatLand(plot)
	return not plot:IsHills() and not plot:IsMountain()
end

local function HasResource(plot)
	return plot:GetResourceType() >= 0
end

local function PressureCost(plot, distance)
	local base = PRESSURE_BASE
	if plot:IsFreshWater() then base = base - 1 end
	if FlatLand(plot) then base = base - 1 end
	if HasResource(plot) or plot:IsNaturalWonder() then base = base - 2 end
	if plot:IsHills() then base = base + 1 end
	if plot:IsImpassable() then base = base * 2 end
	local n = distance - 1
	return base * (n * (n + 1) / 2)
end

local function IsPlotNearPlayer(plot, playerID)
	local pPlayer = Players[playerID]
	if pPlayer == nil or not pPlayer:IsAlive() then return false end
	local pX, pY = plot:GetX(), plot:GetY()
	for _, vCity in pPlayer:GetCities():Members() do
		if Map.GetPlotDistance(pX, pY, vCity:GetX(), vCity:GetY()) <= EXPANSION_BUFFER then
			return true
		end
	end
	return false
end

local function IsExpansionAllowed(plot, expandingPlayerID)
	if IsPlotNearPlayer(plot, expandingPlayerID) then return true end
	for _, otherID in ipairs(PlayerManager.GetAliveIDs()) do
		if otherID ~= expandingPlayerID and IsPlotNearPlayer(plot, otherID) then
			return false
		end
	end
	return true
end

-- Mirror of CityExpansion.lua:GetExpandablePlots — BFS from city center
-- through owned and through unowned-but-affordable plots at the given pop.
local function ProjectClaimable(playerID, cityID, pop)
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return {} end
	local cityX, cityY = city:GetX(), city:GetY()
	local visited = { [Map.GetPlotIndex(cityX, cityY)] = true }
	local queue = { Map.GetPlot(cityX, cityY) }
	local head = 1
	local claimable = {}
	while head <= #queue do
		local plot = queue[head]; head = head + 1
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

-- For each plot the city will eventually claim, find the smallest pop offset
-- (>= 1) at which it first becomes reachable. Returns { plotIndex = popsAway }.
local function BuildPlotPopMap(playerID, cityID, currentPop)
	local seen = {}
	for offset = 1, LOOK_AHEAD_POPS do
		local pop = currentPop + offset
		for _, plot in ipairs(ProjectClaimable(playerID, cityID, pop)) do
			local idx = Map.GetPlotIndex(plot:GetX(), plot:GetY())
			if seen[idx] == nil then seen[idx] = offset end
		end
	end
	return seen
end

-- ===========================================================================
-- Overlay rendering
-- ===========================================================================
local function ClearOverlay()
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

local function ShowOverlayForCity(pCity)
	ClearOverlay()
	if pCity == nil then return end

	local iPlayer = pCity:GetOwner()
	local iCity   = pCity:GetID()
	if iPlayer ~= Game.GetLocalPlayer() then return end

	local currentPop  = pCity:GetPopulation()
	local growth      = pCity:GetGrowth()
	local turnsPerPop = growth and growth:GetTurnsUntilGrowth() or -1

	local plotMap = BuildPlotPopMap(iPlayer, iCity, currentPop)

	for plotIdx, popsAway in pairs(plotMap) do
		UILens.SetLayerGrowthHex(m_PurchasePlot, iPlayer, plotIdx, 1, "GrowthHexBG")
		m_DrawnPlots[plotIdx] = true

		local inst = m_LabelIM:GetInstance()
		local plotX, plotY = Map.GetPlotLocation(plotIdx)
		local worldX, worldY, worldZ = UI.GridToWorld(plotX, plotY)
		inst.Anchor:SetWorldPositionVal(worldX, worldY + 15, worldZ)

		local labelText
		if turnsPerPop and turnsPerPop > 0 then
			labelText = "~" .. tostring(turnsPerPop * popsAway)
		else
			labelText = "?"
		end
		inst.TurnsLabel:SetText(labelText)

		inst.Anchor:SetHide(false)
		inst.LabelAlpha:SetToBeginning()
		inst.LabelAlpha:Play()

		m_ActiveInstances[#m_ActiveInstances + 1] = inst
	end
end

local function OnInterfaceModeChanged(eOldMode, eNewMode)
	if eOldMode == InterfaceModeTypes.CITY_MANAGEMENT then
		ClearOverlay()
	end
	if eNewMode == InterfaceModeTypes.CITY_MANAGEMENT then
		ShowOverlayForCity(UI.GetHeadSelectedCity())
	end
end

-- ===========================================================================
-- Lifecycle
-- ===========================================================================
function OnInit(bIsReload)
	if not ContextPtr:LookUpControl("/InGame/WorldViewControls") then
		Events.LoadScreenClose.Add(OnInit)
		m_bLoadScreenClose = true
		return
	end

	m_LabelIM = InstanceManager:new("PressureLabelInstance", "Anchor", Controls.PressureOverlayContainer)

	Events.InterfaceModeChanged.Add(OnInterfaceModeChanged)

	local pWorldView = ContextPtr:LookUpControl("/InGame/WorldViewControls")
	ContextPtr:ChangeParent(pWorldView)

	if bIsReload and UI.GetInterfaceMode() == InterfaceModeTypes.CITY_MANAGEMENT then
		ShowOverlayForCity(UI.GetHeadSelectedCity())
	end
end

function OnShutdown()
	if m_bLoadScreenClose then
		Events.LoadScreenClose.Remove(OnInit)
	end
	Events.InterfaceModeChanged.Remove(OnInterfaceModeChanged)
end

function Initialize()
	ContextPtr:SetInitHandler(OnInit)
	ContextPtr:SetShutdown(OnShutdown)
	ContextPtr:SetHide(false)
end
Initialize()
