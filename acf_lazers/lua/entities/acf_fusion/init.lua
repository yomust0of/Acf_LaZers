-- =========================================================================
-- ACF FUSION ENGINE: SERVER FILE
-- NEW (16.8). Goes to:  lua/entities/acf_fusion/init.lua
--           NEEDS the new config (lua/autorun/acf_lazers_config.lua, 16.8) AND lua/autorun/acf_lazers_heat.lua: it refuses to load without them
--
-- THE ACF FUSION ENGINE. A self-powered energy source for the capacitors. Two sizes (the Fusion tool picks one; FusionTypes in the config):
--     Large Fusion Engine   10,000 kg   model scale 1      the energy of a 6500 hp generator hub   (33,800 kJ/s)
--     Small Fusion Engine    1,500 kg   model scale 0.25   the energy of a  250 hp generator hub   ( 1,300 kJ/s)
--   * links:    fusion engine <-> capacitor, with the same link tools as a generator hub (right-click the engine, then the capacitor; reload unlinks). Nothing else links to it.
--               The capacitor sees it in its list of linked "generators" (the capacitor file is not changed).
--   * energy:   every pass it makes  hp x GenKJPerHP x health efficiency x Draw  kJ per second and shares them out with ACFLazers.WaterFill into the free room of the whole capacitor group
--               (like a dump). No room (or AllowCharge off on every capacitor with room) = nothing is made. Health efficiency: 1 at full health down to GenDamagedEfficiency at 0%, like a hub.
--   * wire:     input Draw (0 = make nothing ... 100 = make everything; unwired counts as FusionDrawDefault)
--               outputs Energy (kJ per second going into the capacitors), Rated (the generator-equivalent hp), MaxEnergy (kJ/s it could make now: its size, health and Draw),
--               Load (percent: Energy / MaxEnergy), Full (1 = the capacitors have no room), HeatKJ, HeatF, HeatPct
--   * heat:     FusionHeatScalar (0 as shipped) kJ of heat per kJ made; 0 = it makes no heat
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Fusion...).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities

local CFG = ACFLazers and ACFLazers.Config

