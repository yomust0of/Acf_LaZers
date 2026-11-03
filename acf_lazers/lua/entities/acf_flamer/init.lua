-- =========================================================================
-- ACF FLAMETHROWER: SERVER FILE  (22)
-- Goes to:  lua/entities/acf_flamer/init.lua       (the CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the 22 config (lua/autorun/acf_lazers_config.lua: the Flame knobs and helpers), lua/autorun/acf_lazers_heat.lua, the projectile lua/acf/entities/ammo_types/lazers_flame.lua and the
--           fuel type lua/acf/entities/fuel_types/napalm.lua: it refuses to load (and says why in the console) when the config is older.
--
-- THE FLAMETHROWER. It burns NAPALM from the ACF fuel tanks linked to it and throws a flame projectile FlameShotsPerSecond (7) times a second while its Fire input is above 0.
--   * Fuel: FlameFuelSmall .. FlameFuelBig litres per second (0.5 L/s at 75 mm, 2 L/s at 150 mm, 3.5 L/s at 225 mm: a straight line over the caliber), taken shot by shot (a share of a second's worth each)
--     from the linked tanks that can give fuel. Link a napalm tank with the link controls of any tool of this addon: right-click the flamethrower, then right-click the tank (or the other way round).
--     A tank is ACF's own scalable fuel tank filled with the fuel type Napalm (lua/acf/entities/fuel_types/napalm.lua); the flamethrower tool makes one with Shift + left-click.
--   * Size: FlameCaliberMin .. FlameCaliberMax mm (75 to 225); the model (models/lasers/flamer.mdl) is at scale caliber / FlameCaliberBase (150 mm = 1).
--   * The flames start at the point the config names (FlameMuzzleX / Y / Z at scale 1, times the scale), looking along the model's forward. What the projectile does on its way is in
--     lua/acf/entities/ammo_types/lazers_flame.lua.
--   * A flamethrower in a safezone (marked by a safezone addon, or inside one of ACF's own zones) throws harmless flames: they fly and are drawn, and touch nothing.
--   * Sounds: a loop at the gun while it fires (config FlameGunLoop...), and a short sound when it starts (FlameStartSound).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities

local LASER_CONFIG = ACFLazers and ACFLazers.Config

if not LASER_CONFIG then
    ErrorNoHalt("[acf_flamer] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

if not (ACFLazers.FlameNumber and ACFLazers.GetFlameFuelPerShot and ACFLazers.GetFlameSpeed and ACFLazers.GetFlameDragCoef and ACFLazers.GetFlameMuzzleOffset and ACFLazers.GetFlameReadout
    and ACFLazers.IsProtectedBySafezone and ACFLazers.PickFlameSound and ACFLazers.GetFlameGravity and ACFLazers.FlameAmmoID) then
    ErrorNoHalt("[acf_flamer] the flamethrower helpers are missing: lua/autorun/acf_lazers_config.lua is older than this init.lua. Copy the new config as well, then restart.\n")
    return
end

local VERSION = "22"
MsgN("[acf_flamer] init.lua version " .. VERSION .. " loaded")

local FUEL          = ACFLazers.FlameFuelID or "Napalm"
local IDLE_THINK    = 0.5   -- seconds between Thinks while nobody holds Fire and nothing is playing
local READOUT_BUSY  = 0.25  -- seconds between readout refreshes while the gun is in use
local GUN_HOLD      = 0.35  -- seconds the gun's loop plays on after the last projectile

for _, name in ipairs({ "FlameGunLoop", "FlameStartSound", "FlameProjSound" }) do
    for _, path in ipairs(ACFLazers.FlameSoundList(name)) do util.PrecacheSound(path) end
end

ENT.OverlayDelay = math.max(tonumber(LASER_CONFIG.LazerOverlayDelay) or 0.25, 0) -- ACF's hover-text buffer for this entity (the lazer's number)

-- How many flamethrowers one player may own: GMod reads a server variable called sbox_max<name> (MakeACFFlamer asks ply:CheckLimit("acf_flamers")), and CreateConVar does nothing if it already exists.
CreateConVar("sbox_maxacf_flamers", tostring(ACFLazers.FlameNumber("FlameMaxPerPlayer")), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF flamethrowers one player may spawn")
cleanup.Register("acf_flamers")

-- Clamp whatever the tool / a dupe / an update sends us into the allowed range. The SERVER-side guard: never trust the client.
local function VerifyData(Data)
    Data.Caliber = math.Round(ACFLazers.ClampFlameCaliber(Data.Caliber), 2)
end

function ENT:Initialize()
    self.FuelTanks    = {}    -- the napalm tanks linked to this flamethrower (a set: key = tank). Filled and emptied by the link functions at the bottom
    self.FuelTypes    = { [FUEL] = true } -- the fuel types it burns, in the form ACF's fuel tank looks at (acf_fueltank/modules/spawning.lua: Engine.FuelTypes[Fuel]): a tank updated to another fuel lets go of us
    self.WantFire     = false -- what the Fire input says right now
    self.NextShot     = 0     -- CurTime() of the next projectile
    self.LastShot     = -1e9  -- CurTime() of the last projectile released
    self.NoFuel       = false -- true while Fire is wanted but there is nothing to burn
    self.LastFuel     = 0     -- litres the linked tanks can give (the "Fuel" wire output)
    self.NextRead     = 0     -- CurTime() of the next readout refresh
    self.ReadyShown   = nil   -- the last value written to the "Ready" output
    self.GunSnd       = nil   -- the gun's loop (a looping sound patch), made when it fires

    if WireLib then
        WireLib.CreateInputs(self, { "Fire" })
        WireLib.CreateOutputs(self, {
            "Caliber",   -- mm
            "FuelRate",  -- litres of napalm per second of firing
            "Fuel",      -- litres the linked tanks can give right now
            "Ready",     -- 1 = a projectile would be released now if Fire were held (there is fuel)
            "NoFuel",    -- 1 while Fire is held but there is nothing to burn
            "Firing",    -- 1 while projectiles are being thrown
        })
    end

    self:UpdateWireOutputs()
end

-- The single place that turns caliber (mm) into model size, mass and ACF health. Order matters (the lazer's, from acf_gun):
--   1. SetScaledModel + SetScale  -> creates the physics object at the right size
--   2. ACF.Activate               -> needs that physics object; calls ENT:ACF_Activate below
--   3. Contraption.SetMass        -> ACF stores the mass in self.ACF.Mass (and re-applies it if anything resets it)
function ENT:ApplyCaliber(caliber)
    caliber = tonumber(caliber) or ACFLazers.FlameNumber("FlameCaliberBase")

    self:SetCaliberSize(caliber)

    self:SetScaledModel(ACFLazers.FlameString("FlameModel"))
    self:SetScale(ACFLazers.GetFlameScale(caliber))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetFlameMass(caliber))

    self:NetworkBolt()
    self:UpdateWireOutputs()
end

-- What ACF's bullet effect reads from the "crate" of a bullet (here: this flamethrower), on every client, to draw the flying projectile [SEEN effects/acf_bullet_effect.lua:42-71]: the ammo type name,
-- the caliber (the effect sets the model scale to it x 0.1), the mass, the drag, whether it has a tracer, the acceleration (the effect flies the picture with it, so it must be the gravity the
-- server uses) and the model. FlightLife is read by lazers_flame.lua's client hook: it ends the picture when the server deletes the projectile after FlameLifetime.
function ENT:NetworkBolt()
    local caliber = self:GetCaliber()

    self:SetNW2String("AmmoType", ACFLazers.FlameAmmoID)
    self:SetNW2Float("Caliber", 10)
    self:SetNW2Float("ProjMass", 1)
    self:SetNW2Float("PropMass", 0)
    self:SetNW2Float("DragCoef", ACFLazers.GetFlameDragCoef(caliber))
    self:SetNW2Float("Tracer", 0)
    self:SetNW2Float("FillerMass", 0)
    self:SetNW2Vector("Accel", Vector(0, 0, -ACFLazers.GetFlameGravity()))
    self:SetNW2Float("FlightLife", ACFLazers.FlameNumber("FlameLifetime"))
end

-- Apply a whole Data table {Caliber = mm}. Used by spawn AND by update, so both behave the same.
-- self.Caliber is a plain field on purpose: the duplicator saves entity fields, and Entities.Register (bottom of this file) lists the name, so a paste can rebuild the flamethrower.
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Caliber = Data.Caliber
    self.Name    = string.format("%gmm Flamethrower", Data.Caliber) -- the undo list uses Entity.Name

    self:ApplyCaliber(Data.Caliber)
    self:ScheduleWireUpdate()
end

-- How ACF works out this entity's health/armour: the lazer's (gun-style numbers from acf_gun) with the flamethrower's multipliers.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = self:GetCaliber() * ACF.ArmorMod * ACFLazers.FlameNumber("FlameArmourMult")
    local Health  = Area / ACF.Threshold * ACFLazers.FlameNumber("FlameHealthMult")
    local Percent = 1

    if Recalc and SelfACF.Health and SelfACF.MaxHealth then
        Percent = SelfACF.Health / SelfACF.MaxHealth
    end

    SelfACF.Area      = Area
    SelfACF.Health    = Health * Percent
    SelfACF.MaxHealth = Health
    SelfACF.Armour    = Armour * (0.5 + Percent * 0.5)
    SelfACF.MaxArmour = Armour
    SelfACF.Type      = "Prop"
end

-- =====================  FUEL  =====================

-- The linked tanks that can give fuel right now (valid, napalm, active, not empty), in a fixed order (by entity index).
function ENT:GetTanks()
    local list = {}

    for tank in pairs(self.FuelTanks) do
        if IsValid(tank) and tank.FuelType == FUEL and tank.CanConsume and tank:CanConsume() then list[#list + 1] = tank end
    end

    table.sort(list, function(a, b) return a:EntIndex() < b:EntIndex() end)

    return list
end

-- Litres the linked tanks can give.
function ENT:GetFuel()
    local total = 0

    for _, tank in ipairs(self:GetTanks()) do total = total + math.max(tonumber(tank.Amount) or 0, 0) end

    return total
end

-- Litres every linked napalm tank holds when full.
function ENT:GetFuelCapacity()
    local total = 0

    for tank in pairs(self.FuelTanks) do
        if IsValid(tank) then total = total + math.max(tonumber(tank.Capacity) or 0, 0) end
    end

    return total
end

-- Burn `amount` litres: tank after tank, in order. Returns how many litres were really taken (less than asked only when the tanks run dry).
function ENT:TakeFuel(amount)
    local need, taken = math.max(tonumber(amount) or 0, 0), 0

    for _, tank in ipairs(self:GetTanks()) do
        if need <= 1e-12 then break end

        local give = math.min(tonumber(tank.Amount) or 0, need)

        if give > 0 then
            tank:Consume(give)

            need  = need - give
            taken = taken + give
        end
    end

    return taken
end

-- Who gets the credit for the damage: the owner ACF stored, then the prop-protection owner, then the flamethrower itself.
function ENT:GetAttacker()
    local owner = self.Owner

    if not IsValid(owner) and self.CPPIGetOwner then
        owner = self:CPPIGetOwner()
    end

    if IsValid(owner) then return owner end

    return self
end

-- Tell the flamethrower's OWNER, in chat, why it does not fire. At most one message per reason per NoticeInterval seconds (config), so it cannot flood.
function ENT:Notify(key, text, interval)
    if LASER_CONFIG.ShowProblemNotices == false then return end

    self.NoticeNext = self.NoticeNext or {}

    local now = CurTime()

    if now < (self.NoticeNext[key] or 0) then return end

    self.NoticeNext[key] = now + (interval or tonumber(LASER_CONFIG.NoticeInterval) or 10)

    local line  = string.format("[acf_flamer v%s #%d] %s", VERSION, self:EntIndex(), text)
    local owner = self:GetAttacker()

    if IsValid(owner) and owner:IsPlayer() then
        owner:ChatPrint(line)
    end

    MsgN(line)
end

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local caliber = self:GetCaliber()

    WireLib.TriggerOutput(self, "Caliber", caliber)
    WireLib.TriggerOutput(self, "FuelRate", ACFLazers.GetFlameFuelRate(caliber))
    WireLib.TriggerOutput(self, "Fuel", self.LastFuel or 0)
    WireLib.TriggerOutput(self, "NoFuel", self.NoFuel and 1 or 0)
    WireLib.TriggerOutput(self, "Firing", self:IsFiring() and 1 or 0)
    self:UpdateReadyOutput()
end

-- "Ready" follows the fuel; it is only written when it changes.
function ENT:UpdateReadyOutput()
    if not WireLib then return end

    local ready = (self.LastFuel or 0) > 1e-9 and 1 or 0

    if ready ~= self.ReadyShown then
        self.ReadyShown = ready
        WireLib.TriggerOutput(self, "Ready", ready)
    end
end

-- Refresh the wire outputs once on the next tick. Outputs set during spawn can be too early for Wire to show them (the lazer does the same).
function ENT:ScheduleWireUpdate()
    timer.Simple(0, function()
        if IsValid(self) then self:UpdateWireOutputs() end
    end)
end

-- Is it throwing flames right now? (A projectile within the last GUN_HOLD seconds.)
function ENT:IsFiring(now)
    return ((now or CurTime()) - self.LastShot) <= GUN_HOLD
end

-- Called every Think and whenever Fire changes. Keeps NoFuel right and refreshes the Fuel / Ready outputs and the hover text (every READOUT_BUSY seconds while the gun is in use, once a second
-- when idle; force = do it now).
function ENT:RefreshFuel(force)
    local now  = CurTime()
    local fuel = nil

    if force or now >= self.NextRead then
        fuel = self:GetFuel()
    end

    local noFuel = self.WantFire and (fuel or self.LastFuel or 0) <= 1e-9 or false

    if noFuel ~= self.NoFuel then
        self.NoFuel = noFuel
        force       = true
        fuel        = fuel or self:GetFuel()
    end

    if noFuel then self:ExplainNoFuel() end

    if not force and now < self.NextRead then return end

    self.NextRead = now + ((self.WantFire or self:IsFiring(now)) and READOUT_BUSY or 1)
    self.LastFuel = fuel or self:GetFuel()

    self:UpdateWireOutputs()
    self:UpdateOverlay()
end

-- Remind the owner in chat that a flamethrower with Fire held has NO napalm tank linked (at most once per NoCapacitorNoticeInterval, 30 s). Nothing is said when tanks are linked but empty:
-- the hover text says that.
function ENT:ExplainNoFuel()
    if next(self.FuelTanks) then return end

    self:Notify("nofuel", "This flamethrower has no napalm tank linked, so it cannot fire. Link one with the link controls of the flamethrower tool (right-click the flamethrower, then right-click the tank). Make a napalm tank with Shift + left-click.", tonumber(LASER_CONFIG.NoCapacitorNoticeInterval) or 30)
end

-- =====================  FIRING  =====================

-- The gun's loop (a looping sound patch that follows the gun): made when the gun starts firing (its sound level has to be set BEFORE it starts playing), its pitch follows the size, and it is stopped
-- GUN_HOLD seconds after the last projectile. [GUESS] that CreateSound loops this file by itself, as for the generator's hum.
function ENT:StopGun()
    if self.GunSnd then
        self.GunSnd:Stop()
        self.GunSnd = nil
    end
end

function ENT:UpdateGun(now)
    local name = ACFLazers.PickFlameSound("FlameGunLoop", function() return 1 end)

    if not self:IsFiring(now) or not name then
        self:StopGun()

        return
    end

    local volume = math.Clamp(ACFLazers.FlameNumber("FlameGunVolume"), 0, 1)
    local pitch  = ACFLazers.GetFlameGunPitch(self:GetCaliber())
    local level  = ACFLazers.FlameNumber("FlameGunLevel")

    if self.GunSnd and self.GunName ~= name then self:StopGun() end

    if not self.GunSnd then
        local snd = CreateSound(self, name)

        if not snd then return end

        snd:SetSoundLevel(level)
        snd:PlayEx(volume, pitch)

        self.GunSnd, self.GunName = snd, name
    elseif not self.GunSnd:IsPlaying() then -- (the engine stops a patch now and then, e.g. on a map cleanup)
        self.GunSnd:PlayEx(volume, pitch)
    end
end

-- A sound that goes wrong must never stop the gun from working (and spam the console only once).
function ENT:SafeUpdateGun(now)
    local ok, err = pcall(self.UpdateGun, self, now)

    if not ok and not self.GunFailed then
        self.GunFailed = true
        ErrorNoHalt("[acf_flamer] the gun sound failed: " .. tostring(err) .. "\n")
    end
end

-- The short sound when the gun starts.
function ENT:PlayStartSound()
    local name = ACFLazers.PickFlameSound("FlameStartSound")

    if not name then return end

    pcall(self.EmitSound, self, name, ACFLazers.FlameNumber("FlameGunLevel"), math.Round(ACFLazers.GetFlameGunPitch(self:GetCaliber())), math.Clamp(ACFLazers.FlameNumber("FlameStartVolume"), 0, 1), CHAN_AUTO)
end

-- Release one projectile. Returns true if ACF made it, false if it could not (ACF had no free bullet slot, or the projectile file is missing).
function ENT:Shoot()
    local Ballistics = ACF.Ballistics
    local Clock      = ACF.Utilities.Clock
    local Ammo       = ACF.Classes.AmmoTypes.Get(ACFLazers.FlameAmmoID)

    if not (Ammo and Ammo.FlameFlightStep) then
        self:Notify("noammo", "The flame projectile file is missing or too old: copy lua/acf/entities/ammo_types/lazers_flame.lua (the one of this batch) to the game folder and the server, then restart.")

        return false
    end

    local caliber  = self:GetCaliber()
    local now      = Clock.CurTime
    local speed    = ACFLazers.GetFlameSpeed(caliber) * ACF.MeterToInch -- ACF holds speeds in units per second
    local forward  = self:GetForward()
    local ancestor = (self.GetAncestor and self:GetAncestor()) or self
    local velocity = IsValid(ancestor) and ancestor:GetVelocity() or Vector(0, 0, 0) -- the shooter's own speed is added, as ACF guns do
    local contra   = self.CFW_GetContraption and self:CFW_GetContraption()

    -- THE FILTER IS A COPY. ACF's gun puts the contraption's list straight into the bullet, and ACF later ADDS to a bullet's filter (CreateBullet appends the shooter's vehicle for every weapon that is
    -- not an acf_gun, ballistics_sv.lua: that is us). Sharing the list would grow the contraption's one list by a vehicle on every shot. A copy leaves ACF's list alone.
    local filter = {}

    for _, ent in ipairs((contra and contra.BulletFilter) or { self }) do filter[#filter + 1] = ent end

    -- SAFEZONE: a flamethrower that stands in a safezone fires flames that touch nothing. Decided here, at the muzzle, and once more at every touch (lazers_flame.lua).
    local safe = ACFLazers.IsProtectedBySafezone(self)

    if safe then
        self:Notify("safezone", "This flamethrower is inside a safezone, so its flames touch NOTHING (they still fly and are drawn). Move it out of the safezone to hurt things.")
    end

    local bullet = Ballistics.CreateBullet({
        Type       = ACFLazers.FlameAmmoID,
        Owner      = self:GetAttacker(),
        Gun        = self,
        Crate      = self:EntIndex(),                                -- the entity's INDEX, a number (ACF's ammo crates do the same: spawning.lua:322). ACF sends it to the clients with EffectData:SetEntIndex, which refuses an entity
        Pos        = self:GetMuzzlePos(),
        Flight     = forward * speed + velocity,
        Accel      = Vector(0, 0, -ACFLazers.GetFlameGravity()),     -- ACF's gravity (times FlameGravityMult): the flame falls
        DragCoef   = ACFLazers.GetFlameDragCoef(caliber),            -- FlameDragMult times an ordinary shell's
        Caliber    = caliber / 10,                                   -- ACF holds a bullet's caliber in centimetres
        Diameter   = caliber / 10,
        ProjArea   = math.pi * (caliber / 20) ^ 2,                   -- cm^2
        ProjMass   = 1,
        FillerMass = 0,
        ShovePower = 0,
        KillTime   = now + ACFLazers.FlameNumber("FlameLifetime"),   -- ACF removes the bullet when this time comes (before anything else is looked at)
        Filter     = filter,                                         -- the contraption's own props are not touched by the flame, as for ACF guns (a COPY, see above)
        FlameStart   = now,                                          -- the sphere grows from here (lazers_flame.lua)
        FlameCaliber = caliber,                                      -- what the flame does to a thing is worked out from the caliber (the gun may be gone by then)
        FlameSafe    = safe,                                         -- true = this gun stood in a safezone when it fired: the flame touches nothing
        FlameHit     = {},                                           -- the things this projectile has touched (each is touched once)
        PostCalcFlight = Ammo.FlameFlightStep,                       -- ACF calls this after every step of the flight: the sphere is checked there
    })

    if not bullet then
        self:Notify("slots", "ACF has no free projectile slot (too many bullets in the air), so the flames were not released and no fuel was burned.")

        return false
    end

    return true
end

-- Try to release a projectile now. Needs: Fire held, the time between projectiles over, and fuel.
function ENT:TryShoot()
    if not self.WantFire then return false end

    local now = CurTime()

    if now < self.NextShot then return false end

    local fuel = self:GetFuel()

    if fuel <= 1e-9 then return false end -- a dud: RefreshFuel reports it

    if not self:Shoot() then return false end

    local wasFiring = self:IsFiring(now)

    self:TakeFuel(math.min(ACFLazers.GetFlameFuelPerShot(self:GetCaliber()), fuel)) -- the last drop is burned in a smaller puff

    self.LastShot = now
    self.NextShot = self.NextShot + ACFLazers.GetFlameShotInterval()

    if self.NextShot < now - ACFLazers.GetFlameShotInterval() then self.NextShot = now end -- (late by more than a whole interval, e.g. after a lag spike: no burst to catch up)

    if not wasFiring then self:PlayStartSound() end

    self.NextRead = 0 -- the fuel readout is refreshed on the next Think

    return true
end

-- Fire: held = projectiles; letting go stops them.
function ENT:TriggerInput(iname, value)
    if iname ~= "Fire" then return end

    local want = value > 0

    if want and not self.WantFire then self.NextShot = math.max(self.NextShot, CurTime()) end -- (the first projectile is released now, not owed from a long time ago; and never sooner than the last one's interval, so tapping Fire is no faster than holding it)

    self.WantFire = want

    self:TryShoot()
    self:RefreshFuel(true)
    self:NextThink(CurTime())
end

function ENT:Think()
    local now = CurTime()

    if self.WantFire then self:TryShoot() end

    self:SafeUpdateGun(now)
    self:RefreshFuel(false)

    -- every tick while Fire is held or the gun is still sounding; slowly when it is idle
    self:NextThink(now + ((self.WantFire or self.GunSnd) and 0 or IDLE_THINK))

    return true
end

-- The hover text, built the way ACF's cannons build theirs (ACF_UpdateOverlayState is called by ACF's overlay system when we call self:UpdateOverlay()).
function ENT:ACF_UpdateOverlayState(State)
    local caliber = self:GetCaliber()
    local info    = ACFLazers.GetFlameReadout(caliber)
    local fuel    = self.LastFuel or 0

    if self:IsFiring() and self.WantFire then
        State:AddSuccess("Firing")
    elseif fuel > 1e-9 then
        State:AddSuccess("Ready to fire")
    elseif not next(self.FuelTanks) then
        State:AddError("Cannot fire: no napalm tank linked")
    else
        State:AddError("Cannot fire: out of napalm")
    end

    State:AddKeyValue("Caliber", string.format("%g mm", caliber))
    State:AddKeyValue("Napalm use", string.format("%.2f L/s (%.3f L per projectile, %g projectiles a second)", info.fuelRate, info.fuelPerShot, info.shots))
    State:AddKeyValue("Muzzle velocity", string.format("%.0f m/s (%.0f m/s after %g s)", info.speed, info.speedAfter, info.lifetime))
    State:AddKeyValue("Sphere", string.format("%.0f units across, growing to %.0f", info.sphereStart, info.sphereEnd))
    State:AddKeyValue("Burns for", string.format("%.0f s", info.ignite))
    State:AddKeyValue("Heat per touch", string.format("%.1f%% of HOT (damage over %g%%: %.1f HP per touch)", info.heatPct, info.damageAt, info.hp))
    State:AddKeyValue("People", string.format("%.0f damage per touch", info.playerDamage))

    local capacity = self:GetFuelCapacity()

    if capacity > 0 then
        State:AddProgressBar("Napalm available", math.Round(fuel, 2), math.Round(capacity, 2), " L")
    else
        State:AddKeyValue("Napalm available", "0 L")
    end

    local linked = 0

    for _ in pairs(self.FuelTanks) do linked = linked + 1 end

    State:AddKeyValue("Napalm tanks", string.format("%d linked", linked))

    if info.fuelRate > 0 and fuel > 0 then
        State:AddKeyValue("Fuel lasts", string.format("%.0f s of firing", fuel / info.fuelRate))
    end
end

function ENT:PhysgunPickup(ply) return true end
function ENT:OnPhysgunFreeze(weapon, phys, ent, ply) return true end
function ENT:CanTool(ply, trace, tool) return true end

function ENT:OnRemove()
    self:StopGun()

    -- forget the tanks, and make them forget us
    for tank in pairs(self.FuelTanks or {}) do
        if IsValid(tank) and tank.Engines then
            tank.Engines[self] = nil

            if tank.InvalidateClientInfo then tank:InvalidateClientInfo() end
        end
    end

    if WireLib and WireLib.Remove then WireLib.Remove(self) end -- (what ACF's own gun does at the end of its OnRemove)
end

-- Click-to-update. Entities.Update calls this. Same shape as the lazer's: wrap the change in SaveEntity/RestoreEntity so welds and the frozen state survive the rescale.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Flamethrower updated successfully!"
end

if SERVER then
    -- Data is a table {Caliber = mm}. Signature (Player, Pos, Angle, Data) is what Entities.Register wants.
    function MakeACFFlamer(ply, pos, angles, Data)
        if not istable(Data) then
            Data = { Caliber = Data }
        end

        if IsValid(ply) and not ply:CheckLimit("acf_flamers") then return nil end

        local ent = ents.Create("acf_flamer")
        if not IsValid(ent) then return nil end

        -- ACF wants this table and a model BEFORE Spawn
        ent.ACF = {}
        Contraption.SetModel(ent, ACFLazers.FlameString("FlameModel"))

        ent:SetPos(pos)
        ent:SetAngles(angles)

        -- Spawn the entity first so NetworkVars (SetupDataTables) initialize
        ent:Spawn()
        ent:Activate()

        -- Caliber, size, mass, health: all through the same function Update uses
        ent:ApplyData(Data)

        if IsValid(ply) then
            if ent.SetPlayer then ent:SetPlayer(ply) end
            if CPPI then ent:CPPISetOwner(ply) end
            ply:AddCount("acf_flamers", ent)
            ply:AddCleanup("acf_flamers", ent)
        end

        return ent
    end

    -- "Caliber" is the plain field ApplyData stores; ACF's Register builds the duplicator entry with it. If it is ever renamed, old dupes paste at the default size.
    Entities.Register("acf_flamer", MakeACFFlamer, "Caliber")

    -- LINKING FLAMETHROWER <-> NAPALM TANK, through ACF's own link system (the same one engines and fuel tanks use, and it works from either side). The flamethrower puts itself in the tank's Engines set
    -- (that is what the tank unlinks when it is removed, or updated to another fuel, and what its hover text counts) and the tank in the flamethrower's FuelTanks.
    ACF.RegisterLinkSource("acf_flamer", "FuelTanks")

    ACF.RegisterClassLink("acf_flamer", "acf_fueltank", function(Flamer, Tank)
        if Flamer.FuelTanks[Tank] or (Tank.Engines and Tank.Engines[Flamer]) then return false, "This flamethrower is already linked to this fuel tank." end
        if Tank.FuelType ~= FUEL then return false, "A flamethrower only burns " .. FUEL .. ". This tank holds " .. tostring(Tank.FuelType) .. "." end
        if Tank.NoLinks then return false, "This fuel tank doesn't allow linking." end
        if not Tank.Engines then return false, "This is not a fuel tank ACF can link." end

        Flamer.FuelTanks[Tank] = true
        Tank.Engines[Flamer]   = true

        Flamer:RefreshFuel(true)
        Tank:UpdateOverlay()

        if Tank.InvalidateClientInfo then Tank:InvalidateClientInfo() end

        return true, "Flamethrower linked to the napalm tank."
    end)

    ACF.RegisterClassUnlink("acf_flamer", "acf_fueltank", function(Flamer, Tank)
        if not (Flamer.FuelTanks[Tank] or (Tank.Engines and Tank.Engines[Flamer])) then return false, "This flamethrower is not linked to this fuel tank." end

        Flamer.FuelTanks[Tank] = nil

        if Tank.Engines then Tank.Engines[Flamer] = nil end

        Flamer:RefreshFuel(true)
        Tank:UpdateOverlay()

        if Tank.InvalidateClientInfo then Tank:InvalidateClientInfo() end

        return true, "Flamethrower unlinked from the napalm tank."
    end)

    -- Breaks every link this flamethrower has. Returns how many it broke. (The link kit's reload uses it.)
    function ENT:UnlinkAll()
        local count = 0

        for tank in pairs(self.FuelTanks) do
            if ACF.PerformClassUnlink(self, tank) then count = count + 1 end
        end

        return count
    end

    -- Duplicator: the linked tanks' ids are saved with the flamethrower and linked again when the dupe is pasted (the engine does the same with its fuel tanks).
    function ENT:PreEntityCopy()
        if next(self.FuelTanks) then
            local ids = {}

            for tank in pairs(self.FuelTanks) do
                if IsValid(tank) then ids[#ids + 1] = tank:EntIndex() end
            end

            duplicator.StoreEntityModifier(self, "ACFFlamerTanks", ids)
        end

        self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
    end

    function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
        local mods = Ent.EntityMods

        if mods and mods.ACFFlamerTanks then
            for _, id in pairs(mods.ACFFlamerTanks) do
                local tank = CreatedEntities[id]

                if IsValid(tank) then self:Link(tank) end
            end

            mods.ACFFlamerTanks = nil
        end

        self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
    end
end
