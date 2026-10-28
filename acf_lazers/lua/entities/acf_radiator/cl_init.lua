-- =========================================================================
-- NEW (15.2), CHANGED (15.3, 15.4). Goes to:  lua/entities/acf_radiator/cl_init.lua
--
-- THE ACF RADIATOR, client part. It draws the radiator as ACF draws any entity, and it draws the RADIUS: while you hold the toolgun (any tool) and are not sitting in a seat, the
-- radiator you are aiming at shows a sphere of its radius around it (config RadDrawAimDistance .. RadDrawLines). Nothing is drawn for a radiator you are not aiming at.
-- 15.4: the puffs use ACF's own smoke sprites (RadPuffMaterials); the steam sounds fade out on the server.
-- 15.3: while the radiator VENTS (the server sets the network flag ACFRadVent) it throws a cloud of steam out of its top, in the colour the tool gave it (ACFRadColor). The server plays the
-- sounds; this file only draws. The numbers of the cloud are the config's RadPuff... knobs.
-- =========================================================================

include("shared.lua")

assert(ACFLazers and ACFLazers.Config, "[acf_radiator] lua/autorun/acf_lazers_config.lua is missing or did not load")
assert(ACFLazers.GetRadRadius and ACFLazers.PickRadPuffMaterial and ACFLazers.PickRadPuffSpot, "[acf_radiator] lua/autorun/acf_lazers_config.lua is older than this file (it has no ACFLazers.PickRadPuffMaterial). Copy the config of the same batch.")

local Config = ACFLazers.Config

function ENT:Draw()
    self.BaseClass.Draw(self) -- [SEEN acf_engine/cl_init.lua:166]
end

-- ===================== THE STEAM ===================== [CHANGED 1]
-- [KNOW] ParticleEmitter(pos, use3D) makes an emitter; emitter:Add(material, pos) returns a particle that is shaped with SetDieTime / SetStartAlpha / SetEndAlpha / SetStartSize / SetEndSize /
-- SetColor / SetVelocity / SetGravity / SetAirResistance / SetRoll / SetRollDelta; emitter:Finish() removes the emitter. ENT:Think runs every frame on the client; this asks for that explicitly.
function ENT:Think()
    -- ACF's scalable base needs its own Think to run (it finishes the entity's set-up) [SEEN acf/entities/base_scalable/cl_init.lua:38]
    if self.BaseClass and self.BaseClass.Think then self.BaseClass.Think(self) end

    self:SetNextClientThink(CurTime())

    if not self:GetNW2Bool("ACFRadVent", false) then
        self.PuffCarry = 0
        self.PuffLast  = nil

        return true
    end

    local now  = CurTime()
    local dt   = now - (self.PuffLast or now)
    local ply  = LocalPlayer()

    self.PuffLast = now

    if self:IsDormant() or (IsValid(ply) and ply:GetPos():DistToSqr(self:GetPos()) > Config.RadPuffDistance * Config.RadPuffDistance) then return true end

    local kind  = self:GetKind() -- [CHANGED 3] (15.8)
    local scale = ACFLazers.GetRadScale(self:GetWidth(), kind)
    local count

    count, self.PuffCarry = ACFLazers.GetRadPuffs(scale, dt, self.PuffCarry)

    if count <= 0 then return true end

    self.PuffEmitter = self.PuffEmitter or ParticleEmitter(self:GetPos(), false)

    local emitter = self.PuffEmitter

    if not emitter then return true end

    local r, g, b  = ACFLazers.UnpackRadColor(self:GetNW2Int("ACFRadColor", -1))
    local mins     = self:OBBMins()
    local maxs     = self:OBBMaxs()
    local up       = self:GetUp()
    local life     = math.max(Config.RadPuffLife, 0.1)
    local size     = math.max(Config.RadPuffSize, 1) * scale
    local speed    = math.max(Config.RadPuffSpeed, 0) * scale

    for _ = 1, count do
        -- a random spot on the top of the model (a rectangle for the heatsink, a disc for the roundsink)
        local px, py = ACFLazers.PickRadPuffSpot(kind, math.Rand(0, 1), math.Rand(0, 1), mins.x, maxs.x, mins.y, maxs.y)
        local pos = self:LocalToWorld(Vector(px, py, maxs.z))
        local puff = emitter:Add(ACFLazers.PickRadPuffMaterial(math.Rand(0, 1)), pos) -- [CHANGED 2] one of ACF's own smoke sprites (the old guess had no texture)

        if puff then
            puff:SetDieTime(life * math.Rand(0.7, 1.15))
            puff:SetStartAlpha(math.Rand(150, 210))
            puff:SetEndAlpha(0)
            puff:SetStartSize(size * math.Rand(0.7, 1.1))
            puff:SetEndSize(size * 4 * math.Rand(0.8, 1.2))
            puff:SetColor(r, g, b)
            puff:SetVelocity(up * speed * math.Rand(0.6, 1.2) + VectorRand() * speed * 0.25)
            puff:SetGravity(Vector(0, 0, 25)) -- steam drifts up
            puff:SetAirResistance(60)
            puff:SetRoll(math.Rand(0, 360))
            puff:SetRollDelta(math.Rand(-1.5, 1.5))
        end
    end

    return true
end

function ENT:OnRemove()
    if self.BaseClass and self.BaseClass.OnRemove then self.BaseClass.OnRemove(self) end

    if self.PuffEmitter then
        self.PuffEmitter:Finish()
        self.PuffEmitter = nil
    end
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

    local radius = ACFLazers.GetRadRadius(radiator:GetWidth(), radiator:GetKind())
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
