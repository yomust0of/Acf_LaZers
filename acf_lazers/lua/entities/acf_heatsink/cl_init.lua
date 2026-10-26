-- =========================================================================
-- NEW (15.2). Goes to:  lua/entities/acf_radiator/cl_init.lua
--
-- THE ACF RADIATOR, client part. It draws the radiator as ACF draws any entity, and it draws the RADIUS: while you hold the toolgun (any tool) and are not sitting in a seat, the
-- radiator you are aiming at shows a sphere of its radius around it (config RadDrawAimDistance .. RadDrawLines). Nothing is drawn for a radiator you are not aiming at.
-- =========================================================================

include("shared.lua")

assert(ACFLazers and ACFLazers.Config, "[acf_radiator] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.GetRadRadius, "[acf_radiator] lua/autorun/acf_lazers_config.lua is older than this file (it has no ACFLazers.GetRadRadius). Copy the config of the same batch.")

local Config = ACFLazers.Config

function ENT:Draw()
    self.BaseClass.Draw(self) -- [SEEN acf_engine/cl_init.lua:166]
end

-- The radiator the player is aiming at with the toolgun out (nil when none, or when sitting in a seat).
local function AimedRadiator()
    local ply = LocalPlayer()

    if not IsValid(ply) or ply:InVehicle() then return nil end

    local weapon = ply:GetActiveWeapon()

    if not IsValid(weapon) or weapon:GetClass() ~= "gmod_tool" then return nil end

    local from = ply:EyePos()
    local tr   = util.TraceLine({ start = from, endpos = from + ply:GetAimVector() * Config.RadDrawAimDistance, filter = ply })

    if tr and tr.Hit and IsValid(tr.Entity) and tr.Entity:GetClass() == "acf_radiator" then return tr.Entity end

    return nil
end

-- [KNOW] PostDrawTranslucentRenderables(bDrawingDepth, bDrawingSkybox): drawing here shows up in the world. render.DrawWireframeSphere / render.DrawSphere (a NEGATIVE radius draws
-- the inside of the sphere, so it can be seen from within) take a position, a radius, the numbers of lines and a colour.
hook.Add("PostDrawTranslucentRenderables", "ACFLazers_RadiatorRadius", function(drawingDepth, drawingSkybox)
    if drawingSkybox then return end

    local radiator = AimedRadiator()

    if not radiator then return end

    local radius = ACFLazers.GetRadRadius(radiator:GetWidth())
    local pos    = radiator:WorldSpaceCenter()
    local rgb    = Config.RadDrawColor
    local lines  = math.Clamp(math.floor(Config.RadDrawLines), 4, 64)

    render.SetColorMaterial()
    render.DrawWireframeSphere(pos, radius, lines, lines, Color(rgb[1], rgb[2], rgb[3], 255), false)

    if Config.RadDrawFillAlpha > 0 then
        local fill = Color(rgb[1], rgb[2], rgb[3], math.Clamp(Config.RadDrawFillAlpha, 0, 255))

        render.DrawSphere(pos, radius, lines, lines, fill)
        render.DrawSphere(pos, -radius, lines, lines, fill)
    end
end)
