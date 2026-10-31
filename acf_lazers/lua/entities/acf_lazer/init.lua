-- =========================================================================
-- ACF LAZER: SERVER FILE
-- Goes to:  lua/entities/acf_lazer/init.lua      (the server runs this one. The CLIENT file is cl_init.lua next to it: never put this file there)
--           NEEDS the new config (lua/autorun/acf_lazers_config.lua) AND the new file lua/autorun/acf_lazers_heat.lua: it refuses to load without them
--
-- CHANGES vs the init.lua you have now (version 14). Search this file for [CHANGED n].
--   1  The version line says 15.7
--   2  A LOAD-TIME CHECK for the heat system (ACFLazers.Heat, from acf_lazers_heat.lua). Missing = one clear console error and the lazer does not load
--   3  LAZER HEAT (new section). The lazer's own heat: GetHeatPct, GetHeatRate, HeatThink, TakeHeatDamage, HeatDeath.
--      New fields in Initialize (NextHeatCheck, LastHeatCheck) and three new wire outputs: HeatKJ, HeatF, HeatPct (percent of the lazer's limit)
--   4  THE SHOT HEATS THE LAZER: Think adds draw x scalar x dt of heat after every paid tick, and runs HeatThink
--   5  (15.3: GONE) There is no cooling mode and no lock-out any more: a lazer fires whenever it has power, however hot it is. Heat only hurts it (HeatThink / TakeHeatDamage: quadratic,
--      plus the TURBO damage past HeatTurboStartPct, both in ACFLazers.GetHeatDamagePct). Safeguards are the player's own, built on the wire outputs HeatPct / HeatF / HeatKJ
--   6  The hover text shows the temperature (Fahrenheit) and the percent of the limit, and says when the lazer is damaging itself
--   7  THE BEAM HEATS WHAT IT HITS, and a plate has to be HOT to be burned through. DamageProp adds heat to every prop ACF accepted the hit on; the burn-through test has one more
--      condition (HeatPenGate in the config). A destroyed plate still lets the beam through
--   8  (15.5) THE HEAT READOUT HAS ITS OWN CLOCK. The wire outputs HeatKJ / HeatF / HeatPct and the hover text used to be refreshed together with the energy read: every 0.25 s while Fire was held,
--      once a SECOND when the lazer was idle, and ACF buffers a hover text for 1 s on top. The heat itself was always exact; an idle lazer that was cooling just LOOKED slower than one with Fire
--      held on an empty pool. New: HeatReadout (called from Think) refreshes the three outputs and the hover text every HeatOutputInterval while the lazer holds heat (and once more when it
--      has cooled to room temperature); UpdateHeatOutputs writes them (UpdateWireOutputs does not any more: the readout has ONE owner); ENT.OverlayDelay = LazerOverlayDelay. NEEDS the 15.5 config (two knobs)
--   9  (15.6) FIX: a lazer that was never hot showed 0 on its HeatF output (the Wire default) instead of 59 F, because the readout flag started as "cold and already shown". It starts as "not yet shown"
--      now: the first readout writes the cold state (0 kJ, 59 F, 0%) once. Nothing else in this file changed.
--   10 (15.7) THE TWO READOUT KNOBS ARE OPTIONAL. 15.5 / 15.6 stopped this file at its first lines when HeatOutputInterval / LazerOverlayDelay were missing from the config, and a file that stops there
--      leaves an EMPTY SHELL of a class behind (no hover text, no wire outputs, stock size). Now a missing knob means 0.1 s / 0.25 s, and nothing about the readout can stop this file.
--   11 (15.7) THE PLAYER LIMIT: the server variable sbox_maxacf_lazers is created HERE, from LazerMaxPerPlayer (config; 40, also when the config has none), like the capacitor, generator and radiator
--      do. A separate file of yours used to create it (lua/autorun/server/acf_lazers_limits.lua, at 20): copy the 15.7 version of that file over it, or it creates the variable first and its 20 stays.
--   12 (16.1) AUTOMATIC FOCUS + SHARED SAFEZONE RULES. While it fires, the lazer moves its own focal length toward the distance of the first thing its beam hits (ENT:AutoFocus, called at the end of
--      FireLaserBeam), at LazerFocusSpeed units per second, always inside the focal limits of its size (ACFLazers.StepFocus). The tool's slider (and a dupe's value) is where it starts. And the
--      safezone helpers that used to be written out near the top of this file are the config's now (ACFLazers.IsEntityInSafezone / SafezoneFlags): the PPC uses the same ones. NEEDS the 16.1 config
-- =========================================================================

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")   -- ACF entities send shared.lua explicitly (see acf_gun/init.lua:10-11)
include("shared.lua")

local ACF         = ACF
local Contraption = ACF.Contraption
local Damage      = ACF.Damage
local Objects     = Damage.Objects
local Entities    = ACF.Classes.Entities

-- The old `local LASER_CONFIG = { ... }` block moved to lua/autorun/acf_lazers_config.lua.
-- Same variable name, so every LASER_CONFIG.Something below still reads naturally.
local LASER_CONFIG = ACFLazers and ACFLazers.Config

if not LASER_CONFIG then
    ErrorNoHalt("[acf_lazer] ACFLazers.Config is missing. Is lua/autorun/acf_lazers_config.lua installed?\n")
    return
end

-- This file needs the config of the SAME batch (ACFLazers.GetBeamMask is new in 14). With the old config every beam tick would throw; say it once, clearly.
if not ACFLazers.GetBeamMask then
    ErrorNoHalt("[acf_lazer] ACFLazers.GetBeamMask is missing: lua/autorun/acf_lazers_config.lua is older than this init.lua. Copy the new config as well.\n")
    return
end

-- [CHANGED 2] The heat system lives in lua/autorun/acf_lazers_heat.lua (a new file in this batch) with its maths in the config. Without them every beam tick would throw; say so once, clearly.
if not (ACFLazers.Heat and ACFLazers.Heat.Add and ACFLazers.GetHeatCapacity) then
    ErrorNoHalt("[acf_lazer] the heat system is missing: copy lua/autorun/acf_lazers_heat.lua (new) and the new lua/autorun/acf_lazers_config.lua, then restart.\n")
    return
end

-- [CHANGED 12] (16.1) The safezone rules and the auto-focus maths are in the config of this batch. Without them every beam tick would throw; say so once, clearly.
if not (ACFLazers.IsEntityInSafezone and ACFLazers.SafezoneFlags and ACFLazers.StepFocus and ACFLazers.AutoFocusOn) then
    ErrorNoHalt("[acf_lazer] the safezone / auto-focus helpers are missing: lua/autorun/acf_lazers_config.lua is older than this init.lua (16.1). Copy the new config as well, then restart.\n")
    return
end

local Heat = ACFLazers.Heat

-- [CHANGED 10] (15.7) The two knobs of the heat readout are OPTIONAL: a config without them (a 15.4 one) gets these. (15.5 / 15.6 returned from this file when they were missing, and a file that
-- stops at its first lines leaves an empty shell of a class behind. Nothing about the readout may stop this file.)
local READOUT_INTERVAL_DEFAULT = 0.1  -- seconds between heat-readout refreshes (config: HeatOutputInterval)
local OVERLAY_DELAY_DEFAULT    = 0.25 -- seconds, the hover-text buffer of this entity (config: LazerOverlayDelay)

ENT.OverlayDelay = math.max(tonumber(LASER_CONFIG.LazerOverlayDelay) or OVERLAY_DELAY_DEFAULT, 0) -- [CHANGED 8] ACF's hover-text buffer for this entity (ACF's own default is 1 s)

-- Which version of this file is running. It is printed to the server console when the file loads, and every notice below carries it.
local VERSION = "16.1" -- [CHANGED 1] [CHANGED 12]
MsgN("[acf_lazer] init.lua version " .. VERSION .. " loaded")

-- [CHANGED 11] (15.7) How many lazers one player may own: GMod reads a server variable called sbox_max<name> (the spawn function below asks ply:CheckLimit("acf_lazers")), and CreateConVar does
-- nothing if the variable already exists. The default is the config knob LazerMaxPerPlayer (40 when the config has none). In single player GMod never checks limits [SEEN wiki: Player:CheckLimit].
CreateConVar("sbox_maxacf_lazers", tostring(tonumber(LASER_CONFIG.LazerMaxPerPlayer) or 40), FCVAR_ARCHIVE + FCVAR_NOTIFY, "Maximum ACF lazers one player may spawn")
cleanup.Register("acf_lazers") -- (this line used to be in lua/autorun/server/acf_lazers_limits.lua)

-- Diagnosis switch, now a COMMAND. Admins (in their own console) and the server console type  acf_lazer_debug 1  and fire at a prop:
-- the lazer prints, once a second, what happened to it (which gate said no, what ACF's damage permission says, health before / after, whether the fire step ran)
-- to its owner's console. 0 = silent (the default); with no number the command flips it. (A console VARIABLE did not work here: on a dedicated server a player's
-- console cannot see a server-side variable, but it can run a command the server registered.)
local DebugOn = false

concommand.Add("acf_lazer_debug", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then
        ply:PrintMessage(HUD_PRINTCONSOLE, "[acf_lazer] only admins can switch the lazer debug mode\n")

        return
    end

    if args[1] == nil then
        DebugOn = not DebugOn
    else
        DebugOn = (args[1] == "1")
    end

    local msg = "[acf_lazer] debug mode is now " .. (DebugOn and "ON" or "OFF") .. "\n"

    if IsValid(ply) then
        ply:PrintMessage(HUD_PRINTCONSOLE, msg)
    else
        Msg(msg)
    end
end, nil, "1 = lazers tell their owner in the console what they do to props, 0 = off (admins only)")

-- [CHANGED 12] (16.1) The safezone rules (which flag names count, and THE BUG THE OLD LOCAL CODE FIXED: a flag that an addon defines as a METHOD is CALLED and its answer used, not taken as "yes" because the
-- name exists) moved to the config as ACFLazers.IsEntityInSafezone / SafezoneFlags, because the PPC needs the very same rules. Same names here, so every use below reads as before.
local IsEntityInSafezone = ACFLazers.IsEntityInSafezone
local SafezoneFlags      = ACFLazers.SafezoneFlags

-- A short name for a prop in a message: its class and the file name of its model.
local function Describe(ent)
    if not IsValid(ent) then return "?" end

    local model = tostring(ent:GetModel() or "?")

    return string.format("%s [%s]", ent:GetClass(), string.match(model, "([^/]+)$") or model)
end

