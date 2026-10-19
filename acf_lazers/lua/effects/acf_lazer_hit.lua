-- =========================================================================
-- acf_lazer_hit : REPLACEMENT client effect (v3)
-- Put this file at:  lua/effects/acf_lazer_hit.lua   (same place as v2; just overwrite it)
--
-- v2 re-used ACF's AP-shell effects, which come with cannon decals and "clunk" hit sounds. You didn't want either.
-- v3 draws its OWN particles: sparks on everything, plus a dust puff / plume on rock and dirt. No decals. No sounds.
-- (The burn / rumble sounds are separate: they are loops on the server, see ENT:UpdateBeamSounds in init.lua.)
--
-- The server (ENT:SendHitEffect in entities/acf_lazer/init.lua) calls util.Effect("acf_lazer_hit", ...) about 20 times a second
-- per firing lazer, and every client runs this file. Fields we receive:
--   Origin     = where the beam hit
--   Normal     = the SURFACE normal (stuff flies OUT of the surface)
--   Radius     = lazer caliber in mm
--   DamageType = surface material number (MAT_*), carried in a field that is just a whole number to the engine
--   Magnitude  = intensity: 1 = beam burning it, 2 = beam burned through, 3 = destroyed it
--
-- Where every ACF name used here was [SEEN]:
--   ACF.Utilities.Effects.CreateEffect   acf/core/utilities/effects/effects_sh.lua:10
--   Effects.MaterialColors               acf/core/utilities/effects/effects_cl.lua:4   (colour per surface)
--   "Sparks" effect, particle sprite names (flamelet, fleck_tile, smokesprites): effects/acf_penetration.lua:48-150
-- =========================================================================

-- Soft ground gets a tall dirt plume; hard ground (concrete / tile) gets a small flat puff.
local SoftGround = {
    [MAT_DIRT]  = true,
    [MAT_GRASS] = true,
    [MAT_SAND]  = true,
    [MAT_SNOW]  = true,
}

function EFFECT:Init(Data)
    local Effects = ACF.Utilities.Effects
    local Colors  = Effects.MaterialColors

    local Origin    = Data:GetOrigin()
    local Normal    = Data:GetNormal()
    local Caliber   = Data:GetRadius()
    local MatType   = Data:GetDamageType()
    local Intensity = math.max(Data:GetMagnitude(), 1)

    if Normal:IsZero() then Normal = Vector(0, 0, 1) end

    -- "Scale" is the size of the show: 1 is the smallest we ever draw. A 100 mm lazer burning = 1, a 300 mm one = 3,
    -- and burning through / destroying something makes it bigger (x1.5, x2). Everything below is multiplied by it.
    local Scale = math.max(1, ACFLazers.GetScale(Caliber) * (0.5 + 0.5 * Intensity))
    local Tint = Colors[MatType] or Colors.Default
    local Earth = ACFLazers.GetSurfaceClass(MatType) == "earth"

    -- Sparks: every surface gets them (the beam is hot), but rock / dirt gets fewer.
    local SparkScale = Earth and math.max(1, Scale * 0.5) or Scale

    Effects.CreateEffect("Sparks", {
        Origin    = Origin,
        Normal    = Normal,
        Magnitude = SparkScale,
        Scale     = SparkScale,
        Radius    = SparkScale,
    })

    local Emitter = ParticleEmitter(Origin)
    if not IsValid(Emitter) then return end

    self:Embers(Emitter, Origin, Normal, Scale)

    if Earth then
        self:Dust(Emitter, Origin, Normal, Scale, Tint, SoftGround[MatType])
    else
        self:Flecks(Emitter, Origin, Normal, Scale, Tint)
    end

    Emitter:Finish()
end

-- Little glowing bits thrown off the spot (every surface).
function EFFECT:Embers(Emitter, Origin, Normal, Scale)
    for _ = 1, math.ceil(2 * Scale) do
        local Ember = Emitter:Add("particles/flamelet" .. math.random(1, 5), Origin)

        if Ember then
            local Spread = Vector(math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(-1, 1))

            Ember:SetVelocity((Normal + Spread) * math.Rand(30, 80) * Scale)
            Ember:SetLifeTime(0)
            Ember:SetDieTime(math.Rand(0.15, 0.4) * math.sqrt(Scale))
            Ember:SetStartAlpha(255)
            Ember:SetEndAlpha(0)
            Ember:SetStartSize(2 * Scale)
            Ember:SetEndSize(0)
            Ember:SetStartLength(4 * Scale)
            Ember:SetEndLength(0)
            Ember:SetRoll(math.Rand(0, 360))
            Ember:SetAirResistance(20)
            Ember:SetGravity(Vector(0, 0, -100))
            Ember:SetColor(255, 200, 140)
        end
    end
