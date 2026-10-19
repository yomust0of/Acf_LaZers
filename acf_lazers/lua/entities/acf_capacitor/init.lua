-- =========================================================================
-- CHANGES vs the capacitor init.lua you have now (version 9.7). Search this file for [CHANGED n].
--   1  The version line says 12
--   2  GENERATOR HUBS can be linked to a capacitor (the new acf_generator entity pours energy into the capacitor group). New set self.Generators; it is filled and emptied by the
--      generator <-> capacitor link functions in the GENERATOR's init.lua. Here: the set itself, the link-source registration (E2/Starfall can see it), UnlinkAll and OnRemove
--      also let go of generators, and the hover text counts them. No new wire inputs / outputs. AllowCharge off still refuses everything that would charge it, generators included
--      (the generator looks at cap.Allowing, generator init.lua GetRoom)
--   3  New ENT:IsChargeAllowed(): AllowCharge read straight from the wire (the `Allowing` mirror is refreshed only in Think, up to CapThinkInterval late). Think uses it, and the generator hub uses it
--      so a capacitor whose AllowCharge was just switched off never gets another kJ from a generator
--   (The 9.x numbering of earlier handoffs is gone: [CHANGED n] marks restart at 1 with every whole-number handoff.)
--   Goes to:  lua/entities/acf_capacitor/init.lua
--
-- THE ACF CAPACITOR. Stores energy in kJ (the same unit as ACF's HE: ACF.HEPower = 8000 kJ per kg of filler).
--   * size: a diameter in units (config CapDiameterMin..Max); capacity grows with the physical volume (config CapEnergyPerVolume)
--   * fills by itself at the "charge rate" setting (kJ per second, never more than a third of the capacity per second). NOT while a lazer is drawing from it.
--     Generator hubs (acf_generator) also charge it, as fast as the engines behind them can deliver
--   * lazers draw energy from it (lazer init.lua: TakeEnergy); capacitors linked to each other form one group that shares the load
--   * wire:  inputs AllowCharge, Dump (kJ per second)   outputs Charge, Capacity, Percent, ChargeRate, RateSetting, Dumping, GroupCharge, GroupCapacity, Diameter
--     AllowCharge is the only switch: nothing wired = charging allowed; wired = follows the signal (above 0 = charging, 0 = no charging). It stops this capacitor's own
--     charging, its intake of dumps and its intake from generators; lazers can still draw from it and it can still dump out
--   * damage: may explode (more likely the fuller it is compared to its health); destroyed = always explodes, releasing 50-100% of what it stored
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Cap...).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Damage      = ACF.Damage
local Objects     = Damage.Objects
local Entities    = ACF.Classes.Entities

local CFG = ACFLazers and ACFLazers.Config