-- Is this PERSON protected right now? Two things must be true: they are inside a safezone (IsEntityInSafezone, above) AND they have kept the
-- "Safezone protection" checkbox on in their own toolgun settings (client ConVar acf_lazer_tool_safezone; the tool's ConVars are sent to the server, which
-- is why the server can read it from the player). NPCs have no setting, so an NPC in a safezone always counts as protected.
-- [KNOW] Player:GetInfoNum(name, default) reads a ConVar the player's client sent to the server. [GUESS] works for tool ConVars (the tool already relies on it).
local function IsPersonProtected(target)
    if not IsEntityInSafezone(target) then return false end

    if target:IsPlayer() then
        return target:GetInfoNum("acf_lazer_tool_safezone", 1) >= 1
    end

    return true
end

-- NEW: multiplayer. By default GMod only sends an entity to players whose view area (the "PVS") touches it.
-- A lazer can be small and tucked behind a wall while its 10000-unit beam crosses the room you are standing in; with the
-- default, that beam would simply not exist for you. TRANSMIT_ALWAYS = "everyone always knows about this lazer".
-- [KNOW] UpdateTransmitState is the standard server-side hook for this. Switch it off with AlwaysTransmit = false in the config.
function ENT:UpdateTransmitState()
    return LASER_CONFIG.AlwaysTransmit and TRANSMIT_ALWAYS or TRANSMIT_PVS
end

-- Initialize does not set the model, scale or physics: the ACF scalable base does that when
-- ApplyCaliber() (below) calls SetScaledModel/SetScale (base_scalable/shared.lua:57-73).
function ENT:Initialize()
    self.MaxRange  = ACFLazers.GetEffectiveRange(LASER_CONFIG.CaliberBase) -- "effective range" (wire output MaxRange); ApplyCaliber sets the real values
    self.BeamRange = ACFLazers.GetBeamRange(LASER_CONFIG.CaliberBase)      -- how far the beam really reaches (damage is 0 there)
    self.Firing = false
    -- The burst timer state (BurstStart / RechargeUntil / Recharging) was here and is gone.
    -- WantFire = what the Fire input says right now. It can be on while the lazer cannot fire (no energy), see Think.
    self.WantFire      = false
    -- power state. Caps = the capacitors linked to this lazer (a set: key = capacitor). It is filled and emptied by the link functions at the bottom.
    self.Caps          = {}
    self.NoPower       = false -- true while Fire is wanted but the lazer cannot fire (not enough energy): a "dud"
    self.LastEnergy    = 0     -- the pool's energy at the last refresh (the "Energy" wire output)
    self.NextEnergyRead = 0    -- CurTime() of the next refresh (see RefreshPower)
    self.Pool          = {}    -- the capacitor group this lazer draws from (rebuilt when ACFLazers.LinkVersion changes)
    self.PoolVersion   = -1
    self.LastBeamTime = 0     -- replaces NextFire / FireInterval
    self.WobbleSeed   = math.Rand(0, 100) -- this lazer's own starting phase for the wobble, so two damaged lazers never drift in step
    self.NextHitEffect = 0    -- per-lazer cooldown so the spark / dust effects don't flood the network
    self.HeatDying     = false -- [CHANGED 3]
    self.NextHeatCheck = 0     -- [CHANGED 3] CurTime() of the next heat check (HeatThink)
    self.LastHeatCheck = CurTime() -- [CHANGED 3]
    self.NextHeatRead  = 0     -- [CHANGED 8] CurTime() of the next heat-readout refresh (HeatReadout)
    self.HeatShown     = true  -- [CHANGED 9] (15.6) true until the readout has written the COLD state: the first refresh writes 0 kJ / 59 F / 0% even for a lazer that was never hot (15.5 started it false, so HeatF stayed at the Wire default 0)
    -- end-of-beam sounds (see the BeamSounds block below). All start empty; they are created on demand.
    self.SoundEmitter  = nil  -- the invisible entity that carries the sounds to the beam end
    self.BurnSnd       = nil  -- CSoundPatch (the object CreateSound returns): the burn loop
    self.RumbleSnd     = nil  -- CSoundPatch: the earth rumble loop
    self.BurnOn        = false
    self.RumbleOn      = false

    local chosenSound = self:GetLaserSoundPath()
    if not chosenSound or chosenSound == "" then
        chosenSound = LASER_CONFIG.SoundFile
        self:SetLaserSoundPath(chosenSound)
    end

    self.LaserSound = CreateSound(self, chosenSound)

    if WireLib then
        WireLib.CreateInputs(self, { "Fire" })
        WireLib.CreateOutputs(self, {
            "IsFiring",
            "Caliber",
            "FocalLength",
            "MaxRange",
            "FocalRange",  -- the radius of the focused zone in units, worked out from the Focus amount and this lazer's size
            "FocusAmount", -- the Focus amount setting (0 = loosest ... 100 = sharpest)
            "FocalMult",   -- live readout: the damage multiplier where the beam ends right now (1 = normal max). Handy for testing the curve in E2.
            "DamageMult",  -- the same, but with the distance falloff multiplied in (focal curve x falloff) = what a hit at the beam's end really gets
            "PowerDraw",    -- kJ per second this lazer eats while firing
            "Energy",       -- kJ in the capacitor pool this lazer can draw from right now
            "NoPower",      -- 1 while Fire is on but the pool is too low to fire (a "dud")
            "Wobble",       -- the current wobble cone in MOA (0 = perfect aim); refreshed when the lazer starts / stops and while it fires
            "HeatKJ",       -- [CHANGED 3] kJ of heat above room temperature
            "HeatF",        -- [CHANGED 3] temperature in Fahrenheit
            "HeatPct"       -- [CHANGED 3] percent of the lazer's heat limit (100 = at the limit, above = damaging itself)
        })
    end

    self:UpdateWireOutputs()
end

-- NEW: clamp whatever the tool / a dupe / an update sends us into the allowed ranges.
-- This is the SERVER-side guard. The tool slider also reads the same limits, but a stale convar or a hand-edited
-- dupe could still send out-of-range numbers, so we never trust the client.
local function VerifyData(Data)
    Data.Caliber = math.Round(ACFLazers.ClampNumber(Data.Caliber, LASER_CONFIG.CaliberBase, LASER_CONFIG.CaliberMin, LASER_CONFIG.CaliberMax), 2)

    -- The longest focal length depends on the lazer's size (Data.Caliber was clamped just above). A missing Focus amount (an old dupe) = the default.
    -- The limits come from ACFLazers.GetFocalLimits (config): the tool's slider reads the very same function.
    local focalMin, focalMax = ACFLazers.GetFocalLimits(Data.Caliber)

    Data.Focal       = math.Round(ACFLazers.ClampNumber(Data.Focal, LASER_CONFIG.FocalDefault, focalMin, focalMax), 2)
    Data.FocusAmount = math.Round(ACFLazers.ClampNumber(Data.FocusAmount, LASER_CONFIG.FocusAmountDefault, LASER_CONFIG.FocusAmountMin, LASER_CONFIG.FocusAmountMax), 2)

    -- ColorSet is a 0/1 flag. Anything else (missing in an old dupe, junk from a console) becomes 0.
    Data.ColorSet = (tonumber(Data.ColorSet) or 0) >= 1 and 1 or 0

    -- Custom beam colour: a 0/1 switch and red / green / blue 0-255, whatever the tool or a hand-edited dupe sends. (no opacity: a CustomA in an old dupe is ignored)
    -- A missing value (an old dupe) becomes CustomColorDefault from the config.
    local default = LASER_CONFIG.CustomColorDefault

    Data.UseCustomColor = (tonumber(Data.UseCustomColor) or 0) >= 1 and 1 or 0
    Data.CustomR = math.Round(ACFLazers.ClampNumber(Data.CustomR, default[1], 0, 255))
    Data.CustomG = math.Round(ACFLazers.ClampNumber(Data.CustomG, default[2], 0, 255))
    Data.CustomB = math.Round(ACFLazers.ClampNumber(Data.CustomB, default[3], 0, 255))

    -- The burst length / recharge time checks were here and are gone (an old tool or dupe may still send them; they are ignored).
end

-- The single place that turns caliber (mm) into model size, mass and ACF health.
-- Order matters:
--   1. SetScaledModel + SetScale  -> creates the physics object at the right size
--   2. ACF.Activate               -> needs that physics object; calls ENT:ACF_Activate below
--   3. Contraption.SetMass        -> ACF stores the mass in self.ACF.Mass (and re-applies it if anything resets it)
-- Same order acf_gun uses: acf_gun/init.lua:359-360, 436, 443
-- Motion is NOT touched here any more: base_scalable freezes the physobj when it scales (base_scalable/init.lua:56-60),
-- and ACF.SaveEntity / ACF.RestoreEntity (used by ENT:Update below) put the old freeze state back after an update.
function ENT:ApplyCaliber(caliber)
    caliber = tonumber(caliber) or LASER_CONFIG.CaliberBase

    self:SetCaliberSize(caliber)

    self:SetScaledModel(LASER_CONFIG.DefaultModel)
    self:SetScale(ACFLazers.GetScale(caliber))

    ACF.Activate(self, true)
    Contraption.SetMass(self, ACFLazers.GetMass(caliber))

    -- ranges depend on the lazer's size (config: GetEffectiveRange / GetBeamRange)
    self.MaxRange  = ACFLazers.GetEffectiveRange(caliber)
    self.BeamRange = ACFLazers.GetBeamRange(caliber)

    self:UpdateWireOutputs()
end

-- NEW: apply a whole Data table {Caliber=, Focal=, FocusAmount=, ColorSet=, UseCustomColor=, CustomR=, CustomG=, CustomB=}. Used by spawn AND by update, so both behave the same.
-- self.Caliber / self.Focal are stored as plain fields on purpose: the duplicator saves entity fields, and
-- Entities.Register (bottom of this file) lists these names, so a paste can rebuild the lazer (same trick as acf_gun/init.lua:363-365).
function ENT:ApplyData(Data)
    VerifyData(Data)

    self.Caliber = Data.Caliber
    self.Focal   = Data.Focal
    self.FocusAmount = Data.FocusAmount -- plain field, saved by dupes; only the server needs it (CalculateFocalDamage)
    -- (the BurstTime / RechargeTime fields were here)
    self.ColorSet = Data.ColorSet -- plain field so the duplicator saves it (see Entities.Register at the bottom)
    self.Name    = string.format("%gmm Lazer", Data.Caliber) -- the undo list uses Entity.Name (registration.lua:1146)

    self:SetFocalLength(Data.Focal)
    self:SetColorSet(Data.ColorSet == 1) -- NetworkVar (shared.lua), so every client colours the beam the same way

    -- custom beam colour: plain fields (the duplicator saves them, see the names at the bottom) and NetworkVars (so every client draws the same colour)
    self.UseCustomColor = Data.UseCustomColor
    self.CustomR = Data.CustomR
    self.CustomG = Data.CustomG
    self.CustomB = Data.CustomB

    self:SetUseCustomColor(Data.UseCustomColor == 1)
    self:SetCustomColorRGB(Vector(Data.CustomR, Data.CustomG, Data.CustomB))
    self:ApplyCaliber(Data.Caliber)
    self:ScheduleWireUpdate()
