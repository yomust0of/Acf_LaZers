-- =========================================================================
-- ACF RADIATOR: SERVER FILE
-- Goes to:  lua/entities/acf_radiator/init.lua      (the server runs this one. The CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the 15.4 config (lua/autorun/acf_lazers_config.lua) AND lua/autorun/acf_lazers_heat.lua: it refuses to load without them. 15.6 ALSO NEEDS the HeatOutputInterval knob of the 15.5 config
--
-- 15.6 (search for [CHANGED 3]): THE HEAT READOUT HAS ITS OWN CLOCK, like the lazer's since 15.5. The wire outputs HeatKJ / HeatF / HeatPct used to be written at the end of every sweep (RadSweepInterval,
--   0.25 s). Now ONE more timer (every HeatOutputInterval, 0.1 s) writes them for every radiator that holds heat, and once more when it has cooled to room temperature (so the readout ends at 0);
--   a radiator at room temperature that already shows 0 costs one table lookup per interval. UpdateWireOutputs no longer writes them (one owner: HeatReadout). The hover text is unchanged.
-- 15.4 (search for [CHANGED 2]): NO MORE OVERCLOCK. The radiator takes out RadSapSmall .. RadSapBig kJ per second (times the strength its tank gives it) and never hurts itself from heat any
--   more; the Overclock wire input, the damage and the "over its limit" state are gone. The steam sounds FADE OUT when the flush ends (RadFlushFadeSeconds).
-- 15.3 ADDS THE COOLANT (search for [CHANGED 1]): a tank (1/8 of the bounding box, 108 litres at the default size), a Flush wire input that vents it as a coloured cloud of steam with a
--   hissing sound while taking heat out with it, and a restock from an ACF supply crate (the radiator registers itself in ACF's fuel tank list: Amount, Capacity, Consume).
--
-- NEW (15.2). THE RADIATOR (heat sink): takes heat out of the parts around it. All the cooling logic is HERE; the parts hold none.
--   * size: the tool slider is the WIDTH in units (config RadWidthMin..RadWidthMax). The model (RadModel, 42 x 42 x 30 at scale 1) is scaled by width / RadModelWidth. The width sets the
--     mass (RadMassMin..RadMassMax), the radius (RadRadiusSmall..Big), the sap rate (RadSapSmall..Big, in kJ per second) and the waste share (RadWasteSmall..Big)
--   * members: every entity with a physics object in the radiator's CONTRAPTION (ACF's own tracking, CFW) and inside its radius, except players, NPCs and radiators. The list is rebuilt
--     when CFW says the contraption changed (parts added / removed, merged, split), when the radiator is resized or linked, and every RadRefreshInterval seconds as a safety net
--   * work: ONE timer for all radiators (every RadSweepInterval seconds). Per sweep a radiator pool takes  rate x time  kJ out of the hot members, each giving in proportion to its
--     temperature above room temperature ^ RadWeightPower (a part never goes below room temperature; what it cannot give goes to the others)
--   * pools: radiators linked to each other (the link tools) are one pool: one combined member list (a part counts once) and the sum of the sap rates. Each keeps its own heat
--     and efficiency. A radiator on its own is a pool of one
--   * its own heat: it makes waste heat (RadWaste x the work it TRIES to do); its efficiency is 100% up to RadEffStartPct of HOT, falls in a straight line to RadEffFloorPct at 100% and stays
--     there above. It never damages itself. It cools by itself HeatCoolMultRad times as fast as a prop
--   * wire:  input  Flush (above 0 = vent the coolant; with RadFlushPool the whole pool vents)
--            outputs SapRate (kJ/s it really takes out), Attempted (kJ/s it tries to take out), Efficiency (percent), Members (parts in range), HotParts (hot parts in its pool),
--            Pool (radiators in its pool), Radius (units), HeatKJ, HeatF, HeatPct (percent of the HOT temperature), Coolant (litres), CoolantPct, Flushing (1 while it vents)
-- All numbers live in lua/autorun/acf_lazers_config.lua (everything starting with Rad...).
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Entities    = ACF.Classes.Entities

local CFG = ACFLazers and ACFLazers.Config