if not CFG then
    ErrorNoHalt("[acf_fusion] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

if not (ACFLazers.Heat and ACFLazers.Heat.Add and ACFLazers.GetHeatCapacity) then
    ErrorNoHalt("[acf_fusion] the heat system is missing: copy lua/autorun/acf_lazers_heat.lua and the new lua/autorun/acf_lazers_config.lua, then restart.\n")
    return
end

if not (ACFLazers.FusionNumber and ACFLazers.GetFusionModel and ACFLazers.GetFusionType and ACFLazers.ClampFusionType and ACFLazers.GetFusionRate and ACFLazers.GetFusionReadout) then
    ErrorNoHalt("[acf_fusion] lua/autorun/acf_lazers_config.lua is older than this file (it has no fusion helpers). Copy the config of the same batch (16.8), then restart.\n")
    return
end

local Heat = ACFLazers.Heat

local VERSION = "16.8"
MsgN("[acf_fusion] init.lua version " .. VERSION .. " loaded")

-- How many fusion engines one player may own (GMod reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists).
CreateConVar("sbox_maxacf_fusions", tostring(ACFLazers.FusionNumber("FusionMaxPerPlayer")), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF fusion engines one player may spawn")

-- ===================== WIRE =====================

-- The Draw input as a fraction 0..1. Nothing wired = FusionDrawDefault. [GUESS] that Wire keeps the entity a wire comes from in Inputs[name].Src (the generator and the capacitor's
-- AllowCharge rely on the same thing). Should this Wire not have it, the last value sent to TriggerInput is used as soon as one has arrived.
function ENT:GetDraw()
    local input = self.Inputs and self.Inputs.Draw
    local value = ACFLazers.FusionNumber("FusionDrawDefault")
    local top   = math.max(ACFLazers.FusionNumber("FusionDrawMax"), 1e-6)

    if input and IsValid(input.Src) then
        self.SrcWorks = true
        value         = tonumber(input.Value) or 0
    elseif not self.SrcWorks and self.DrawTouched then
        value = self.WireDraw
    end

    if value ~= value then value = 0 end -- NaN (a broken E2 can send one) means nothing; math.Clamp would let it through

    return math.Clamp(value, 0, top) / top
end

function ENT:TriggerInput(name, value)
    if name == "Draw" then
        self.WireDraw    = tonumber(value) or 0
        self.DrawTouched = true
    end

    self:UpdateOverlay()
end

-- ===================== SPAWN AND SIZE =====================

function ENT:Initialize()
    self.FusionType  = ACFLazers.ClampFusionType(nil)
    self.Caps        = {}      -- capacitors linked to this engine (a set)
    self.Pool        = {}      -- the capacitor group the energy goes to (rebuilt when ACFLazers.LinkVersion changes)
    self.PoolVersion = -1
    self.EnergyRate  = 0       -- kJ per second going into the capacitors (smoothed)
    self.Room        = math.huge -- free room in the capacitors, kJ (as of the last pass; until the first pass nothing is known, so it counts as plenty)
    self.Refusing    = 0       -- capacitors with room that refuse energy because their AllowCharge is off (as of the last pass)
    self.Status      = "Not set up yet"
    self.Efficiency  = 1       -- energy multiplier from the engine's health (1 = undamaged)
    self.LastThink   = CurTime()
    self.NextOutput  = 0
    self.OverlaySig  = ""

    if WireLib then
        WireLib.CreateInputs(self, { "Draw" })
        WireLib.CreateOutputs(self, {
            "Energy",    -- kJ per second going into the capacitors
            "Rated",     -- the generator-equivalent hp of this size
            "MaxEnergy", -- kJ per second it could make now (its size, its health and the Draw input)
            "Load",      -- percent: Energy / MaxEnergy
            "Full",      -- 1 while the capacitors have no room (nothing is made)
            "HeatKJ",    -- kJ of heat above room temperature
            "HeatF",     -- temperature in Fahrenheit
            "HeatPct"    -- percent of the HOT temperature (100 = HOT)
        })
    end

    self:NextThink(CurTime())
    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.FusionType = ACFLazers.ClampFusionType(Data.FusionType)
end

-- Model, scale, ACF health and mass for a size. Same order the lazer, the capacitor and the generator use: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(id)
    local size = ACFLazers.GetFusionType(id)

    self:SetScaledModel(ACFLazers.GetFusionModel())
    self:SetScale(size.scale)

    ACF.Activate(self, true)
    Contraption.SetMass(self, size.mass)
end

-- Apply a whole Data table {FusionType = id}. Used by spawn AND by update. FusionType is a plain field on purpose: the duplicator saves entity fields (see Entities.Register at the bottom).
function ENT:ApplyData(Data)
    VerifyData(Data)

    local size = ACFLazers.GetFusionType(Data.FusionType)

    self.FusionType = size.id
    self.Name       = size.name -- the undo list uses Entity.Name

    self:SetNW2String("ACFFusionType", self.FusionType)
    self:ApplyScale(self.FusionType)

    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the model scale in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = ACFLazers.FusionNumber("FusionArmourAtOne") * ACFLazers.GetFusionType(self.FusionType).scale * ACF.ArmorMod
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

-- One pass of work. `dt` = seconds since the last pass.
function ENT:Run(now, dt)
    local draw   = self:GetDraw()
    local health = self:GetHealthFraction()
    local room, caps, limits, refusing = self:GetRoom()

    -- What it could make in this time (its size, its health, the Draw input), and no more than the capacitors can hold.
    local wantKJ   = ACFLazers.GetFusionRate(self.FusionType, health, draw) * dt
    local storedKJ = math.min(wantKJ, room)

    if storedKJ > 0 then
        local scalar = ACFLazers.FusionNumber("FusionHeatScalar")

        if scalar > 0 then Heat.Add(self, storedKJ * scalar) end

        local takes = ACFLazers.WaterFill(limits, storedKJ)

        for i, cap in ipairs(caps) do
            if takes[i] > 0 then cap:AddCharge(takes[i]) end
        end
    end

    -- The reading: kJ per second, smoothed.
    local alpha = 1 - math.exp(-dt / math.max(ACFLazers.FusionNumber("FusionPowerSmoothing"), 1e-6))

    self.EnergyRate = self.EnergyRate + (storedKJ / dt - self.EnergyRate) * alpha
    self.Efficiency = ACFLazers.GetGenEfficiency(health)
    self.Room       = room
    self.Refusing   = refusing

    self:UpdateStatus(draw, room)

    -- Wire outputs and hover text, a few times a second.
    if now >= self.NextOutput then
        self.NextOutput = now + ACFLazers.FusionNumber("FusionOutputInterval")
        self:UpdateWireOutputs()
        self:RefreshOverlay()
    end
end

-- kJ per second it could make now: its size, its health and the Draw input.
function ENT:GetMaxRate()
    return ACFLazers.GetFusionRate(self.FusionType, self:GetHealthFraction(), self:GetDraw())
end

-- The one-line state for the hover text.
function ENT:UpdateStatus(draw, room)
    if next(self.Caps) == nil then
        self.Status = "No capacitor linked (nothing to store the energy in)"
    elseif room <= 0 and self.Refusing > 0 then
        self.Status = "AllowCharge is off on the capacitors (nothing is made)"
    elseif room <= 0 then
        self.Status = "Capacitors full (nothing is made)"
    elseif draw <= 0 then
        self.Status = "Draw is 0 (nothing is made)"
    else
        self.Status = string.format("Making %.0f kJ/s", self.EnergyRate)
    end
end

-- ===================== WIRE + OVERLAY =====================

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local size = ACFLazers.GetFusionType(self.FusionType)
    local max  = self:GetMaxRate()

    WireLib.TriggerOutput(self, "Energy", self.EnergyRate)
    WireLib.TriggerOutput(self, "Rated", size.hp)
    WireLib.TriggerOutput(self, "MaxEnergy", max)
    WireLib.TriggerOutput(self, "Load", max > 0 and self.EnergyRate / max * 100 or 0)
    WireLib.TriggerOutput(self, "Full", (next(self.Caps) ~= nil and self.Room <= 0 and self.Refusing == 0) and 1 or 0)
    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", Heat.GetPctHot(self) * 100)
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    local size       = ACFLazers.GetFusionType(self.FusionType)
    local linkedCaps = 0

    for _ in pairs(self.Caps) do linkedCaps = linkedCaps + 1 end

    if linkedCaps > 0 and self.EnergyRate > 0 then
        State:AddSuccess(self.Status)
    elseif linkedCaps == 0 then
        State:AddWarning(self.Status)
    else
        State:AddLabel(self.Status)
    end

    State:AddKeyValue("Type", string.format("%s (%.0f kg, model scale %g)", size.name, size.mass, size.scale))
    State:AddKeyValue("Rated power", string.format("%g hp of a generator hub (%.0f kJ/s at full health)", size.hp, ACFLazers.GetFusionRate(size.id, 1, 1)))
    State:AddKeyValue("Making", string.format("%.0f kJ/s", self.EnergyRate))
    State:AddKeyValue("Health efficiency", string.format("%.0f%% (x%.2f energy)", self.Efficiency * 100, self.Efficiency))
    State:AddKeyValue("Draw input", string.format("%.0f%%", self:GetDraw() * 100))

    if ACFLazers.FusionNumber("FusionHeatScalar") > 0 then
        State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of HOT)", Heat.GetTempF(self), Heat.GetPctHot(self) * 100))
    end

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
    local signature = self.Status .. "|" .. self.FusionType .. "|" .. math.floor(self.EnergyRate / 10) .. "|" .. math.floor(self:GetDraw() * 100) .. "|" .. math.floor(self.Efficiency * 100) .. "|" .. math.floor(Heat.GetPctHot(self) * 20)

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

-- ===================== LINKING =====================
-- fusion engine <-> capacitor uses ACF's link system, like the generator <-> capacitor link does. The tools call  a:Link(b)  and  a:Unlink(b).
-- (A link made from either side works: ACF tries the registered pair in both orders.) The capacitor keeps the engine in its set of linked "generators" (its own file is not changed).

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

function ENT:OnRemove()
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

-- Dupe key: FusionType ("large" / "small"). A dupe with none, or an unknown one, is the default size.
Entities.Register("acf_fusion", MakeACFFusion, "FusionType")