end

-- How ACF works out this entity's health/armour. Gun-style numbers copied from acf_gun
-- (acf_gun/init.lua:1344-1364), with Caliber swapped for our NetworkVar and two multiplier knobs added.
function ENT:ACF_Activate(Recalc)
    local SelfACF = self.ACF
    local PhysObj = SelfACF.PhysObj

    local Area    = (PhysObj:GetSurfaceArea() or 0) * ACF.InchToCmSq
    local Armour  = self:GetCaliber() * ACF.ArmorMod * LASER_CONFIG.ArmourMult
    local Health  = Area / ACF.Threshold * LASER_CONFIG.HealthMult
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

function ENT:UpdateWireOutputs()
    if not WireLib then return end

    local focal = (self.GetFocalLength and self:GetFocalLength() > 0) and self:GetFocalLength() or LASER_CONFIG.FocalDefault

    WireLib.TriggerOutput(self, "IsFiring", self.Firing and 1 or 0)
    WireLib.TriggerOutput(self, "Caliber", self:GetCaliber())
    WireLib.TriggerOutput(self, "FocalLength", focal)
    WireLib.TriggerOutput(self, "MaxRange", self.MaxRange or ACFLazers.GetEffectiveRange(LASER_CONFIG.CaliberBase)) -- the effective range (damage is 3/5 there)
    WireLib.TriggerOutput(self, "FocalRange", ACFLazers.GetFocalRange(self:GetCaliber(), self.FocusAmount)) -- the radius in units
    WireLib.TriggerOutput(self, "FocusAmount", self.FocusAmount or LASER_CONFIG.FocusAmountDefault)
    WireLib.TriggerOutput(self, "FocalMult", self.Firing and (self.LastFocalMult or 0) or 0) -- reads 0 while the lazer is off
    WireLib.TriggerOutput(self, "DamageMult", self.Firing and (self.LastDamageMult or 0) or 0) -- same
    WireLib.TriggerOutput(self, "PowerDraw", ACFLazers.GetDrawRate(self:GetCaliber()))
    WireLib.TriggerOutput(self, "Energy", self.LastEnergy or 0)
    WireLib.TriggerOutput(self, "NoPower", self.NoPower and 1 or 0)
    -- [CHANGED 8] (15.5) the heat outputs HeatKJ / HeatF / HeatPct are written by HeatReadout, on their own clock (they used to be written here, with the energy read)

    self.LastWobbleMOA = ACFLazers.GetWobbleCone(self:GetCaliber(), self:GetHealthFraction()) * 60 -- degrees -> MOA
    WireLib.TriggerOutput(self, "Wobble", self.LastWobbleMOA)
end

-- NEW: refresh the wire outputs once on the next tick. Outputs set during spawn can be too early for
-- Wire to show them (they read 0 until you touch the wiring). One extra update a moment later is the fix you asked for.
-- [GUESS] that this is the cause. If outputs still read 0 after spawn, tell me and I'll look at Wire's own code instead.
function ENT:ScheduleWireUpdate()
    timer.Simple(0, function()
        if IsValid(self) then self:UpdateWireOutputs() end
    end)
end

