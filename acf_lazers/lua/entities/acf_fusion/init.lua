-- =========================================================================
-- ACF FUSION ENGINE: SERVER FILE
-- REBUILT (16.9), CHANGED (17: throttle, size curve, hum, damaged heat; 22: STATIC HEAT from the charge). Goes to:  lua/entities/acf_fusion/init.lua   (on the SERVER, and in the game folder; restart the server after copying: a new entity folder is only read at start)
--           NEEDS the 22 config (lua/autorun/acf_lazers_config.lua) AND lua/autorun/acf_lazers_heat.lua. Without them the engine is still REGISTERED with ACF, but refuses to spawn and says why.
--           For the PPC to disturb engines, the 16.9 (or newer) acf/entities/ammo_types/lazers_ppc.lua has to be on the server too.
--
-- THE ACF FUSION ENGINE. A self-powered energy source for the capacitors. The Fusion tool has one SLIDER (the rated power in hp, 250 .. 6500, the hp of a generator hub that would make the same energy);
-- the spin-up time and the PPC numbers follow it on straight lines; the mass and the model scale follow the SIZE CURVE (an inverse exponential blended with a straight line, FusionSizeCurve): small engines
-- grow fast along the slider, big ones slowly (see FUSION ENGINES in the config).
--   * links:    fusion engine <-> capacitor, with the same link tools as a generator hub (right-click the engine, then the capacitor; reload unlinks). Nothing else links to it.
--   * parent:   it only runs while it is PARENTED to something (FusionNeedsParent): a vehicle that is still being spawned in or built cannot blow up. Not parented = operating 0 and no energy (its charge, and so its heat, drain away).
--   * wire:     input Active, a THROTTLE from 0 to 1 = the operating percent the engine is asked to hold (nothing wired = FusionActiveDefault, full). Outputs: Energy, Rated, MaxEnergy, Load, Full, Operating (%), Efficiency (%), Charge (kJ), ChargePct, HeatKJ, HeatF, HeatPct, Parented
--   * operating percent: it climbs from 0 to 100% in 8 s (smallest) .. 15 s (biggest), toward its TARGET = the lower of the Active throttle and its CEILING = its efficiency (health efficiency x heat efficiency).
--               Switched off (Active 0), or over its target, it falls the same way.
--   * energy:   kJ per second = hp x GenKJPerHP x operating percent, water-filled into the free room of the whole capacitor group (like a dump). No room = nothing is made (its static heat goes on: it follows the charge).
--   * heat:     STATIC (22): every pass it heats itself by GetFusionStaticHeat per second = FusionStaticHeat (0.15) x FusionHeatScalar x the rated kJ/s x its CHARGE PERCENT x a health multiplier (1 at full health ... FusionDamagedHeatMult 5 at 0%),
--               whether or not the capacitors have room. (FusionEnergyHeatMult 1 adds the old FusionHeatScalar kJ per kJ stored.) At FusionCriticalF (1500 F) it DETONATES.
--   * hum:      a looping sound that follows the operating percent (volume, pitch) and the engine's size (louder, deeper, farther when bigger). FusionHum... in the config; "" for FusionHumSound = silent.
--   * charge:   the energy it holds. Follows the operating percent up at once, drains away slowly (FusionChargeDrainSeconds) when the operating percent falls. It is the size of the bang when the engine
--               explodes (critical heat, or destroyed): filler kg = charge kJ x FusionBlastMult / ACF.HEPower.
--   * safezone: an engine inside a safezone (ACFLazers.IsProtectedBySafezone) cannot explode and is not touched by PPCs.
--   * PPC:      a PPC that detonates within FusionPPCRange (300 units) cuts the operating percent at once (by the PPC's heat percent per shot x the engine's size scalar), the engine cannot grow again for a
--               random 1 .. 3 s (smallest) / 1 .. 5 s (biggest) and then climbs back at its normal spin-up rate. The PPC announces its blast with the hook ACFLazers_PPCImpact (pos, caliber, bullet).
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Fusion...).
-- =========================================================================

local VERSION = "22"

-- The first line this file prints. If the server console does NOT show it after a restart, the server never ran this file (the folder lua/entities/acf_fusion/ is not on the SERVER, or the file
-- has a syntax error: the console shows one then).
MsgN("[acf_fusion] init.lua version " .. VERSION .. " loaded")

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities
local Damage      = ACF.Damage
local Objects     = Damage.Objects

local CFG  = ACFLazers and ACFLazers.Config
local Heat = ACFLazers and ACFLazers.Heat

