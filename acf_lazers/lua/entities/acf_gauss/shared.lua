-- =========================================================================
-- ACF GAUSS RIFLE: SHARED FILE  (23)
-- Goes to:  lua/entities/acf_gauss/shared.lua
-- Both the server (init.lua) and the client (cl_init.lua) include it.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName = "ACF Gauss Rifle"
ENT.WireDebugName = "ACF Gauss Rifle"
ENT.PluralName = "ACF Gauss Rifles"
ENT.Author = "ACF Team"
ENT.Spawnable = false      -- tool-only: a rifle made from the Q-menu would skip MakeACFGauss and have no model / physics
ENT.AdminSpawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "CaliberSize")
end

-- Shared. Falls back to the base caliber while the NetworkVar is still 0 (right after Spawn, before ApplyCaliber).
function ENT:GetCaliber()
    local caliber = self:GetCaliberSize()

    if caliber > 0 then return caliber end

    return ACFLazers.GaussNumber("GaussCaliberBase")
end

-- ONE definition of "where the shot starts": the point the config names (GaussMuzzleX / Y / Z, at scale 1, from the model's origin) times the scale of this caliber.
function ENT:GetMuzzlePos()
    local x, y, z = ACFLazers.GetGaussMuzzleOffset(self:GetCaliber())

    return self:LocalToWorld(Vector(x, y, z))
end

if CLIENT then
    killicon.AddAlias("acf_gauss", "weapon_crossbow")
end