function ENT:SetFiringState(state)
    if self.Firing == state then return end
    self.Firing = state
    if self.SetIsFiring then self:SetIsFiring(state) end

    if SERVER then
        if state then
            self.LastBeamTime = CurTime() -- first tick of a new burst measures from NOW, not from the last time it fired
            -- (the burst timer start was here)

            if self.LaserSound then
                -- Lerp(t, a, b) = "a when t is 0, b when t is 1, a straight line in between" [KNOW].
                -- t = 0 for the smallest lazer ... 1 for the biggest (ACFLazers.GetSizeFraction, config file).
                local size     = ACFLazers.GetSizeFraction(self:GetCaliber())
                local loudness = Lerp(size, LASER_CONFIG.MuzzleVolumeSmall, LASER_CONFIG.MuzzleVolumeBig)
                local pitch    = math.Clamp(Lerp(size, LASER_CONFIG.MuzzlePitchSmall, LASER_CONFIG.MuzzlePitchBig), 0, 255) -- the engine's pitch ends at 255

                -- The engine's volume stops at 1. Loudness above 1 becomes extra SOUND LEVEL instead: every doubling = MuzzleDbPerDoubling more decibels,
                -- which makes the hum carry farther. (Natural log divided by log 2 = "how many doublings", because Lua's math.log only has the natural one.)
                local doublings = loudness > 1 and math.log(loudness) / math.log(2) or 0

                self.LaserSound:SetSoundLevel(LASER_CONFIG.MuzzleSoundLevel + LASER_CONFIG.MuzzleDbPerDoubling * doublings) -- set BEFORE Play: [GUESS] it only applies to a sound that starts afterwards
                self.LaserSound:Play()
                self.LaserSound:ChangeVolume(math.min(loudness, 1), 0)
                self.LaserSound:ChangePitch(pitch, 0)
            end
        else
            -- The "burst just ended, maybe lock the lazer out" rule was here and is gone: energy decides now.

            if self.LaserSound then
                self.LaserSound:Stop()
            end

            -- beam is off: no sound at the end of it, and nothing for clients to draw
            self:StopBeamSounds()
            self:SetBeamHit(false)
            self:SetBeamLength(0)
        end
    end

    self:UpdateWireOutputs()
    self:UpdateOverlay() -- the hover text says Firing / Ready to fire / Cannot fire
end

-- =====================  LAZER HEAT  =====================
-- The lazer heats ITSELF while it fires (Think adds the heat it makes each tick). There is NO lock-out: it fires whenever it has the power, however hot it is. Above 100% of its limit
-- it damages itself (quadratic, plus the turbo damage past HeatTurboStartPct), and if that kills it, it may explode. Over HeatIgniteF it sets players that touch it on fire (the heat
-- file does that). The heat itself is kept by lua/autorun/acf_lazers_heat.lua; every number is in the config (everything starting with Heat...). [CHANGED 3]

-- How hot the lazer is as a fraction of its limit (HeatLazerCapF): 0 = room temperature, 1 = the limit, 2 = twice as far above room temperature as the limit.
function ENT:GetHeatPct()
    return Heat.GetPct(self, ACFLazers.GetHeatRiseLazer())
end

-- kJ of heat per second this lazer makes while it fires: its draw x the lazer scalar (HeatLazerSmall .. HeatLazerBig). Its beam heats props with the same rate (x HeatHitSmall .. HeatHitBig).
function ENT:GetHeatRate()
    return self:GetDrawRate() * ACFLazers.GetLazerHeatScalar(self:GetCaliber())
end

-- [CHANGED 8] (15.5) The three heat wire outputs: kJ above room temperature, degrees Fahrenheit, percent of the lazer's limit.
function ENT:UpdateHeatOutputs()
    if not WireLib then return end

    WireLib.TriggerOutput(self, "HeatKJ", Heat.GetKJ(self))
    WireLib.TriggerOutput(self, "HeatF", Heat.GetTempF(self))
    WireLib.TriggerOutput(self, "HeatPct", self:GetHeatPct() * 100)
end

-- [CHANGED 8] (15.5) The heat READOUT (the three outputs above and the hover text) has its OWN clock. Until 15.4 it was refreshed together with the energy reading, which runs every
-- LazerEnergyReadInterval (0.25 s) while Fire is held and only once a SECOND when the lazer is idle (and ACF buffers a hover text for another second): the real heat was the same in
-- every case (the heat store is exact), but an idle lazer that was cooling down, or being cooled by a radiator, LOOKED up to a second behind, and a lazer with Fire held on an empty pool
-- looked fresher. Now: every HeatOutputInterval while the lazer holds heat, and once more when it has cooled to room temperature (so the readout ends at 0). A lazer at room
-- temperature that already shows 0 costs one table lookup per interval and nothing else. Called from Think every tick.
function ENT:HeatReadout(now)
    if now < self.NextHeatRead then return end

    self.NextHeatRead = now + math.max(tonumber(LASER_CONFIG.HeatOutputInterval) or READOUT_INTERVAL_DEFAULT, 0) -- [CHANGED 10] a missing knob = 0.1 s

    local hot = Heat.GetKJ(self) > 0

    if not (hot or self.HeatShown) then return end

    self.HeatShown = hot

    self:UpdateHeatOutputs()
    self:UpdateOverlay()
end

-- Called from Think every tick; does its work every HeatCheckInterval seconds: the damage a lazer over its limit does to itself.
function ENT:HeatThink(now)
    if now < self.NextHeatCheck then return end

    local dt = math.Clamp(now - self.LastHeatCheck, 0, LASER_CONFIG.HeatMaxDeltaTime) -- the cap: a lag spike must not become one huge burst of damage

    self.LastHeatCheck = now
    self.NextHeatCheck = now + LASER_CONFIG.HeatCheckInterval

    local over = self:GetHeatPct() - 1

    if over > 0 then self:TakeHeatDamage(over, dt) end
end

-- `over` = how far above its limit it is (0.5 = at 150%). Damage per second = HeatLazerDamage percent of max health x over^2. It goes through ACF's own damage pipeline
-- (Heat.Hurt), so ACF's hooks and permission rules apply as for any hit. A lazer has no damage handler of its own, so the kill is carried out here (HeatDeath).
function ENT:TakeHeatDamage(over, dt)
    local acf = self.ACF

    if not (acf and acf.MaxHealth and acf.MaxHealth > 0) then return end

    local pctPerSecond = ACFLazers.GetHeatDamagePct(over, LASER_CONFIG.HeatLazerDamage)
    local HitRes       = Heat.Hurt(self, acf.MaxHealth * pctPerSecond / 100 * dt)

    if HitRes and HitRes.Kill then self:HeatDeath() end
end

-- Killed by its own heat. While FIRING, with the chance HeatExplodeChance, it explodes like a capacitor does: HeatExplodeKJMult x its draw (kJ) becomes HE filler (kJ / ACF.HEPower,
-- so not literal kilograms). Otherwise it simply dies, like a prop killed by a bullet.
function ENT:HeatDeath()
    if self.HeatDying then return end

    self.HeatDying = true

    local dmgInfo = Objects.DamageInfo(self:GetAttacker(), self)

    if self.Firing and math.random() < LASER_CONFIG.HeatExplodeChance then
        local filler   = ACFLazers.GetLazerExplosionFiller(self:GetCaliber())
        local position = self:LocalToWorld(self:OBBCenter())

        ACF.KillChildProps(self, position, filler)

        Damage.createExplosion(position, filler, filler * 0.5, { self }, dmgInfo)
        Damage.explosionEffect(position, nil, filler)

        constraint.RemoveAll(self)
        self:Remove()
    else
        ACF.APKill(self, VectorRand(), math.min(LASER_CONFIG.HeatDeathDebrisPower, LASER_CONFIG.MaxDebrisPower), dmgInfo)
    end
end

-- =====================  LAZER POWER  =====================
-- The lazer's energy lives in capacitors. A lazer is linked to one or more capacitors (self.Caps); capacitors can be linked to each other (their CapLinks), and a
-- lazer can draw from every capacitor connected to the ones it is linked to. That whole set is its "pool".

-- The list of capacitors this lazer can draw from. Rebuilt only when a link changed somewhere (ACFLazers.LinkVersion goes up), not every tick.
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

-- kJ per second this lazer eats while it fires (config GetDrawRate: from LazerDrawSmall at the smallest lazer to LazerDrawBig at the biggest, shaped by LazerDrawCurve).
function ENT:GetDrawRate()
    return ACFLazers.GetDrawRate(self:GetCaliber())
end

-- Can the lazer START (or restart after running dry) right now? Yes when the pool holds LazerStartSeconds of the lazer's draw, OR when the whole pool is at least
-- LazerStartFullFraction full (the override, so a lazer whose capacitors can never hold the start energy still fires). Always yes if RequireCapacitor is off.
function ENT:HasStartEnergy()
    if not LASER_CONFIG.RequireCapacitor then return true end

    local energy = self:GetPoolEnergy()

    if energy >= ACFLazers.GetStartEnergy(self:GetCaliber()) then return true end

    local fraction = LASER_CONFIG.LazerStartFullFraction or 0
    local capacity = self:GetPoolCapacity()

    return fraction > 0 and capacity > 0 and energy >= capacity * fraction
end

-- Pay `amount` kJ out of the pool, or pay nothing and return false if the pool holds less than that (the lazer is then a "dud").
-- The payment is split with ACFLazers.WaterFill (config file): every capacitor gives the same share; one that cannot give a full share gives all it has and the
-- others cover what it was short.
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
        if IsValid(cap) then cap.LastDrainTime = now end -- the WHOLE pool counts as drained, also a member that had nothing to give (see ENT:IsBeingDrained in the capacitor)
    end

    return true
end

-- Remind the owner in chat that a lazer with Fire held has NO capacitor linked (at most once per NoCapacitorNoticeInterval, 30 s). Nothing is said
-- when capacitors are linked but empty: the hover text already shows that (Cannot fire: needs N kJ), and the arming-up feel should not come with chat type-outs.
function ENT:ExplainNoPower()
    if not LASER_CONFIG.RequireCapacitor then return end
    if next(self.Caps) then return end
    if CurTime() < ((self.NoticeNext or {}).nopower or 0) then return end -- Notify would throttle it anyway; this just skips building the text every tick

    self:Notify("nopower", "This lazer has no capacitor linked, so it cannot fire. Link one with the capacitor tool (right-click the lazer, then right-click a capacitor).", LASER_CONFIG.NoCapacitorNoticeInterval)
    -- the "capacitors hold N kJ and it needs M kJ to start" chat line was here
end

-- Called every Think and whenever Fire changes. Keeps NoPower right, refreshes the Energy wire output and the hover text (every LazerEnergyReadInterval
-- seconds while the lazer is in use, once a second when idle; force = do it now).
function ENT:RefreshPower(force)
    local now     = CurTime()
    local noPower = (self.WantFire and not self.Firing) and true or false

    if noPower ~= self.NoPower then
        self.NoPower = noPower
        force        = true
    end

    if noPower then self:ExplainNoPower() end

    if not force and now < self.NextEnergyRead then return end

    self.NextEnergyRead = now + ((self.Firing or self.WantFire) and LASER_CONFIG.LazerEnergyReadInterval or 1)
    self.LastEnergy     = self:GetPoolEnergy()

    self:UpdateWireOutputs()
    self:UpdateOverlay()
end

-- What the Fire input says is remembered in WantFire. The lazer starts at once if its pool can pay for a start; if not it waits as a "dud" and Think (below)
-- starts it the moment the pool can. Letting go of Fire stops it.
function ENT:TriggerInput(iname, value)
    if iname == "Fire" then
        self.WantFire = value > 0

        if not self.WantFire then
            self:SetFiringState(false)
        elseif not self.Firing and self:HasStartEnergy() then
            self:SetFiringState(true)
        end

        self:RefreshPower(true)
    end
end

-- Think can never run faster than the server tick, so the old "FireInterval = 0.01 (100 Hz)" was never real,
-- and damage per second silently changed with the server's tickrate [KNOW, fairly sure].
-- Now: measure the real time since the last beam tick (dt) and let the damage scale with dt.
-- MaxDeltaTime stops a lag spike from turning into one giant hit.
function ENT:Think()
    local now = CurTime()

    if self.WantFire then
        if self.Firing then
            local dt = math.min(now - self.LastBeamTime, LASER_CONFIG.MaxDeltaTime)
            self.LastBeamTime = now

            if dt > 0 then
                -- Pay for this tick's bite (draw rate x dt) first. If the pool cannot, the lazer cuts out: a "dud" until the pool can start it again.
                if self:TakeEnergy(self:GetDrawRate() * dt) then
                    Heat.Add(self, self:GetHeatRate() * dt) -- [CHANGED 4] the paid bite also heats the lazer itself
                    self:FireLaserBeam(dt)
                else
                    self:SetFiringState(false)
                end
            end
        elseif self:HasStartEnergy() then
            self:SetFiringState(true) -- Fire is still held and the pool has recovered: carry on by itself
        end
    end

    self:HeatThink(now) -- [CHANGED 4]

    if not IsValid(self) then return end -- [CHANGED 4] its own heat can destroy it

    self:HeatReadout(now) -- [CHANGED 8]

    self:RefreshPower(false)

    self:NextThink(now) -- run again on the very next tick
    return true
end

-- The focal-length damage curve (the maths and the explanation live in the config: ACFLazers.GetFocalFactor).
-- Returns a multiplier on damage for a hit this many units from the muzzle; 1 = the normal max.
function ENT:CalculateFocalDamage(hitDistance)
    return ACFLazers.GetFocalFactor(
        self.Focal       or LASER_CONFIG.FocalDefault,
        self.FocusAmount or LASER_CONFIG.FocusAmountDefault, -- the Focus amount (the radius is worked out from it and the caliber)
        hitDistance,
        self:GetCaliber() -- the sharp-focus bonus depends on the lazer's size
    )
end

-- The multiplier on ALL damage for a hit this far from the muzzle: the focal curve (above) times the distance falloff
-- (config: ACFLazers.GetFalloff, 1.0 at the muzzle down to FalloffAtRange at the effective range and on to 0). Props AND people both get this.
function ENT:CalculateDamageMult(hitDistance)
    return self:CalculateFocalDamage(hitDistance) * ACFLazers.GetFalloff(hitDistance, self:GetCaliber())
end

-- How healthy is this lazer, 1 = full ... 0 = dead? ACF keeps current / max health in self.ACF (set in ENT:ACF_Activate, lowered by every hit).
-- If ACF hasn't set them up yet (a lazer that is still spawning) it counts as healthy.
function ENT:GetHealthFraction()
    local acf = self.ACF

    if not (acf and acf.Health and acf.MaxHealth and acf.MaxHealth > 0) then return 1 end

    return math.Clamp(acf.Health / acf.MaxHealth, 0, 1)
end

-- The damaged-lazer wobble. Called once per beam tick, BEFORE the beam is traced.
--   1. cone = how far off true aim the beam may be right now, in degrees (config: ACFLazers.GetWobbleCone; 0 while the lazer is healthy)
--   2. (u, v) = where inside that cone the aim is right now (config: ACFLazers.GetWobblePoint, a smooth wander that only depends on the time and our seed)
--   3. publish yaw / pitch as NetworkVars so the clients draw the very same direction (shared.lua: GetBeamDirection)
-- Returns the cone (degrees) so FireLaserBeam can update the wire readout.
function ENT:UpdateWobble()
    local cone         = ACFLazers.GetWobbleCone(self:GetCaliber(), self:GetHealthFraction())
    local yaw, pitch   = 0, 0

    if cone > 0 then
        local u, v = ACFLazers.GetWobblePoint(self.WobbleSeed or 0, CurTime())

        yaw, pitch = u * cone, v * cone
    end

    -- A NetworkVar only costs network traffic when its value changes. Changes under 0.001 degrees (about 0.2 units of error at 10000 units away)
    -- are invisible, so skip them; going back to exactly 0 is always sent, so a repaired lazer gets its perfect aim back.
    local curYaw, curPitch = self:GetBeamYaw(), self:GetBeamPitch()

    if yaw ~= curYaw and (yaw == 0 or math.abs(yaw - curYaw) > 0.001) then self:SetBeamYaw(yaw) end
    if pitch ~= curPitch and (pitch == 0 or math.abs(pitch - curPitch) > 0.001) then self:SetBeamPitch(pitch) end

    return cone
end

-- NEW: who gets the credit for the damage. Entities.Spawn stores the player in Entity.Owner
-- (acf/core/classes/entities/registration.lua:1142); falls back to the prop-protection owner, then to the lazer itself.
function ENT:GetAttacker()
    local owner = self.Owner

    if not IsValid(owner) and self.CPPIGetOwner then
        owner = self:CPPIGetOwner()
    end

    if IsValid(owner) then return owner end

    return self
end

-- =====================  END-OF-BEAM SOUNDS  =====================
-- Two looping sounds that sit at the spot the beam is burning and follow it:
--   BURN   plays whenever the beam is touching something (pitch gets lower as the lazer gets bigger)
--   RUMBLE plays only while that something is rock / dirt / sand ("ablative" layer)
-- Neither is tied to damage: they start when the beam starts touching a surface and stop when it stops.
--
-- WHY THE SERVER PLAYS THEM (you asked "server or client?")
--   A sound in GMod belongs to an ENTITY, and a loop that follows a moving point needs an entity standing on that point.
--   The server version is simplest and gives every player the same result: the engine handles distance fade and
--   who is in earshot. The cost is one invisible helper entity per FIRING lazer (it is removed when the beam stops).
--   The client-side alternative (each player creates their own sounds) saves that entity but needs a per-client entity
--   anyway, and each client would have to re-derive what the beam hits. I judged that worse for a multiplayer test.
-- [GUESS] this is the part most likely to need a tweak after your 2-player test. Tell me what you hear.

-- The invisible helper entity. Created the first time the beam hits something, moved to the beam end every tick.
function ENT:GetSoundEmitter()
    if IsValid(self.SoundEmitter) then return self.SoundEmitter end

    -- The old helper (if any) is gone (map cleanup?): the sounds attached to it are dead too, so forget them.
    if self.BurnSnd then self.BurnSnd:Stop() end
    if self.RumbleSnd then self.RumbleSnd:Stop() end
    self.BurnSnd, self.RumbleSnd = nil, nil
    self.BurnOn, self.RumbleOn = false, false

    local emitter = ents.Create("prop_dynamic") -- prop_dynamic is on ACF's ignore list (acf/core/globals.lua:232), so ACF never sees it
    if not IsValid(emitter) then return nil end

    emitter:SetModel(LASER_CONFIG.EmitterModel)
    emitter:SetPos(self:GetMuzzlePos())
    emitter:Spawn()
    -- Invisible by ZERO OPACITY, not SetNoDraw(true). [GUESS] GMod does not send no-draw entities to players; a sound attached to an
    -- entity the player has never been told about stays frozen where it started. That is the "rumble stuck in one spot" bug. This helper is
    -- still sent to players near it (just drawn with 0 opacity), so the engine can move the sounds along with it.
    emitter:SetRenderMode(RENDERMODE_TRANSCOLOR)
    emitter:SetColor(Color(255, 255, 255, 0))
    emitter:SetSolid(SOLID_NONE)     -- nothing can hit it or be blocked by it
    emitter:SetMoveType(MOVETYPE_NONE)
    emitter:DrawShadow(false)

    self:DeleteOnRemove(emitter)     -- [KNOW] if the lazer is removed, GMod removes the helper with it

    self.SoundEmitter = emitter

    return emitter
end

-- Silence both loops but KEEP the helper (used when the beam flies off into the sky for a moment: no point
-- deleting and re-creating an entity every time it sweeps past the horizon).
function ENT:SilenceBeamSounds()
    if self.BurnSnd then self.BurnSnd:Stop() end
    if self.RumbleSnd then self.RumbleSnd:Stop() end

    self.BurnOn   = false
    self.RumbleOn = false
end

-- Silence everything AND remove the helper. Called when the beam stops firing and when the lazer is removed.
function ENT:StopBeamSounds()
    self:SilenceBeamSounds()

    self.BurnSnd   = nil
    self.RumbleSnd = nil

    if IsValid(self.SoundEmitter) then
        self.SoundEmitter:Remove()
    end

    self.SoundEmitter = nil
end

-- Called once per beam tick from FireLaserBeam with where the beam ended.
-- hit = did it end on a surface; endPos = where; matType = what that surface is made of (MAT_* number).
function ENT:UpdateBeamSounds(hit, endPos, matType)
    if not hit then
        self:SilenceBeamSounds()
        return
    end

    local emitter = self:GetSoundEmitter()
    if not emitter then return end

    emitter:SetPos(endPos) -- the whole trick: the helper stands on the spot being burned

    local size = ACFLazers.GetSizeFraction(self:GetCaliber()) -- 0 = smallest lazer, 1 = biggest

    -- BURN: on whenever the beam touches anything. Bigger lazer = lower pitch (Lerp slides from the Small number to the Big number).
    if not self.BurnOn then
        if not self.BurnSnd then
            self.BurnSnd = CreateSound(emitter, LASER_CONFIG.BurnSound)
            self.BurnSnd:SetSoundLevel(LASER_CONFIG.BurnSoundLevel) -- [KNOW] must be set before Play
        end

        self.BurnSnd:PlayEx(LASER_CONFIG.BurnVolume, Lerp(size, LASER_CONFIG.BurnPitchSmall, LASER_CONFIG.BurnPitchBig))
        self.BurnOn = true
    end

    -- RUMBLE: only while the surface is rock / dirt / sand / ... and it stops again when the beam moves onto metal.
    local wantRumble = ACFLazers.GetSurfaceClass(matType) == "earth"

    if wantRumble and not self.RumbleOn then
        if not self.RumbleSnd then
            self.RumbleSnd = CreateSound(emitter, LASER_CONFIG.RumbleSound)
            self.RumbleSnd:SetSoundLevel(LASER_CONFIG.BurnSoundLevel)
        end

        self.RumbleSnd:PlayEx(LASER_CONFIG.RumbleVolume, Lerp(size, LASER_CONFIG.RumblePitchSmall, LASER_CONFIG.RumblePitchBig))
        self.RumbleOn = true
    elseif not wantRumble and self.RumbleOn then
        self.RumbleSnd:Stop()
        self.RumbleOn = false
    end
end

-- The surface normal for effects. Some hits report a zero normal (ACF's own code meets the same case:
-- acf/core/utilities/util_sh.lua:484); then "straight back at the beam" is a fine stand-in.
local function SurfaceNormal(tr, dir)
    if tr.HitNormal:IsZero() then return -dir end

    return tr.HitNormal
end

-- Ask every client to draw the sparks / dust at the end of the beam (client file: lua/effects/acf_lazer_hit.lua).
-- Payload (all fields the v2 effect already proved work):
--   Origin = where it hit      Normal = the SURFACE normal (stuff flies OUT of the surface)
--   Radius = caliber in mm     DamageType = surface material number (MAT_*)   Magnitude = intensity: 1 hit, 2 burned through, 3 destroyed
-- No decals, no sounds: the client effect draws particles only.
function ENT:SendHitEffect(pos, normal, matType, intensity)
    local data = EffectData()

    data:SetOrigin(pos)
    data:SetNormal(normal)
    data:SetRadius(self:GetCaliber())
    data:SetDamageType(matType or 0) -- [GUESS-ish] this field is just a whole number to the engine; we borrow it to carry the material
    data:SetMagnitude(intensity or 1)

    util.Effect("acf_lazer_hit", data, true, true) -- same two extra arguments ACF uses for its own server-side effects (ballistics_sv.lua:39)
end

-- Set something on fire for `seconds`. The beam hits the same target every tick, and restarting the fire that often would be
-- wasteful, so it only (re)lights it every half second. The fire still lasts `seconds` after the LAST time the beam touched it.
-- Print one debug line to the lazer's owner (their client console; works on a dedicated server too), or to the server console when the lazer has
-- no player owner. At most once a second per key, so the console doesn't flood. Does nothing unless acf_lazer_debug is 1.
function ENT:DebugSay(key, text)
    if not DebugOn then return end

    self.DebugNext = self.DebugNext or {}

    local now = CurTime()

    if now < (self.DebugNext[key] or 0) then return end

    self.DebugNext[key] = now + 1

    local line  = string.format("[acf_lazer %d] %s", self:EntIndex(), text)
    local owner = self:GetAttacker()

    if IsValid(owner) and owner:IsPlayer() then
        owner:PrintMessage(HUD_PRINTCONSOLE, line .. "\n")
    else
        MsgN(line)
    end
end

-- Tell the lazer's OWNER, in chat, why a prop is not being hurt. No console and no command needed. At most one message per reason per lazer
-- every NoticeInterval seconds (config), so it cannot flood. The server console keeps a copy. Switch it off with ShowProblemNotices = false (config).
function ENT:Notify(key, text, interval) -- optional third argument: seconds before this reason may be sent again (default NoticeInterval)
    if not LASER_CONFIG.ShowProblemNotices then return end

    self.NoticeNext = self.NoticeNext or {}

    local now = CurTime()

    if now < (self.NoticeNext[key] or 0) then return end

    self.NoticeNext[key] = now + (interval or LASER_CONFIG.NoticeInterval)

    local line  = string.format("[acf_lazer v%s #%d] %s", VERSION, self:EntIndex(), text)
    local owner = self:GetAttacker()

    if IsValid(owner) and owner:IsPlayer() then
        owner:ChatPrint(line)
    end

    MsgN(line)
end

-- When ACF took a hit and dealt NO damage, say who could have said no: ACF's own permission check, every hook on ACF_PreDamageEntity (other
-- addons add theirs there), and the prop's own ACF_PreDamage. Each part is read inside pcall.
function ENT:ExplainRefusal(target, DmgInfo)
    local parts = {}

    local permOk, permRes = pcall(ACF.Permissions.CanDamage, target, nil, DmgInfo)
    parts[#parts + 1] = "ACF's permission check " .. ((permOk and permRes == false) and "BLOCKS it" or "allows it")

    local names = {}
    local hookOk, hooks = pcall(function() return hook.GetTable().ACF_PreDamageEntity end)

    if hookOk and istable(hooks) then
        for name in pairs(hooks) do names[#names + 1] = tostring(name) end
    end

    table.sort(names)
    parts[#parts + 1] = "hooks that can veto damage (ACF_PreDamageEntity): " .. (#names > 0 and table.concat(names, ", ") or "none found")

    if target.ACF_PreDamage then
        parts[#parts + 1] = "the prop has its own ACF_PreDamage"
    end

    return table.concat(parts, " | ")
end

-- The full report on one prop hit (only called when acf_lazer_debug is 1). Everything is read inside a pcall so the report itself can never break the beam.
function ENT:ReportPropHit(target, tr, hpBefore, HitRes, DmgInfo, damageCallOk)
    pcall(function()
        local perm      = ACF.Permissions
        local modeName  = perm and table.KeyFromValue(perm.Modes, perm.DamagePermission) or "?"
        local attacker  = DmgInfo:GetAttacker()
        local _, canDmg = pcall(perm.CanDamage, target, nil, DmgInfo) -- ACF's own "may this attacker damage this prop?"; false = blocked, nil / true = allowed
        local inZoneEnt = perm.IsInSafezone and perm.IsInSafezone(target:GetPos())
        local inZoneAtt = perm.IsInSafezone and IsValid(attacker) and perm.IsInSafezone(attacker:GetPos())
        local acfData   = target.ACF or {}

        self:DebugSay("prop1", string.format("HIT %s model=%s matType=%s (MAT_WOOD=%s) flammable=%s explosive=%s onFireNow=%s",
            tostring(target), tostring(target:GetModel()), tostring(tr.MatType), tostring(MAT_WOOD),
            tostring(ACFLazers.IsFlammable(tr.MatType, target)), tostring(ACFLazers.IsExplosiveProp(target)), tostring(target:IsOnFire())))
        self:DebugSay("prop2", string.format("ACF health %s -> %s of %s | armour %s | damage call ran without error=%s | HitRes.Damage=%s Kill=%s",
            tostring(hpBefore and math.Round(hpBefore, 1)), tostring(acfData.Health and math.Round(acfData.Health, 1)), tostring(acfData.MaxHealth and math.Round(acfData.MaxHealth, 1)),
            tostring(acfData.Armour and math.Round(acfData.Armour, 1)), tostring(damageCallOk), tostring(HitRes and HitRes.Damage), tostring(HitRes and HitRes.Kill)))
        self:DebugSay("prop3", string.format("ACF permission mode=%s canDamage=%s | safezones on=%s zones loaded=%s targetInZone=%s attackerInZone=%s | prop owner=%s attacker=%s | our IsEntityInSafezone(prop)=%s",
            tostring(modeName), tostring(canDmg), tostring(ACF.EnableSafezones), tostring(perm.Safezones and true or false), tostring(inZoneEnt), tostring(inZoneAtt),
            tostring(target.CPPIGetOwner and target:CPPIGetOwner()), tostring(attacker), tostring(IsEntityInSafezone(target))))
        self:DebugSay("prop4", self:ExplainRefusal(target, DmgInfo) .. " | safezone flags: " .. SafezoneFlags(target))
    end)
end

local function IgniteThrottled(target, seconds)
    local now = CurTime()

    if (target.ACFLazers_NextIgnite or 0) > now then return end

    target.ACFLazers_NextIgnite = now + 0.5
    target:Ignite(seconds) -- [KNOW] Entity:Ignite(seconds)
end

-- Players / NPCs: direct damage per SECOND (dt slices it into per-tick pieces), plus the safezone rule,
-- disintegration and fire.
function ENT:DamagePerson(target, dt, focal, beam)
    local caliber = self:GetCaliber()

    -- Safezone rule: reduced damage, no fire. Decided by the PERSON being hit (IsPersonProtected, top of file): in a safezone AND their own checkbox is on.
    -- [GUESS] this relies on your safezone addon marking people the way IsEntityInSafezone (top of file) expects.
    local protected = IsPersonProtected(target)

    -- Damage per SECOND this lazer deals to a person right now. Measuring in seconds (not ticks) keeps it the same on any server tick rate.
    -- times beam.scale: a beam that already burned through a plate is weaker (see DamageProp) for whoever stands behind it.
    local dps = LASER_CONFIG.PersonDPSPerMM * caliber * focal * beam.scale * (protected and LASER_CONFIG.SafezoneDamageMult or 1)

    -- Mark them BEFORE the damage lands: if this very tick kills them, the death hooks (bottom of file) already know to disintegrate the body.
    -- The mark lasts half a second and is refreshed every tick the beam keeps hitting.
    -- Decided by the lazer's CALIBER (DisintegrateCaliber, config). [GUESS] like fire: only direct hits (not behind a pierced plate)
    -- and not for someone protected by a safezone. Say if you want either of those different.
    if caliber >= LASER_CONFIG.DisintegrateCaliber and not protected and not beam.penetrated then
        target.ACFLazers_DisintegrateUntil = CurTime() + 0.5
    end

    local dmgInfo = DamageInfo()

    dmgInfo:SetDamage(dps * dt)
    dmgInfo:SetAttacker(self:GetAttacker())
    dmgInfo:SetInflictor(self)
    dmgInfo:SetDamageType(DMG_GENERIC)

    target:TakeDamageInfo(dmgInfo)

    -- Fire: big enough lazers only, never inside a protected safezone, never on someone who just died.
    -- Burn time scale: PersonIgniteCaliber gives BurnTimeMin, CaliberMax gives BurnTimeMax, then times PersonBurnMult (all in the config).
    -- also: not when the beam already burned through a plate to get here (direct hits only).
    if not protected and not beam.penetrated and caliber >= LASER_CONFIG.PersonIgniteCaliber and IsValid(target) and target:Health() > 0 then
        IgniteThrottled(target, ACFLazers.GetBurnSeconds(caliber, LASER_CONFIG.PersonIgniteCaliber) * LASER_CONFIG.PersonBurnMult)
    end
end

-- Props and vehicles: build the same two objects an ACF bullet builds (Damage.getBulletDamage,
-- acf/damage/damage_sv.lua:79-102) and hand them to ACF's own Damage.dealDamage (damage_sv.lua:263).
-- ACF then handles armour, angle, health, prop dirtying and the kill; we only decide what the "hit" looks like.
-- Returns true if the beam should carry on through this entity (it was penetrated or destroyed).
function ENT:DamageProp(target, tr, dir, dt, focal, doEffects, beam)
    local caliber = self:GetCaliber()
    local armour  = target.ACF.Armour                -- ACF.Check() already ran, so this exists
    local hitAngle = ACF.GetHitAngle(tr, dir)        -- 0 = straight on, 90 = grazing (acf/core/utilities/util_sh.lua:480)

    -- Gentle angle. The angle we USE is the real one shrunk by AngleInfluence (0 = ignore, 1 = full).
    --   (a) ACF is told the shrunk angle, so thick plates get a little tougher when tilted.
    --   (b) The damage area is multiplied by cos(shrunk angle): the same beam smeared over a longer streak does less
    --       per spot. This part works even on thin plates, where ACF's own maths can't show any angle effect.
    local influence = math.Clamp(LASER_CONFIG.AngleInfluence, 0, 1)
    local angle     = hitAngle * influence
    local spread    = math.cos(math.rad(angle))

    -- Beam cross-section in cm^2: caliber is the diameter in mm, so the radius in cm is caliber / 20.
    -- Multiplying by dt is what makes the balance independent of the server tick rate.
    local beamArea = math.pi * (caliber / 20) ^ 2
    -- times beam.scale: 1 for a full-strength beam, less once it has burned through a plate (rule below). The angle effect
    -- (spread, above) uses THIS prop's own hit angle, so a weakened beam still gets the angle effect on whatever it lands on.
    local boost    = ACFLazers.GetSmallDamageBoost(caliber) -- small lazers hit props harder (config: SmallBoost*); 1 for big ones
    local area     = beamArea * LASER_CONFIG.HitsPerSecond * dt * focal * spread * beam.scale * boost
    local pen      = caliber * LASER_CONFIG.PenetrationPerMM -- depends ONLY on caliber, as you asked

    -- 5th argument (Factor) is not used by DamageResult:Compute (damage_result.lua:31-47); filled in the way ACF's bullets do.
    local DmgResult = Objects.DamageResult(area, pen, armour, angle, armour / (caliber * 0.1), 1)
    local DmgInfo   = Objects.DamageInfo(self:GetAttacker(), self, DMG_ENERGYBEAM, self:GetMuzzlePos(), tr.HitPos, tr.HitGroup)

    -- pcall = "call it, but if it errors give me the error instead of stopping". Hooks from OTHER addons run inside ACF's dealDamage; if one errors, the
    -- error used to abort this whole function (no fire, no sparks, no pass-through) while the player damage, which does not use ACF, still worked.
    -- [GUESS] that this is (part of) what you saw in multiplayer. Now the error is printed and we carry on with the rest.
    local hpBefore = target.ACF and target.ACF.Health
    local damageOk, HitRes = pcall(Damage.dealDamage, target, DmgResult, DmgInfo)

    if not damageOk then
        local err = tostring(HitRes)

        HitRes = DmgResult:GetBlank() -- same "nothing happened" result ACF itself returns when damage is refused

        if CurTime() >= (self.NextDamageErrorPrint or 0) then
            self.NextDamageErrorPrint = CurTime() + 5
            ErrorNoHalt("[acf_lazer] ACF's damage call failed: " .. err .. "\n")
        end

        self:DebugSay("error", "ACF damage call FAILED: " .. err)
        self:Notify("error", "ACF's damage call crashed on " .. Describe(target) .. ": " .. string.sub(err, 1, 200) .. " (usually another addon's damage hook). Details are in the server console.")
    end

    local killed = HitRes.Kill

    -- Did ACF really ACCEPT this hit? A refused hit (permission, safezone, another addon's hook) comes back as a blank result with 0 damage; a crash
    -- also counts as not accepted. Fire below needs this ("fire should only hit props that can be acf damaged"). At the very end of the beam the area is 0, so
    -- 0 damage is normal there and nothing is reported.
    local accepted = damageOk and (killed == true or (HitRes.Damage or 0) > 0)

    -- [CHANGED 7] A hit ACF accepted heats the prop: the lazer's heat rate x HeatHitSmall .. HeatHitBig, weakened exactly like the damage is (focus x falloff, angle, burn-through).
    -- (The small-lazer damage boost is NOT in it: that is a damage balance knob, not energy.)
    if accepted then
        Heat.Add(target, self:GetHeatRate() * ACFLazers.GetLazerHitHeatMult(caliber) * dt * focal * spread * beam.scale)
    end

    if damageOk and not accepted and area > 0 then
        self:Notify("refused", "ACF took the hit on " .. Describe(target) .. " but dealt it no damage, so there is no damage and no fire. " .. self:ExplainRefusal(target, DmgInfo))
    end

    -- dealDamage never kills by itself: the caller must (ACF's bullets do it at ballistics_sv.lua:398-399)
    if killed and IsValid(target) then
        local _, mass, speed = ACFLazers.GetFakeShell(caliber)
        local power = math.min(ACF.Kinetic(speed, mass).Kinetic, LASER_CONFIG.MaxDebrisPower)

        ACF.APKill(target, dir, power, DmgInfo)
    end

    -- Wooden props catch fire. tr.MatType is what the beam hit (ACFLazers.IsFlammable, config file, decides which materials burn).
    -- Burn time: BurnTimeMin at the smallest lazer up to BurnTimeMax at the biggest, a straight line in between (ACFLazers.GetBurnSeconds).
    -- Direct hits only: no fire on anything BEHIND a plate the beam burned through (beam.penetrated is set further down,
    -- so the plate being burned through still counts as a direct hit and can burn).
    -- IsFlammable also gets the prop now: explosive props (barrels, gas cans ...) burn like wood.
    local fireStep = accepted and not beam.penetrated and IsValid(target) and ACFLazers.IsFlammable(tr.MatType, target) -- accepted = ACF really damaged it

    if fireStep then
        IgniteThrottled(target, ACFLazers.GetBurnSeconds(caliber))

        -- The fire step ran but the prop is not burning: something else (a fire mod, an extinguisher script ...) is stopping Ignite. Say so.
        if IsValid(target) and not target:IsOnFire() then
            self:Notify("noflame", "The lazer tried to set " .. Describe(target) .. " on fire but it is not burning. Another addon is probably stopping Entity:Ignite (fire mods like vFire change how fire works).")
        end
    end

    if DebugOn then
        self:DebugSay("fire", string.format("fire step ran=%s (needs: ACF accepted the damage [accepted=%s], not behind a pierced plate [penetrated=%s], flammable surface or explosive prop) -> prop onFire=%s",
            tostring(fireStep), tostring(accepted), tostring(beam.penetrated), tostring(IsValid(target) and target:IsOnFire())))
        self:ReportPropHit(target, tr, hpBefore, HitRes, DmgInfo, damageOk)
    end

    -- DOES THE BEAM CARRY ON? (rule explained in the config, next to PenArmourFraction / PenDamageFraction / PenRampEnd)
    --   destroyed prop                  -> yes, nothing left to block it, and it does not use up the burn-through
    --   already burned through a plate  -> no: this prop survived, so it stops the beam (it still took the weakened damage above)
    --   otherwise                       -> only if this plate's armour NOW (ACF lowers it as health drops, damage_sv.lua:245) is below
    --                                      PenArmourFraction x caliber x the damage multiplier of this hit ("the line", ACFLazers.GetPassLine:
    --                                      it follows the damage, so it is smaller far away or off the focus). The plate itself took normal damage this tick; everything
    --                                      behind it takes a slice of the damage this plate took (at THIS plate's multiplier, beam.penMult): nothing when the armour is right on the line,
    --                                      the full PenDamageFraction once the armour is at PenRampEnd x the line or lower, a straight slide in between.
    -- [LATER] Burst lazers may want different numbers: make PenArmourFraction / PenDamageFraction depend on the lazer type here.
    local passes = false

    if killed then
        passes = true
    elseif not beam.penetrated and target.ACF and target.ACF.Armour then
        local threshold  = ACFLazers.GetPassLine(caliber, focal) -- "the line", in mm of armour. focal = this hit's damage multiplier (focal curve x falloff): the line follows the damage
        local armourNow  = target.ACF.Armour
        -- [CHANGED 7] One more condition: the plate must be HOT (HeatPenGate in the config; the heat of THIS tick's hit is already in). A cold plate stops the beam however thin it is.
        local hotEnough  = (not LASER_CONFIG.HeatPenGate) or Heat.IsHot(target)

        if armourNow < threshold and not hotEnough then
            self:DebugSay("cold", string.format("beam NOT burning through %s: armour %.1f mm is under the line (%.1f mm) but the plate is only at %.0f%% of HOT (%.0f F needed)",
                tostring(target), armourNow, threshold, Heat.GetPctHot(target) * 100, LASER_CONFIG.HeatHotF))
        end

        if armourNow < threshold and hotEnough then
            -- How far below the line, as a share of the whole slide (0 = right on the line, 1 = at or past PenRampEnd x the line).
            -- math.max(..., 0.001) only protects against a mistyped PenRampEnd of 1 or more (that would divide by zero).
            local slide      = threshold * math.max(1 - LASER_CONFIG.PenRampEnd, 0.001)
            local howFar     = math.Clamp((threshold - armourNow) / slide, 0, 1)

            passes           = true
            beam.penetrated  = true
            beam.scale       = LASER_CONFIG.PenDamageFraction * howFar
            beam.penMult     = focal -- remember the multiplier THIS plate took: everything behind it uses it (ProcessLaserImpact, where focal is worked out)
        end
    end

    if doEffects then
        -- 1 = beam is burning it, 2 = beam went through, 3 = it was destroyed. (Ricochet effect removed.)
        local intensity = killed and 3 or (passes and 2 or 1)

        self:SendHitEffect(tr.HitPos, SurfaceNormal(tr, dir), tr.MatType, intensity)
    end

    return passes
end

-- Replaces the old ProcessLaserImpact (fake .ACF table + armour stripping). Returns true if the beam passes through.
function ENT:ProcessLaserImpact(tr, dir, dt, doEffects, beam)
    local target = tr.Entity

    -- Safezones: props are protected (the beam stops on them). People still take damage everywhere (for funny moments),
    -- but DamagePerson makes it a fraction and blocks fire for people inside a safezone (switch: each person's own toolgun checkbox, see IsPersonProtected).
    local isPerson = target:IsPlayer() or target:IsNPC() or target:IsNextBot()
    if not isPerson and LASER_CONFIG.ProtectSafezoneProps and IsEntityInSafezone(target) then -- ProtectSafezoneProps = false (config) turns this protection off
        self:DebugSay("sz", "beam BLOCKED: our IsEntityInSafezone() says " .. tostring(target) .. " is in a safezone (props there are protected)")
        self:Notify("sz", Describe(target) .. " is treated as inside a safezone (the lazer's safezone check saw: " .. SafezoneFlags(target) .. "). Props there are protected: no damage, no fire, and the beam stops on it. If that is wrong for this prop, tell Claude the flag name above; to switch the protection off set ProtectSafezoneProps = false in acf_lazers_config.lua.")

        return false -- Block damage and block penetration on protected safezone props
    end

    local focal = self:CalculateDamageMult((tr.HitPos - self:GetMuzzlePos()):Length()) -- "focal" now means focal curve x distance falloff

    -- Behind a plate the beam burned through (beam.penetrated), everything takes the multiplier that plate took (beam.penMult, set in DamageProp)
    -- and the slice beam.scale of it, not the multiplier at its own, farther, distance. People get the same.
    if beam.penetrated and beam.penMult then
        focal = beam.penMult
    end

    if isPerson then
        self:DamagePerson(target, dt, focal, beam)
        return true -- the beam always passes through people / NPCs
    end

    -- ACF.Check (acf/core/validation_sv.lua:226) is ACF's own "can this be armoured / damaged?" test.
    -- It is false for things ACF ignores completely (holograms, E2, ragdolls, prop_dynamic... see ACF.GlobalFilter,
    -- acf/core/globals.lua:215). ACF's AP rounds fly straight through those, so the beam does too.
    -- (The old code BLOCKED the beam on anything that wasn't a prop or vehicle.)
    if not ACF.Check(target) then
        self:DebugSay("check", "ACF.Check is false for " .. tostring(target) .. ": the beam passes through it (no damage, no fire)")

        if string.StartWith(target:GetClass(), "prop_physics") then -- only for ordinary props; holograms, ragdolls etc. are ignored by ACF on purpose
            self:Notify("check", Describe(target) .. ": ACF does not treat it as damageable (ACF.Check is false), so the beam passes through it with no damage and no fire.")
        end

        return true
    end

    return self:DamageProp(target, tr, dir, dt, focal, doEffects, beam)
end

-- [CHANGED 12] (16.1) AUTOMATIC FOCUS. Moves the focal length toward `target` (the distance of the first thing the beam hit this tick; nil = nothing hit = stay) by at most LazerFocusSpeed x dt,
-- always inside the focal limits of this size (ACFLazers.StepFocus does the moving and the clamping). self.Focal is the plain field the damage curve reads and the duplicator saves; the NetworkVar
-- FocalLength is what the clients and the tool see; the wire output follows. Off (LazerAutoFocus = false) or a speed of 0: nothing moves.
function ENT:AutoFocus(dt, target)
    if not target or not ACFLazers.AutoFocusOn() then return end

    local old = self.Focal or LASER_CONFIG.FocalDefault
    local new = ACFLazers.StepFocus(old, target, dt, self:GetCaliber())

    if new == old then return end

    self.Focal = new
    self:SetFocalLength(new)

    if WireLib then WireLib.TriggerOutput(self, "FocalLength", new) end
end

-- Server-side trace loop. dt = seconds since the last beam tick (see Think).
-- It now also works out WHERE THE BEAM ENDED and publishes that (BeamLength / BeamHit, shared.lua), so every
-- client draws the same beam and the end-of-beam sounds know where to stand. Clients no longer trace anything themselves.
function ENT:FireLaserBeam(dt)
    local now       = CurTime()
    local startPos  = self:GetMuzzlePos()
    local cone      = self:UpdateWobble()       -- pick this tick's aim error first (it is published to clients too)...
    local dir       = self:GetBeamDirection()   -- ...then trace along it (shared.lua). Healthy lazer = exactly GetForward().
    local filter    = { self }
    local mask      = ACFLazers.GetBeamMask(self:GetCaliber()) -- ACF's own bullet mask for this caliber (config), decided once per tick
    local from      = startPos
    local remaining = self.BeamRange -- how far this lazer's beam really reaches (damage is 0 at the end)

    -- Effects (sparks / dust) are rate-limited per lazer. Damage still happens every tick.
    local doEffects = now >= self.NextHitEffect
    if doEffects then
        self.NextHitEffect = now + LASER_CONFIG.HitEffectInterval
    end

    -- Where the beam ended. Starts as "flew off to max range"; each stop below overwrites it.
    local endPos  = startPos + dir * remaining
    local endHit  = false -- true = it ended on a surface
    local endMat  = 0     -- material of that surface (MAT_* number)
    local ranOut  = true  -- only stays true if the loop used up all MaxBeamHits (a pathological beam)
    local focusDist = nil -- [CHANGED 12] distance from the muzzle to the FIRST thing the beam hit this tick (nil = it hit nothing): what the automatic focus aims for

    -- The beam's own state, shared by everything it hits this tick:
    --   scale      = its strength: 1 = full. After it burns through a plate this becomes a slice of PenDamageFraction (see DamageProp).
    --   penetrated = true once it has burned through a plate; the next plate that survives it will stop it.
    --   penMult    = the damage multiplier (focal curve x falloff) the burned-through plate took; everything behind it uses this one
    local beam = { scale = 1, penetrated = false, penMult = nil }

    for _ = 1, LASER_CONFIG.MaxBeamHits do
        if remaining <= 0 then
            ranOut = false
            break
        end

        -- ACF.trace (acf/core/utilities/traces_sh.lua:73) = util.TraceLine that also skips clipped-away parts of props.
        -- The mask is no longer MASK_SHOT: it is what an ACF bullet of this caliber uses (see the knob BeamMaskSmallBelowMM in the config).
        local tr = ACF.trace({
            start  = from,
            endpos = from + dir * remaining,
            filter = filter,
            mask   = mask
        })

        if not tr.Hit then
            ranOut = false
            break
        end

        if not focusDist then focusDist = startPos:Distance(tr.HitPos) end -- [CHANGED 12] only the first hit counts (a beam that burns through a plate keeps focusing on that plate)

        local target = tr.Entity

        if not tr.HitNonWorld or not IsValid(target) then
            -- The map stopped the beam
            endPos, endHit, endMat = tr.HitPos, true, tr.MatType
            ranOut = false

            if doEffects then self:SendHitEffect(tr.HitPos, SurfaceNormal(tr, dir), tr.MatType, 1) end
            break
        end

        -- Filter the entity BEFORE damaging it: if it dies, it is removed a moment later and we don't want to trace into it again.
        -- With it in the filter the next trace passes straight through it, so the old safeStart step loop is not needed.
        filter[#filter + 1] = target

        if not self:ProcessLaserImpact(tr, dir, dt, doEffects, beam) then
            -- blocked by a safezone or by armour the beam couldn't get through
            endPos, endHit, endMat = tr.HitPos, true, tr.MatType
            ranOut = false
            break
        end

        from      = tr.HitPos
        remaining = self.BeamRange - from:Distance(startPos)
    end

    if ranOut then
        endPos, endHit = from, true -- stopped trying after MaxBeamHits: treat the last surface as the end
    end

    -- publish the result. NetworkVars only send when the value changes, so a still beam costs nothing extra.
    self:SetBeamLength(startPos:Distance(endPos))
    self:SetBeamHit(endHit)
    self:UpdateBeamSounds(endHit, endPos, endMat)

    self:AutoFocus(dt, focusDist) -- [CHANGED 12] after this tick's damage, so the damage of a tick uses the focal length the tick STARTED with

    -- Wire readout of the focal damage multiplier where the beam ended. Only sent when it changed by a visible amount.
    if WireLib then
        local mult = self:CalculateFocalDamage(self:GetBeamLength())

        if math.abs(mult - (self.LastFocalMult or -1)) > 0.005 then
            self.LastFocalMult = mult
            WireLib.TriggerOutput(self, "FocalMult", mult)
        end

        -- and the total multiplier (focal curve x distance falloff) at the end of the beam
        local total = mult * ACFLazers.GetFalloff(self:GetBeamLength(), self:GetCaliber())

        if math.abs(total - (self.LastDamageMult or -1)) > 0.005 then
            self.LastDamageMult = total
            WireLib.TriggerOutput(self, "DamageMult", total)
        end

        -- same idea for the wobble readout: only when it moved by half an MOA or more
        local moa = cone * 60

        if math.abs(moa - (self.LastWobbleMOA or -1)) > 0.5 then
            self.LastWobbleMOA = moa
            WireLib.TriggerOutput(self, "Wobble", moa)
        end
    end
end

-- The hover text, built the way ACF's cannons build theirs (ACF_UpdateOverlayState is called by ACF's overlay system, which is also what calls it
-- when we call self:UpdateOverlay()). It replaces the old GetOverlayText that only said "ACF Lazer / Status".
function ENT:ACF_UpdateOverlayState(State)
    local caliber = self:GetCaliber()
    local needs   = LASER_CONFIG.RequireCapacitor

    if self.Firing then
        State:AddSuccess("Firing")
    elseif self:HasStartEnergy() then
        State:AddSuccess("Ready to fire")
    elseif not next(self.Caps) then
        State:AddError("Cannot fire: no capacitor linked")
    else
        local need     = ACFLazers.GetStartEnergy(caliber)
        local fraction = LASER_CONFIG.LazerStartFullFraction or 0

        if fraction > 0 and fraction <= 1 then
            State:AddError(string.format("Cannot fire: needs %.0f kJ in the capacitors to start, or the pool %.0f%% full", need, fraction * 100))
        else
            State:AddError(string.format("Cannot fire: needs %.0f kJ in the capacitors to start", need))
        end
    end

    State:AddKeyValue("Caliber", string.format("%g mm", caliber))

    -- [CHANGED 6] the heat, in Fahrenheit, and as a share of the lazer's limit
    local heatPct = self:GetHeatPct()

    State:AddKeyValue("Temperature", string.format("%.0f F (%.0f%% of its limit)", Heat.GetTempF(self), heatPct * 100))

    if heatPct > 1 then
        State:AddError("Overheated: taking damage")
    end

    if needs then
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
        State:AddKeyValue("Power draw", string.format("%.0f kJ/s", self:GetDrawRate()))
    else
        State:AddKeyValue("Power", "free (RequireCapacitor is off in the config)")
    end
end

function ENT:PhysgunPickup(ply) return true end
function ENT:OnPhysgunFreeze(weapon, phys, ent, ply) return true end
function ENT:CanTool(ply, trace, tool) return true end

function ENT:OnRemove()
    if self.LaserSound then
        self.LaserSound:Stop()
    end

    -- forget the capacitors, and make them forget us
    for cap in pairs(self.Caps or {}) do
        if IsValid(cap) and cap.Lazers then cap.Lazers[self] = nil end
    end

    ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

    self:StopBeamSounds()
end

-- NEW: click-to-update. Entities.Update (acf/core/classes/entities/registration.lua:1170) calls this.
-- Same shape as acf_gun/init.lua:541: refuse while busy, wrap the change in SaveEntity/RestoreEntity so welds and
-- the frozen state survive the rescale, and return true plus a message (or false plus a reason).
function ENT:Update(Data)
    if self.Firing then return false, "Stop firing before updating the lazer!" end

    ACF.SaveEntity(self)

    self:ApplyData(Data)

    ACF.RestoreEntity(self)

    return true, "Lazer updated successfully!"
end

if SERVER then
    -- Data is now a table {Caliber = mm, Focal = number}.
    -- Signature (Player, Pos, Angle, Data) is what Entities.Register wants (registration.lua:1007).
    -- A plain number in the 4th slot (the v1 call style: ply, pos, ang, caliber, focal) still works.
    function MakeACFLazer(ply, pos, angles, Data, focal)
        if not istable(Data) then
            Data = { Caliber = Data, Focal = focal }
        end

        if IsValid(ply) and not ply:CheckLimit("acf_lazers") then return nil end

        local ent = ents.Create("acf_lazer")
        if not IsValid(ent) then return nil end

        -- ACF wants this table and a model BEFORE Spawn (acf_gun/init.lua:482-488)
        ent.ACF = {}
        Contraption.SetModel(ent, LASER_CONFIG.DefaultModel)

        ent:SetPos(pos)
        ent:SetAngles(angles)

        -- Spawn the entity first so NetworkVars (SetupDataTables) initialize
        ent:Spawn()
        ent:Activate()

        -- Caliber, focal, size, mass, health: all through the same function Update uses
        ent:ApplyData(Data)

        if IsValid(ply) then
            if ent.SetPlayer then ent:SetPlayer(ply) end
            if CPPI then ent:CPPISetOwner(ply) end
            ply:AddCount("acf_lazers", ent)
            ply:AddCleanup("acf_lazers", ent)
        end

        return ent
    end

    -- Replaces duplicator.RegisterEntityClass("acf_lazer", MakeACFLazer, "Pos", "Ang", "CaliberSize", ...).
    -- The old argument names were NetworkVars, not entity fields, so the duplicator had nothing to save and a paste lost the caliber.
    -- "Caliber" and "Focal" are the plain fields ApplyData stores. ACF's Register builds the duplicator entry with the keys
    -- "Pos", "Angle", "Data" + our names (registration.lua:1025-1031). [KNOW, fairly sure] GMod's duplicator fills the special key
    -- "Data" with the whole saved entity table, which is how acf_gun gets its Caliber back on a paste.
    -- NOTE: if "Caliber" is ever renamed, old dupes will paste at the default size.
    -- Old dupes without a newer name paste with its default (ColorSet 0, default FocusAmount; an old FocalRange is ignored). Old dupes that still carry BurstTime / RechargeTime ignore them.
    -- The custom colour names (UseCustomColor, CustomR / G / B / A) are plain fields too; an old dupe without them pastes on the palettes.
    Entities.Register("acf_lazer", MakeACFLazer, "Caliber", "Focal", "FocusAmount", "ColorSet", "UseCustomColor", "CustomR", "CustomG", "CustomB")

    -- LINKING lazer <-> capacitor, through ACF's own link system (the same one guns and ammo crates use).
    -- The capacitor tool calls  lazer:Link(capacitor)  and  lazer:Unlink(capacitor);  ACF finds these two functions by the entity classes, in either order.
    -- RegisterLinkSource lets ACF's E2 / Starfall link functions and tools see the "Caps" set.
    ACF.RegisterLinkSource("acf_lazer", "Caps")

    ACF.RegisterClassLink("acf_lazer", "acf_capacitor", function(Lazer, Cap)
        if Lazer.Caps[Cap] then return false, "This lazer is already linked to this capacitor." end

        Lazer.Caps[Cap]   = true
        Cap.Lazers[Lazer] = true

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1 -- every lazer and capacitor rebuilds its group the next time it needs it

        Lazer:RefreshPower(true)
        Cap:UpdateOverlay(true)

        return true, "Lazer linked to the capacitor."
    end)

    ACF.RegisterClassUnlink("acf_lazer", "acf_capacitor", function(Lazer, Cap)
        if not (Lazer.Caps[Cap] or Cap.Lazers[Lazer]) then return false, "This lazer is not linked to this capacitor." end

        Lazer.Caps[Cap]   = nil
        Cap.Lazers[Lazer] = nil

        ACFLazers.LinkVersion = ACFLazers.LinkVersion + 1

        Lazer:RefreshPower(true)
        Cap:UpdateOverlay(true)

        return true, "Lazer unlinked from the capacitor."
    end)

    -- Breaks every link this lazer has. Returns how many it broke. (The capacitor tool's reload uses it.)
    function ENT:UnlinkAll()
        local count = 0

        for cap in pairs(self.Caps) do
            if ACF.PerformClassUnlink(self, cap) then count = count + 1 end
        end

        return count
    end

    -- Duplicator: the linked capacitors' ids are saved with the lazer and linked again when the dupe is pasted (same way acf_gun does it with its crates).
    function ENT:PreEntityCopy()
        if next(self.Caps) then
            local ids = {}

            for cap in pairs(self.Caps) do
                if IsValid(cap) then ids[#ids + 1] = cap:EntIndex() end
            end

            duplicator.StoreEntityModifier(self, "ACFLazerCaps", ids)
        end

        self.BaseClass.PreEntityCopy(self) -- wire's own dupe info
    end

    function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
        local mods = Ent.EntityMods

        if mods and mods.ACFLazerCaps then
            for _, id in pairs(mods.ACFLazerCaps) do
                local cap = CreatedEntities[id]

                if IsValid(cap) then self:Link(cap) end
            end

            mods.ACFLazerCaps = nil
        end

        self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
    end

    -- DISINTEGRATION. DamagePerson (above) puts a half-second mark on anyone the lazer is hitting hard enough.
    -- When a marked person dies, their body (ragdoll) is dissolved. Two hooks, because players and NPCs make their ragdolls differently:
    --   CreateEntityRagdoll  = "an NPC / entity just got a server ragdoll" (owner = who died)
    --   PlayerDeath          = a player died; their ragdoll exists a moment later
    -- [GUESS] one of the two covers each case; the other is harmless. Dissolving a body that is already dissolving does nothing.
    local function WasDisintegrated(ent)
        return IsValid(ent) and (ent.ACFLazers_DisintegrateUntil or 0) >= CurTime()
    end

    local function DissolveBody(ragdoll)
        if IsValid(ragdoll) then
            ragdoll:Dissolve(LASER_CONFIG.DisintegrateType) -- [KNOW] Entity:Dissolve(type)
        end
    end

    hook.Add("CreateEntityRagdoll", "ACFLazers_Disintegrate", function(owner, ragdoll)
        if WasDisintegrated(owner) then DissolveBody(ragdoll) end
    end)

    hook.Add("PlayerDeath", "ACFLazers_Disintegrate", function(victim)
        if not WasDisintegrated(victim) then return end

        timer.Simple(0, function()
            if IsValid(victim) then DissolveBody(victim:GetRagdollEntity()) end
        end)
    end)
end
