-- =========================================================================
-- ACF GAUSS RIFLE: SERVER FILE  (23.2)
-- Goes to:  lua/entities/acf_gauss/init.lua       (the CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the 23.1 config (lua/autorun/acf_lazers_config.lua: the Gauss knobs and helpers), the weapon class lua/acf/entities/weapons/lazers_gauss.lua and the ammo type
--           lua/acf/entities/ammo_types/lazers_dart.lua: it refuses to load (and says why in the console) when the config is older.
--
-- THE GAUSS RIFLE. One shot = one DART.
--   * Size: GaussCaliberMin .. GaussCaliberMax mm (30 to 300); the model (models/lasers/gauss.mdl) is at scale caliber / GaussCaliberBase (100 mm = 1).
--   * Ammo: ROUNDS from the ammo boxes linked to it (GaussRoundsPerShot, 1, per shot). A box is ACF's own scalable ammo crate holding the ammo type DART (so it is inert: nothing in it can burn or blow up); the gauss tool makes one with
--     Shift + left-click. Link it with the link controls of any tool of this addon: right-click the rifle, then right-click the box (or the other way round). The rifle takes from the box it used last
--     until that is empty, then from the next one. A box must hold DARTs, be as wide as the rifle (GaussCrateMatchCaliber) and within ACF's link distance (GaussCrateDistance): ACF checks it again every second or
--     two and lets go of a box that stops fitting (for example after the rifle's caliber was changed).
--   * The shot: one of ACF's own projectiles (ACF.Ballistics.CreateBullet) of the type DART (lua/acf/entities/ammo_types/lazers_dart.lua). It starts at the point the config names (GaussMuzzleX / Y / Z at
--     scale 1, times the scale; shipped 37, 0, 1), looking along the model's forward, at GaussSpeedSmall .. GaussSpeedBig m/s (1400 at 30 mm, 2000 at 100, 2300 at 300) with NO drop and NO drag, and is
--     deleted GaussLifetime seconds after the shot. The speed of the rifle's own contraption is added to it, as ACF guns do.
--   * Fire (wire): a shot is released when Fire goes from 0 to above 0 and the rifle is not cooling (GaussRefireSmall .. GaussRefireBig seconds) and there is a round. With GaussAutoRepeat on, holding Fire
--     repeats the shot every refire time.
--   * Tracer: a choice of the tool (the rifle keeps it and sends it with the DART; ACF draws the tracer).
--   * A rifle in a safezone (marked by a safezone addon, or inside one of ACF's own zones) fires harmless darts: they fly and are drawn, and touch nothing.
--   * (23.2) WHEN THE RIFLE CANNOT BE CREATED it says why, in chat and in the server console, instead of ACF's bare "The spawn function for acf_gauss didn't return an entity.": the usual cause is that the
--     SERVER does not have the entity's three files (init.lua, shared.lua, cl_init.lua in lua/entities/acf_gauss/) under exactly those names; it also names a missing model and a reached limit.
-- Not in yet (asked for later): the effects (muzzle, the gauss look of the DART), recoil, power from capacitors, other round types.
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- (23.2) Did shared.lua really run, and is this file where GMod must find it? If shared.lua is missing (or misnamed, for example shared.lua.new) include() only complains and this file goes on, but the
-- game then cannot create the entity: ents.Create gives nothing and ACF only says "didn't return an entity". These two answers are kept for the message MakeACFGauss gives.
local SHARED_OK = isfunction(ENT.GetMuzzlePos) -- the LAST function shared.lua defines before its client part: a shared.lua that stopped half way fails this too
local Source    = debug and debug.getinfo and debug.getinfo(1, "S")
local LOADED_FROM = string.gsub(tostring(Source and Source.short_src or "?"), "\\", "/")
local FOLDER_OK = LOADED_FROM == "?" or string.find(LOADED_FROM, "entities/acf_gauss/init.lua", 1, true) ~= nil

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities

local LASER_CONFIG = ACFLazers and ACFLazers.Config

if not LASER_CONFIG then
    ErrorNoHalt("[acf_gauss] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

if not (ACFLazers.GaussNumber and ACFLazers.GetGaussSpeed and ACFLazers.GetGaussMuzzleOffset and ACFLazers.GetGaussReadout and ACFLazers.GetGaussToolData and ACFLazers.GaussInertRound
    and ACFLazers.IsProtectedBySafezone and ACFLazers.DescribeSafezone and ACFLazers.PickGaussSound and ACFLazers.GetGaussRefire and ACFLazers.GaussAmmoID and ACFLazers.GetGaussDartDiameterCm) then
    ErrorNoHalt("[acf_gauss] the gauss rifle helpers are missing: lua/autorun/acf_lazers_config.lua is older than this init.lua. Copy the new config as well, then restart.\n")
    return
end

local VERSION = "23.2"
MsgN("[acf_gauss] init.lua version " .. VERSION .. " loaded")

if not SHARED_OK then
    ErrorNoHalt("[acf_gauss] shared.lua did not run: it is missing or misnamed in lua/entities/acf_gauss/ on this server, or it has an error (look for a red line above this one). The rifle cannot be created until it is fixed.\n")
end

if not FOLDER_OK then
    ErrorNoHalt("[acf_gauss] this init.lua was loaded from " .. LOADED_FROM .. " but it must be lua/entities/acf_gauss/init.lua (the folder name is the entity name). The rifle cannot be created until it is moved.\n")
end

local IDLE_THINK   = 0.5   -- seconds between Thinks while nobody holds Fire and the rifle is not cooling
local READ_BUSY    = 0.25  -- seconds between ammo readouts while Fire is held
local READ_IDLE    = 1     -- seconds between ammo readouts when idle

for _, path in ipairs(ACFLazers.GaussSoundList("GaussFireSound")) do util.PrecacheSound(path) end

ENT.OverlayDelay = math.max(tonumber(LASER_CONFIG.LazerOverlayDelay) or 0.25, 0) -- ACF's hover-text buffer for this entity (the lazer's number)

-- How many rifles one player may own: GMod reads a server variable called sbox_max<name> (MakeACFGauss asks ply:CheckLimit("acf_gausses")), and CreateConVar does nothing if it already exists.
CreateConVar("sbox_maxacf_gausses", tostring(ACFLazers.GaussNumber("GaussMaxPerPlayer")), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF gauss rifles one player may spawn")
cleanup.Register("acf_gausses")

-- Clamp whatever the tool / a dupe / an update sends us into the allowed range. The SERVER-side guard: never trust the client.
local function VerifyData(Data)
    Data.Caliber = math.Round(ACFLazers.ClampGaussCaliber(Data.Caliber), 2)

    local Tracer = Data.Tracer

    Data.Tracer = Tracer == true or (tonumber(Tracer) or 0) >= 1
end

function ENT:Initialize()
    self.Crates         = {}    -- the inert ammo boxes linked to this rifle (a set: key = crate). Filled and emptied by the link functions at the bottom
    self.CurrentCrate   = nil   -- the box the last round came from (it is emptied before the next box is touched)
    self.WantFire       = false -- what the Fire input says right now
    self.PressPending   = false -- Fire went up and no shot has answered it yet
    self.NextShot       = 0     -- CurTime() when the cooling ends
    self.NoAmmo         = false -- true while Fire is wanted but there is no round to fire
    self.LastAmmo       = 0     -- rounds the linked boxes can give (the "Ammo" wire output)
    self.NextRead       = 0     -- CurTime() of the next ammo readout
    self.ReadyShown     = nil   -- the last value written to the "Ready" output
    self.CoolingShown   = false -- the hover text has said "Cooling": it is refreshed once more when the cooling ends
    self.DartData       = nil   -- ACF's round data of the DART this rifle fires (built on the first shot, forgotten when the caliber or the tracer changes)

    if WireLib then
        WireLib.CreateInputs(self, { "Fire" })
        WireLib.CreateOutputs(self, {
            "Caliber",     -- mm
            "MuzzleVel",   -- m/s
            "Refire",      -- seconds between two shots
            "Ammo",        -- rounds the linked boxes can give right now
            "Ready",       -- 1 = a shot would be released now if Fire went up (not cooling, there is a round)
            "NoAmmo",      -- 1 while Fire is held but there is no round to fire
        })
    end

    self:UpdateWireOutputs()
end

-- The single place that turns caliber (mm) into model size, mass and ACF health. Order matters (the lazer's, from acf_gun):
--   1. SetScaledModel + SetScale  -> creates the physics object at the right size
--   2. ACF.Activate               -> needs that physics object; calls ENT:ACF_Activate below
--   3. Contraption.SetMass        -> ACF stores the mass in self.ACF.Mass (and re-applies it if anything resets it)
function ENT:ApplyCaliber(caliber)
    caliber = tonumber(caliber) or ACFLazers.GaussNumber("GaussCaliberBase")

    self:SetCaliberSize(caliber)

    self:SetScaledModel(ACFLazers.GaussString("GaussModel"))
    self:SetScale(ACFLazers.GetGaussScale(caliber))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetGaussMass(caliber))

    self:NetworkBolt()
    self:UpdateWireOutputs()
end

-- ACF's round data for the DART this rifle fires: the DART type's ServerConvert of the rifle's own tool data (class, caliber, length, no propellant, the tracer choice). Built once and kept; nil (with
-- self.DartError saying why) when ACF cannot build it, for example when one of the DART's files is missing.
function ENT:GetDartData()
    if self.DartData then return self.DartData end

    local Dart = ACF.Classes.AmmoTypes.Get(ACFLazers.GaussAmmoID)

    if not (Dart and Dart.ServerConvert) then
        self.DartError = "the DART ammo type is not registered (lua/acf/entities/ammo_types/lazers_dart.lua is missing or did not load)"

        return nil
    end

    local Ok, Data = pcall(Dart.ServerConvert, Dart, ACFLazers.GetGaussToolData(self:GetCaliber(), self.Tracer))

    if not Ok or type(Data) ~= "table" or not (tonumber(Data.ProjMass) and Data.ProjMass > 0) then
        self.DartError = "ACF could not build the DART round" .. (Ok and " (is lua/acf/entities/weapons/lazers_gauss.lua installed?)" or (": " .. tostring(Data)))

        return nil
    end

    self.DartData  = Data
    self.DartError = nil

    return Data
end

-- What ACF's bullet effect reads from the "crate" of a bullet (here: this rifle), on every client, to draw the flying DART: the DART type writes it (Ammo:Network). FlightLife is for the effects to come:
-- the picture should end when the server deletes the projectile after GaussLifetime.
function ENT:NetworkBolt()
    local Data = self:GetDartData()
    local Dart = ACF.Classes.AmmoTypes.Get(ACFLazers.GaussAmmoID)

    if Data and Dart and Dart.Network then
        local Ok, Err = pcall(Dart.Network, Dart, self, Data)

        if not Ok then ErrorNoHalt("[acf_gauss] could not network the DART: " .. tostring(Err) .. "\n") end
    end

    self:SetNW2Float("FlightLife", ACFLazers.GaussNumber("GaussLifetime"))
end

-- Apply a whole Data table {Caliber = mm, Tracer = true / false}. Used by spawn AND by update, so both behave the same.
-- self.Caliber and self.Tracer are plain fields on purpose: the duplicator saves entity fields, and Entities.Register (bottom of this file) lists the names, so a paste can rebuild the rifle.
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Caliber  = Data.Caliber
    self.Tracer   = Data.Tracer
    self.Class    = ACFLazers.GaussClassID -- ACF's crate code looks at a linked weapon's Class (the ammo type's blacklist)
    self.DartData = nil
    self.Name     = string.format("%gmm Gauss Rifle", Data.Caliber) -- the undo list uses Entity.Name

    self:ApplyCaliber(Data.Caliber)
    self:ScheduleWireUpdate()
end

-- How ACF works out this entity's health/armour: the lazer's (gun-style numbers from acf_gun) with the rifle's multipliers.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = self:GetCaliber() * ACF.ArmorMod * ACFLazers.GaussNumber("GaussArmourMult")
    local Health  = Area / ACF.Threshold * ACFLazers.GaussNumber("GaussHealthMult")
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

-- =====================  AMMO  =====================

-- A box we may take rounds from: still there, an inert box, and willing to give (ACF's own CanConsume: loaded, not disabled, not empty).
local function CanGive(Crate)
    return IsValid(Crate) and Crate.IsInertCrate == true and Crate.CanConsume ~= nil and Crate:CanConsume() == true
end

-- The boxes that can give a round, the one the last round came from first, the others by entity number.
function ENT:GetCrates()
    local List = {}

    for Crate in pairs(self.Crates) do
        if CanGive(Crate) then List[#List + 1] = Crate end
    end

    table.sort(List, function(a, b) return a:EntIndex() < b:EntIndex() end)

    local Current = self.CurrentCrate

    if IsValid(Current) then
        for i, Crate in ipairs(List) do
            if Crate == Current then
                table.remove(List, i)
                table.insert(List, 1, Crate)

                break
            end
        end
    end

    return List
end

-- Rounds the linked boxes can give.
function ENT:GetAmmo()
    local Total = 0

    for _, Crate in ipairs(self:GetCrates()) do Total = Total + math.max(tonumber(Crate.Amount) or 0, 0) end

    return Total
end

-- Rounds the linked inert boxes hold when full.
function ENT:GetCapacity()
    local Total = 0

    for Crate in pairs(self.Crates) do
        if IsValid(Crate) and Crate.IsInertCrate then Total = Total + math.max(tonumber(Crate.Capacity) or 0, 0) end
    end

    return Total
end

-- Rounds one shot costs.
function ENT:GetRoundsPerShot()
    return math.max(math.floor(ACFLazers.GaussNumber("GaussRoundsPerShot") + 0.5), 1)
end

-- Take `count` rounds, from the box used last first. Returns true if all of them were there (nothing is taken when they are not).
function ENT:TakeRounds(count)
    count = math.max(math.floor(tonumber(count) or 0), 0)

    if count == 0 then return true end
    if self:GetAmmo() < count then return false end

    for _, Crate in ipairs(self:GetCrates()) do
        local Take = math.min(count, math.max(tonumber(Crate.Amount) or 0, 0))

        if Take > 0 then
            Crate:Consume(Take)

            self.CurrentCrate = Crate
            count = count - Take
        end

        if count <= 0 then break end
    end

    return count <= 0
end

-- ACF calls this on a weapon when a crate it was loaded from is changed: forget the box.
function ENT:Unload()
    self.CurrentCrate = nil

    self:RefreshAmmo(true)
end

function ENT:GetAttacker()
    local owner = self.Owner

    if not IsValid(owner) and self.CPPIGetOwner then
        owner = self:CPPIGetOwner()
    end

    if IsValid(owner) then return owner end

    return self
end

-- Tell the rifle's OWNER, in chat, why it does not fire. At most one message per reason per NoticeInterval seconds (config), so it cannot flood.
function ENT:Notify(key, text, interval)
    if LASER_CONFIG.ShowProblemNotices == false then return end

    self.NoticeNext = self.NoticeNext or {}

    local now = CurTime()

    if now < (self.NoticeNext[key] or 0) then return end

    self.NoticeNext[key] = now + (interval or tonumber(LASER_CONFIG.NoticeInterval) or 10)

    local line  = string.format("[acf_gauss v%s #%d] %s", VERSION, self:EntIndex(), text)
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
    WireLib.TriggerOutput(self, "MuzzleVel", ACFLazers.GetGaussSpeed(caliber))
    WireLib.TriggerOutput(self, "Refire", ACFLazers.GetGaussRefire(caliber))
    WireLib.TriggerOutput(self, "Ammo", self.LastAmmo or 0)
    WireLib.TriggerOutput(self, "NoAmmo", self.NoAmmo and 1 or 0)
    self:UpdateReadyOutput()
end

-- "Ready" follows the cooling and the ammo; it is only written when it changes.
function ENT:UpdateReadyOutput()
    if not WireLib then return end

    local ready = (CurTime() >= self.NextShot and (self.LastAmmo or 0) >= self:GetRoundsPerShot()) and 1 or 0

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

-- Called every Think and whenever Fire or a link changes. Keeps NoAmmo right and refreshes the Ammo / Ready outputs and the hover text (every READ_BUSY seconds while Fire is held, every READ_IDLE seconds
-- otherwise; force = do it now).
function ENT:RefreshAmmo(force)
    local now = CurTime()

    if not force and now < self.NextRead then return end

    self.NextRead = now + (self.WantFire and READ_BUSY or READ_IDLE)

    local ammo   = self:GetAmmo()
    local noAmmo = self.WantFire and ammo < self:GetRoundsPerShot() or false

    if noAmmo ~= self.NoAmmo then
        self.NoAmmo = noAmmo

        if WireLib then WireLib.TriggerOutput(self, "NoAmmo", noAmmo and 1 or 0) end
    end

    if noAmmo then self:ExplainNoAmmo() end

    if ammo ~= self.LastAmmo then
        self.LastAmmo = ammo

        if WireLib then WireLib.TriggerOutput(self, "Ammo", ammo) end

        self:UpdateOverlay()
    end

    self:UpdateReadyOutput()
end

function ENT:ExplainNoAmmo()
    if next(self.Crates) then return end

    self:Notify("noammo", "This gauss rifle has no ammo box linked, so it cannot fire. Link one with the link controls of the gauss tool (right-click the rifle, then right-click the box). Make an inert box with Shift + left-click.", tonumber(LASER_CONFIG.NoCapacitorNoticeInterval) or 30)
end

-- =====================  THE SHOT  =====================

function ENT:PlayFireSound()
    local sound = ACFLazers.PickGaussSound("GaussFireSound")

    if not sound then return end

    local pitch = math.Round(ACFLazers.GetGaussFirePitch(self:GetCaliber())) -- (the engine takes whole percents)

    self:EmitSound(sound, ACFLazers.GaussNumber("GaussFireLevel"), pitch, math.Clamp(ACFLazers.GaussNumber("GaussFireVolume"), 0, 1), CHAN_AUTO)
end

-- Release one DART. Returns true if ACF made it, false if it could not (no round data, or ACF had no free bullet slot): then nothing is paid.
function ENT:Shoot()
    local Ballistics = ACF.Ballistics
    local Clock      = ACF.Utilities.Clock
    local Data       = self:GetDartData()

    if not Data then
        self:Notify("nodart", "The DART round could not be built, so the shot was not released: " .. tostring(self.DartError))

        return false
    end

    local caliber  = self:GetCaliber()
    local now      = Clock.CurTime
    local speedMS  = ACFLazers.GetGaussSpeed(caliber)
    local speed    = speedMS * ACF.MeterToInch -- ACF holds speeds in units per second
    local forward  = self:GetForward()
    local ancestor = (self.GetAncestor and self:GetAncestor()) or self
    local velocity = IsValid(ancestor) and ancestor:GetVelocity() or Vector(0, 0, 0) -- the shooter's own speed is added, as ACF guns do
    local contra   = self.CFW_GetContraption and self:CFW_GetContraption()

    -- THE FILTER IS A COPY. ACF's gun puts the contraption's list straight into the bullet, and ACF later ADDS to a bullet's filter (CreateBullet appends the shooter's vehicle for every weapon that is
    -- not an acf_gun, ballistics_sv.lua: that is us). Sharing the list would grow the contraption's one list by a vehicle on every shot. A copy leaves ACF's list alone.
    local filter = {}

    for _, ent in ipairs((contra and contra.BulletFilter) or { self }) do filter[#filter + 1] = ent end

    -- SAFEZONE: a rifle that stands in a safezone fires darts that do no damage to anything. Decided here, at the muzzle (the DART type also asks about its target).
    local safe = ACFLazers.IsProtectedBySafezone(self)

    if safe then
        self:Notify("safezone", "This gauss rifle is inside a safezone, so its shots do NO damage to anything (the DART still flies and is still drawn). Move it out of the safezone to hurt things. (The safezone check saw: " .. tostring(ACFLazers.DescribeSafezone(self)) .. ")")
    end

    local Bullet = table.Copy(Data) -- ACF's round data for this rifle's DART (type, caliber, mass, penetration numbers ...)

    Bullet.Owner      = self:GetAttacker()
    Bullet.Gun        = self
    Bullet.Crate      = self:EntIndex()                  -- the entity's INDEX, a number (ACF's ammo crates do the same). ACF sends it to the clients with EffectData:SetEntIndex, which refuses an entity; the client effect reads the networked values from this entity
    Bullet.Pos        = self:GetMuzzlePos()
    Bullet.Flight     = forward * speed + velocity
    Bullet.Accel      = Vector(0, 0, 0)                  -- ACF uses its gravity when Accel is nil: this is what makes the DART fly straight
    Bullet.DragCoef   = 0
    Bullet.MuzzleVel  = speedMS
    Bullet.KillTime   = now + ACFLazers.GaussNumber("GaussLifetime") -- ACF removes the bullet when this time comes
    Bullet.Filter     = filter                           -- the contraption's own props are not hit by the projectile, as for ACF guns (a COPY, see above)
    Bullet.GaussSafe  = safe                             -- true = this rifle stood in a safezone when it fired: the DART does NO damage (lazers_dart.lua)

    local Shot = Ballistics.CreateBullet(Bullet)

    if not Shot then
        self:Notify("slots", "ACF has no free projectile slot (too many bullets in the air), so the shot was not released and no round was used.")

        return false
    end

    self:PlayFireSound()

    return true
end

-- Try to release a shot now. Needs: Fire held, a press not yet answered (or GaussAutoRepeat), the cooling over, and the rounds in the boxes.
function ENT:TryShoot()
    if not self.WantFire then return false end

    local now = CurTime()

    if now < self.NextShot then return false end
    if not (self.PressPending or ACFLazers.GaussFlag("GaussAutoRepeat")) then return false end

    local rounds = self:GetRoundsPerShot()

    if self:GetAmmo() < rounds then return false end -- a dud: RefreshAmmo reports it
    if not self:Shoot() then return false end

    self:TakeRounds(rounds)

    self.PressPending = false
    self.NextShot     = now + ACFLazers.GetGaussRefire(self:GetCaliber())
    self.CoolingShown = true

    self:RefreshAmmo(true)
    self:UpdateOverlay()

    return true
end

-- Fire: a press (0 -> above 0) is remembered until a shot answers it; letting go forgets it.
function ENT:TriggerInput(iname, value)
    if iname ~= "Fire" then return end

    local want = value > 0

    if want and not self.WantFire then self.PressPending = true end
    if not want then self.PressPending = false end

    self.WantFire = want

    self:TryShoot()
    self:RefreshAmmo(true)
end

function ENT:Think()
    local now = CurTime()

    if self.WantFire then self:TryShoot() end

    -- the hover text said "Cooling": say "Ready" when it is over
    if self.CoolingShown and now >= self.NextShot then
        self.CoolingShown = false
        self:UpdateOverlay()
    end

    self:RefreshAmmo(false)

    -- every tick while Fire is held or the rifle is cooling between shots; slowly when idle
    self:NextThink(now + ((self.WantFire or now < self.NextShot) and 0 or IDLE_THINK))

    return true
end

-- The hover text, built the way ACF's cannons build theirs (ACF_UpdateOverlayState is called by ACF's overlay system when we call self:UpdateOverlay()).
function ENT:ACF_UpdateOverlayState(State)
    local caliber = self:GetCaliber()
    local now     = CurTime()
    local rounds  = self:GetRoundsPerShot()
    local ammo    = self.LastAmmo or 0

    if now < self.NextShot then
        self.CoolingShown = true
        State:AddWarning(string.format("Cooling: %.1f s", self.NextShot - now))
    elseif ammo >= rounds then
        State:AddSuccess("Ready to fire")
    elseif not next(self.Crates) then
        State:AddError("Cannot fire: no ammo box linked")
    else
        State:AddError("Cannot fire: the linked boxes are empty")
    end

    local info = ACFLazers.GetGaussReadout(caliber)

    State:AddKeyValue("Caliber", string.format("%g mm", caliber))
    State:AddKeyValue("Muzzle velocity", string.format("%.0f m/s", info.speed))
    State:AddKeyValue("Refire", string.format("%.2f s (%.2f shots a second)", info.refire, info.shots))
    State:AddKeyValue("DART", string.format("%.1f kg, %.0f cm long, %.0f mm wide", info.dartMass, info.dartLength, info.dartWidth * 10))

    if info.penetration then
        State:AddKeyValue("Penetration", string.format("%.0f mm at the muzzle", info.penetration))
    end

    State:AddKeyValue("Tracer", self.Tracer and "yes" or "no")

    local capacity = self:GetCapacity()

    if capacity > 0 then
        State:AddProgressBar("Rounds available", math.Round(ammo, 1), math.Round(capacity, 1))
    else
        State:AddKeyValue("Rounds available", "0")
    end

    local linked = 0

    for _ in pairs(self.Crates) do linked = linked + 1 end

    State:AddKeyValue("Ammo boxes", string.format("%d linked (%d round%s a shot)", linked, rounds, rounds == 1 and "" or "s"))
end

function ENT:PhysgunPickup(ply) return true end
function ENT:OnPhysgunFreeze(weapon, phys, ent, ply) return true end
function ENT:CanTool(ply, trace, tool) return true end

function ENT:OnRemove()
    -- forget the boxes, and make them forget us
    for Crate in pairs(self.Crates or {}) do
        if IsValid(Crate) and Crate.Weapons then
            Crate.Weapons[self] = nil

            if Crate.UpdateOverlay then Crate:UpdateOverlay(true) end
        end
    end
end

-- Click-to-update. Entities.Update calls this. Same shape as the lazer's: wrap the change in SaveEntity/RestoreEntity so welds and the frozen state survive the rescale. A box that no longer fits
-- (the caliber changed) is let go by ACF's own link check at once.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    local Dropped = 0

    for Crate in pairs(self.Crates) do
        if IsValid(Crate) then
            local Ok = ACF.PerformClassLinkCheck(self, Crate)

            if not Ok then Dropped = Dropped + 1 end
        end
    end

    self:RefreshAmmo(true)

    return true, "Gauss rifle updated successfully!" .. (Dropped > 0 and string.format(" %d ammo box(es) no longer fit and were unlinked.", Dropped) or "")
end

if SERVER then
    -- Data is a table {Caliber = mm, Tracer = true / false}. Signature (Player, Pos, Angle, Data) is what Entities.Register wants.
    -- (23.2) A refusal is told to the player (chat, one line each) and to the server console. Lines are kept short: the chat cuts long ones.
    local function Refuse(ply, Lines)
        for _, line in ipairs(Lines) do
            ErrorNoHalt(line .. "\n")

            if IsValid(ply) then ply:ChatPrint(line) end
        end
    end

    -- (23.2) WHY ents.Create("acf_gauss") gave nothing: what this SERVER has in lua/entities/acf_gauss/ and what the game knows. The files are looked up on the server ("GAME" = everything it mounted).
    local function WhyNoEntity()
        local Dir   = "lua/entities/acf_gauss/"
        local Lines = { "[acf_gauss] The server cannot create the entity acf_gauss (ents.Create gave nothing)." }
        local Miss  = {}

        for _, name in ipairs({ "init.lua", "shared.lua", "cl_init.lua" }) do
            if not file.Exists(Dir .. name, "GAME") then Miss[#Miss + 1] = name end
        end

        if #Miss > 0 then
            Lines[#Lines + 1] = "[acf_gauss] Missing ON THE SERVER in " .. Dir .. " : " .. table.concat(Miss, ", ") .. ". Each file must have exactly that name (no .new, no acf_gauss_ in front)."
        end

        if not SHARED_OK then
            Lines[#Lines + 1] = "[acf_gauss] shared.lua did not run when init.lua loaded: it is missing, misnamed or has an error (see the red lines in the server console from the start)."
        end

        if not FOLDER_OK then
            Lines[#Lines + 1] = "[acf_gauss] This init.lua was loaded from " .. LOADED_FROM .. " but it must be lua/entities/acf_gauss/init.lua."
        end

        local _, Folders = file.Find("lua/entities/*gauss*", "GAME")
        local Others = {}

        for _, name in ipairs(Folders or {}) do
            if name ~= "acf_gauss" then Others[#Others + 1] = name end
        end

        if #Others > 0 then
            Lines[#Lines + 1] = "[acf_gauss] Folders with gauss in the name: " .. table.concat(Others, ", ") .. " . The folder must be called acf_gauss."
        end

        if not (scripted_ents and scripted_ents.GetStored and scripted_ents.GetStored("acf_gauss")) then
            Lines[#Lines + 1] = "[acf_gauss] The game does not know any scripted entity called acf_gauss."
        end

        if #Lines == 1 then
            Lines[#Lines + 1] = "[acf_gauss] All three files are there. Restart the SERVER (not only the game) after copying, then look in the server console for red lines about acf_gauss."
        end

        return Lines
    end

    -- Data is a table {Caliber = mm, Tracer = true / false}. Signature (Player, Pos, Angle, Data) is what Entities.Register wants.
    function MakeACFGauss(ply, pos, angles, Data)
        if not istable(Data) then
            Data = { Caliber = Data }
        end

        if IsValid(ply) and not ply:CheckLimit("acf_gausses") then
            local Var = GetConVar and GetConVar("sbox_maxacf_gausses")

            Refuse(ply, { "[acf_gauss] You have reached the limit of gauss rifles (the server variable sbox_maxacf_gausses is " .. (Var and Var:GetString() or "not set") .. ")." })

            return nil
        end

        -- (23.2) Like the radiator: a model the SERVER does not have would make ACF's scalable base fail with a pile of errors, so say so instead.
        local Model = ACFLazers.GaussString("GaussModel")

        if not util.IsValidModel(Model) then
            Refuse(ply, { "[acf_gauss] The model " .. Model .. " is missing on this server (GaussModel in acf_lazers_config.lua). Is it installed on the SERVER and is the file name spelled right?" })

            return nil
        end

        local ent = ents.Create("acf_gauss")

        if not IsValid(ent) then
            Refuse(ply, WhyNoEntity())

            return nil
        end

        -- ACF wants this table and a model BEFORE Spawn
        ent.ACF = {}
        Contraption.SetModel(ent, Model)

        ent:SetPos(pos)
        ent:SetAngles(angles)

        -- Spawn the entity first so NetworkVars (SetupDataTables) initialize
        ent:Spawn()
        ent:Activate()

        -- Caliber, size, mass, health: all through the same function Update uses
        ent:ApplyData(Data)

        if not IsValid(ent) then
            Refuse(ply, { "[acf_gauss] The rifle removed itself while it was being built. Look in the server console for the error just above this line." })

            return nil
        end

        if IsValid(ply) then
            if ent.SetPlayer then ent:SetPlayer(ply) end
            if CPPI then ent:CPPISetOwner(ply) end
            ply:AddCount("acf_gausses", ent)
            ply:AddCleanup("acf_gausses", ent)
        end

        return ent
    end

    -- "Caliber" and "Tracer" are the plain fields ApplyData stores; ACF's Register builds the duplicator entry with them. If they are ever renamed, old dupes paste at the default size.
    Entities.Register("acf_gauss", MakeACFGauss, "Caliber", "Tracer")

    -- LINKING RIFLE <-> AMMO BOX, through ACF's own link system (the same one guns and ammo crates use). What a box must be to feed this rifle: a box of DARTs (the ammo type of lazers_dart.lua), of the
    -- rifle's caliber (GaussCrateMatchCaliber), not further away than GaussCrateDistance (0 = ACF's LinkDistance). Returns nil when the box fits, or the reason it does not.
    local function CrateProblem(Gun, Crate)
        if not IsValid(Crate) or Crate:GetClass() ~= "acf_ammo" then return "This is not an ammo crate." end

        if not Crate.IsInertCrate then
            return "A gauss rifle only takes DART rounds. This crate holds " .. tostring(Crate.AmmoType) .. ". Make a box of darts with Shift + left-click of the gauss tool."
        end

        local rifle = Gun:GetCaliber()
        local crate = tonumber(Crate.Caliber) or 0

        if ACFLazers.GaussFlag("GaussCrateMatchCaliber") and math.abs(rifle - crate) > 0.01 then
            return string.format("Wrong ammo for this rifle: the box holds %g mm rounds and the rifle is %g mm.", crate, rifle)
        end

        local distance = ACFLazers.GetGaussCrateDistance()

        if Crate:GetPos():DistToSqr(Gun:GetPos()) > distance * distance then
            return "This ammo box is too far away from this rifle."
        end
    end

    ACF.RegisterLinkSource("acf_gauss", "Crates")

    ACF.RegisterClassLinkCheck("acf_gauss", "acf_ammo", function(Gun, Crate)
        local Problem = CrateProblem(Gun, Crate)

        if Problem then return false, Problem end

        return true
    end)

    ACF.RegisterClassLink("acf_gauss", "acf_ammo", function(Gun, Crate)
        if Gun.Crates[Crate] or (Crate.Weapons and Crate.Weapons[Gun]) then return false, "This gauss rifle is already linked to this ammo box." end
        if not Crate.Weapons then return false, "This is not an ammo crate ACF can link." end

        Gun.Crates[Crate]  = true
        Crate.Weapons[Gun] = true

        Gun:RefreshAmmo(true)
        Crate:UpdateOverlay(true)

        return true, "Gauss rifle linked to the ammo box."
    end)

    ACF.RegisterClassUnlink("acf_gauss", "acf_ammo", function(Gun, Crate)
        if not (Gun.Crates[Crate] or (Crate.Weapons and Crate.Weapons[Gun])) then return false, "This gauss rifle is not linked to this ammo box." end

        Gun.Crates[Crate] = nil

        if Crate.Weapons then Crate.Weapons[Gun] = nil end
        if Gun.CurrentCrate == Crate then Gun.CurrentCrate = nil end

        Gun:RefreshAmmo(true)
        Crate:UpdateOverlay(true)

        return true, "Gauss rifle unlinked from the ammo box."
    end)

    -- Breaks every link this rifle has. Returns how many it broke. (The link kit's reload uses it.)
    function ENT:UnlinkAll()
        local count = 0

        for Crate in pairs(self.Crates) do
            if ACF.PerformClassUnlink(self, Crate) then count = count + 1 end
        end

        return count
    end

    -- Duplicator: the linked boxes' ids are saved with the rifle and linked again when the dupe is pasted (the flamethrower does the same with its tanks).
    function ENT:PreEntityCopy()
        if next(self.Crates) then
            local ids = {}

            for Crate in pairs(self.Crates) do
                if IsValid(Crate) then ids[#ids + 1] = Crate:EntIndex() end
            end

            duplicator.StoreEntityModifier(self, "ACFGaussCrates", ids)
        end

        self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
    end

    function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
        local mods = Ent.EntityMods

        if mods and mods.ACFGaussCrates then
            for _, id in pairs(mods.ACFGaussCrates) do
                local Crate = CreatedEntities[id]

                if IsValid(Crate) then self:Link(Crate) end
            end

            mods.ACFGaussCrates = nil
        end

        self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
    end
end
