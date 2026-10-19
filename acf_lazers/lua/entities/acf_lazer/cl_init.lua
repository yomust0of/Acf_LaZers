-- Goes to:  lua/entities/acf_lazer/cl_init.lua
--
-- CHANGES vs the cl_init.lua you have now (handoff 9.7). Search this file for [CHANGED n].
--   [CHANGED 1] The solid pass now runs ACF's own Draw (self.BaseClass.Draw) instead of a bare DrawModel(). ACF's Draw is the code that draws the blue outline ("halo") around an
--               entity you look at, and that calls Wiremod's Wire_Render [SEEN acf_base_simple/modules/cl.lua:14-30; the generator and ACF's engine call it the same way]. Our bare
--               DrawModel() skipped all of that, which is why the lazer never showed the outline.
--   [CHANGED 2] A see-through lazer (colour alpha under 255, or any render mode but Normal) is drawn in the see-through pass. Before, that pass drew only the beam, and the solid
--               pass does not show a model the engine counts as translucent, so a lazer coloured with alpha under 255 vanished completely. (The beam is unchanged: it was never
--               affected by the model's colour.)

include("shared.lua")

assert(ACFLazers and ACFLazers.Config, "[acf_lazer] lua/autorun/acf_lazers_config.lua is missing or did not load")

local Config   = ACFLazers.Config -- lua/autorun/acf_lazers_config.lua (shared)
local LaserMat = Material("effects/laser1")
local GlowMat  = Material("sprites/light_glow02_add")

-- "Call both Draw (solid pass) and DrawTranslucent (see-through pass) for this entity." [KNOW]
ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:Initialize()
    self.BeamBoundsSet = false -- have we stretched the render box to cover the beam?

    self.BaseClass.Initialize(self) -- REQUIRED: the scalable base marks itself initialized here; without it
                                    -- its Think would re-run our Initialize forever (base_scalable/cl_init.lua:20-24, 38-44)
end

-- Keep the render box wrapped around the beam while firing, and put the model's own box back afterwards.
-- (base_scalable sets the model's box with SetRenderBounds(GetCollisionBounds()) at base_scalable/cl_init.lua:62; we do the same on stop.)
function ENT:UpdateBeamBounds()
    local firing = self.GetIsFiring and self:GetIsFiring()

    if not firing then
        if self.BeamBoundsSet then
            self:SetRenderBounds(self:GetCollisionBounds())
            self.BeamBoundsSet = false
        end

        return
    end

    local startPos = self:GetMuzzlePos()
    local endPos   = startPos + self:GetBeamDirection() * self:GetBeamLength() -- the wobbled direction
    local padding  = Vector(50, 50, 50)

    -- World-space box from the muzzle to the beam end, a little fatter than the beam
    local minVec = Vector(
        math.min(startPos.x, endPos.x),
        math.min(startPos.y, endPos.y),
        math.min(startPos.z, endPos.z)
    ) - padding

    local maxVec = Vector(
        math.max(startPos.x, endPos.x),
        math.max(startPos.y, endPos.y),
        math.max(startPos.z, endPos.z)
    ) + padding

    self:SetRenderBoundsWS(minVec, maxVec)
    self.BeamBoundsSet = true
end

function ENT:Think()
    self:UpdateBeamBounds() -- 

    -- the scalable base's Think (base_scalable/cl_init.lua:38) must keep running; it is what re-runs Initialize if it was missed
    local baseThink = self.BaseClass.Think

    if baseThink then
        return baseThink(self)
    end
end

-- [CHANGED 2] Is the lazer's MODEL see-through? The engine files an entity under "translucent" when its colour alpha is under 255 or its render mode is not Normal [KNOW]
-- (the Colour tool can set either). Such a model is drawn in the see-through pass, not the solid one. Exactly one of the two passes draws it, never both.
function ENT:ModelIsSeeThrough()
    return self:GetColor().a < 255 or self:GetRenderMode() ~= RENDERMODE_NORMAL
end

-- Solid pass: the model, drawn by ACF's own Draw so the blue outline and the Wiremod render hook work like on every other ACF entity. [CHANGED 1]
function ENT:Draw()
    if self:ModelIsSeeThrough() then return end -- [CHANGED 2] DrawTranslucent draws it instead

    self.BaseClass.Draw(self)
end

-- See-through pass: the model when it is see-through, then the beam.
function ENT:DrawTranslucent()
    if self:ModelIsSeeThrough() then
        self.BaseClass.Draw(self) -- [CHANGED 2]
    end

    if not (self.GetIsFiring and self:GetIsFiring()) then return end

    -- The SERVER decided how long the beam is. 0 means "not known yet", so draw nothing.
    local length = self:GetBeamLength()
    if length <= 0 then return end

    local startPos = self:GetMuzzlePos() -- same helper as the server, so beam origin matches
    local endPos   = startPos + self:GetBeamDirection() * length -- the wobbled direction, same function the server traces with

    -- Caliber & Beam Width
    local caliber   = self:GetCaliber()
    local beamWidth = math.Clamp(caliber * 0.2, 10, 100)

    -- Colour: this lazer's own custom colour when its box is ticked, otherwise the config's palettes (size picks the spot along the palette,
    -- ColorSet picks which palette). The beam is always fully opaque (9.7: the opacity setting is gone).
    local override

    if self:GetUseCustomColor() then
        local rgb = self:GetCustomColorRGB()

        override = Color(rgb.x, rgb.y, rgb.z)
    end

    local beamColor = ACFLazers.GetBeamColor(caliber, self:GetColorSet(), override)

    -- Texture UV Scroll
    local scrollSpeed  = CurTime() * -15
    local textureScale = length / 128

    render.SetMaterial(LaserMat)
    render.DrawBeam(startPos, endPos, beamWidth, scrollSpeed, scrollSpeed + textureScale, beamColor)

    if self:GetBeamHit() then
        render.SetMaterial(GlowMat)
        render.DrawSprite(endPos, beamWidth * 2.5, beamWidth * 2.5, beamColor)
    end
end
