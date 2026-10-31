-- =========================================================================
-- ACF PPC: SHARED FILE  (16)
-- Goes to:  lua/entities/acf_ppc/shared.lua     (replaces the 469-byte placeholder that is there now)
-- Both the server (init.lua) and the client (cl_init.lua) include it.
-- =========================================================================

DEFINE_BASECLASS("acf_base_scalable") -- ACF entities inherit this way (acf_gun/shared.lua:1)

ENT.PrintName = "ACF PPC"
ENT.WireDebugName = "ACF PPC"
ENT.PluralName = "ACF PPCs"
ENT.Author = "ACF Team"
ENT.Spawnable = false      -- tool-only: a PPC made from the Q-menu would skip MakeACFPPC and have no model / physics
ENT.AdminSpawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "CaliberSize")
end

-- Shared. Falls back to the base caliber while the NetworkVar is still 0 (right after Spawn, before ApplyCaliber).
function ENT:GetCaliber()
    local caliber = self:GetCaliberSize()

    if caliber > 0 then return caliber end

    return ACFLazers.PPCNumber("PPCCaliberBase")
end

-- ONE definition of "where the projectile starts": the front of the model, the same rule the lazer's beam uses.
-- OBBMaxs().x is the front end of the model (the PPC's hull is 63.1 long in front of its origin at scale 1), so it grows with the scale.
function ENT:GetMuzzlePos()
    return self:LocalToWorld(Vector(self:OBBMaxs().x, 0, 0))
end

if CLIENT then
    killicon.AddAlias("acf_ppc", "weapon_crossbow")
end
