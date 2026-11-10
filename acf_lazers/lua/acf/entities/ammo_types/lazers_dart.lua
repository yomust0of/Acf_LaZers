-- =========================================================================
-- THE DART: THE GAUSS RIFLE'S ONE AMMO TYPE  (23.1)
-- Goes to:  lua/acf/entities/ammo_types/lazers_dart.lua      (ACF loads every file of that folder in every addon, server and client, with no AddCSLuaFile needed)
--           lua/acf/entities/ammo_types/lazers_inert.lua of handoff 23 is GONE: delete it. The DART is the box's ammo AND the rifle's projectile, so there is one type, not two.
--
-- An ACF "ammo type" is the rulebook of one kind of round. The DART is a child of ACF's own APFSDS (armour piercing fin stabilized, the dart): it gets ACF's long-rod penetration (the Lanz Odermatt
-- equation, a tungsten rod), its ricochet rules, its impact pictures, its flight model and its icon. The three numbers that make it a dart are knobs: the rod is GaussDartScale (0.35) of the
-- caliber wide, ricochets from GaussDartRicochet (80) degrees, and its best penetration speed is GaussDartLimitVel (1000 m/s). What makes it a GAUSS dart:
--   * No propellant, no filler, no sabot: just the rod, GaussDartLength calibers long, its mass scaled by GaussDartDensityMult (1 = ACF's tungsten). The muzzle speed is not worked out from a
--     powder charge: the rifle sets it (GaussSpeedSmall .. GaussSpeedBig). A round takes the room of a full-caliber cylinder in the box (the rod rides in its own armature).
--   * No drop and no drag: the rifle gives the projectile a ZERO acceleration (ACF uses its gravity when there is none) and a drag coefficient of 0, so it flies in a straight line until it hits
--     something or GaussLifetime seconds are over. (Penetrating a prop still bends nothing: ACF only changes its speed.)
--   * The safezone rule of the PPC: a rifle that stood in a safezone when it fired (the projectile carries the answer: GaussSafe) fires harmless darts, and a DART never hurts anything a safezone
--     protects (ACFLazers.IsProtectedBySafezone, the same rules the lazer uses): it simply ends on it, dealing nothing.
--   * A BOX OF DARTS IS INERT. The box is an ordinary ACF ammo crate (spawned from the gauss tool with Shift + left-click, the way the flamethrower tool spawns napalm tanks) holding this type. There
--     is nothing in a DART that can burn or blow up, so the box cannot:
--       - damage: the box takes damage like a plain prop (ACF's own prop damage, Damage.doPropDamage). It never rolls the dice for a cook-off and never detonates; when its health runs out ACF
--         breaks it into pieces like any other prop, and the rounds are gone with it.
--       - the box is not "explosive" for ACF's chain reactions (Crate.IsExplosive is false): a blast nearby breaks it as a prop instead of setting it off.
--       - the two ACF hooks that decide a cook-off (ACF_PreBurnAmmo) and an explosion (ACF_PreExplodeAmmo) say NO for such a box, as a second wall.
--     Everything is undone when the crate is changed to another ammo type (OnLast puts ACF's own behaviour back).
-- It is blacklisted for every ACF weapon except the rifle's class (the weapon class is in lazers_gauss.lua), so it never shows up in an ACF gun's ammo menu and an ACF gun cannot be linked to a box
-- of it (the gauss rifle checks the box itself: lua/entities/acf_gauss/init.lua).
-- LATER (asked for): effects that show it is a gauss round. The client hook for that goes at the bottom.
-- =========================================================================

local ACF       = ACF
local Classes   = ACF.Classes
local AmmoTypes = Classes.AmmoTypes

local ID    = (ACFLazers and ACFLazers.GaussAmmoID) or "LazerDart"
local CLASS = (ACFLazers and ACFLazers.GaussClassID) or "LazerGauss"
local Ammo  = AmmoTypes.Register(ID, "APFSDS")

local function Number(name, default)
    if ACFLazers and ACFLazers.GaussNumber then return ACFLazers.GaussNumber(name) end

    return default
end

function Ammo:OnLoaded()
    Ammo.BaseClass.OnLoaded(self)

    self.Name        = "DART"
    self.Description = "The round of a gauss rifle: a long tungsten dart that ACF treats like an APFSDS round. No propellant and no explosive, so a box of them cannot cook off or explode."
    self.Blacklist   = ACF.GetWeaponBlacklist({ [CLASS] = true }) -- every weapon but the gauss rifle's class: not in any ACF weapon's menu, and no ACF gun can take it
end

-- ACF's APFSDS numbers with the three dart knobs in their place (APFSDS: ProjScale 0.35, LimitVel 1000, Ricochet 80, ShovePower 0.2). UpdateRoundData is APFSDS's own (the tungsten rod).
function Ammo:BaseConvert(ToolData)
    local Data, GUIData = ACF.RoundBaseGunpowder(ToolData, { ProjScale = Number("GaussDartScale", 0.35) }) -- ratio of the rod to the caliber

    Data.ShovePower = 0.2
    Data.LimitVel   = Number("GaussDartLimitVel", 1000) -- most efficient penetration speed in m/s
    Data.Ricochet   = Number("GaussDartRicochet", 80)   -- base ricochet angle

    self:UpdateRoundData(ToolData, Data, GUIData)

    return Data, GUIData
end

-- The round is the DART of the rifle's own caliber, however the data was asked for: the length comes from the config, there is no propellant. The caliber itself is held to the rifle's range here
-- (ACF does not clamp the caliber of a crate for a scalable class: a dupe or a console command with a junk number would otherwise make a box ACF's round maths cannot work with). A CRATE (ACF passes
-- the weapon class as the second argument) also never has a tracer: the tracer is a choice of the rifle (the tool), which builds its own data.
function Ammo:VerifyData(ToolData, Class)
    Ammo.BaseClass.VerifyData(self, ToolData, Class)

    local Config = ACFLazers

    if not (Config and Config.ClampGaussCaliber and Config.GetGaussDartLengthCm) then return end

    local Caliber = Config.ClampGaussCaliber(ToolData.Caliber)

    ToolData.Caliber    = Caliber
    ToolData.Projectile = math.Round(Config.GetGaussDartLengthCm(Caliber), 2)
    ToolData.Propellant = 0

    if Class then ToolData.Tracer = false end
end

if SERVER then
    local Damage = ACF.Damage

    -- ACF's round data for a rifle of this caliber (the rifle hands in ACFLazers.GetGaussToolData; a crate hands in its own data), made solid: no propellant, no filler, no sabot, no drag.
    function Ammo:ServerConvert(ToolData)
        local Data = Ammo.BaseClass.ServerConvert(self, ToolData)

        if ACFLazers and ACFLazers.GaussInertRound then ACFLazers.GaussInertRound(Data) end

        return Data
    end

    -- What the clients read from the "crate" of a bullet (here: the rifle, whose index the bullet carries) to draw the flying projectile [SEEN effects/acf_bullet_effect.lua; ap.lua Ammo:Network]: the
    -- ammo type, the caliber (of the ROD), the mass, the drag, the tracer, the acceleration (a ZERO vector: no gravity) and the model. A crate gets the same, with no tracer.
    function Ammo:Network(Entity, BulletData)
        Entity:SetNW2String("AmmoType", ID)
        Entity:SetNW2Float("Caliber", BulletData.Diameter)
        Entity:SetNW2Float("ProjMass", BulletData.ProjMass)
        Entity:SetNW2Float("PropMass", 0)
        Entity:SetNW2Float("DragCoef", 0)
        Entity:SetNW2Float("Tracer", BulletData.Tracer or 0)
        Entity:SetNW2Vector("Accel", Vector(0, 0, 0))

        local Flight = self:ResolveModel("Flight")

        if Flight then
            Entity:SetNW2String("FlightModel", Flight.Model)
            Entity:SetNW2Int("FlightBodygroup", Flight.Bodygroup)
        end
    end

    -- Is this entity one a safezone protects? (A missing helper means NOT protected: the shooter's own safezone check, GaussSafe, is the one that matters most.)
    local function Protected(Ent)
        return ACFLazers and ACFLazers.IsProtectedBySafezone and ACFLazers.IsProtectedBySafezone(Ent) or false
    end

    function Ammo:PropImpact(Bullet, Trace)
        if Bullet.GaussSafe then return false end -- the rifle stood in a safezone: the DART hurts nothing

        local Target = Trace.Entity

        if IsValid(Target) and Protected(Target) then return false end -- a protected target takes nothing

        return Ammo.BaseClass.PropImpact(self, Bullet, Trace)
    end

    -- ---------------------------------------------------------------- the box: it holds darts, so it cannot blow up

    -- ACF's own prop damage and nothing else: no cook-off roll, no detonation. A killed box is handled by whoever dealt the damage (ACF breaks it into pieces), like any prop.
    local function InertDamage(Crate, DmgResult, DmgInfo)
        return Damage.doPropDamage(Crate, DmgResult, DmgInfo)
    end

    -- Called by ACF (Ammo:OnFirst(Crate)) when the crate takes this ammo type, spawn or update, after MakeAmmo set IsExplosive.
    function Ammo:OnFirst(Crate)
        Crate.IsExplosive   = false
        Crate.IsInertCrate  = true
        Crate.ACF_OnDamage  = InertDamage
    end

    -- Called by ACF (Ammo:OnLast(Crate)) when the crate leaves this ammo type (an update to another type, or the removal): ACF's own behaviour comes back.
    function Ammo:OnLast(Crate)
        Ammo.BaseClass.OnLast(self, Crate)

        Crate.IsInertCrate = nil

        if Crate.ACF_OnDamage == InertDamage then Crate.ACF_OnDamage = nil end

        Crate.IsExplosive = true -- what ACF's MakeAmmo gives every crate
    end

    function Ammo:UpdateCrateOverlay(BulletData, State)
        State:AddKeyValue("Rounds", "DART (inert: cannot cook off or explode)")
        State:AddNumber("Round length", BulletData.ProjLength, " cm", 1)
        State:AddNumber("Round mass", BulletData.ProjMass, " kg", 2)
    end

    -- Nothing was ever fired from a box: the rifle builds its own projectile (ENT:Shoot). If ACF ever asks a box for one, the answer is "nothing flies".
    function Ammo:Create() end

    -- The second wall: the two questions ACF asks before a cook-off and before an explosion. nil (no opinion) for every crate that is not ours.
    hook.Add("ACF_PreBurnAmmo", "ACFLazers_InertCrate", function(Crate)
        if IsValid(Crate) and Crate.IsInertCrate then return false end
    end)

    hook.Add("ACF_PreExplodeAmmo", "ACFLazers_InertCrate", function(Crate)
        if IsValid(Crate) and Crate.IsInertCrate then return false end
    end)
else
    -- The impact pictures (ACF's, inherited from APFSDS) look their decal up by the bullet's ammo type: this type has the dart's (the APCR) ones.
    ACF.RegisterAmmoDecal(ID, "damage/apcr_pen", "damage/apcr_rico")

    -- LATER: hook.Add("ACF_OnCreateBulletEffect", "ACFLazers_GaussDart", function(Effect, BulletData) ... end) -- the gauss look of the flying DART (BulletData.AmmoType == ID).
end
