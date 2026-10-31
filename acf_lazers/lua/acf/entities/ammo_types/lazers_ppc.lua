-- =========================================================================
-- THE PPC'S PROJECTILE  (16.1)
-- Goes to:  lua/acf/entities/ammo_types/lazers_ppc.lua      (NEW FILE. ACF loads every file of that folder in every addon, server and client, with no AddCSLuaFile needed)
--
-- An ACF "ammo type" is the rulebook of one kind of projectile: what happens when it hits something and how it is drawn. This one is only ever fired by the PPC (the PPC names it on every
-- projectile: ACFLazers.PPCAmmoID). It is blacklisted for every ACF weapon, so it never shows up in an ammo crate's menu.
--
--   * Flight: ACF's own. The PPC gives the projectile no acceleration (so no drop), no drag and a KillTime (the PPC's PPCLifetime), and ACF deletes it when the time is up, quietly.
--   * The end of the flight (it hit anything: a prop, the world, a player): an HE explosion at the point of impact and nothing else. No penetration, no ricochet, no kinetic damage.
--   * The explosion is ACF's own (ACF.Damage.createExplosion) with the filler the PPC worked out from the shot's energy. Two multipliers are put on the damage each prop takes from it:
--       - PPCPropDamageScalar x the time factor (1 at the muzzle, PPCDamageAtEnd after PPCLifetime seconds of flight, a straight line between) on the BLAST part of the damage
--       - PPCFragmentScalar x the time factor on the FRAGMENT part (0 = none: a pure blast)
--     The damage ACF works out for each prop already follows the blast it received (how far, how much of the prop the blast covers), so the multiplier is "relative to the blast received".
--
-- 16.1 RULES OF THE BLAST (asked for by name):
--   * SAFEZONES, completely: a PPC that stands in a safezone (when it fired, or when the blast happens) makes NO explosion call at all and no heat. For a PPC outside, every entity the blast could
--     reach is asked ACFLazers.IsProtectedBySafezone (the same rules the lazer uses: an addon's flag, or inside one of ACF's own zones). A protected entity goes into the explosion's FILTER, so it takes
--     nothing from the blast (damage, fragments, push) and gets no heat. ACF's own permission check (which looks at the SHOOTER's position) still runs on top of that, inside dealDamage.
--   * NOT ITS OWN CONTRAPTION: the projectile's filter (the shooter's contraption, copied at the muzzle) is handed to the explosion as well, so the blast damages nothing that is welded / parented to the PPC.
--     (A filtered entity is also see-through to the blast's line-of-sight trace: it neither takes damage nor shields what is behind it.)
--   * HEAT (16.6, the user's rule: "only heat props that receive damage, proportional to the amount of damage received"): the damage every part takes from the explosion is added up as ACF deals it
--     (the hook below, which sees every hit of OUR explosion), and when the explosion is over each part that was hurt gets ACFLazers.GetPPCDamageHeat of it as heat. So the parts ACF's own line-of-sight
--     and armour rules never let the blast reach, the shooter's contraption (filtered), safezones, people and anything ACF's permission check refuses get nothing. (16.1 to 16.5 heated every ACF thing
--     inside a sphere, falling off with distance, whether the blast could reach it or not.) Later the heat is to become the way lazers and PPCs do their damage.
--   * No penetration, no world penetration: the projectile explodes on the first thing it touches (PropImpact / WorldImpact return false). [LATER: it may pass light props and explode on the heaviest.]
-- =========================================================================

local ACF       = ACF
local Classes   = ACF.Classes
local AmmoTypes = Classes.AmmoTypes
local Damage    = ACF.Damage
local Clock     = ACF.Utilities.Clock

local ID   = (ACFLazers and ACFLazers.PPCAmmoID) or "LazerPPC"
local Ammo = AmmoTypes.Register(ID, "AP")

function Ammo:OnLoaded()
    Ammo.BaseClass.OnLoaded(self)

    self.Name        = "PPC Bolt"
    self.Description = "The projectile of an ACF PPC. Made only by a PPC."
    self.Blacklist   = ACF.GetWeaponBlacklist({}) -- every weapon: not in any ammo menu
end

-- No penetration: the PPC's projectile does its damage with the explosion.
function Ammo:GetPenetration()
    return 0
end

if SERVER then
    local Objects = Damage.Objects

    -- The explosion being made right now: { Info = the DamageInfo handed to ACF, Blast = multiplier, Frag = multiplier }. Nil the rest of the time. The hook below only touches damage whose
    -- DamageInfo IS this table's Info, so an explosion started by anything else (a prop blown up by ours, say) is left alone.
    local Active

    -- Everything the projectile touches ends its flight: ACF asks the ammo type what to do on a hit, and "false" means "nothing special, the flight is over" (OnFlightEnd below).
    function Ammo:PropImpact()
        return false
    end

    function Ammo:WorldImpact()
        return false
    end

    -- Did the PPC stand in a safezone when it fired (the projectile carries the answer: PPCSafe), or does it stand in one now (if it is still there)?
    local function ShooterProtected(Bullet)
        if Bullet.PPCSafe then return true end

        local Gun = Bullet.Gun

        return IsValid(Gun) and ACFLazers.IsProtectedBySafezone(Gun) or false
    end

    -- The list ACF's explosion gets as its filter: a COPY of the projectile's own (the shooter's contraption: ACF adds to the list it is given, and that must not grow the projectile's or the
    -- contraption's list), plus every PROTECTED entity the blast could reach (the same sphere ACF searches). Returns the list.
    local function BlastFilter(Bullet, Position, Radius)
        local Filter = {}

        for _, Ent in ipairs(Bullet.Filter or {}) do Filter[#Filter + 1] = Ent end

        for _, Ent in ipairs(ents.FindInSphere(Position, Radius)) do
            if ACFLazers.IsProtectedBySafezone(Ent) then
                Filter[#Filter + 1] = Ent
            end
        end

        return Filter
    end

    -- Can this entity be heated? Only things ACF knows (props, guns, engines ...), not people / NPCs, and not things ACF is already destroying.
    local function CanHeat(Ent)
        if not IsValid(Ent) or not Ent.ACF then return false end
        if Ent.ACF.Type == "Squishy" then return false end
        if Ent.ACF_Killed or Ent.Exploding then return false end

        return true
    end

    -- THE HEAT PASS [CHANGED 28] (16.6). `Hits` = { [entity] = the damage points ACF's explosion did to it }, collected by the hook below. Each part that was hurt gets ACFLazers.GetPPCDamageHeat of its damage
    -- (the config's PPCHeatPerDamage, held to PPCHeatMaxPct of what takes THIS part to the HOT temperature, so the part's heat capacity is asked from the heat store). The permission and safezone
    -- rules need no check here: a part ACF refused, or the blast filtered out, was never hurt and is not in the list. The safezone helper is asked once more all the same (a part can move into a zone
    -- while the blast works).
    local function HeatPass(Hits)
        local Heat = ACFLazers.Heat

        if not (Heat and Heat.Add and Heat.GetCapacity) or type(Hits) ~= "table" then return end

        for Ent, Taken in pairs(Hits) do
            if CanHeat(Ent) and not ACFLazers.IsProtectedBySafezone(Ent) then
                local KJ = ACFLazers.GetPPCDamageHeat(Taken, Heat.GetCapacity(Ent))

                if KJ > 0 then
                    Heat.Add(Ent, KJ)
                end
            end
        end
    end

    function Ammo:OnFlightEnd(Bullet, Trace)
        local Config = ACFLazers

        -- A missing helper (an older config) means NO blast, never an unprotected one: the safezone helpers are part of the list on purpose.
        if Config and Config.GetPPCDamageMult and Config.PPCNumber and Config.IsProtectedBySafezone and Config.GetPPCDamageHeat and Bullet.Pos and Bullet.Flight then
            local Filler   = Bullet.FillerMass or 0
            local HitPos   = (Trace and Trace.HitPos) or Bullet.Pos
            local Position = HitPos - Bullet.Flight:GetNormalized() * Config.PPCNumber("PPCBlastBackoff") -- a little in front of the surface, not inside it

            if Filler > 0 and not ShooterProtected(Bullet) then
                local Age      = Clock.CurTime - (Bullet.PPCStart or Clock.CurTime)
                local TimeMult = Config.GetPPCDamageMult(Age)
                local Fragment = math.max(Filler * Config.PPCNumber("PPCFragMassRatio"), 0.001) -- a zero casing would divide by zero inside ACF's explosion
                local DmgInfo  = Objects.DamageInfo(Bullet.Owner, Bullet.Gun)
                local Radius   = Damage.getBlastRadius(Filler)

                local Hits = {} -- [CHANGED 28] entity -> the damage points this explosion did to it (filled by the hook below)

                Active = {
                    Info  = DmgInfo,
                    Blast = Config.PPCNumber("PPCPropDamageScalar") * TimeMult,
                    Frag  = Config.PPCNumber("PPCFragmentScalar") * TimeMult,
                    Hits  = Hits,
                }

                -- pcall: if ACF's explosion throws, the multipliers must not stay switched on for the next explosion
                local Ok, Err = pcall(function()
                    Damage.createExplosion(Position, Filler, Fragment, BlastFilter(Bullet, Position, Radius), DmgInfo)
                end)

                Active = nil

                if not Ok then
                    ErrorNoHalt("[acf_ppc] the explosion failed: " .. tostring(Err) .. "\n")
                end

                -- The heat comes after the blast and does not depend on it: a blast that fails half way still heats what it hurt before, and a failing heat pass never breaks the blast (or the removal below).
                local HeatOk, HeatErr = pcall(HeatPass, Hits)

                if not HeatOk then
                    ErrorNoHalt("[acf_ppc] the heat pass failed: " .. tostring(HeatErr) .. "\n")
                end
            end
        end

        Bullet.KillTime = Clock.CurTime

        Ammo.BaseClass.OnFlightEnd(self, Bullet, Trace) -- ACF's own: removes the projectile
    end

    -- ACF calls this for every thing it damages, with the DamageResult it worked out (Area x (penetration / thickness)^2 is the damage) and the DamageInfo. Our explosion's DamageInfo is marked
    -- by the table above; scaling the Area scales the damage in a straight line and leaves ACF's penetration and loss maths alone.
    hook.Add("ACF_OnDamageEntity", "ACFLazers_PPCBlast", function(Ent, DmgResult, DmgInfo)
        local Blast = Active

        if not Blast or Blast.Info ~= DmgInfo then return end

        local Kind = DmgInfo:GetType()
        local Mult

        if Kind == DMG_BLAST then
            Mult = Blast.Blast
        elseif Kind == DMG_BULLET then
            Mult = Blast.Frag
        else
            return
        end

        DmgResult:SetArea(DmgResult:GetArea() * Mult)

        local Custom = DmgResult:GetDamage() -- "custom damage": ACF's own explosion does not set it, but if something did, it is scaled the same way

        if isnumber(Custom) then DmgResult:SetDamage(Custom * Mult) end

        -- [CHANGED 28] what this hit does, as ACF will work it out (DamageResult:Compute is the very call ACF's damage handler makes), is kept for the heat pass
        if Blast.Hits and IsValid(Ent) then
            local Taken = DmgResult:Compute().Damage

            if isnumber(Taken) and Taken == Taken and Taken > 0 then Blast.Hits[Ent] = (Blast.Hits[Ent] or 0) + Taken end
        end
    end)
else
    -- The picture of the end of the flight: ACF's own explosion picture, sized by the filler.
    function Ammo:ImpactEffect(_, Bullet)
        Damage.explosionEffect(Bullet.SimPos, Bullet.SimFlight, Bullet.FillerMass)
    end

    -- ACF's client effect has just made the flying ball (model and scale from the values the PPC networked). Two small touches, both optional and harmless if they do not take:
    --   * the material the config asks for (PPCBallMaterial; empty = the model's own)
    --   * ACF keeps a client ball for 45 seconds, whatever the server does. The server deletes the projectile after PPCLifetime, so the ball is told to stop at the same time.
    hook.Add("ACF_OnCreateBulletEffect", "ACFLazers_PPCBall", function(Effect, BulletData)
        if BulletData.AmmoType ~= ID then return end

        local Crate = BulletData.Crate

        if not IsValid(Crate) then return end

        local Material = Crate:GetNW2String("FlightMaterial", "")

        if Material ~= "" then Effect:SetMaterial(Material) end

        local Life = Crate:GetNW2Float("FlightLife", 0)

        if Life > 0 and Life < 45 and isnumber(Effect.CreateTime) then
            Effect.CreateTime = Effect.CreateTime + Life - 45 -- ACF's effect ends when CreateTime is more than 45 seconds old
        end
    end)
end
