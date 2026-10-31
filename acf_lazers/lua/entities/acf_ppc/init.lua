-- =========================================================================
-- ACF PPC: SERVER FILE  (16.6)
-- Goes to:  lua/entities/acf_ppc/init.lua       (replaces the EMPTY placeholder that is there now. The CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the 16.2 config (lua/autorun/acf_lazers_config.lua: the PPC knobs and helpers), lua/autorun/acf_lazers_heat.lua (the heat store) AND lua/acf/entities/ammo_types/lazers_ppc.lua (the projectile): it refuses to load without them
--
-- THE PPC. One shot = one projectile.
--   * It is linked to capacitors like a lazer (same tools) and draws a shot's energy from the pool all at once. Shot energy, speed, size: see the PPC block of the config.
--   * The projectile is one of ACF's own (ACF.Ballistics.CreateBullet): straight line (no gravity, no drag), removed after PPCLifetime, drawn by ACF's own bullet effect with a ball model.
--     It starts at the front of the model, the end the lazer's beam starts at. What it does on impact is in lua/acf/entities/ammo_types/lazers_ppc.lua: an HE explosion, nothing else.
--   * Fire (wire): a shot is released when Fire goes from 0 to above 0 and the PPC is not cooling (PPCRefireSeconds) and the pool holds the shot's energy. With PPCAutoRepeat on, holding
--     Fire repeats the shot every PPCRefireSeconds as soon as the pool can pay.
-- 16.1: THE CRASH ON THE FIRST SHOT IS FIXED. 16 handed ACF the PPC ENTITY as the bullet's "crate"; ACF sends that number to the clients with EffectData:SetEntIndex, which wants a NUMBER
--   ("bad argument #2 to 'EffectFunc' (number expected, got userdata)"). Now it is self:EntIndex(), the way ACF's own ammo crates do it (spawning.lua:322). Also new in 16.1: each projectile gets a COPY of
--   the contraption's filter list; a PPC inside a safezone fires harmless projectiles (PPCSafe); the projectile carries its caliber (PPCCaliber) for the heat pass. The rest is in lazers_ppc.lua.
-- 16.2: A SHOT HEATS THE PPC ITSELF, and a PPC over its limit hurts itself, like a lazer (the lazer's HeatThink / TakeHeatDamage / HeatDeath, with the PPC's own numbers: config PPCHeat...).
--   * every shot that is released adds PPCHeatPctSmall .. PPCHeatPctBig percent of the PPC's own limit as heat (ACFLazers.GetPPCShotHeat; 16.2 and 16.3 used the shot's kJ x PPCHeatSmall .. PPCHeatBig), all at once; 100% is PPCHeatCapF
--   * over 100% it loses health (checked every HeatCheckInterval seconds): PPCHeatDamage x over^2 percent of its max health per second, plus the lazers' TURBO damage past HeatTurboStartPct (ACFLazers.GetHeatDamagePct)
--   * when that kills it: if it fired within the last PPCHeatFiringSeconds (or Fire is held) it explodes with chance PPCHeatExplodeChance, with the HE of PPCHeatExplosionMult (1/3) of a lazer's death
--     explosion of the same size; otherwise it just dies and the pieces fly (ACF.APKill)
--   * wire outputs HeatKJ / HeatF / HeatPct, and "Temperature: N F (N% of its limit)" in the hover text, like the lazer. Radiators cool it like any entity in their contraption: no link is needed
--   * 16.2 also plays the FIRE SOUND (two Half-Life 2 sounds layered, config PPCFire...) at the muzzle end of every shot that is released
-- 16.4 and 16.5: only comments and the version changed in this file: the heat of a shot is a PERCENT of the PPC's own limit, on a straight line over the caliber (config PPCHeatPctSmall .. PPCHeatPctBig; shipped:
--   67.8% at 20 mm, 77% at 100 mm, 100% at 300 mm). The code already asked the config.
-- 16.6: the load check no longer asks for ACFLazers.GetPPCHeat (the blast's heat is worked out from the damage it does now: lazers_ppc.lua and GetPPCDamageHeat; this file never used it). The smallest PPC is 50 mm
--   (config PPCCaliberMin; Data.Caliber is clamped to it as before). Nothing else changed.
-- Not in yet (asked for later): the effects (sparks, energy round the projectile), RECOIL (the same maths ACF's cannons use, parented and unparented), pushing the parent chain of a prop that is hit,
--   penetrating light props (explode on the heaviest instead), the explosion's own sound and effects.
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities
local Damage      = ACF.Damage
local Objects     = Damage.Objects

local LASER_CONFIG = ACFLazers and ACFLazers.Config

if not LASER_CONFIG then
    ErrorNoHalt("[acf_ppc] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

-- This file needs the config of the SAME batch (the PPC helpers are new in 16). With an older config every shot would throw; say it once, clearly.
if not (ACFLazers.GetPPCShotEnergy and ACFLazers.PPCNumber and ACFLazers.GetPPCSpeed and ACFLazers.ClampPPCCaliber and ACFLazers.IsProtectedBySafezone and ACFLazers.DescribeSafezone and ACFLazers.GetPPCDamageHeat) then
    ErrorNoHalt("[acf_ppc] the PPC helpers are missing: lua/autorun/acf_lazers_config.lua is older than this init.lua. Copy the new config as well, then restart.\n")
    return
end

-- 16.2: the PPC's own heat and its fire sound. The heat store is lua/autorun/acf_lazers_heat.lua; the maths and the numbers are in the config of this batch. Without them every shot would throw; say so once.
if not (ACFLazers.Heat and ACFLazers.Heat.Add and ACFLazers.GetHeatCapacity and ACFLazers.GetHeatDamagePct and ACFLazers.GetPPCShotHeat and ACFLazers.GetPPCHeatRise and ACFLazers.GetPPCDeathFiller and ACFLazers.PickPPCSound and ACFLazers.GetPPCFirePitch) then
    ErrorNoHalt("[acf_ppc] the heat system or the 16.2 PPC helpers are missing: copy lua/autorun/acf_lazers_heat.lua and the 16.2 lua/autorun/acf_lazers_config.lua, then restart.\n")
    return
end

local Heat = ACFLazers.Heat

local VERSION = "16.6"
MsgN("[acf_ppc] init.lua version " .. VERSION .. " loaded")

local IDLE_THINK = 0.2   -- seconds between Thinks while nobody holds Fire, the PPC is not cooling and it holds no heat
local HEAT_THINK = 0.05  -- seconds between Thinks while it holds heat (the heat check itself waits for HeatCheckInterval)
local READOUT_INTERVAL_DEFAULT = 0.1 -- seconds between heat-readout refreshes (config: HeatOutputInterval; the lazer's default)

-- 16.2: the fire sound is precached once (a sound played for the first time otherwise makes a small hitch). Every path of both layers, the config's or the defaults'.
for _, layer in ipairs({ "PPCFireSound", "PPCFireSound2" }) do
    for _, path in ipairs(ACFLazers.PPCSoundList(layer)) do util.PrecacheSound(path) end
end

ENT.OverlayDelay = math.max(tonumber(LASER_CONFIG.LazerOverlayDelay) or 0.25, 0) -- ACF's hover-text buffer for this entity (the lazer's number)

-- How many PPCs one player may own: GMod reads a server variable called sbox_max<name> (MakeACFPPC asks ply:CheckLimit("acf_ppcs")), and CreateConVar does nothing if it already exists.
CreateConVar("sbox_maxacf_ppcs", tostring(ACFLazers.PPCNumber("PPCMaxPerPlayer")), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF PPCs one player may spawn")
cleanup.Register("acf_ppcs")

-- Clamp whatever the tool / a dupe / an update sends us into the allowed range. The SERVER-side guard: never trust the client.
local function VerifyData(Data)
    Data.Caliber = math.Round(ACFLazers.ClampPPCCaliber(Data.Caliber), 2)
end

function ENT:Initialize()
    self.Caps           = {}    -- the capacitors linked to this PPC (a set: key = capacitor). Filled and emptied by the link functions at the bottom
    self.Pool           = {}    -- the capacitor group this PPC draws from (rebuilt when ACFLazers.LinkVersion changes)
    self.PoolVersion    = -1
    self.WantFire       = false -- what the Fire input says right now
    self.PressPending   = false -- Fire went up and no shot has answered it yet
    self.NextShot       = 0     -- CurTime() when the cooling ends
    self.NoPower        = false -- true while Fire is wanted but the pool cannot pay for the shot
    self.LastEnergy     = 0     -- the pool's energy at the last read (the "Energy" wire output)
    self.NextEnergyRead = 0     -- CurTime() of the next read
    self.ReadyShown     = nil   -- the last value written to the "Ready" output
    self.CoolingShown   = false -- the hover text has said "Cooling": it is refreshed once more when the cooling ends
    self.HeatDying      = false -- 16.2: true once its heat has killed it (the death runs once)
    self.NextHeatCheck  = 0     -- CurTime() of the next heat check (HeatThink)
    self.LastHeatCheck  = CurTime()
    self.NextHeatRead   = 0     -- CurTime() of the next heat-readout refresh (HeatReadout)
    self.HeatShown      = true  -- true until the readout has written the COLD state (the first refresh writes 0 kJ / room temperature / 0%, like the lazer's)
    self.LastShotTime   = -1e9  -- CurTime() of the last shot that was released (the explosion dice use it)

    if WireLib then
        WireLib.CreateInputs(self, { "Fire" })
        WireLib.CreateOutputs(self, {
            "Caliber",     -- mm
            "ShotKJ",      -- kJ one shot costs
            "MuzzleVel",   -- m/s
            "BlastKg",     -- kg of HE in one shot
            "BlastRadius", -- units
            "Energy",      -- kJ in the capacitor pool this PPC can draw from right now
            "Shots",       -- how many shots the pool can pay for
            "Ready",       -- 1 = a shot would be released now if Fire went up (not cooling, the pool can pay)
            "NoPower",     -- 1 while Fire is held but the pool cannot pay for the shot
            "HeatKJ",      -- 16.2: kJ of heat above room temperature
            "HeatF",       -- degrees Fahrenheit
            "HeatPct",     -- percent of the PPC's limit (PPCHeatCapF): 100 = the limit, above it the PPC hurts itself
        })
    end

    self:UpdateWireOutputs()
end

-- The single place that turns caliber (mm) into model size, mass and ACF health. Order matters (the lazer's, from acf_gun):
--   1. SetScaledModel + SetScale  -> creates the physics object at the right size
--   2. ACF.Activate               -> needs that physics object; calls ENT:ACF_Activate below
--   3. Contraption.SetMass        -> ACF stores the mass in self.ACF.Mass (and re-applies it if anything resets it)
function ENT:ApplyCaliber(caliber)
    caliber = tonumber(caliber) or ACFLazers.PPCNumber("PPCCaliberBase")

    self:SetCaliberSize(caliber)

    self:SetScaledModel(ACFLazers.PPCString("PPCModel"))
    self:SetScale(ACFLazers.GetPPCScale(caliber))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetPPCMass(caliber))

    self:NetworkBolt()
    self:UpdateWireOutputs()
end

-- What ACF's bullet effect reads from the "crate" of a bullet (here: this PPC), on every client, to draw the flying projectile [SEEN effects/acf_bullet_effect.lua:42-71]:
-- the ammo type name, the caliber (the effect sets the model scale to it x 0.1), the mass, the drag, whether it has a tracer, the acceleration (a ZERO vector: no gravity) and the model.
-- FillerMass is read by the explosion picture when the projectile ends. FlightMaterial and FlightLife are read by lazers_ppc.lua's client hook.
function ENT:NetworkBolt()
    local caliber = self:GetCaliber()

    self:SetNW2String("AmmoType", ACFLazers.PPCAmmoID)
    self:SetNW2Float("Caliber", ACFLazers.GetPPCBallScale(caliber) * 10)
    self:SetNW2Float("ProjMass", 1)
    self:SetNW2Float("PropMass", 0)
    self:SetNW2Float("DragCoef", 0)
    self:SetNW2Float("Tracer", 0)
    self:SetNW2Float("FillerMass", ACFLazers.GetPPCFillerMass(caliber))
    self:SetNW2Vector("Accel", Vector(0, 0, 0))
    self:SetNW2String("FlightModel", ACFLazers.PPCString("PPCBallModel"))
    self:SetNW2Int("FlightBodygroup", 0)
    self:SetNW2String("FlightMaterial", ACFLazers.PPCString("PPCBallMaterial"))
    self:SetNW2Float("FlightLife", ACFLazers.PPCNumber("PPCLifetime")) -- lazers_ppc.lua's client hook ends the ball when the server's projectile is deleted
end

-- Apply a whole Data table {Caliber = mm}. Used by spawn AND by update, so both behave the same.
-- self.Caliber is a plain field on purpose: the duplicator saves entity fields, and Entities.Register (bottom of this file) lists the name, so a paste can rebuild the PPC.
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Caliber = Data.Caliber
    self.Name    = string.format("%gmm PPC", Data.Caliber) -- the undo list uses Entity.Name

    self:ApplyCaliber(Data.Caliber)
    self:ScheduleWireUpdate()
end

-- How ACF works out this entity's health/armour: the lazer's (gun-style numbers from acf_gun) with the PPC's multipliers.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = self:GetCaliber() * ACF.ArmorMod * ACFLazers.PPCNumber("PPCArmourMult")
    local Health  = Area / ACF.Threshold * ACFLazers.PPCNumber("PPCHealthMult")
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

-- =====================  PPC POWER  =====================
-- The same pool rules as the lazer (lazer init.lua: GetPool, GetPoolEnergy, GetPoolCapacity, TakeEnergy): the capacitors linked to this PPC and every capacitor grouped with them, paid with
-- ACFLazers.WaterFill. A copy on purpose, so the lazer file stays as it is; if the rules ever change, change both (or move them to one shared place).

function ENT:GetPool()
    local version = ACFLazers.LinkVersion

    if self.PoolVersion ~= version then
        self.Pool        = ACFLazers.GetCapGroup(self.Caps)
        self.PoolVersion = version
    end

    return self.Pool
end

-- kJ in the pool right now.
function ENT:GetPoolEnergy()
    local total = 0

    for _, cap in ipairs(self:GetPool()) do
        if IsValid(cap) and not cap.Exploding then total = total + cap.Charge end
    end

    return total
end

-- kJ the pool holds when every capacitor in it is full.
function ENT:GetPoolCapacity()
    local total = 0

    for _, cap in ipairs(self:GetPool()) do
        if IsValid(cap) and not cap.Exploding then total = total + cap.Capacity end
    end

    return total
end

-- kJ one shot costs.
function ENT:GetShotEnergy()
    return ACFLazers.GetPPCShotEnergy(self:GetCaliber())
end

-- Can the pool pay `amount` kJ right now? Always yes if RequireCapacitor is off.
function ENT:CanAfford(amount)
    if not LASER_CONFIG.RequireCapacitor or amount <= 0 then return true end

    return self:GetPoolEnergy() + 1e-9 >= amount
end

-- Pay `amount` kJ out of the pool, or pay nothing and return false if the pool holds less. Every capacitor gives the same share (ACFLazers.WaterFill); one that cannot give a full share gives
-- all it has and the others cover what it was short. The whole pool is stamped as drained, so the chargers pause for a moment (the capacitor's IsBeingDrained).
function ENT:TakeEnergy(amount)
    if not LASER_CONFIG.RequireCapacitor or amount <= 0 then return true end

    local pool, limits, total = self:GetPool(), {}, 0

    for i, cap in ipairs(pool) do
        local charge = (IsValid(cap) and not cap.Exploding) and cap.Charge or 0

        limits[i] = charge
        total     = total + charge
    end

    if total + 1e-9 < amount then return false end

    local takes = ACFLazers.WaterFill(limits, amount)
    local now   = CurTime()

    for i, cap in ipairs(pool) do
        if takes[i] > 0 and IsValid(cap) then cap:RemoveCharge(takes[i]) end
        if IsValid(cap) then cap.LastDrainTime = now end
    end

    return true
end

-- Who gets the credit for the damage: the owner ACF stored, then the prop-protection owner, then the PPC itself.
function ENT:GetAttacker()
    local owner = self.Owner

    if not IsValid(owner) and self.CPPIGetOwner then
        owner = self:CPPIGetOwner()
    end

    if IsValid(owner) then return owner end

    return self
end

-- Tell the PPC's OWNER, in chat, why it does not fire. At most one message per reason per NoticeInterval seconds (config), so it cannot flood.
function ENT:Notify(key, text, interval)
    if LASER_CONFIG.ShowProblemNotices == false then return end

    self.NoticeNext = self.NoticeNext or {}

    local now = CurTime()

    if now < (self.NoticeNext[key] or 0) then return end

    self.NoticeNext[key] = now + (interval or tonumber(LASER_CONFIG.NoticeInterval) or 10)

    local line  = string.format("[acf_ppc v%s #%d] %s", VERSION, self:EntIndex(), text)
    local owner = self:GetAttacker()

    if IsValid(owner) and owner:IsPlayer() then
        owner:ChatPrint(line)
    end

    MsgN(line)
end

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local caliber = self:GetCaliber()
    local cost    = self:GetShotEnergy()

    WireLib.TriggerOutput(self, "Caliber", caliber)
    WireLib.TriggerOutput(self, "ShotKJ", cost)
    WireLib.TriggerOutput(self, "MuzzleVel", ACFLazers.GetPPCSpeed(caliber))
    WireLib.TriggerOutput(self, "BlastKg", ACFLazers.GetPPCFillerMass(caliber))
    WireLib.TriggerOutput(self, "BlastRadius", ACFLazers.GetPPCBlastRadius(caliber))
    WireLib.TriggerOutput(self, "Energy", self.LastEnergy or 0)
    WireLib.TriggerOutput(self, "Shots", (cost > 0 and LASER_CONFIG.RequireCapacitor) and math.floor((self.LastEnergy or 0) / cost + 1e-9) or 0)
    WireLib.TriggerOutput(self, "NoPower", self.NoPower and 1 or 0)
    self:UpdateReadyOutput()
end

-- "Ready" follows the cooling clock and the pool; it is only written when it changes.
function ENT:UpdateReadyOutput()
    if not WireLib then return end

    local ready = (CurTime() >= self.NextShot and self:CanAfford(self:GetShotEnergy())) and 1 or 0

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

-- Remind the owner in chat that a PPC with Fire held has NO capacitor linked (at most once per NoCapacitorNoticeInterval, 30 s). Nothing is said when capacitors are linked but empty:
-- the hover text says that.
function ENT:ExplainNoPower()
    if not LASER_CONFIG.RequireCapacitor then return end
    if next(self.Caps) then return end

    self:Notify("nopower", "This PPC has no capacitor linked, so it cannot fire. Link one with the capacitor tool (right-click the PPC, then right-click a capacitor).", tonumber(LASER_CONFIG.NoCapacitorNoticeInterval) or 30)
end

-- Called every Think and whenever Fire changes. Keeps NoPower right, refreshes the Energy / Shots outputs and the hover text (every LazerEnergyReadInterval seconds while the PPC is in use, once a
-- second when idle; force = do it now).
function ENT:RefreshPower(force)
    local now     = CurTime()
    local noPower = (self.WantFire and now >= self.NextShot and not self:CanAfford(self:GetShotEnergy())) and true or false

    if noPower ~= self.NoPower then
        self.NoPower = noPower
        force        = true
    end

    if noPower then self:ExplainNoPower() end

    if not force and now < self.NextEnergyRead then return end

    self.NextEnergyRead = now + ((self.WantFire or now < self.NextShot) and (tonumber(LASER_CONFIG.LazerEnergyReadInterval) or 0.25) or 1)
    self.LastEnergy     = self:GetPoolEnergy()

    self:UpdateWireOutputs()
    self:UpdateOverlay()
end

-- =====================  PPC HEAT  (16.2)  =====================
-- The lazer's heat code (acf_lazer/init.lua: GetHeatPct, UpdateHeatOutputs, HeatReadout, HeatThink, TakeHeatDamage, HeatDeath) with the PPC's numbers. The heat itself lives in the heat store
-- (lua/autorun/acf_lazers_heat.lua); this entity only ADDS to it (a shot), READS it (the percent, the readout) and acts on it (damage, death). Every number is in the config (PPCHeat...).

-- How hot the PPC is as a fraction of its limit (PPCHeatCapF): 0 = room temperature, 1 = the limit, 2 = twice as far above room temperature as the limit.
function ENT:GetHeatPct()
    return Heat.GetPct(self, ACFLazers.GetPPCHeatRise())
end

-- kJ of heat one shot gives this PPC (16.4: a percent of its own limit, config PPCHeatPctSmall .. PPCHeatPctBig).
function ENT:GetShotHeat()
    return ACFLazers.GetPPCShotHeat(self:GetCaliber())
end

-- The three heat wire outputs: kJ above room temperature, degrees Fahrenheit, percent of the PPC's limit.
function ENT:UpdateHeatOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", self:GetHeatPct() * 100)
end

-- The heat READOUT (the three outputs and the hover text) has its own clock, like the lazer's: every HeatOutputInterval while the PPC holds heat, and once more when it has cooled to room
-- temperature (so the readout ends at 0). A PPC at room temperature that already shows 0 costs one table lookup per interval and nothing else. Called from Think.
function ENT:HeatReadout(now)
    if now < self.NextHeatRead then return end

    self.NextHeatRead = now + math.max(tonumber(LASER_CONFIG.HeatOutputInterval) or READOUT_INTERVAL_DEFAULT, 0)

    local hot = Heat.GetKJ(self) > 0

    if not (hot or self.HeatShown) then return end

    self.HeatShown = hot

    self:UpdateHeatOutputs()
    self:UpdateOverlay()
end

-- A shot was released and paid: it heats the PPC. The readout is refreshed on the next Think, and the PPC keeps thinking fast while it holds heat.
function ENT:AddShotHeat(now)
    self.LastShotTime = now

    local heat = self:GetShotHeat()

    if heat > 0 then Heat.Add(self, heat) end

    self.NextHeatRead = 0
    self.HeatShown    = true
end

-- Did it fire lately? (Fire held, or a shot within PPCHeatFiringSeconds.) The explosion dice of its death use it.
function ENT:IsFiring(now)
    now = now or CurTime()

    return self.WantFire or (now - self.LastShotTime) <= math.max(ACFLazers.PPCNumber("PPCHeatFiringSeconds"), 0)
end

-- Called from Think every tick; does its work every HeatCheckInterval seconds: the damage a PPC over its limit does to itself.
function ENT:HeatThink(now)
    if now < self.NextHeatCheck then return end

    local dt = math.Clamp(now - self.LastHeatCheck, 0, LASER_CONFIG.HeatMaxDeltaTime) -- the cap: a lag spike must not become one huge burst of damage

    self.LastHeatCheck = now
    self.NextHeatCheck = now + LASER_CONFIG.HeatCheckInterval

    local over = self:GetHeatPct() - 1

    if over > 0 then self:TakeHeatDamage(over, dt) end
end

-- `over` = how far above its limit it is (0.5 = half again as hot as the limit); dt = seconds this check stands for. The loss is a share of its MAX health, through ACF's own damage call.
function ENT:TakeHeatDamage(over, dt)
    local acf = self.ACF

    if not (acf and acf.MaxHealth and acf.MaxHealth > 0) then return end

    local pctPerSecond = ACFLazers.GetHeatDamagePct(over, ACFLazers.PPCNumber("PPCHeatDamage"))
    local HitRes       = Heat.Hurt(self, acf.MaxHealth * pctPerSecond / 100 * dt)

    if HitRes and HitRes.Kill then self:HeatDeath() end
end

-- Its own heat has killed it. A PPC that fired lately explodes with chance PPCHeatExplodeChance (PPCHeatExplosionMult of what a lazer of its size would blow up with); otherwise it just dies and the
-- pieces fly. Once only.
function ENT:HeatDeath()
    if self.HeatDying then return end

    self.HeatDying = true

    local dmgInfo = Objects.DamageInfo(self:GetAttacker(), self)

    if self:IsFiring() and math.random() < ACFLazers.PPCNumber("PPCHeatExplodeChance") then
        local filler   = ACFLazers.GetPPCDeathFiller(self:GetCaliber())
        local position = self:LocalToWorld(self:OBBCenter())

        ACF.KillChildProps(self, position, filler)
        Damage.createExplosion(position, filler, filler * 0.5, { self }, dmgInfo)
        Damage.explosionEffect(position, nil, filler)

        constraint.RemoveAll(self)
        self:Remove()
    else
        ACF.APKill(self, VectorRand(), math.min(ACFLazers.PPCNumber("PPCHeatDeathDebrisPower"), LASER_CONFIG.MaxDebrisPower), dmgInfo)
    end
end

-- =====================  FIRING  =====================

-- The fire sound (16.2): two layers, the burst and the crackle, each a Half-Life 2 sound picked from its list (config PPCFireSound, PPCFireSound2), at the PPC. The pitch follows the size
-- (a big PPC is deeper). A layer whose list is empty is silent.
function ENT:PlayFireSound()
    local pitch = ACFLazers.GetPPCFirePitch(self:GetCaliber())
    local level = ACFLazers.PPCNumber("PPCFireSoundLevel")

    local burst = ACFLazers.PickPPCSound("PPCFireSound")

    pitch = math.Round(pitch) -- (the engine takes whole percents)

    if burst then self:EmitSound(burst, level, pitch, math.Clamp(ACFLazers.PPCNumber("PPCFireVolume"), 0, 1), CHAN_AUTO) end

    local crackle = ACFLazers.PickPPCSound("PPCFireSound2")

    if crackle then self:EmitSound(crackle, level, pitch, math.Clamp(ACFLazers.PPCNumber("PPCFireVolume2"), 0, 1), CHAN_AUTO) end
end

-- Release one projectile. Returns true if ACF made it, false if ACF had no free bullet slot (the 2000 of ACF.Ballistics): then nothing is paid.
function ENT:Shoot()
    local Ballistics = ACF.Ballistics
    local Clock      = ACF.Utilities.Clock
    local caliber    = self:GetCaliber()
    local now        = Clock.CurTime
    local speed      = ACFLazers.GetPPCSpeed(caliber) * ACF.MeterToInch -- ACF holds speeds in units per second
    local forward    = self:GetForward()
    local ancestor   = (self.GetAncestor and self:GetAncestor()) or self
    local velocity   = IsValid(ancestor) and ancestor:GetVelocity() or Vector(0, 0, 0) -- the shooter's own speed is added, as ACF guns do
    local contra     = self.CFW_GetContraption and self:CFW_GetContraption()
    local lifetime   = ACFLazers.PPCNumber("PPCLifetime")

    -- THE FILTER IS A COPY. ACF's gun puts the contraption's list straight into the bullet, and ACF later ADDS to a bullet's filter (CreateBullet appends the shooter's vehicle for every weapon that is
    -- not an acf_gun, ballistics_sv.lua: that is us). Sharing the list would grow the contraption's one list by a vehicle on every shot. A copy leaves ACF's list alone.
    local filter = {}

    for _, ent in ipairs((contra and contra.BulletFilter) or { self }) do filter[#filter + 1] = ent end

    -- SAFEZONE: a PPC that stands in a safezone (marked by a safezone addon, or inside one of ACF's own zones) fires projectiles that do no damage and no heat to anything. Decided here, at the muzzle, and
    -- once more at the blast (lazers_ppc.lua); everything the blast could reach is checked one by one there as well.
    local safe = ACFLazers.IsProtectedBySafezone(self)

    if safe then
        self:Notify("safezone", "This PPC is inside a safezone, so its shots do NO damage and NO heat to anything (the projectile still flies and the explosion is still drawn). Move it out of the safezone to hurt things. (The safezone check saw: " .. ACFLazers.DescribeSafezone(self) .. ")", 20)
    end

    local bullet = Ballistics.CreateBullet({
        Type       = ACFLazers.PPCAmmoID,
        Owner      = self:GetAttacker(),
        Gun        = self,
        Crate      = self:EntIndex(),                                -- the entity's INDEX, a number (ACF's ammo crates do the same: spawning.lua:322). ACF sends it to the clients with EffectData:SetEntIndex, which refuses an entity; the client effect then finds the entity again and reads its NW2 values (ENT:NetworkBolt). 16 passed the entity itself: that was the crash on the first shot
        Pos        = self:GetMuzzlePos(),
        Flight     = forward * speed + velocity,
        Accel      = Vector(0, 0, 0),                                -- ACF uses its gravity when Accel is nil: this is what makes the projectile fly straight
        DragCoef   = 0,
        Caliber    = caliber / 10,                                   -- ACF holds a bullet's caliber in centimetres
        Diameter   = caliber / 10,
        ProjArea   = math.pi * (caliber / 20) ^ 2,                   -- cm^2
        ProjMass   = 1,
        FillerMass = ACFLazers.GetPPCFillerMass(caliber),
        ShovePower = 0,
        KillTime   = now + lifetime,                                 -- ACF removes the bullet when this time comes
        Filter     = filter,                                         -- the contraption's own props are not hit by the projectile, as for ACF guns (a COPY, see above)
        PPCStart   = now,                                            -- the falloff in lazers_ppc.lua counts from here
        PPCCaliber = caliber,                                        -- the heat pass in lazers_ppc.lua works the heat out from the caliber (the PPC may be gone by then)
        PPCSafe    = safe,                                           -- true = this PPC stood in a safezone when it fired: the projectile does NO damage and NO heat (lazers_ppc.lua)
    })

    if not bullet then
        self:Notify("slots", "ACF has no free projectile slot (too many bullets in the air), so the shot was not released and no energy was used.")

        return false
    end

    self:PlayFireSound() -- 16.2

    return true
end

-- Try to release a shot now. Needs: Fire held, a press not yet answered (or PPCAutoRepeat), the cooling over, and the energy in the pool.
function ENT:TryShoot()
    if not self.WantFire then return false end

    local now = CurTime()

    if now < self.NextShot then return false end
    if not (self.PressPending or ACFLazers.PPCFlag("PPCAutoRepeat")) then return false end

    local cost = self:GetShotEnergy()

    if not self:CanAfford(cost) then return false end -- a dud: RefreshPower reports it
    if not self:Shoot() then return false end

    self:TakeEnergy(cost)
    self:AddShotHeat(now) -- 16.2: the paid shot heats the PPC itself

    self.PressPending = false
    self.NextShot     = now + math.max(ACFLazers.PPCNumber("PPCRefireSeconds"), 0)
    self.LastEnergy   = self:GetPoolEnergy()

    self:UpdateWireOutputs()
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
    self:RefreshPower(true)
end

function ENT:Think()
    local now = CurTime()

    if self.WantFire then self:TryShoot() end

    -- the hover text said "Cooling": say "Ready" when it is over
    if self.CoolingShown and now >= self.NextShot then
        self.CoolingShown = false
        self:UpdateOverlay()
    end

    self:HeatThink(now) -- 16.2: the damage its own heat does to it

    if not IsValid(self) then return end -- its own heat can destroy it

    self:HeatReadout(now)

    self:UpdateReadyOutput()
    self:RefreshPower(false)

    -- every tick while Fire is held or it is cooling between shots; fast (HEAT_THINK) while it holds heat, so the heat damage and the readout keep up; slow when it is cold and idle
    self:NextThink(now + ((self.WantFire or now < self.NextShot) and 0 or (self.HeatShown and HEAT_THINK or IDLE_THINK)))

    return true
end

-- The hover text, built the way ACF's cannons build theirs (ACF_UpdateOverlayState is called by ACF's overlay system when we call self:UpdateOverlay()).
function ENT:ACF_UpdateOverlayState(State)
    local caliber = self:GetCaliber()
    local cost    = self:GetShotEnergy()
    local now     = CurTime()

    if now < self.NextShot then
        self.CoolingShown = true
        State:AddWarning(string.format("Cooling: %.1f s", self.NextShot - now))
    elseif self:CanAfford(cost) then
        State:AddSuccess("Ready to fire")
    elseif not next(self.Caps) then
        State:AddError("Cannot fire: no capacitor linked")
    else
        State:AddError(string.format("Cannot fire: needs %.0f kJ in the capacitors for a shot", cost))
    end

    local info = ACFLazers.GetPPCReadout(caliber)

    State:AddKeyValue("Caliber", string.format("%g mm", caliber))

    -- 16.2: the heat, in Fahrenheit and as a share of the PPC's limit, and what one shot adds
    local heatPct = self:GetHeatPct()

    State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of its limit)", Heat.GetTempF(self), heatPct * 100))
    State:AddKeyValue("Heat per shot", string.format("%.0f kJ (%.0f%% of its limit)", info.heat, info.heatPct))

    if heatPct > 1 then
        State:AddError("Overheated: taking damage")
    end

    State:AddKeyValue("Muzzle velocity", string.format("%.0f m/s", info.speed))
    State:AddKeyValue("Blast", string.format("%.2f kg of HE, radius %.1f m", info.filler, info.radiusM))
    State:AddKeyValue("Projectile life", string.format("%g s (damage %d%% at the end)", info.lifetime, math.floor(info.damageEnd * 100 + 0.5)))

    if LASER_CONFIG.RequireCapacitor then
        local capacity = self:GetPoolCapacity()
        local energy   = self:GetPoolEnergy()

        if capacity > 0 then
            State:AddProgressBar("Energy available", math.Round(energy, 1), math.Round(capacity, 1), " kJ")
        else
            State:AddKeyValue("Energy available", "0 kJ")
        end

        local linked, grouped = 0, #self:GetPool()

        for _ in pairs(self.Caps) do linked = linked + 1 end

        State:AddKeyValue("Capacitors", string.format("%d linked (%d in the group)", linked, grouped))
        State:AddKeyValue("Energy per shot", string.format("%.0f kJ (%d shots in the pool)", cost, math.floor(energy / math.max(cost, 1e-6) + 1e-9)))
    else
        State:AddKeyValue("Power", "free (RequireCapacitor is off in the config)")
    end
end

function ENT:PhysgunPickup(ply) return true end
function ENT:OnPhysgunFreeze(weapon, phys, ent, ply) return true end
function ENT:CanTool(ply, trace, tool) return true end

function ENT:OnRemove()
    -- forget the capacitors, and make them forget us
    for cap in pairs(self.Caps or {}) do
        if IsValid(cap) and cap.Lazers then cap.Lazers[self] = nil end
    end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- Click-to-update. Entities.Update calls this. Same shape as the lazer's: wrap the change in SaveEntity/RestoreEntity so welds and the frozen state survive the rescale.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "PPC updated successfully!"
end

if SERVER then
    -- Data is a table {Caliber = mm}. Signature (Player, Pos, Angle, Data) is what Entities.Register wants.
    function MakeACFPPC(ply, pos, angles, Data)
        if not istable(Data) then
            Data = { Caliber = Data }
        end

        if IsValid(ply) and not ply:CheckLimit("acf_ppcs") then return nil end

        local ent = ents.Create("acf_ppc")
        if not IsValid(ent) then return nil end

        -- ACF wants this table and a model BEFORE Spawn
        ent.ACF = {}
        Contraption.SetModel(ent, ACFLazers.PPCString("PPCModel"))

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
            ply:AddCount("acf_ppcs", ent)
            ply:AddCleanup("acf_ppcs", ent)
        end

        return ent
    end

    -- "Caliber" is the plain field ApplyData stores; ACF's Register builds the duplicator entry with it. If it is ever renamed, old dupes paste at the default size.
    Entities.Register("acf_ppc", MakeACFPPC, "Caliber")

    -- LINKING PPC <-> capacitor, through ACF's own link system (the same one lazers, guns and ammo crates use). The PPC puts itself in the capacitor's Lazers set: the capacitor treats it like a
    -- lazer (the link count in its hover text, "powering something" while the PPC draws, unlinking when either is removed).
    ACF.RegisterLinkSource("acf_ppc", "Caps")

    ACF.RegisterClassLink("acf_ppc", "acf_capacitor", function(PPC, Cap)
        if PPC.Caps[Cap] then return false, "This PPC is already linked to this capacitor." end

        PPC.Caps[Cap]   = true
        Cap.Lazers[PPC] = true

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1 -- every lazer, PPC and capacitor rebuilds its group the next time it needs it

        PPC:RefreshPower(true)
        Cap:UpdateOverlay(true)

        return true, "PPC linked to the capacitor."
    end)

    ACF.RegisterClassUnlink("acf_ppc", "acf_capacitor", function(PPC, Cap)
        if not (PPC.Caps[Cap] or Cap.Lazers[PPC]) then return false, "This PPC is not linked to this capacitor." end

        PPC.Caps[Cap]   = nil
        Cap.Lazers[PPC] = nil

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

        PPC:RefreshPower(true)
        Cap:UpdateOverlay(true)

        return true, "PPC unlinked from the capacitor."
    end)

    -- Breaks every link this PPC has. Returns how many it broke. (The link kit's reload uses it.)
    function ENT:UnlinkAll()
        local count = 0

        for cap in pairs(self.Caps) do
            if ACF.PerformClassUnlink(self, cap) then count = count + 1 end
        end

        return count
    end

    -- Duplicator: the linked capacitors' ids are saved with the PPC and linked again when the dupe is pasted (the lazer does the same with its own modifier name).
    function ENT:PreEntityCopy()
        if next(self.Caps) then
            local ids = {}

            for cap in pairs(self.Caps) do
                if IsValid(cap) then ids[#ids + 1] = cap:EntIndex() end
            end

            duplicator.StoreEntityModifier(self, "ACFPPCCaps", ids)
        end

        self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
    end

    function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
        local mods = Ent.EntityMods

        if mods and mods.ACFPPCCaps then
            for _, id in pairs(mods.ACFPPCCaps) do
                local cap = CreatedEntities[id]

                if IsValid(cap) then self:Link(cap) end
            end

            mods.ACFPPCCaps = nil
        end

        self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
    end
end