if not CFG then
    ErrorNoHalt("[acf_radiator] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

if not (ACFLazers.Heat and ACFLazers.Heat.Add and ACFLazers.GetHeatCapacity) then
    ErrorNoHalt("[acf_radiator] the heat system is missing: copy lua/autorun/acf_lazers_heat.lua and the 15.2 lua/autorun/acf_lazers_config.lua, then restart.\n")
    return
end

if not (ACFLazers.GetRadSap and ACFLazers.RadPoolStep and ACFLazers.WeightedFill and ACFLazers.GetRadCoolantCapacity and ACFLazers.GetHeatCoolRate) then
    ErrorNoHalt("[acf_radiator] lua/autorun/acf_lazers_config.lua is older than this file (it has no radiator or coolant knobs or helpers). Copy the config of the same batch (15.4), then restart.\n")
    return
end

local Heat = ACFLazers.Heat

-- [CHANGED 3] (15.6) The knob of the heat-readout timer. Without it the timer below could not be made; say so once, clearly.
if not tonumber(CFG.HeatOutputInterval) then
    ErrorNoHalt("[acf_radiator] the config has no HeatOutputInterval (15.5): paste the two lines of config_lines_15_5.txt into lua/autorun/acf_lazers_config.lua (next to HeatMaxDeltaTime), or copy the 15.5 config, then restart.\n")
    return
end

local VERSION = "15.6"
MsgN("[acf_radiator] init.lua version " .. VERSION .. " loaded")

-- How many radiators one player may own (GMod reads a server variable called sbox_max<name>; CreateConVar does nothing if it already exists).
CreateConVar("sbox_maxacf_radiators", tostring(CFG.RadMaxPerPlayer), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF radiators one player may spawn")

-- ===================== THE MANAGER =====================
-- Every radiator is in Rad.List (a weak set: a removed radiator drops out by itself). Rad.Groups = the pools (lists of radiators), rebuilt when a link changed (ACFLazers.LinkVersion)
-- or a radiator appeared / went. One timer runs the work of every pool.
ACFLazers.Rad = ACFLazers.Rad or {}

local Rad = ACFLazers.Rad

Rad.List         = Rad.List or setmetatable({}, { __mode = "k" })
Rad.Groups       = Rad.Groups or {}
Rad.GroupVersion = Rad.GroupVersion or -1
Rad.GroupsDirty  = true

local function ByIndex(a, b) return a:EntIndex() < b:EntIndex() end

-- The pools: connected sets of linked radiators, each in a fixed order (by entity index), so everything that depends on the order is repeatable.
function Rad.BuildGroups()
    local list = {}

    for radiator in pairs(Rad.List) do
        if IsValid(radiator) then list[#list + 1] = radiator end
    end

    table.sort(list, ByIndex)

    local seen, groups = {}, {}

    for _, radiator in ipairs(list) do
        if not seen[radiator] then
            local group, head = { radiator }, 1

            seen[radiator] = true

            while head <= #group do
                local current = group[head]

                head = head + 1

                for other in pairs(current.Links) do
                    if IsValid(other) and Rad.List[other] and not seen[other] then
                        seen[other]        = true
                        group[#group + 1] = other
                    end
                end
            end

            table.sort(group, ByIndex)

            groups[#groups + 1] = group
        end
    end

    Rad.Groups       = groups
    Rad.GroupVersion = ACFLazers.LinkVersion
    Rad.GroupsDirty  = false
end

-- The hot parts of a pool: every entity with a heat record that is a member of ANY radiator in it (a part counts once). Returns the entities, their weights, their limits (the kJ each
-- holds) and the total kJ. The heat store's registry is small (only parts that are warm), so this costs by the number of hot parts, not by the size of the contraption.
local function GatherHot(live)
    local hot, weights, limits, avail = {}, {}, {}, 0
    local power = CFG.RadWeightPower

    for ent in pairs(Heat.Registry) do
        if IsValid(ent) then
            local member = false

            for _, radiator in ipairs(live) do
                if radiator.Members[ent] then
                    member = true

                    break
                end
            end

            if member then
                local kJ = Heat.GetKJ(ent)

                if kJ > 0 then
                    local weight = (kJ / Heat.GetCapacity(ent)) ^ power -- temperature above room temperature, ^ RadWeightPower

                    if weight ~= weight or weight <= 0 then weight = 1e-9 end -- (a hot part always gets some weight, so it is never left out)

                    hot[#hot + 1]         = ent
                    weights[#weights + 1] = weight
                    limits[#limits + 1]   = kJ
                    avail                 = avail + kJ
                end
            end
        end
    end

    return hot, weights, limits, avail
end

-- One pool, one sweep. `dt` = seconds since the last sweep.
function Rad.RunGroup(group, now, dt)
    local live = {}

    for _, radiator in ipairs(group) do
        if IsValid(radiator) then
            if radiator.MembersDirty or now >= radiator.NextRefresh then radiator:RebuildMembers(now) end

            live[#live + 1] = radiator
        end
    end

    if #live == 0 then return end

    -- 0. [CHANGED 1] the coolant and the flush. Each radiator works at the strength its tank gives it at the START of the sweep; then the radiators that are told to flush (their own
    -- Flush input, or any Flush input in the pool with RadFlushPool) vent what they vent in this sweep. The litres that leave carry heat away (step 3b).
    local anyFlush = false

    if CFG.RadFlushPool then
        for _, radiator in ipairs(live) do
            if radiator.FlushWire then anyFlush = true; break end
        end
    end

    local ventKJ = 0

    for _, radiator in ipairs(live) do
        radiator.CoolantMult = ACFLazers.GetRadCoolantMult(radiator:GetFill())

        local drained = radiator:Vent(radiator.FlushWire or anyFlush, dt)

        radiator.VentRate = dt > 0 and drained / dt or 0
        ventKJ            = ventKJ + drained * CFG.RadFlushKJPerLiter -- (a knob below 0 makes ventKJ negative: the check below then takes no heat)
    end

    -- 1. what the pool could take, and what is there to take
    local hot, weights, limits, avail = GatherHot(live)
    local items = {}

    for i, radiator in ipairs(live) do
        local sap = ACFLazers.GetRadSap(radiator:GetWidth()) * radiator.CoolantMult -- [CHANGED 2] no overclock: the table's rate times the strength the tank gives

        radiator.NominalSap = sap
        radiator.Efficiency = ACFLazers.GetRadEfficiency(radiator:GetHeatPct())

        items[i] = { sap = sap, eff = radiator.Efficiency }
    end

    -- 2. the step: how much is removed, and how much work each radiator did
    local total, out = ACFLazers.RadPoolStep(items, avail, dt)

    -- 3. take it out of the hot parts (each gives by weight, never more than it holds)
    if total > 0 then
        local takes = ACFLazers.WeightedFill(weights, limits, total)

        for i, ent in ipairs(hot) do
            if takes[i] > 0 and IsValid(ent) then Heat.Add(ent, -takes[i]) end
        end
    end

    -- 3b. [CHANGED 1] the vented coolant takes heat with it: the same sharing by temperature, from what the parts hold NOW (after step 3), on top of the radiators' own rate
    local boiled = 0

    if ventKJ > 0 then
        local hot2, weights2, limits2, avail2 = GatherHot(live)

        if avail2 > 0 then
            local takes2 = ACFLazers.WeightedFill(weights2, limits2, ventKJ) -- (it never gives more than the parts hold)

            for i, ent in ipairs(hot2) do
                if takes2[i] > 0 and IsValid(ent) then
                    Heat.Add(ent, -takes2[i])

                    boiled = boiled + takes2[i]
                end
            end
        end
    end

    -- 4. the radiators: waste heat, readings, then each one's state / outputs / hover text
    for i, radiator in ipairs(live) do
        local step = out[i]

        if step.work > 0 then Heat.Add(radiator, step.work * ACFLazers.GetRadWaste(radiator:GetWidth())) end

        radiator.Attempted = dt > 0 and step.work / dt or 0
        radiator.SapRate   = dt > 0 and step.removed / dt or 0
        radiator.PoolSap   = dt > 0 and total / dt or 0
        radiator.PoolBoil  = dt > 0 and boiled / dt or 0
        radiator.PoolSize  = #live
        radiator.HotParts  = #hot
    end

    for _, radiator in ipairs(live) do radiator:Finish() end
end

function Rad.Sweep()
    local now = CurTime()
    local dt  = math.Clamp(now - (Rad.LastSweep or now), 0, math.max(CFG.RadMaxDeltaTime, 0.05))

    Rad.LastSweep = now

    if Rad.GroupsDirty or Rad.GroupVersion ~= ACFLazers.LinkVersion then Rad.BuildGroups() end

    for _, group in ipairs(Rad.Groups) do Rad.RunGroup(group, now, dt) end
end

timer.Create("ACFLazers_RadiatorSweep", math.max(CFG.RadSweepInterval, 0.05), 0, function() Rad.Sweep() end)

-- [CHANGED 3] (15.6) The heat READOUT of every radiator (the three heat wire outputs), on its own clock: one timer for all of them, like the sweep. The heat itself is exact whenever it is read
-- (the heat store settles lazily), so this only decides how often the outputs are refreshed. HeatOutputInterval is the lazer's knob too; at least 0.02 s so a 0 cannot flood the server.
function Rad.Readout()
    for radiator in pairs(Rad.List) do
        if IsValid(radiator) then radiator:HeatReadout() end
    end
end

timer.Create("ACFLazers_RadiatorReadout", math.max(tonumber(CFG.HeatOutputInterval) or 0.1, 0.02), 0, function() Rad.Readout() end)

-- ===================== CFW EVENTS =====================
-- [GUESS] the arguments: entityAdded / entityRemoved (contraption, entity), created / removed (contraption), merged (contraption, the one it was merged into), split (previous, new)
-- [SEEN in track_cost_sv.lua, entity_tracking_sv.lua, kill_tracking_sv.lua, acf_rack/init.lua:446-453]. Only the contraption is used: radiators in it rebuild their member list at the
-- next sweep. For the rare structural events every radiator rebuilds.
local function MarkContraption(contraption)
    for radiator in pairs(Rad.List) do
        if IsValid(radiator) then
            if not istable(contraption) or not radiator.HasContraption or radiator:GetMyContraption() == contraption then radiator.MembersDirty = true end
        end
    end
end

hook.Add("cfw.contraption.entityAdded", "ACFLazers_RadiatorMembers", function(contraption) MarkContraption(contraption) end)
hook.Add("cfw.contraption.entityRemoved", "ACFLazers_RadiatorMembers", function(contraption) MarkContraption(contraption) end)

for _, event in ipairs({ "created", "removed", "merged", "split" }) do
    hook.Add("cfw.contraption." .. event, "ACFLazers_RadiatorMembers", function() MarkContraption(nil) end)
end

-- ===================== WIRE =====================

function ENT:TriggerInput(name, value)
    if name == "Flush" then
        local v = tonumber(value) or 0 -- [CHANGED 1] anything above 0 vents the coolant (text counts as 0; NaN is not above 0)

        self.FlushWire = v > 0
    end

    self:UpdateOverlay()
end

-- ===================== SPAWN AND SIZE =====================

function ENT:Initialize()
    self.Width          = CFG.RadWidthDefault
    self.Links          = {}      -- the radiators linked to this one (a set)
    self.Members        = setmetatable({}, { __mode = "k" }) -- the parts it can cool (a set, rebuilt by RebuildMembers)
    self.MemberCount    = 0
    self.MembersDirty   = true
    self.NextRefresh    = 0
    self.HasContraption = false
    self.NominalSap     = 0       -- kJ/s it tries to take out (sap rate x the strength its tank gives it), as of the last sweep
    self.Attempted      = 0       -- kJ/s of work it really did in the last sweep (less than nominal when the parts around it are nearly cold)
    self.SapRate        = 0       -- kJ/s it really took out (the work x its efficiency)
    self.Efficiency     = 1
    self.PoolSap        = 0       -- kJ/s the whole pool took out
    self.PoolSize       = 1
    self.HotParts       = 0
    self.Status         = "Not set up yet"
    self.StatusKind     = "new"
    self.OverlaySig     = ""
    self.HeatShown      = true    -- [CHANGED 3] true until the readout has written the COLD state (the first refresh writes 0 kJ / 59 F / 0% for a radiator that was never hot)

    -- [CHANGED 1] the coolant tank. ApplyData sizes it (Capacity, litres) and fills it (Amount, litres). The names Amount / Capacity / GetUnitMass / Consume are the ones ACF's SUPPLY CRATE
    -- looks for in its list of fuel tanks (ACF.FuelTanks, entities/acf_supply/modules/supply.lua): being in that list is all it takes to be topped up by a supply crate.
    self.Capacity       = 0       -- litres a full tank holds
    self.Amount         = 0       -- litres in the tank now
    self.TankReady      = false   -- false until the first ApplyData has filled the tank (a resize after that keeps the level)
    self.FuelType       = "Coolant" -- (the supply crate only asks whether it is "Electric", for the sound it plays)
    self.FlushWire      = false   -- the Flush input is on
    self.Venting        = false   -- it is venting right now
    self.VentRate       = 0       -- litres per second it vented in the last sweep
    self.CoolantMult    = 1       -- how strong the tank lets it work (1 = full strength), as of the last sweep
    self.PoolBoil       = 0       -- kJ per second the pool's venting took out of the hot parts in the last sweep
    self.CoolantR, self.CoolantG, self.CoolantB = ACFLazers.ClampRadColor(nil, nil, nil)

    if ACF.FuelTanks then ACF.FuelTanks[self] = true end

    Rad.List[self]  = true
    Rad.GroupsDirty = true

    if WireLib then
        WireLib.CreateInputs(self, { "Flush" })
        WireLib.CreateOutputs(self, {
            "SapRate",    -- kJ per second it really takes out
            "Attempted",  -- kJ per second it tries to take out
            "Efficiency", -- percent
            "Members",    -- parts in range (in its contraption and inside its radius)
            "HotParts",   -- hot parts in its pool
            "Pool",       -- radiators in its pool
            "Radius",     -- units
            "HeatKJ",     -- kJ of heat above room temperature
            "HeatF",      -- temperature in Fahrenheit
            "HeatPct",    -- percent of the HOT temperature (100 = HOT; a radiator takes no damage from heat, [CHANGED 2] 15.4)
            "Coolant",    -- litres of coolant in the tank
            "CoolantPct", -- percent full
            "Flushing"    -- 1 while it is venting
        })
    end

    self:UpdateWireOutputs()
end

-- Clamp whatever the tool / a dupe / an update sends us (the server never trusts the client).
local function VerifyData(Data)
    Data.Width = ACFLazers.ClampRadWidth(Data.Width)

    Data.CoolantR, Data.CoolantG, Data.CoolantB = ACFLazers.ClampRadColor(Data.CoolantR, Data.CoolantG, Data.CoolantB) -- [CHANGED 1] the colour of the steam
end

-- Model, scale, ACF health and mass for a width. Same order the lazer, the capacitor and the generator use: scale first (that makes the physics object), then ACF.Activate, then the mass.
function ENT:ApplyScale(width)
    self:SetScaledModel(CFG.RadModel)
    self:SetScale(ACFLazers.GetRadScale(width))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetRadMass(width))
end

-- Apply a whole Data table {Width = units}. Used by spawn AND by update. Width is a plain field on purpose: the duplicator saves entity fields (see Entities.Register at the bottom).
function ENT:ApplyData(Data)
    if self.TankReady then -- an update that says nothing about the colour keeps the colour it has
        if Data.CoolantR == nil then Data.CoolantR = self.CoolantR end
        if Data.CoolantG == nil then Data.CoolantG = self.CoolantG end
        if Data.CoolantB == nil then Data.CoolantB = self.CoolantB end
    end

    VerifyData(Data)

    self.Width = Data.Width
    self.Name  = string.format("%d-unit Radiator", Data.Width) -- the undo list uses Entity.Name

    self.CoolantR, self.CoolantG, self.CoolantB = Data.CoolantR, Data.CoolantG, Data.CoolantB -- [CHANGED 1] plain fields: the duplicator saves them (see Entities.Register)

    self:SetNW2Int("ACFRadWidth", self.Width)
    self:SetNW2Int("ACFRadColor", ACFLazers.PackRadColor(self.CoolantR, self.CoolantG, self.CoolantB)) -- one number for the client: red * 65536 + green * 256 + blue
    self:ApplyScale(Data.Width)

    -- [CHANGED 1] the tank follows the size. A new radiator starts at RadCoolantStart; one that is resized keeps its level (its share of the tank).
    local level = self.TankReady and (self.Capacity > 0 and self.Amount / self.Capacity or 0) or ACFLazers.ClampNumber(CFG.RadCoolantStart, 1, 0, 1)

    self.Capacity  = ACFLazers.GetRadCoolantCapacity(Data.Width)
    self.Amount    = math.Clamp(level, 0, 1) * self.Capacity
    self.TankReady = true

    self.MembersDirty = true -- the radius changed

    self:UpdateWireOutputs()
end

-- Gun-style health and armour (acf_gun/init.lua:1344-1364), with the model scale in place of a caliber and the multipliers from the config.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = CFG.RadArmourAtOne * ACFLazers.GetRadScale(self.Width or CFG.RadWidthDefault) * ACF.ArmorMod
    local Health  = Area / ACF.Threshold * CFG.RadHealthMult
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

-- ===================== THE MEMBERS =====================

-- CFW's contraption this radiator is in (nil when it is not constrained to anything, or CFW is missing).
function ENT:GetMyContraption()
    if not self.CFW_GetContraption then return nil end

    return self:CFW_GetContraption()
end

-- Can this entity be cooled by a radiator? Anything with a physics object, except players, NPCs and radiators.
local function Eligible(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() or ent:IsNPC() then return false end
    if ent:GetClass() == "acf_radiator" then return false end

    return IsValid(ent:GetPhysicsObject())
end

-- Rebuild the list of parts this radiator can cool: its contraption's entities that are inside its radius. One squared-distance check per part.
function ENT:RebuildMembers(now)
    local members, count = setmetatable({}, { __mode = "k" }), 0
    local contraption    = self:GetMyContraption()

    if contraption and contraption.ents then
        local center  = self:WorldSpaceCenter()
        local radius  = ACFLazers.GetRadRadius(self:GetWidth())
        local radius2 = radius * radius

        for ent in pairs(contraption.ents) do
            if ent ~= self and Eligible(ent) and ent:WorldSpaceCenter():DistToSqr(center) <= radius2 then
                members[ent] = true
                count        = count + 1
            end
        end
    end

    self.Members        = members
    self.MemberCount    = count
    self.HasContraption = contraption ~= nil
    self.MembersDirty   = false
    self.NextRefresh    = now + CFG.RadRefreshInterval
end

-- ===================== THE COOLANT ===================== [CHANGED 1]
-- The tank holds Capacity litres (RadCoolantBoxFrac of the volume of the radiator's box). A full tank is full strength; the less is in it, the weaker the radiator works (config:
-- RadDryPct at empty, a straight line up to 100% at full). It is refilled by an ACF supply crate, which treats the radiator like a fuel tank. FLUSH (wire input) vents it as a cloud of steam
-- with a hiss, RadFlushFraction of a full tank every RadFlushSeconds, and every litre that leaves takes RadFlushKJPerLiter of heat out of the hot parts around it (Rad.RunGroup).

--- kg per litre: what the supply crate takes out of its own stock for each litre it puts in. Never 0 (the crate divides by it).
function ENT:GetUnitMass()
    return math.max(tonumber(CFG.RadCoolantUnitMass) or 1, 1e-6)
end

--- Sets the level (litres), kept between empty and full. NaN and text count as empty.
function ENT:SetAmount(amount)
    self.Amount = ACFLazers.ClampNumber(amount, 0, 0, self.Capacity or 0)
end

--- Takes litres out (a negative number puts litres in: this is how the supply crate fills it, exactly as for a fuel tank).
function ENT:Consume(amount)
    local n = tonumber(amount)

    if not n or n ~= n then return end -- (text and NaN change nothing: a bad number must not empty the tank)

    self:SetAmount(self.Amount - n)
end

--- How full the tank is, 0..1 (SetAmount keeps the level between empty and full). A radiator with no tank at all (RadCoolantBoxFrac 0) counts as full: the whole coolant system is switched off.
function ENT:GetFill()
    if (self.Capacity or 0) <= 0 then return 1 end

    return self.Amount / self.Capacity
end

-- A sound patch that starts at once at this volume and pitch (nil when there is no sound to play). [CHANGED 2] Both steam sounds are patches, so both can be faded out: a burst made with
-- EmitSound cannot be turned down, and the HL2 steam sound is several seconds long.
local function StartSound(ent, name, volume, pitch)
    if not (isstring(name) and name ~= "") then return nil end

    local snd = CreateSound(ent, name)

    if not snd then return nil end

    snd:SetSoundLevel(75)
    snd:PlayEx(volume, pitch)

    return snd
end

-- Fades a sound out over `seconds` and then stops it for good (FadeOut only turns the volume down over the time; the Stop after it makes sure nothing is left playing).
local function FadeOutSound(snd, seconds)
    if not snd then return end

    if seconds > 0 then
        snd:FadeOut(seconds)

        timer.Simple(seconds + 0.1, function() snd:Stop() end)
    else
        snd:Stop()
    end
end

--- Starts or stops the steam: the network flag the client draws the cloud from, the burst, and the hiss that goes on while it vents. When it stops both sounds fade out (RadFlushFadeSeconds).
function ENT:SetVenting(on)
    on = on and true or false

    if on == self.Venting then return end

    self.Venting = on
    self:SetNW2Bool("ACFRadVent", on)

    if on then
        local pitch  = math.floor(ACFLazers.GetRadFlushPitch(self:GetWidth()) + 0.5)
        local volume = ACFLazers.ClampNumber(CFG.RadFlushVolume, 0.9, 0, 1)

        self.VentBurst = StartSound(self, CFG.RadFlushStartSound, volume, pitch)
        self.VentSound = StartSound(self, CFG.RadFlushLoopSound, volume, pitch) -- (a new pair is made at every flush: the ones that are fading out are left to finish)
    else
        local fade = ACFLazers.ClampNumber(CFG.RadFlushFadeSeconds, 0.8, 0, 10)

        FadeOutSound(self.VentBurst, fade)
        FadeOutSound(self.VentSound, fade)

        self.VentBurst, self.VentSound = nil, nil
    end
end

--- One sweep of venting: `on` = flush, `dt` = seconds. Drains up to RadFlushFraction x capacity / RadFlushSeconds litres per second, never more than is left. Returns the litres that left.
function ENT:Vent(on, dt)
    local drained = 0

    if on and dt > 0 and self.Amount > 0 then
        drained = math.min(self.Amount, ACFLazers.GetRadFlushRate(self.Capacity) * dt)

        self:Consume(drained)
    end

    self:SetVenting(drained > 0)

    return drained
end

-- ===================== HEAT =====================
-- Heat is kept by lua/autorun/acf_lazers_heat.lua; the manager above puts the waste in. The radiator's 100% is the HOT temperature, like a plate's.

function ENT:GetHeatPct()
    return Heat.GetPctHot(self)
end

-- The end of a sweep for this radiator: the one-line state, the wire outputs and the hover text.
function ENT:Finish()
    self:UpdateStatus()
    self:UpdateWireOutputs()
    self:RefreshOverlay()
end

-- ===================== STATE, WIRE + OVERLAY =====================

-- The one-line state for the hover text, and a short key for it (the hover text only refreshes when something worth showing changed).
function ENT:UpdateStatus()
    if not self.CFW_GetContraption then
        self.StatusKind = "nocfw"
        self.Status     = "ACF's contraption tracking (CFW) was not found: nothing can be cooled"
    elseif not self.HasContraption then
        self.StatusKind = "free"
        self.Status     = "Not constrained to anything: it has no parts to cool"
    elseif self.Venting then
        self.StatusKind = "vent"
        self.Status     = string.format("FLUSHING: venting %.1f L/s of coolant, %.0f kJ/s of heat leaves with it", self.VentRate, self.PoolBoil)
    elseif self.Capacity > 0 and self.Amount <= 0 then
        self.StatusKind = "dry"
        self.Status     = string.format("OUT OF COOLANT: working at %.0f%% strength. A supply crate refills it", ACFLazers.GetRadCoolantMult(0) * 100)
    elseif self.MemberCount == 0 then
        self.StatusKind = "empty"
        self.Status     = string.format("No other part of its contraption is within %.0f units", ACFLazers.GetRadRadius(self:GetWidth()))
    elseif self.HotParts == 0 then
        self.StatusKind = "cold"
        self.Status     = string.format("Nothing in range is hot (%d parts in range)", self.MemberCount)
    elseif self.Efficiency < 0.999 then
        self.StatusKind = "hot"
        self.Status     = string.format("Cooling at %.0f%% efficiency (it is hot itself): %.0f kJ/s", self.Efficiency * 100, self.SapRate)
    else
        self.StatusKind = "work"
        self.Status     = string.format("Cooling: taking %.0f kJ/s out of %d hot parts", self.SapRate, self.HotParts)
    end
end

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "SapRate", self.SapRate)
    WireLib.TriggerOutput(self, "Attempted", self.Attempted)
    WireLib.TriggerOutput(self, "Efficiency", self.Efficiency * 100)
    WireLib.TriggerOutput(self, "Members", self.MemberCount)
    WireLib.TriggerOutput(self, "HotParts", self.HotParts)
    WireLib.TriggerOutput(self, "Pool", self.PoolSize)
    WireLib.TriggerOutput(self, "Radius", ACFLazers.GetRadRadius(self:GetWidth()))
    -- [CHANGED 3] (15.6) HeatKJ / HeatF / HeatPct are written by HeatReadout, on their own clock (they used to be written here, with every sweep)
    WireLib.TriggerOutput(self, "Coolant", self.Amount)
    WireLib.TriggerOutput(self, "CoolantPct", self:GetFill() * 100)
    WireLib.TriggerOutput(self, "Flushing", self.Venting and 1 or 0)
end

-- [CHANGED 3] (15.6) The three heat wire outputs: kJ above room temperature, degrees Fahrenheit, percent of the HOT temperature.
function ENT:UpdateHeatOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", self:GetHeatPct() * 100)
end

-- [CHANGED 3] (15.6) One refresh of the heat readout (Rad.Readout calls it every HeatOutputInterval): while the radiator holds heat, and once more after it has cooled to room temperature so
-- the readout ends at 0. A radiator at room temperature that already shows 0 costs one table lookup.
function ENT:HeatReadout()
    local hot = Heat.GetKJ(self) > 0

    if not (hot or self.HeatShown) then return end

    self.HeatShown = hot

    self:UpdateHeatOutputs()
end

-- The hover text (ACF's overlay system calls this; ENT:UpdateOverlay() asks it to refresh).
function ENT:ACF_UpdateOverlayState(State)
    if self.StatusKind == "dry" then
        State:AddError(self.Status)
    elseif self.StatusKind == "work" then
        State:AddSuccess(self.Status)
    elseif self.StatusKind == "hot" or self.StatusKind == "free" or self.StatusKind == "nocfw" or self.StatusKind == "empty" or self.StatusKind == "vent" then
        State:AddWarning(self.Status)
    else
        State:AddLabel(self.Status)
    end

    local width = self:GetWidth()

    State:AddKeyValue("Size", string.format("%d units wide (model scale %.2f), %d kg", width, ACFLazers.GetRadScale(width), ACFLazers.GetRadMass(width)))
    State:AddKeyValue("Radius", string.format("%.0f units, %d parts in range", ACFLazers.GetRadRadius(width), self.MemberCount))
    State:AddKeyValue("Sap rate", string.format("%.0f kJ/s with a full tank (%.0f kJ/s tried now)", ACFLazers.GetRadSap(width), self.NominalSap))
    State:AddKeyValue("Taking out", string.format("%.0f kJ/s (efficiency %.0f%%)", self.SapRate, self.Efficiency * 100))
    State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of HOT)", Heat.GetTempF(self), self:GetHeatPct() * 100))

    if self.Capacity > 0 then
        State:AddProgressBar("Coolant", math.Round(self.Amount, 1), math.Round(self.Capacity, 1), " L") -- [CHANGED 1]
    end

    if self.PoolSize > 1 then
        State:AddKeyValue("Pool", string.format("%d radiators, %.0f kJ/s together, %d hot parts", self.PoolSize, self.PoolSap, self.HotParts))
    end
end

-- Refresh the hover text, but only when something worth showing changed (ACF's overlay networks changes).
function ENT:RefreshOverlay()
    local signature = table.concat({
        self.StatusKind,
        math.floor(self:GetHeatPct() * 20),                                   -- the heat in steps of 5% of HOT
        math.floor(self.Efficiency * 20),
        math.floor(self.SapRate / math.max(self.NominalSap, 1) * 10),         -- the work as tenths of what it could do
        self.MemberCount,
        self.HotParts,
        self.PoolSize,
        math.floor(self:GetFill() * 20),                                      -- [CHANGED 1] the tank in steps of 5% (venting shows in StatusKind)
    }, "|")

    if signature ~= self.OverlaySig then
        self.OverlaySig = signature
        self:UpdateOverlay()
    end
end

-- ===================== LINKING =====================
-- radiator <-> radiator uses ACF's link system, like capacitor <-> capacitor. The tools call  a:Link(b)  and  a:Unlink(b). Linked radiators are one POOL (see the top of this file).

ACF.RegisterLinkSource("acf_radiator", "Links")

ACF.RegisterClassLink("acf_radiator", "acf_radiator", function(A, B)
    if A == B then return false, "A radiator cannot be linked to itself." end
    if A.Links[B] or B.Links[A] then return false, "These radiators are already linked." end

    A.Links[B] = true
    B.Links[A] = true

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Radiators linked into one pool."
end)

ACF.RegisterClassUnlink("acf_radiator", "acf_radiator", function(A, B)
    if not (A.Links[B] or B.Links[A]) then return false, "These radiators are not linked." end

    A.Links[B] = nil
    B.Links[A] = nil

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    A:UpdateOverlay(true)
    B:UpdateOverlay(true)

    return true, "Radiators unlinked."
end)

-- Breaks every link this radiator has. Returns how many it broke. (The link tools' reload uses it.)
function ENT:UnlinkAll()
    local count = 0

    for other in pairs(self.Links) do
        if IsValid(other) and ACF.PerformClassUnlink(self, other) then
            count = count + 1
        else
            self.Links[other] = nil
        end
    end

    return count
end

function ENT:OnRemove()
    -- Straight table clean-up instead of ACF.PerformClassUnlink: the entity is on its way out and we only need everybody to forget it.
    for other in pairs(self.Links) do
        if IsValid(other) and other.Links then other.Links[self] = nil end
    end

    Rad.List[self]  = nil
    Rad.GroupsDirty = true

    if ACF.FuelTanks then ACF.FuelTanks[self] = nil end -- [CHANGED 1] the supply crate forgets it

    for _, key in ipairs({ "VentBurst", "VentSound" }) do -- [CHANGED 2] a radiator that goes while it vents takes its sounds with it, at once
        if self[key] then
            self[key]:Stop()
            self[key] = nil
        end
    end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1
end

-- ===================== UPDATE, SPAWN, DUPES =====================

-- Click-to-update (Entities.Update calls this). Same shape as the generator's.
function ENT:Update(Data)
    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Radiator updated successfully!"
end

-- Duplicator: the linked radiators' ids are saved and linked again on paste (the same way the generator does it).
function ENT:PreEntityCopy()
    local links = {}

    for other in pairs(self.Links) do
        if IsValid(other) then links[#links + 1] = other:EntIndex() end
    end

    if #links > 0 then duplicator.StoreEntityModifier(self, "ACFRadLinks", links) end

    self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
    local mods = Ent.EntityMods

    if mods and mods.ACFRadLinks then
        for _, id in pairs(mods.ACFRadLinks) do
            local other = CreatedEntities[id]

            if IsValid(other) and other ~= self then self:Link(other) end
        end

        mods.ACFRadLinks = nil
    end

    self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

-- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
function MakeACFRadiator(ply, pos, angles, Data)
    if not istable(Data) then Data = {} end

    if IsValid(ply) and not ply:CheckLimit("acf_radiators") then return nil end

    -- The model is your buddy's. If it is missing the scalable base cannot build a physics mesh, so say so instead of failing with a pile of errors.
    if not util.IsValidModel(CFG.RadModel) then
        local msg = "[acf_radiator] the model " .. CFG.RadModel .. " is missing on this server (RadModel in acf_lazers_config.lua). Is it installed and is the file name spelled right?"

        ErrorNoHalt(msg .. "\n")

        if IsValid(ply) then ply:ChatPrint(msg) end

        return nil
    end

    local ent = ents.Create("acf_radiator")
    if not IsValid(ent) then return nil end

    -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
    ent.ACF = {}
    Contraption.SetModel(ent, CFG.RadModel)

    ent:SetPos(pos)
    ent:SetAngles(angles)

    ent:Spawn()
    ent:Activate()

    ent:ApplyData(Data)

    if IsValid(ply) then
        if ent.SetPlayer then ent:SetPlayer(ply) end
        if CPPI then ent:CPPISetOwner(ply) end
        ply:AddCount("acf_radiators", ent)
        ply:AddCleanup("acf_radiators", ent)
    end

    return ent
end

-- Dupe keys: Width, and (15.3) the three channels of the steam colour. A dupe from 15.2 has no colour: the default is used.
Entities.Register("acf_radiator", MakeACFRadiator, "Width", "CoolantR", "CoolantG", "CoolantB")
