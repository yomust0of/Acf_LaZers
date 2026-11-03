-- =========================================================================
-- NAPALM, THE FLAMETHROWER'S FUEL  (22)
-- Goes to:  lua/acf/entities/fuel_types/napalm.lua      (NEW FILE. ACF loads every file of that folder in every addon, server and client, with no AddCSLuaFile needed)
--
-- A fuel type in ACF's own sense (like lua/acf/entities/fuel_types/petrol.lua): ACF's scalable fuel tank can be filled with it, and it is made FULL at the start. No engine burns it
-- (an engine only links to a tank whose fuel is in its own list, and napalm is in nobody's but the flamethrower's), and the flamethrower (lua/entities/acf_flamer) only burns this.
-- The density (kg per litre) is the config's FlameNapalmDensity (a full tank weighs its steel plus that per litre), 0.9 when the config is not loaded yet.
-- =========================================================================

local FuelTypes = ACF.Classes.FuelTypes

local Density = 0.9

if ACFLazers and ACFLazers.FlameNumber then
    Density = ACFLazers.FlameNumber("FlameNapalmDensity")
end

FuelTypes.Register((ACFLazers and ACFLazers.FlameFuelID) or "Napalm", {
    Name    = "Napalm",
    Density = Density,
})