if not CFG then
    ErrorNoHalt("[acf_capacitor] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

local VERSION = "12" -- [CHANGED 1]
MsgN("[acf_capacitor] init.lua version " .. VERSION .. " loaded")

-- How many capacitors one player may own. GMod's own limit system reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists.
CreateConVar("sbox_maxacf_capacitors", tostring(CFG.CapMaxPerPlayer), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF capacitors one player may spawn")

-- Reads a wire input as on / off. An input that nothing is wired to gives `ifNotWired` instead (so AllowCharge counts as ON until you wire it; once wired it follows the signal).
-- [GUESS] that Wire keeps the entity a wire comes from in Inputs[name].Src (I remember it being so). If it does not, AllowCharge is simply always on and Dump
-- (see ReadWireNumber) falls back on the last value Wire sent to TriggerInput (below).
local function ReadWireFlag(self, name, ifNotWired)
    local input = self.Inputs and self.Inputs[name]

    if input and IsValid(input.Src) then
        return (tonumber(input.Value) or 0) > 0
    end

    return ifNotWired
end

-- Reads a wire input as a plain number (the Dump input: kJ per second). Nothing wired = 0. Falls back on the last value Wire sent to TriggerInput.
local function ReadWireNumber(self, name)
    local input = self.Inputs and self.Inputs[name]

    if input and IsValid(input.Src) then
        return tonumber(input.Value) or 0
    end

    if name == "Dump" then return self.WireDump or 0 end

    return 0
end

-- [CHANGED 3] Is charging allowed RIGHT NOW? Read straight from the wire, so it is never a moment late (the `Allowing` field below is only refreshed in Think).
-- Nothing wired = allowed; wired = the signal (above 0 = allowed). Generator hubs ask this before they pour energy in (generator init.lua GetRoom).
function ENT:IsChargeAllowed() -- [CHANGED 3]
    return ReadWireFlag(self, "AllowCharge", true) -- [CHANGED 3]
end -- [CHANGED 3]

function ENT:TriggerInput(name, value)
    if name == "Dump" then self.WireDump = tonumber(value) or 0 end -- a number now, not a yes / no

    self:UpdateOverlay()
end

function ENT:Initialize()
    self.Diameter       = CFG.CapDiameterDefault
    self.Capacity       = ACFLazers.GetCapCapacity(CFG.CapDiameterDefault)
    self.Charge         = 0                  -- kJ stored right now
    self.ChargeRate     = 0                  -- kJ per second this capacitor fills itself (the tool slider)
    self.CapLinks       = {}                 -- capacitors linked to this one (a set: key = capacitor). Together they form a group
    self.Lazers         = {}                 -- lazers linked to this capacitor (a set)
    self.Generators     = {}                 -- [CHANGED 2] generator hubs linked to this capacitor (a set; the generator's link function fills it, generator init.lua)
    self.Group          = { self }           -- the whole group (rebuilt when ACFLazers.LinkVersion changes)
    self.GroupVersion   = -1
    self.DumpRate       = 0                  -- kJ per second the Dump input asks for right now (0 = not dumping)
    self.Allowing       = true               -- mirrors the AllowCharge wire input
    self.Dumping        = false              -- on while the Dump wire input asks for more than 0 kJ/s
    self.WireDump       = 0                  -- last value Wire sent to the Dump input (a number)
    self.LastDrainTime  = -1e9                -- CurTime() when a lazer last drew from this capacitor's pool (set by the lazer, see TakeEnergy)
    self.Drained        = false               -- mirrors IsBeingDrained for the hover text
    self.Exploding      = false
    self.NextExplodeRoll = 0
    self.LastThink      = CurTime()
    self.LastRateTime   = CurTime()
    self.LastRateCharge = 0
    self.ApparentRate   = 0                  -- kJ per second the charge is really changing by (negative while lazers or a dump drain it)
    self.OverlaySig     = ""

    if WireLib then
        WireLib.CreateInputs(self, { "AllowCharge", "Dump" })
        WireLib.CreateOutputs(self, {
            "Charge",        -- kJ stored
            "Capacity",      -- kJ it can hold
            "Percent",       -- 0..100
            "ChargeRate",    -- the apparent rate: kJ per second the charge is changing by right now (+ filling, - draining)
            "RateSetting",   -- the charge rate set in the tool (kJ per second)
            "Dumping",       -- 1 while the Dump input is on
            "GroupCharge",   -- kJ stored in this capacitor's whole group
            "GroupCapacity", -- kJ the whole group can hold
            "Diameter"       -- size in units
        })

        if self.Inputs and self.Inputs.AllowCharge then self.Inputs.AllowCharge.Value = 1 end
    end

    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.Diameter   = math.Round(ACFLazers.ClampNumber(Data.Diameter, CFG.CapDiameterDefault, CFG.CapDiameterMin, CFG.CapDiameterMax), 2)
    Data.ChargeRate = math.Round(ACFLazers.ClampNumber(Data.ChargeRate, CFG.CapChargeRateDefault, 0, ACFLazers.GetCapMaxChargeRate(Data.Diameter)), 2) -- a third of the capacity
end

-- Model, scale, ACF health and mass for a diameter. Same order the lazer uses: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(diameter)
    self:SetScaledModel(CFG.CapModel)
    self:SetScale(ACFLazers.GetCapScale(diameter))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetCapMass(diameter))
end

-- Apply a whole Data table {Diameter = units, ChargeRate = kJ/s}. Used by spawn AND by update, so both behave the same.
-- Diameter and ChargeRate are plain fields on purpose: the duplicator saves entity fields (see Entities.Register at the bottom). The stored charge is NOT saved,
-- so a pasted capacitor starts empty.
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Diameter   = Data.Diameter
    self.ChargeRate = Data.ChargeRate
    self.Capacity   = ACFLazers.GetCapCapacity(Data.Diameter)
    self.Charge     = math.min(self.Charge, self.Capacity) -- shrinking a capacitor cannot keep more energy than it now holds
    self.Name       = string.format("%g-unit Capacitor", Data.Diameter) -- the undo list uses Entity.Name

    self:ApplyScale(Data.Diameter)

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the diameter in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = (self.Diameter or CFG.CapDiameterDefault) * CFG.CapArmourPerUnit * ACF.ArmorMod
    local Health  = Area / ACF.Threshold * CFG.CapHealthMult
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

-- ===================== ENERGY =====================

function ENT:GetChargeFraction()
    if self.Capacity <= 0 then return 0 end

    return math.Clamp(self.Charge / self.Capacity, 0, 1)
end

-- 1 = full health ... 0 = dead (ACF keeps current / max health in self.ACF).
function ENT:GetHealthFraction()
    local acf = self.ACF

    if not (acf and acf.Health and acf.MaxHealth and acf.MaxHealth > 0) then return 1 end

    return math.Clamp(acf.Health / acf.MaxHealth, 0, 1)
end

-- Put energy in. Returns how much really fitted.
function ENT:AddCharge(kJ)
    local added = math.Clamp(kJ, 0, math.max(self.Capacity - self.Charge, 0))

    self.Charge = self.Charge + added

    return added
end

-- Take energy out (lazers call this). Returns how much was really there to take.
function ENT:RemoveCharge(kJ)
    local taken = math.Clamp(kJ, 0, self.Charge)

    self.Charge = self.Charge - taken

    return taken
end

-- Is a lazer drawing from this capacitor's pool right now? The lazer stamps LastDrainTime on every capacitor of its pool each time it pays a bite;
-- the stamp stays "fresh" for CapDrainHoldSeconds. While it is fresh the capacitor does not charge. Switch: CapNoChargeWhileDrained (config).
function ENT:IsBeingDrained(now)
    if not CFG.CapNoChargeWhileDrained then return false end

    return (now or CurTime()) - self.LastDrainTime < CFG.CapDrainHoldSeconds
end

-- Every capacitor connected to this one (this one included). Rebuilt only when a link changed somewhere.
function ENT:GetGroup()
    if self.GroupVersion ~= ACFLazers.LinkVersion then
        self.Group        = ACFLazers.GetCapGroup({ [self] = true })
        self.GroupVersion = ACFLazers.LinkVersion
    end

    return self.Group
end

-- DUMP. A dumping capacitor loses energy at the speed the Dump input asks for (kJ per second) and hands it to the OTHER capacitors of its group. A receiver
-- must not be dumping itself, must have AllowCharge on and must have free room; the only limit on how much it takes is that room (charge rates do not matter).
-- The energy is split between receivers with ACFLazers.WaterFill. Energy is never destroyed: whatever nobody can take stays in the dumping capacitor, so with no
-- room anywhere the dump simply waits.
function ENT:DumpStep(dt, rate)
    local want = math.min(rate * dt, self.Charge)

    if want <= 0 then return end

    local receivers, limits = {}, {}

    for _, cap in ipairs(self:GetGroup()) do
        if cap ~= self and IsValid(cap) and not cap.Exploding and not cap.Dumping and cap.Allowing ~= false then
            local limit = math.max(cap.Capacity - cap.Charge, 0) -- free room is the only limit

            if limit > 0 then
                receivers[#receivers + 1] = cap
                limits[#limits + 1]       = limit
            end
        end
    end

    if #receivers == 0 then return end

    local takes = ACFLazers.WaterFill(limits, want)
    local moved = 0

    for i, cap in ipairs(receivers) do
        if takes[i] > 0 then
            local added = cap:AddCharge(takes[i])

            moved = moved + added
        end
    end

    self:RemoveCharge(moved)
end

-- ===================== WIRE + OVERLAY =====================

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local groupCharge, groupCapacity = 0, 0

    for _, cap in ipairs(self:GetGroup()) do
        if IsValid(cap) then
            groupCharge   = groupCharge + cap.Charge
            groupCapacity = groupCapacity + cap.Capacity
        end
    end

    WireLib.TriggerOutput(self, "Charge", self.Charge)
    WireLib.TriggerOutput(self, "Capacity", self.Capacity)
    WireLib.TriggerOutput(self, "Percent", self:GetChargeFraction() * 100)
    WireLib.TriggerOutput(self, "ChargeRate", self.ApparentRate)
    WireLib.TriggerOutput(self, "RateSetting", self.ChargeRate)
    WireLib.TriggerOutput(self, "Dumping", self.Dumping and 1 or 0)
    WireLib.TriggerOutput(self, "GroupCharge", groupCharge)
    WireLib.TriggerOutput(self, "GroupCapacity", groupCapacity)
    WireLib.TriggerOutput(self, "Diameter", self.Diameter)
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    if self.Dumping then
        State:AddWarning(string.format("Dumping charge (up to %.0f kJ/s)", self.DumpRate))
    elseif self.Drained then
        State:AddWarning("Powering a lazer (charging is paused)")
    elseif not self.Allowing then
        State:AddWarning("Charging is switched off (AllowCharge input)")
    elseif self.Charge >= self.Capacity - 1e-6 then
        State:AddSuccess("Full")
    elseif self.ChargeRate > 0 then
        State:AddSuccess("Charging")
    else
        State:AddLabel("Idle (charge rate is 0)")
    end

    State:AddProgressBar("Charge", math.Round(self.Charge, 1), math.Round(self.Capacity, 1), " kJ")
    State:AddKeyValue("Size", string.format("%g units across", self.Diameter))
    State:AddKeyValue("Charge rate setting", string.format("%g kJ/s", self.ChargeRate))
    State:AddKeyValue("Net rate right now", string.format("%+.1f kJ/s", self.ApparentRate))
    State:AddKeyValue("Explosive content", string.format("%.2f kg of HE", self.Charge / ACF.HEPower * CFG.CapExplosionMult))

    local linkedCaps, linkedLazers, linkedGens = 0, 0, 0 -- [CHANGED 2]

    for _ in pairs(self.CapLinks) do linkedCaps = linkedCaps + 1 end
    for _ in pairs(self.Lazers) do linkedLazers = linkedLazers + 1 end
    for _ in pairs(self.Generators) do linkedGens = linkedGens + 1 end -- [CHANGED 2]

    State:AddKeyValue("Linked", string.format("%d capacitor(s), %d lazer(s), %d generator(s)", linkedCaps, linkedLazers, linkedGens)) -- [CHANGED 2]

    if linkedCaps > 0 then
        local groupCharge, groupCapacity = 0, 0

        for _, cap in ipairs(self:GetGroup()) do
            if IsValid(cap) then
                groupCharge   = groupCharge + cap.Charge
                groupCapacity = groupCapacity + cap.Capacity
            end
        end

        State:AddKeyValue("Group energy", string.format("%.0f / %.0f kJ", groupCharge, groupCapacity))
    end
end

-- Refresh the hover text, but only when something worth showing changed (every half a percent of charge, or a switch flipped): ACF's overlay networks changes.
function ENT:RefreshOverlay()
    local signature = math.floor(self:GetChargeFraction() * 200) .. (self.Dumping and ("d" .. math.floor(self.DumpRate)) or "") .. (self.Allowing and "" or "b") .. (self.Drained and "x" or "")

    if signature ~= self.OverlaySig then
        self.OverlaySig = signature
        self:UpdateOverlay()
    end
end

-- ===================== THINK =====================

function ENT:Think()
    local now = CurTime()
    local dt  = math.Clamp(now - self.LastThink, 0, CFG.CapMaxDeltaTime)

    self.LastThink = now

    local allow    = self:IsChargeAllowed() -- [CHANGED 3] nothing wired = on; wired = the signal (above 0 = on)
    local dumpRate = math.max(ReadWireNumber(self, "Dump"), 0) -- kJ per second the Dump input asks for
    local dump     = dumpRate > 0
    local rate     = self.ChargeRate

    local drained = self:IsBeingDrained(now)

    self.Allowing = allow
    self.Dumping  = dump
    self.DumpRate = dumpRate
    self.Drained  = drained

    if dump then
        self:DumpStep(dt, dumpRate)
    elseif allow and rate > 0 and not drained then
        -- a capacitor a lazer is drawing from does not charge by itself (it still takes dumps: the dump does not look at this)
        self:AddCharge(rate * dt)
    end

    local since = now - self.LastRateTime

    if since >= CFG.CapRateReadInterval then
        self.ApparentRate   = (self.Charge - self.LastRateCharge) / since
        self.LastRateCharge = self.Charge
        self.LastRateTime   = now

        self:UpdateWireOutputs()
        self:RefreshOverlay()
    end

    self:NextThink(now + CFG.CapThinkInterval)

    return true
end

-- ===================== DAMAGE AND EXPLOSION =====================

-- ACF calls this instead of its default prop damage (the same hook acf_fueltank and acf_ammo use for their explosions).
-- Returns the usual HitRes table. Destroyed -> always detonates. Just damaged -> may detonate, depending on charge and health (ACFLazers.GetCapExplodeChance).
function ENT:ACF_OnDamage(DmgResult, DmgInfo)
    local HitRes = Damage.doPropDamage(self, DmgResult, DmgInfo)

    if self.Exploding then return HitRes end

    if HitRes.Kill then
        self.Attacker  = DmgInfo:GetAttacker()
        self.Inflictor = DmgInfo:GetInflictor()

        self:Detonate()

        return HitRes
    end

    if (HitRes.Damage or 0) <= 0 then return HitRes end -- nothing really happened (for example the very end of a lazer beam)

    local now = CurTime()

    if now < self.NextExplodeRoll then return HitRes end -- one roll per CapExplodeRollInterval: a beam damages every tick

    local chance = ACFLazers.GetCapExplodeChance(self:GetChargeFraction(), self:GetHealthFraction())

    if chance <= 0 then return HitRes end

    self.NextExplodeRoll = now + CFG.CapExplodeRollInterval

    if math.random() < chance then
        self.Attacker  = DmgInfo:GetAttacker()
        self.Inflictor = DmgInfo:GetInflictor()

        self:Detonate()
    end

    return HitRes
end

-- The bang. Releases a random share (CapReleaseMinFraction..Max, never exactly 0) of the stored energy as an ACF explosion: filler kg = kJ / HEPower x CapExplosionMult.
-- Same shape as acf_fueltank's Detonate.
function ENT:Detonate()
    if self.Exploding then return end

    self.Exploding = true

    local released = ACFLazers.GetCapRelease(self.Charge, math.random())
    local filler   = released / ACF.HEPower * CFG.CapExplosionMult
    local position = self:LocalToWorld(self:OBBCenter() + VectorRand() * (self:OBBMaxs() - self:OBBMins()) / 2)
    local dmgInfo  = Objects.DamageInfo(self.Attacker or self, self.Inflictor)

    self.Charge = 0 -- it is gone either way; lazers drawing from it in this very tick find it empty

    ACF.KillChildProps(self, position, filler)

    Damage.createExplosion(position, filler, filler * 0.5, { self }, dmgInfo)
    Damage.explosionEffect(position, nil, filler)

    constraint.RemoveAll(self)
    self:Remove()
end

-- ===================== LINKING =====================
-- Capacitor <-> capacitor (this file) and lazer <-> capacitor (lazer init.lua) use ACF's link system. The capacitor tool calls  a:Link(b)  and  a:Unlink(b).
-- Linked capacitors are one GROUP: a lazer linked to any of them draws from all of them (see the lazer's GetPool).

ACF.RegisterLinkSource("acf_capacitor", "CapLinks")
ACF.RegisterLinkSource("acf_capacitor", "Lazers")
ACF.RegisterLinkSource("acf_capacitor", "Generators") -- [CHANGED 2] (the generator <-> capacitor link itself is registered in the generator's init.lua)

ACF.RegisterClassLink("acf_capacitor", "acf_capacitor", function(A, B)
    if A.CapLinks[B] or B.CapLinks[A] then return false, "These capacitors are already linked." end

    A.CapLinks[B] = true
    B.CapLinks[A] = true

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Capacitors linked into one group."
end)

ACF.RegisterClassUnlink("acf_capacitor", "acf_capacitor", function(A, B)
    if not (A.CapLinks[B] or B.CapLinks[A]) then return false, "These capacitors are not linked." end

    A.CapLinks[B] = nil
    B.CapLinks[A] = nil

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Capacitors unlinked."
end)

-- Breaks every link this capacitor has (to other capacitors and to lazers). Returns how many it broke. (The capacitor tool's reload uses it.)
function ENT:UnlinkAll()
    local count = 0

    for other in pairs(self.CapLinks) do
        if ACF.PerformClassUnlink(self, other) then count = count + 1 end
    end

    for lazer in pairs(self.Lazers) do
        if ACF.PerformClassUnlink(lazer, self) then count = count + 1 end
    end

    for gen in pairs(self.Generators) do -- [CHANGED 2]
        if ACF.PerformClassUnlink(gen, self) then count = count + 1 end -- [CHANGED 2]
    end -- [CHANGED 2]

    return count
end

function ENT:OnRemove()
    -- Straight table clean-up instead of ACF.PerformClassUnlink: the entity is on its way out and we only need everybody to forget it.
    for other in pairs(self.CapLinks) do
        if IsValid(other) and other.CapLinks then other.CapLinks[self] = nil end
    end

    for lazer in pairs(self.Lazers) do
        if IsValid(lazer) and lazer.Caps then lazer.Caps[self] = nil end
    end

    for gen in pairs(self.Generators) do -- [CHANGED 2]
        if IsValid(gen) and gen.Caps then gen.Caps[self] = nil end -- [CHANGED 2]
    end -- [CHANGED 2]

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- ===================== UPDATE, SPAWN, DUPES =====================

-- Click-to-update (Entities.Update calls this). Same shape as the lazer's.
function ENT:Update(Data)
    if self.Exploding then return false, "This capacitor is exploding!" end

    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Capacitor updated successfully!"
end

-- Duplicator: the neighbouring capacitors' ids are saved and linked again on paste. Both sides try to link; the second attempt just says "already linked".
function ENT:PreEntityCopy()
    if next(self.CapLinks) then
        local ids = {}

        for other in pairs(self.CapLinks) do
            if IsValid(other) then ids[#ids + 1] = other:EntIndex() end
        end

        duplicator.StoreEntityModifier(self, "ACFCapLinks", ids)
    end

    self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
    local mods = Ent.EntityMods

    if mods and mods.ACFCapLinks then
        for _, id in pairs(mods.ACFCapLinks) do
            local other = CreatedEntities[id]

            if IsValid(other) and other ~= self then self:Link(other) end
        end

        mods.ACFCapLinks = nil
    end

    self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

-- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
function MakeACFCapacitor(ply, pos, angles, Data)
    if not istable(Data) then Data = {} end

    if IsValid(ply) and not ply:CheckLimit("acf_capacitors") then return nil end

    -- The model comes with Wiremod. If it is missing the scalable base cannot build a physics mesh, so say so instead of failing with a pile of errors.
    if not util.IsValidModel(CFG.CapModel) then
        local msg = "[acf_capacitor] the model " .. CFG.CapModel .. " is missing on this server (CapModel in acf_lazers_config.lua). Is Wiremod installed and is the file name spelled right?"

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    local ent = ents.Create("acf_capacitor")
    if not IsValid(ent) then return nil end

    -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
    ent.ACF = {}
    Contraption.SetModel(ent, CFG.CapModel)

    ent:SetPos(pos)
    ent:SetAngles(angles)

    ent:Spawn()
    ent:Activate()

    ent:ApplyData(Data)

    if IsValid(ply) then
        if ent.SetPlayer then ent:SetPlayer(ply) end
        if CPPI then ent:CPPISetOwner(ply) end
        ply:AddCount("acf_capacitors", ent)
        ply:AddCleanup("acf_capacitors", ent)
    end

    return ent
end

-- Dupe keys: Diameter and ChargeRate. (The stored charge is not saved on purpose: a pasted capacitor starts empty.)
Entities.Register("acf_capacitor", MakeACFCapacitor, "Diameter", "ChargeRate")