-- WHAT IS MISSING (16.9, 17). This file NEVER stops loading because of a missing config: the engine is registered with ACF whatever happens below, and a spawn with something missing says what it is
-- (in the player's chat and the server console). In 16.8 a missing piece made this file return before the registration, which looks like "acf_fusion is not a registered ACF entity class".
local NeedHelpers = {
    "FusionNumber", "GetFusionModel", "ClampFusionHP", "GetFusionScale", "GetFusionMass", "GetFusionRatedRate", "GetFusionRate", "GetFusionChargeMax", "GetFusionPPCCut", "GetFusionRecoveryDelay",
    "GetFusionEfficiency", "GetFusionRiseCritical", "StepFusionOperating", "StepFusionCharge", "GetFusionBlastFiller", "IsProtectedBySafezone", "WaterFill", "GetCapGroup", "GetHeatCapacity",
    "GetFusionThrottle", "GetFusionTarget", "GetFusionHeatMult", "GetFusionHum", "GetFusionSizeFraction", "GetFusionStaticHeat", "GetFusionStandardHeat",
}

local Problem

if not CFG then
    Problem = "ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed on the SERVER?"
elseif not (Heat and Heat.Add and Heat.GetPct) then
    Problem = "the heat system is missing: copy lua/autorun/acf_lazers_heat.lua and the 22 lua/autorun/acf_lazers_config.lua to the SERVER, then restart."
else
    local missing = {}

    for _, name in ipairs(NeedHelpers) do
        if not ACFLazers[name] then missing[#missing + 1] = name end
    end

    if #missing > 0 then
        Problem = "lua/autorun/acf_lazers_config.lua on the SERVER is older than this file (22): it has no " .. table.concat(missing, ", ") .. ". Copy the 22 config to the SERVER, then restart."
    end
end

if Problem then ErrorNoHalt("[acf_fusion] " .. Problem .. "\n") end

-- How many fusion engines one player may own (GMod reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists).
CreateConVar("sbox_maxacf_fusions", tostring(Problem and 40 or ACFLazers.FusionNumber("FusionMaxPerPlayer")), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF fusion engines one player may spawn")

-- Every fusion engine that exists (weak keys: a removed engine drops out by itself). The PPC hook at the bottom walks it.
local Engines = setmetatable({}, { __mode = "k" })

-- ===================== WIRE =====================

-- The Active input as the THROTTLE (17): the operating percent the engine is asked to hold, a fraction 0..1 (0 = off). Nothing wired = FusionActiveDefault. [GUESS] that Wire keeps the entity a wire comes from in Inputs[name].Src (the generator and the capacitor's
-- AllowCharge rely on the same thing). Should this Wire not have it, the last value sent to TriggerInput is used as soon as one has arrived.
function ENT:GetThrottle()
    local input = self.Inputs and self.Inputs.Active
    local value = ACFLazers.FusionNumber("FusionActiveDefault")

    if input and IsValid(input.Src) then
        self.SrcWorks = true
        value         = tonumber(input.Value) or 0
    elseif not self.SrcWorks and self.ActiveTouched then
        value = self.WireActive
    end

    return ACFLazers.GetFusionThrottle(value) -- (NaN, which a broken E2 can send, and anything under 0 mean off; over 1 means full)
end

-- The Active input as true / false: asked for anything at all.
function ENT:GetActive()
    return self:GetThrottle() > 0
end

function ENT:TriggerInput(name, value)
    if name == "Active" then
        self.WireActive    = tonumber(value) or 0
        self.ActiveTouched = true
    end

    self:UpdateOverlay()
end

-- ===================== SPAWN AND SIZE =====================

function ENT:Initialize()
    self.RatedHP     = ACFLazers.ClampFusionHP(self.RatedHP) -- (nothing yet = the slider's default; ApplyData sets the real one right after the spawn)
    self.Caps        = {}      -- capacitors linked to this engine (a set)
    self.Pool        = {}      -- the capacitor group the energy goes to (rebuilt when ACFLazers.LinkVersion changes)
    self.PoolVersion = -1
    self.Operating   = 0       -- the operating percent as a fraction, 0..1
    self.Charge      = 0       -- kJ held inside
    self.RecoverAt   = 0       -- CurTime until which a PPC hit keeps the operating percent from growing
    self.EnergyRate  = 0       -- kJ per second going into the capacitors (smoothed)
    self.Room        = math.huge -- free room in the capacitors, kJ (as of the last pass; until the first pass nothing is known, so it counts as plenty)
    self.Refusing    = 0       -- capacitors with room that refuse energy because their AllowCharge is off (as of the last pass)
    self.Status      = "Not set up yet"
    self.CapStatus   = ""
    self.Efficiency  = 1       -- the ceiling of the operating percent: health efficiency x heat efficiency (as of the last pass)
    self.IsOn        = false   -- the Active input is over 0, as of the last pass
    self.Throttle    = 1       -- the Active input as a fraction 0..1, as of the last pass (until the first pass it counts as full)
    self.IsParented  = false   -- parented as of the last pass
    self.AtCritical  = false   -- at or over the critical heat as of the last pass (only stays true in a safezone: anywhere else it explodes)
    self.PPCHits     = 0       -- PPC hits taken (a counter for tests and the hover text)
    self.LastThink   = CurTime()
    self.NextOutput  = 0
    self.OverlaySig  = ""

    Engines[self] = true

    if WireLib then
        WireLib.CreateInputs(self, { "Active" })
        WireLib.CreateOutputs(self, {
            "Energy",     -- kJ per second going into the capacitors
            "Rated",      -- the generator-equivalent hp (the slider)
            "MaxEnergy",  -- kJ per second it makes at the operating percent it has now (with room to put it)
            "Load",       -- percent: Energy / MaxEnergy
            "Full",       -- 1 while the capacitors have no room (nothing is made)
            "Operating",  -- operating percent (0 .. 100)
            "Efficiency", -- the ceiling of the operating percent, percent (health x heat; 100 = full health and low heat)
            "Charge",     -- kJ held inside (the size of the bang)
            "ChargePct",  -- percent of the most it can hold
            "HeatKJ",     -- kJ of heat above room temperature
            "HeatF",      -- temperature in Fahrenheit
            "HeatPct",    -- percent of the CRITICAL heat (100 = it explodes)
            "Parented"    -- 1 while it is parented (it only runs then)
        })
    end

    self:NextThink(CurTime())
    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.RatedHP = ACFLazers.ClampFusionHP(Data.RatedHP)
end

-- Model, scale, ACF health and mass for a rated power. Same order the lazer, the capacitor and the generator use: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(hp)
    self:SetScaledModel(ACFLazers.GetFusionModel())
    self:SetScale(ACFLazers.GetFusionScale(hp))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetFusionMass(hp))
end

-- Apply a whole Data table {RatedHP = hp}. Used by spawn AND by update. RatedHP is a plain field on purpose: the duplicator saves entity fields (see Entities.Register at the bottom).
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.RatedHP = Data.RatedHP
    self.Name    = string.format("Fusion Engine (%d hp)", self.RatedHP) -- the undo list uses Entity.Name

    self:SetNW2Float("ACFFusionHP", self.RatedHP)
    self:ApplyScale(self.RatedHP)

    self.Charge = math.min(self.Charge or 0, ACFLazers.GetFusionChargeMax(self.RatedHP)) -- a smaller engine cannot keep a bigger engine's charge

    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the model scale in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = ACFLazers.FusionNumber("FusionArmourAtOne") * ACFLazers.GetFusionScale(self.RatedHP) * ACF.ArmorMod
    local Health  = Area / ACF.Threshold * ACFLazers.FusionNumber("FusionHealthMult")
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

-- 0..1: the engine's ACF health as a share of its maximum (1 when it has none, so an engine that is not set up yet counts as undamaged).
function ENT:GetHealthFraction()
    local SelfACF = self.ACF

    if SelfACF and SelfACF.Health and SelfACF.MaxHealth and SelfACF.MaxHealth > 0 then
        return math.Clamp(SelfACF.Health / SelfACF.MaxHealth, 0, 1)
    end

    return 1
end

-- ===================== HEAT, PARENT, EFFICIENCY =====================

-- How hot as a share of the CRITICAL heat: 0 = room temperature, 1 = critical (FusionCriticalF), 2 = twice as far above room temperature as the critical heat.
function ENT:GetHeatFraction()
    return Heat.GetPct(self, ACFLazers.GetFusionRiseCritical())
end

-- Is it allowed to run? Parented to something (the GMod parent tool), or FusionNeedsParent is 0.
function ENT:CheckParent()
    if ACFLazers.FusionNumber("FusionNeedsParent") < 1 then return true end

    return IsValid(self:GetParent())
end

-- The ceiling of the operating percent right now: the health efficiency times the heat efficiency (1 = full health and low heat).
function ENT:GetCeiling()
    return ACFLazers.GetFusionEfficiency(self:GetHealthFraction(), self:GetHeatFraction())
end

-- ===================== THE CAPACITORS =====================

-- The capacitors the energy can go to: the whole group of every linked capacitor (like a lazer's pool). Rebuilt only when a link changed somewhere.
function ENT:GetPool()
    if self.PoolVersion ~= ACFLazers.LinkVersion then
        self.Pool        = ACFLazers.GetCapGroup(self.Caps)
        self.PoolVersion = ACFLazers.LinkVersion
    end

    return self.Pool
end

-- Free room (kJ) in every capacitor that will take energy from a fusion engine: it must exist, not be exploding and have AllowCharge on.
-- Returns the total, the two lists WaterFill wants (who, and how much room each has), and how many capacitors have room but refuse because their AllowCharge is off.
function ENT:GetRoom()
    local caps, limits, total, refusing = {}, {}, 0, 0

    for _, cap in ipairs(self:GetPool()) do
        if IsValid(cap) and not cap.Exploding then
            local room = math.max(cap.Capacity - cap.Charge, 0)

            if room > 0 then
                local allowed = cap.Allowing ~= false -- (the old capacitor file has no IsChargeAllowed: its mirror is used)

                if cap.IsChargeAllowed then allowed = cap:IsChargeAllowed() end

                if not allowed then
                    refusing = refusing + 1
                else
                    caps[#caps + 1]     = cap
                    limits[#limits + 1] = room
                    total               = total + room
                end
            end
        end
    end

    return total, caps, limits, refusing
end

-- ===================== THE WORK =====================

-- One pass of work. `now` = CurTime(), `dt` = seconds since the last pass.
function ENT:Run(now, dt)
    local hp       = self.RatedHP
    local parented = self:CheckParent()
    local throttle = self:GetThrottle()
    local active   = throttle > 0
    local ceiling  = self:GetCeiling()
    local target   = ACFLazers.GetFusionTarget(throttle, ceiling)

    -- 1. THE OPERATING PERCENT. Not parented = nothing at all. Otherwise it climbs toward its target (the lower of the throttle and the ceiling; when switched on and not waiting out a PPC hit) or falls.
    if parented then
        self.Operating = ACFLazers.StepFusionOperating(self.Operating, dt, hp, active, target, now >= self.RecoverAt)
    else
        self.Operating = 0
    end

    -- 2. THE CHARGE: follows the operating percent up, drains away slowly.
    self.Charge = ACFLazers.StepFusionCharge(self.Charge, self.Operating, hp, dt)

    -- 3. THE ENERGY: what it makes at this operating percent, no more than the capacitors have room for. Nothing without a parent.
    local room, caps, limits, refusing = self:GetRoom()
    local storedKJ = 0

    if parented and self.Operating > 0 then
        storedKJ = math.min(ACFLazers.GetFusionRate(hp, self.Operating) * dt, room)
    end

    -- 3b. THE HEAT [22]: static. It follows the charge (just updated), not what went into the capacitors, so a full engine on full capacitors is as hot as one that is charging them.
    local health  = self:GetHealthFraction()
    local heatKJ  = ACFLazers.GetFusionStaticHeat(hp, self.Charge, health) * dt
    local perKJ   = ACFLazers.FusionNumber("FusionEnergyHeatMult")

    if storedKJ > 0 and perKJ > 0 then -- (17 to 21: FusionHeatScalar kJ of heat per kJ stored, times the health multiplier; now an option, off by default)
        heatKJ = heatKJ + storedKJ * ACFLazers.FusionNumber("FusionHeatScalar") * ACFLazers.GetFusionHeatMult(health) * perKJ
    end

    if heatKJ > 0 then Heat.Add(self, heatKJ) end

    if storedKJ > 0 then
        local takes = ACFLazers.WaterFill(limits, storedKJ)

        for i, cap in ipairs(caps) do
            if takes[i] > 0 then cap:AddCharge(takes[i]) end
        end
    end

    -- The reading: kJ per second, smoothed.
    local alpha = 1 - math.exp(-dt / math.max(ACFLazers.FusionNumber("FusionPowerSmoothing"), 1e-6))

    self.EnergyRate = self.EnergyRate + (storedKJ / dt - self.EnergyRate) * alpha
    self.Efficiency = ceiling
    self.Room       = room
    self.Refusing   = refusing
    self.IsOn       = active
    self.Throttle   = throttle
    self.IsParented = parented

    self:SafeUpdateHum()

    self:UpdateStatus(now, room)

    -- 4. THE CRITICAL HEAT (checked after this pass's heat went in).
    self:CheckCritical()

    -- Wire outputs and hover text, a few times a second.
    if IsValid(self) and now >= self.NextOutput then -- (CheckCritical may just have blown it up)
        self.NextOutput = now + ACFLazers.FusionNumber("FusionOutputInterval")
        self:UpdateWireOutputs()
        self:RefreshOverlay()
    end
end

-- kJ per second it makes at the operating percent it has now (with room to put it).
function ENT:GetMaxRate()
    return ACFLazers.GetFusionRate(self.RatedHP, self.Operating)
end

-- The one-line state for the hover text, and a second line about the capacitors.
function ENT:UpdateStatus(now, room)
    if not self.IsParented then
        self.Status = "Not parented: it will not run (parent it to its vehicle)"
    elseif not self.IsOn then
        self.Status = self.Operating > 0 and string.format("Switching off: operating %.0f%%", self.Operating * 100) or "Off (the Active input is 0)"
    elseif now < self.RecoverAt then
        self.Status = string.format("Disrupted by a PPC: waiting %.1f s to recover", self.RecoverAt - now)
    else
        -- 17: when the Active input asks for less than the engine could do, the throttle is what it steers toward; otherwise the ceiling (health x heat) is.
        local ask       = ACFLazers.GetFusionThrottle(self.Throttle)
        local target    = ACFLazers.GetFusionTarget(ask, self.Efficiency)
        local throttled = ask < self.Efficiency - 1e-6

        if self.Operating < target - 1e-6 then
            if throttled then
                self.Status = string.format("Spinning up to the Active input's %.0f%%: operating %.0f%%", ask * 100, self.Operating * 100)
            else
                self.Status = string.format("Spinning up: operating %.0f%% of a possible %.0f%%", self.Operating * 100, self.Efficiency * 100)
            end
        elseif self.Operating > target + 1e-6 then
            if throttled then
                self.Status = string.format("Spinning down to the Active input's %.0f%%: operating %.0f%%", ask * 100, self.Operating * 100)
            else
                self.Status = string.format("Over its ceiling (health or heat): falling toward %.0f%%", self.Efficiency * 100)
            end
        elseif throttled then
            self.Status = string.format("Running at %.0f%% (the Active input asks for %.0f%%)", self.Operating * 100, ask * 100)
        else
            self.Status = string.format("Running at %.0f%%", self.Operating * 100)
        end
    end

    if next(self.Caps) == nil then
        self.CapStatus = "No capacitor linked (nothing to store the energy in)"
    elseif room <= 0 and self.Refusing > 0 then
        self.CapStatus = "AllowCharge is off on the capacitors (nothing is made)"
    elseif room <= 0 then
        self.CapStatus = "Capacitors full (nothing is made)"
    else
        self.CapStatus = ""
    end
end

-- ===================== PPC HITS =====================

-- A PPC detonated at `pos` (caliber in mm). Within FusionPPCRange of the engine its operating percent is cut at once and the wait before it may grow again is rolled.
-- Returns true when the engine was hit. Safezone engines, engines that are exploding, and engines that are idle with nothing to disturb are left alone.
function ENT:PPCHit(pos, caliber, now)
    if self.Exploding or not pos then return false end

    now = now or CurTime()

    if ACFLazers.IsProtectedBySafezone(self) then return false end
    if self:LocalToWorld(self:OBBCenter()):Distance(pos) > ACFLazers.FusionNumber("FusionPPCRange") then return false end
    if not (self.Operating > 0 or now < self.RecoverAt) then return false end

    local cut = ACFLazers.GetFusionPPCCut(caliber, self.RatedHP)

    if cut <= 0 then return false end

    self.Operating = math.max(self.Operating - cut, 0)
    self.RecoverAt = now + ACFLazers.GetFusionRecoveryDelay(self.RatedHP, math.random())
    self.PPCHits   = self.PPCHits + 1

    self:UpdateWireOutputs()
    self:UpdateOverlay()

    return true
end

-- ===================== WIRE + OVERLAY =====================

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local max    = self:GetMaxRate()
    local most   = ACFLazers.GetFusionChargeMax(self.RatedHP)
    local critic = ACFLazers.GetFusionRiseCritical()

    WireLib.TriggerOutput(self, "Energy", self.EnergyRate)
    WireLib.TriggerOutput(self, "Rated", self.RatedHP)
    WireLib.TriggerOutput(self, "MaxEnergy", max)
    WireLib.TriggerOutput(self, "Load", max > 0 and self.EnergyRate / max * 100 or 0)
    WireLib.TriggerOutput(self, "Full", (next(self.Caps) ~= nil and self.Room <= 0 and self.Refusing == 0) and 1 or 0)
    WireLib.TriggerOutput(self, "Operating", self.Operating * 100)
    WireLib.TriggerOutput(self, "Efficiency", self.Efficiency * 100)
    WireLib.TriggerOutput(self, "Charge", self.Charge)
    WireLib.TriggerOutput(self, "ChargePct", most > 0 and self.Charge / most * 100 or 0)
    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", Heat.GetPct(self, critic) * 100)
    WireLib.TriggerOutput(self, "Parented", self.IsParented and 1 or 0)
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    local hp         = self.RatedHP
    local linkedCaps = 0
    local most       = ACFLazers.GetFusionChargeMax(hp)
    local heatFrac   = self:GetHeatFraction()

    for _ in pairs(self.Caps) do linkedCaps = linkedCaps + 1 end

    if not self.IsParented then
        State:AddError(self.Status)
    elseif self.Status:find("Disrupted", 1, true) then
        State:AddWarning(self.Status) -- (before the green line: a disrupted engine usually still makes some energy)
    elseif self.EnergyRate > 0 then
        State:AddSuccess(self.Status)
    else
        State:AddLabel(self.Status)
    end

    if self.CapStatus ~= "" then State:AddWarning(self.CapStatus) end

    if self.AtCritical then State:AddError("Critical heat: it would explode, but it is in a safezone") end

    State:AddProgressBar("Operating", math.Round(self.Operating * 100, 1), 100, "%")
    State:AddKeyValue("Active input", string.format("%.0f%% asked for", ACFLazers.GetFusionThrottle(self.Throttle) * 100))
    State:AddProgressBar("Charge", math.Round(self.Charge, 1), math.Round(most, 1), " kJ")
    State:AddKeyValue("Rated power", string.format("%d hp of a generator hub (%.0f kJ/s at 100%%)", hp, ACFLazers.GetFusionRatedRate(hp)))
    State:AddKeyValue("Making", string.format("%.0f kJ/s", self.EnergyRate))
    State:AddKeyValue("Efficiency ceiling", string.format("%.0f%% (health x%.2f, heat x%.2f)", self.Efficiency * 100, ACFLazers.GetFusionHealthEfficiency(self:GetHealthFraction()), ACFLazers.GetFusionHeatEfficiency(heatFrac)))
    State:AddKeyValue("Explosive content", string.format("%.2f kg of HE", ACFLazers.GetFusionBlastFiller(self.Charge)))
    local heatMult   = ACFLazers.GetFusionHeatMult(self:GetHealthFraction())
    local staticHeat = ACFLazers.GetFusionStaticHeat(hp, self.Charge, self:GetHealthFraction())
    local perKJ      = ACFLazers.FusionNumber("FusionEnergyHeatMult")
    local heatText   = string.format("%.0f kJ/s from its charge (%.0f%% charged, x%.2f from damage)", staticHeat, most > 0 and self.Charge / most * 100 or 0, heatMult)

    if perKJ > 0 then heatText = heatText .. string.format(" + %.0f kJ/s from the energy it makes", ACFLazers.FusionNumber("FusionHeatScalar") * heatMult * perKJ * self.EnergyRate) end

    State:AddKeyValue("Heat made", heatText)
    State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of its critical heat, %g F)", Heat.GetTempF(self), heatFrac * 100, ACFLazers.FusionNumber("FusionCriticalF")))
    State:AddKeyValue("Linked", string.format("%d capacitor(s)", linkedCaps))

    if linkedCaps > 0 then
        local charge, capacity = 0, 0

        for _, cap in ipairs(self:GetPool()) do
            if IsValid(cap) then
                charge   = charge + cap.Charge
                capacity = capacity + cap.Capacity
            end
        end

        State:AddKeyValue("Capacitors", string.format("%.0f / %.0f kJ", charge, capacity))
    end
end

-- Refresh the hover text, but only when something worth showing changed (ACF's overlay networks changes).
function ENT:RefreshOverlay()
    local most      = math.max(ACFLazers.GetFusionChargeMax(self.RatedHP), 1e-6)
    local signature = self.Status .. "|" .. self.CapStatus .. "|" .. self.RatedHP .. "|" .. math.floor(self.EnergyRate / 10) .. "|" .. math.floor(self.Operating * 100) .. "|" .. math.floor(self.Efficiency * 100)
        .. "|" .. math.floor(self.Charge / most * 100) .. "|" .. math.floor(self:GetHeatFraction() * 20) .. (self.AtCritical and "c" or "") .. "|" .. math.floor(ACFLazers.GetFusionThrottle(self.Throttle) * 100)

    if signature ~= self.OverlaySig then
        self.OverlaySig = signature
        self:UpdateOverlay()
    end
end

-- ===================== THINK =====================

function ENT:Think()
    local now = CurTime()
    local dt  = math.Clamp(now - self.LastThink, 0, ACFLazers.FusionNumber("FusionMaxDeltaTime"))

    self.LastThink = now

    if dt > 0 then self:Run(now, dt) end

    self:NextThink(now + math.max(ACFLazers.FusionNumber("FusionThinkInterval"), engine.TickInterval()))

    return true
end

-- ===================== DAMAGE AND EXPLOSION =====================

-- At or over the critical heat the engine detonates. In a safezone it cannot: it only keeps the flag (the hover text says so).
function ENT:CheckCritical()
    if self.Exploding then return end

    if self:GetHeatFraction() < 1 then
        self.AtCritical = false

        return
    end

    self.AtCritical = true

    if ACFLazers.IsProtectedBySafezone(self) then return end

    self:Detonate()
end

-- ACF calls this instead of its default prop damage (the same hook the capacitor, acf_fueltank and acf_ammo use for their explosions).
-- Returns the usual HitRes table. Destroyed = detonates (unless it is in a safezone).
function ENT:ACF_OnDamage(DmgResult, DmgInfo)
    local HitRes = Damage.doPropDamage(self, DmgResult, DmgInfo)

    if self.Exploding then return HitRes end

    if HitRes.Kill then
        self.Attacker  = DmgInfo:GetAttacker()
        self.Inflictor = DmgInfo:GetInflictor()

        self:Detonate()
    end

    return HitRes
end

-- The bang. The charge becomes an ACF explosion: filler kg = charge kJ x FusionBlastMult / ACF.HEPower (never under FusionBlastMinKJ worth). Same shape as the capacitor's Detonate.
-- Inside a safezone it cannot explode: it is simply removed (no explosion, nothing else killed).
function ENT:Detonate()
    if self.Exploding then return end

    self.Exploding = true

    local filler = ACFLazers.GetFusionBlastFiller(self.Charge)

    self.Charge    = 0 -- it is gone either way
    self.Operating = 0

    if ACFLazers.IsProtectedBySafezone(self) then
        constraint.RemoveAll(self)
        self:Remove()

        return
    end

    local position = self:LocalToWorld(self:OBBCenter() + VectorRand() * (self:OBBMaxs() - self:OBBMins()) / 2)
    local dmgInfo  = Objects.DamageInfo(self.Attacker or self, self.Inflictor)

    ACF.KillChildProps(self, position, filler)

    Damage.createExplosion(position, filler, filler * 0.5, { self }, dmgInfo)
    Damage.explosionEffect(position, nil, filler)

    constraint.RemoveAll(self)
    self:Remove()
end

-- ===================== LINKING (methods; the registration is at the bottom) =====================

-- Breaks every link this engine has. Returns how many it broke. (The link tools' reload uses it.)
function ENT:UnlinkAll()
    local count = 0

    for Cap in pairs(self.Caps) do
        if IsValid(Cap) and self:Unlink(Cap) then
            count = count + 1
        else
            self.Caps[Cap] = nil
        end
    end

    return count
end

-- ===================== HUM (17) =====================

-- Stops the hum for good (nothing is left playing).
function ENT:StopHum()
    if self.HumSnd then
        self.HumSnd:Stop()
        self.HumSnd = nil
    end
end

-- The hum follows the operating percent and the size (ACFLazers.GetFusionHum): silent at 0, otherwise a looping sound patch made once (its sound level has to be set BEFORE it starts playing) whose
-- volume and pitch glide to the new numbers over one pass. It is made again when the sound file or the level (a resize) changes. [GUESS] that CreateSound loops this file by itself, as for the lazer's burn sound.
function ENT:UpdateHum()
    local hum  = ACFLazers.GetFusionHum(self.RatedHP, self.Operating)
    local name = ACFLazers.GetFusionHumSound()

    if self.Exploding or not hum.on or name == "" then
        self:StopHum()

        return
    end

    if self.HumSnd and (self.HumName ~= name or self.HumLevel ~= hum.level) then self:StopHum() end

    local glide = ACFLazers.FusionNumber("FusionThinkInterval")

    if not self.HumSnd then
        local snd = CreateSound(self, name)

        if not snd then return end

        snd:SetSoundLevel(hum.level)
        snd:PlayEx(hum.volume, hum.pitch)

        self.HumSnd, self.HumName, self.HumLevel, self.HumVolume, self.HumPitch = snd, name, hum.level, hum.volume, hum.pitch
    elseif not self.HumSnd:IsPlaying() then -- (the engine stops a patch now and then, e.g. on a map cleanup)
        self.HumSnd:PlayEx(hum.volume, hum.pitch)
        self.HumVolume, self.HumPitch = hum.volume, hum.pitch
    else
        -- only while the operating percent really moves: a steady engine sends nothing, and a settled one ends exactly on its number
        if math.abs(hum.volume - self.HumVolume) > 1e-4 then
            self.HumSnd:ChangeVolume(hum.volume, glide)
            self.HumVolume = hum.volume
        end

        if math.abs(hum.pitch - self.HumPitch) > 0.01 then
            self.HumSnd:ChangePitch(hum.pitch, glide)
            self.HumPitch = hum.pitch
        end
    end
end

-- A sound that goes wrong must never stop the engine from working (and spam the console only once).
function ENT:SafeUpdateHum()
    local ok, err = pcall(self.UpdateHum, self)

    if not ok and not self.HumFailed then
        self.HumFailed = true
        ErrorNoHalt("[acf_fusion] the hum failed: " .. tostring(err) .. "\n")
    end
end

function ENT:OnRemove()
    Engines[self] = nil

    self:StopHum()

    -- Straight table clean-up instead of ACF.PerformClassUnlink: the entity is on its way out and we only need everybody to forget it.
    for Cap in pairs(self.Caps) do
        if IsValid(Cap) and Cap.Generators then Cap.Generators[self] = nil end
    end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- ===================== UPDATE, SPAWN, DUPES =====================

-- Click-to-update (Entities.Update calls this). Same shape as the generator's.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Fusion engine updated successfully!"
end

-- Duplicator: the linked capacitors' ids are saved and linked again on paste (the same way the generator does it).
function ENT:PreEntityCopy()
    local caps = {}

    for Cap in pairs(self.Caps) do
        if IsValid(Cap) then caps[#caps + 1] = Cap:EntIndex() end
    end

    if #caps > 0 then duplicator.StoreEntityModifier(self, "ACFFusionCaps", caps) end

    self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
    local mods = Ent.EntityMods

    if mods and mods.ACFFusionCaps then
        for _, id in pairs(mods.ACFFusionCaps) do
            local other = CreatedEntities[id]

            if IsValid(other) then self:Link(other) end
        end

        mods.ACFFusionCaps = nil
    end

    self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

-- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
function MakeACFFusion(ply, pos, angles, Data)
    -- Something this file needs is missing (see the top): say exactly what, where the player AND the server console can see it.
    if Problem then
        local msg = "[acf_fusion] cannot spawn: " .. Problem

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    if not istable(Data) then Data = {} end

    if IsValid(ply) and not ply:CheckLimit("acf_fusions") then return nil end

    -- The model is your buddy's. If it is missing the scalable base cannot build a physics mesh, so say so instead of failing with a pile of errors.
    local model = ACFLazers.GetFusionModel()

    if not util.IsValidModel(model) then
        local msg = "[acf_fusion] the model " .. model .. " is missing on this server (FusionModel in acf_lazers_config.lua). Is it installed and is the file name spelled right?"

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    local ent = ents.Create("acf_fusion")
    if not IsValid(ent) then return nil end

    -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
    ent.ACF = {}
    Contraption.SetModel(ent, model)

    ent:SetPos(pos)
    ent:SetAngles(angles)

    ent:Spawn()
    ent:Activate()

    ent:ApplyData(Data)

    if IsValid(ply) then
        if ent.SetPlayer then ent:SetPlayer(ply) end
        if CPPI then ent:CPPISetOwner(ply) end
        ply:AddCount("acf_fusions", ent)
        ply:AddCleanup("acf_fusions", ent)
    end

    return ent
end

-- THE REGISTRATION. It comes BEFORE everything that can fail (the links, the PPC hook) on purpose: from here on ACF knows the class, whatever else goes wrong.
-- Dupe key: RatedHP (the slider value). A dupe with none, or a silly one, is the slider's default.
Entities.Register("acf_fusion", MakeACFFusion, "RatedHP")

if Entities.Get and Entities.Get("acf_fusion") then
    MsgN("[acf_fusion] registered with ACF: acf_fusion can be spawned" .. (Problem and " (but it is refusing to: see the error above)" or ""))
else
    ErrorNoHalt("[acf_fusion] ACF did not take the registration of acf_fusion (Entities.Get finds nothing). Is this ACF's Entities.Register?\n")
end

-- ===================== LINKING AND THE PPC HOOK (each in its own pcall: a failure is printed and does not stop the rest) =====================

local function Try(label, fn)
    local ok, err = pcall(fn)

    if not ok then ErrorNoHalt("[acf_fusion] " .. label .. " could not be set up: " .. tostring(err) .. "\n") end
end

-- fusion engine <-> capacitor uses ACF's link system, like the generator <-> capacitor link does. The tools call  a:Link(b)  and  a:Unlink(b).
-- (A link made from either side works: ACF tries the registered pair in both orders.) The capacitor keeps the engine in its set of linked "generators" (its own file is not changed).
Try("the link to capacitors", function()
    ACF.RegisterLinkSource("acf_fusion", "Caps")

    ACF.RegisterClassLink("acf_fusion", "acf_capacitor", function(Fusion, Cap)
        if Fusion.Caps[Cap] then return false, "This fusion engine is already linked to this capacitor." end

        Fusion.Caps[Cap]        = true
        Cap.Generators          = Cap.Generators or {}
        Cap.Generators[Fusion]  = true

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1 -- every pool rebuilds the next time it is needed

        Fusion:UpdateOverlay(true)
        Cap:UpdateOverlay(true)

        return true, "Fusion engine linked to the capacitor."
    end)

    ACF.RegisterClassUnlink("acf_fusion", "acf_capacitor", function(Fusion, Cap)
        if not (Fusion.Caps[Cap] or (Cap.Generators and Cap.Generators[Fusion])) then return false, "This fusion engine is not linked to this capacitor." end

        Fusion.Caps[Cap] = nil

        if Cap.Generators then Cap.Generators[Fusion] = nil end

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

        Fusion:UpdateOverlay(true)
        Cap:UpdateOverlay(true)

        return true, "Fusion engine unlinked from the capacitor."
    end)
end)

-- The PPC announces every blast with hook.Run("ACFLazers_PPCImpact", position, caliber, bullet) (acf/entities/ammo_types/lazers_ppc.lua, 16.9). Every engine decides for itself what it does (PPCHit).
Try("the PPC hook", function()
    hook.Add("ACFLazers_PPCImpact", "ACFLazers_FusionPPC", function(pos, caliber)
        local now = CurTime()

        for ent in pairs(Engines) do
            if IsValid(ent) then
                ent:PPCHit(pos, caliber, now)
            else
                Engines[ent] = nil
            end
        end
    end)
end)