end

-- Hard / metal surfaces: a few bits of debris, in the surface's colour, flying out and falling.
function EFFECT:Flecks(Emitter, Origin, Normal, Scale, Tint)
    for _ = 1, math.ceil(2 * Scale) do
        local Fleck = Emitter:Add("effects/fleck_tile" .. math.random(1, 2), Origin)

        if Fleck then
            local Spread = Vector(math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(0, 1)) -- never aimed below the hit point

            Fleck:SetVelocity((Normal + Spread) * 120 * math.Rand(0.6, 1.2))
            Fleck:SetLifeTime(0)
            Fleck:SetDieTime(math.Rand(0.4, 0.9) * math.sqrt(Scale))
            Fleck:SetStartAlpha(255)
            Fleck:SetEndAlpha(0)
            Fleck:SetStartSize(0.8 * Scale)
            Fleck:SetEndSize(0.8 * Scale)
            Fleck:SetRoll(math.Rand(0, 360))
            Fleck:SetRollDelta(math.Rand(-3, 3))
            Fleck:SetAirResistance(100)
            Fleck:SetGravity(Vector(0, 0, -650))
            Fleck:SetColor(Tint.r, Tint.g, Tint.b)
        end
    end
end

-- Rock / dirt: a dust puff (concrete) or a taller plume (soft ground), coloured like the ground, plus a few crumbs.
function EFFECT:Dust(Emitter, Origin, Normal, Scale, Tint, Plume)
    local Count  = math.ceil((Plume and 2.5 or 1.5) * Scale)
    local Lift   = Plume and 90 or 45  -- how fast the dust rises along the surface normal
    local Growth = Plume and 9 or 5    -- how big the cloud ends up

    for _ = 1, Count do
        local Smoke = Emitter:Add("particle/smokesprites_000" .. math.random(1, 9), Origin)

        if Smoke then
            local Spread = Vector(math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(0, 1))

            Smoke:SetVelocity(Normal * math.Rand(0.5, 1) * Lift * math.sqrt(Scale) + Spread * 25)
            Smoke:SetLifeTime(0)
            Smoke:SetDieTime(math.Rand(0.5, 1) * (Plume and 1.3 or 0.8))
            Smoke:SetStartAlpha(math.Rand(60, 130))
            Smoke:SetEndAlpha(0)
            Smoke:SetStartSize(2 * Scale)
            Smoke:SetEndSize(Growth * Scale)
            Smoke:SetRoll(math.Rand(150, 360))
            Smoke:SetRollDelta(math.Rand(-0.2, 0.2))
            Smoke:SetAirResistance(200)
            Smoke:SetGravity(Vector(math.Rand(-5, 5), math.Rand(-5, 5), -40))
            Smoke:SetColor(Tint.r, Tint.g, Tint.b)
        end
    end

    -- crumbs
    for _ = 1, math.ceil(1.5 * Scale) do
        local Crumb = Emitter:Add("effects/fleck_tile" .. math.random(1, 2), Origin)

        if Crumb then
            local Spread = Vector(math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(0, 1))

            Crumb:SetVelocity((Normal + Spread) * 100 * math.Rand(0.6, 1.2))
            Crumb:SetLifeTime(0)
            Crumb:SetDieTime(math.Rand(0.4, 0.9) * math.sqrt(Scale))
            Crumb:SetStartAlpha(255)
            Crumb:SetEndAlpha(0)
            Crumb:SetStartSize(1 * Scale)
            Crumb:SetEndSize(1 * Scale)
            Crumb:SetRoll(math.Rand(0, 360))
            Crumb:SetRollDelta(math.Rand(-3, 3))
            Crumb:SetAirResistance(100)
            Crumb:SetGravity(Vector(0, 0, -650))
            Crumb:SetColor(Tint.r, Tint.g, Tint.b)
        end
    end
end

function EFFECT:Think()
    return false
end

function EFFECT:Render()
end
