-- GameData1
-- Author: Ben
-- DateCreated: 9/20/2023 5:08:58 PM
--------------------------------------------------------------


-- Suppress Normal City Expansion
UPDATE GlobalParameters
	SET Value = 1
	WHERE Name = 'PLOT_INFLUENCE_MAX_ACQUIRE_DISTANCE' OR Name = 'CITY_MAX_BUY_PLOT_RANGE';