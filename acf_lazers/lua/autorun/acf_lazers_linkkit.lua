-- =========================================================================
-- NEW (12), fixed in 12.1 (AddCSLuaFile). Goes to:  lua/autorun/acf_lazers_linkkit.lua
-- 15.2: only the TEXTS changed (the messages and help lines now mention radiators); the code is the same. Which things the tools react to is the config's LinkClasses.
-- 16: only the TEXTS changed again (they name PPCs); the code is the same.
--
-- THE LINK KIT: the linking part of every tool of this addon, written ONCE. A tool file adds one line, after its own settings:
--
--     ACFLazers.LinkKit.Install(TOOL, "acf_lazer_tool", "Spawn a lazer with these settings, or update the one you are aiming at")
--
-- and that tool can then link things together, with the same controls everywhere:
--   Right-click          click a thing first (it turns green = selected), then click the thing to link everything green to
--   Shift + right-click  add one more thing to the selection (or take a selected thing off it). A plain right-click then links ALL green things to the thing you aim at
--   Reload               UNLINK. With things selected, aim at the one to unlink them from. With nothing selected, it breaks every link of the thing you aim at that THIS addon made
--   Right-click on nothing, or putting the tool away, clears the selection
-- WHAT can be linked is decided by ACF's own link system (a pair that has no link function is refused with "Links between these two entities are impossible"):
--     engine -> generator hub -> capacitor -> lazer      (also capacitor <-> capacitor, and radiator <-> radiator: linked radiators are one pool)
-- and WHICH things the tools react to at all is the list ACFLazers.Config.LinkClasses (class name -> the short word used in chat messages).
-- An engine only has its generator links broken by "break every link": the links ACF made (gearboxes, fuel) are never touched by these tools.
-- =========================================================================

-- 12.1: THIS LINE WAS MISSING. Files in lua/autorun are only sent to players if they say so; without it the server had the kit but the client did not, and every tool
-- that installs it stopped loading on the client with "acf_lazers_linkkit.lua is missing or did not load". (The config file has the same line.)
if SERVER then AddCSLuaFile() end

ACFLazers = ACFLazers or {}

local Config = ACFLazers.Config

assert(Config and Config.LinkClasses, "[acf_lazers_linkkit] lua/autorun/acf_lazers_config.lua is missing or does not have LinkClasses")

ACFLazers.LinkKit = ACFLazers.LinkKit or {}

local Kit   = ACFLazers.LinkKit
local Modes = Kit.Modes or {} -- every tool (mode name) that has the kit installed; the disconnect hook below goes through them

Kit.Modes = Modes

local Green = Color(0, 255, 0)  -- selected things are painted this green (unchanged from the capacitor tool of the earlier handoffs)

-- ===================== what is linkable =====================

-- Is `ent` something these tools link?
function Kit.IsLinkable(ent)
    if not IsValid(ent) then return false end

    return Config.LinkClasses[ent:GetClass()] ~= nil
end

-- "lazer #12" / "engine #34", for chat messages.
function Kit.Name(ent)
    local word = Config.LinkClasses[ent:GetClass()] or ent:GetClass()

    return word .. " #" .. ent:EntIndex()
end

-- Break every link `ent` has that this addon is responsible for. Returns how many it broke.
-- Lazers, capacitors and generators have an UnlinkAll of their own. An engine only lets go of the generators linked to it.
function Kit.UnlinkAll(ent)
    if ent.UnlinkAll then return ent:UnlinkAll() end

    local count = 0

    if ent.ACFGenerators then
        for gen in pairs(ent.ACFGenerators) do
            if IsValid(gen) and ACF.PerformClassUnlink(gen, ent) then count = count + 1 end
        end
    end

    return count
end

if CLIENT then
    -- The info lines and chat texts. `left` is that tool's own left-click line.
    function Kit.AddLanguage(mode, left)
        language.Add("tool." .. mode .. ".left", left)
        language.Add("tool." .. mode .. ".right", "Link: click an engine, generator, capacitor, lazer, PPC or radiator first (it turns green), then click what to link everything green to (engine > generator > capacitor > lazer or PPC; radiator <-> radiator)")
        language.Add("tool." .. mode .. ".right_shift", "(Hold Shift) Add another thing to the selection, or take a selected thing off it")
        language.Add("tool." .. mode .. ".reload", "Unlink: aim at the one to unlink the selected things from (nothing selected = break all links of what you aim at)")
        language.Add("tool." .. mode .. ".0", "Left-click: " .. left .. ".  Right-click: select / link.  Shift + right-click: select more.  Reload: unlink.")
    end
end

if not SERVER then
    -- the client only needs the info lines
    function Kit.Install(TOOL, mode, left)
        TOOL.Information = {
            { name = "left" },
            { name = "right" },
            { name = "right_shift" },
            { name = "reload" },
        }

        Kit.AddLanguage(mode, left)

        -- the server does the work; returning true here is what makes the tool gun play its animation and sound for the player
        function TOOL:RightClick() return true end
        function TOOL:Reload() return true end
        function TOOL:Holster() end -- ACF's own tool defines Holster in both realms too (acf/menu/tool_functions.lua:410)
    end

    return
end

-- ===================== SERVER =====================

-- Prop protection: if a prop-protection addon (CPPI) is installed, respect it.
local function MayTouch(tool, ply, ent)
    if ent.CPPICanTool and not ent:CPPICanTool(ply, tool.Mode) then return false end

    return true
end

local function Say(ply, kind, text)
    ACF.Utilities.Messages.SendChat(ply, kind, text)
end

-- ===================== selection (the way ACF's own link tool does it) =====================
-- Everything you have selected is painted green; each thing gets its own colour back when it leaves the selection. Nothing else is ever recoloured.
-- The selection can hold SEVERAL things. Two players may select the same thing (and two tools of this addon share this table), so the colour it had is remembered
-- ONCE, with a count of how many selections hold it; it is restored when the last one lets go.
local Highlighted = Kit.Highlighted or {} -- entity -> { color = its own colour, holders = how many selections have it }

Kit.Highlighted = Highlighted

local CallOnRemoveKey = "ACF_LazersLinkKit"

local function Paint(ent)
    local entry = Highlighted[ent]

    if entry then
        entry.holders = entry.holders + 1

        return
    end

    Highlighted[ent] = { color = ent:GetColor(), holders = 1 }

    -- if the entity is removed while selected there is nothing to restore; just forget it
    ent:CallOnRemove(CallOnRemoveKey, function(removed) Highlighted[removed] = nil end)
    ent:SetColor(Green)
end

local function Unpaint(ent)
    local entry = Highlighted[ent]

    if not entry then return end

    entry.holders = entry.holders - 1

    if entry.holders > 0 then return end

    Highlighted[ent] = nil

    ent:RemoveCallOnRemove(CallOnRemoveKey)
    ent:SetColor(entry.color)
end

-- This tool's selection: a list in click order (tool.Selection). Things removed from the world since are dropped here (their colour needs no restoring).
local function Selected(tool)
    local list = tool.Selection

    if not list then
        list           = {}
        tool.Selection = list
    end

    for i = #list, 1, -1 do
        if not IsValid(list[i]) then table.remove(list, i) end
    end

    return list
end

local function IndexOf(list, ent)
    for i, other in ipairs(list) do
        if other == ent then return i end
    end
end

-- Add `ent` to the selection and paint it green.
local function Select(tool, ent)
    local list = Selected(tool)

    if IndexOf(list, ent) then return end

    list[#list + 1] = ent

    Paint(ent)
end

-- Take `ent` off the selection and give it its colour back.
local function Unselect(tool, ent)
    local list  = Selected(tool)
    local index = IndexOf(list, ent)

    if not index then return end

    table.remove(list, index)

    Unpaint(ent)
end

-- End the whole selection: everything gets its colour back. Safe to call with nothing selected.
local function UnselectAll(tool)
    local list = Selected(tool)

    for i = #list, 1, -1 do
        local ent = list[i]

        list[i] = nil

        Unpaint(ent)
    end
end

Kit.Select      = Select
Kit.Unselect    = Unselect
Kit.UnselectAll = UnselectAll
Kit.Selected    = Selected

-- Link (or, with `unlink`, unlink) every thing in `sources` to/from `target`, and tell the player how it went. ACF's own link system decides what may be linked
-- to what and gives the message. Returns true if at least one of them worked.
local function LinkAll(ply, sources, target, unlink)
    local function act(source)
        if unlink then return source:Unlink(target) end

        return source:Link(target)
    end

    if #sources == 1 then
        local source = sources[1]
        local ok, message = act(source)

        if unlink then
            Say(ply, ok and "Info" or "Error", tostring(message or (ok and "Unlinked." or "Could not unlink those.")))
        else
            Say(ply, ok and "Info" or "Error", (ok and (Kit.Name(source) .. " <-> " .. Kit.Name(target) .. ": ") or "") .. tostring(message or (ok and "Linked." or "Could not link those.")))
        end

        return ok
    end

    local done, failed = 0, {}

    for _, source in ipairs(sources) do
        local ok, message = act(source)

        if ok then
            done = done + 1
        else
            failed[#failed + 1] = Kit.Name(source) .. ": " .. tostring(message or "no reason given")
        end
    end

    Say(ply, done > 0 and "Info" or "Error", string.format("%s %d of %d %s %s.", unlink and "Unlinked" or "Linked", done, #sources, unlink and "from" or "to", Kit.Name(target)))

    for i = 1, math.min(#failed, 5) do Say(ply, "Error", failed[i]) end

    if #failed > 5 then Say(ply, "Error", string.format("... and %d more that failed.", #failed - 5)) end

    return done > 0
end

Kit.LinkAll = LinkAll

-- A player who leaves with things selected must not leave them green forever.
hook.Add("PlayerDisconnected", "ACF_LazersLinkKit_ClearSelection", function(ply)
    for mode in pairs(Modes) do
        local ok, tool = pcall(ply.GetTool, ply, mode)

        if ok and tool then UnselectAll(tool) end
    end
end)

-- ===================== the install =====================

-- Adds RightClick, Reload and Holster to a tool table, and its info lines. The tool keeps its own LeftClick, settings and panel.
-- `left` = the one-line text of that tool's left click (for the info lines at the bottom-left of the screen).
function Kit.Install(TOOL, mode, left)
    Modes[mode] = true

    TOOL.Information = {
        { name = "left" },
        { name = "right" },
        { name = "right_shift" },
        { name = "reload" },
    }

    -- right-click: select / link.
    --   nothing selected yet, or Shift held  ->  this click changes the SELECTION (adds the thing, or takes it off if it was selected)
    --   otherwise                            ->  this click is the TARGET: everything selected is linked to it (the target itself, if it was selected, is skipped)
    function TOOL:RightClick(trace)
        local ply = self:GetOwner()
        local hit = trace.Entity

        if not Kit.IsLinkable(hit) then
            UnselectAll(self)

            Say(ply, "Info", "Link: selection cleared. Aim at an engine, a generator, a capacitor, a lazer, a PPC or a radiator.")

            return false
        end

        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to link that.")

            return false
        end

        local list = Selected(self)

        if #list == 0 or ply:KeyDown(IN_SPEED) then
            if IndexOf(list, hit) then
                Unselect(self, hit)

                Say(ply, "Info", string.format("Took %s off the selection (%d selected).", Kit.Name(hit), #list))
            else
                Select(self, hit) -- paints it green too

                Say(ply, "Info", string.format("Selected %s (green, %d selected). Right-click another thing to link everything green to it, or hold Shift and right-click to add more.", Kit.Name(hit), #list))
            end

            return true
        end

        if #list == 1 and list[1] == hit then
            UnselectAll(self)

            Say(ply, "Info", "Selection cleared.")

            return true
        end

        local sources = {}

        for _, ent in ipairs(list) do
            if ent ~= hit then sources[#sources + 1] = ent end
        end

        UnselectAll(self) -- the colours come back BEFORE the links are made; `sources` still holds the entities

        return LinkAll(ply, sources, hit, false)
    end

    -- reload: unlink
    function TOOL:Reload(trace)
        local ply = self:GetOwner()
        local hit = trace.Entity

        if not Kit.IsLinkable(hit) then
            Say(ply, "Info", "Unlink: aim at an engine, a generator, a capacitor, a lazer, a PPC or a radiator.")

            return false
        end

        if not MayTouch(self, ply, hit) then
            Say(ply, "Error", "You are not allowed to unlink that.")

            return false
        end

        local sources = {} -- everything selected except the thing we aim at

        for _, ent in ipairs(Selected(self)) do
            if ent ~= hit then sources[#sources + 1] = ent end
        end

        UnselectAll(self)

        if #sources > 0 then
            return LinkAll(ply, sources, hit, true)
        end

        local count = Kit.UnlinkAll(hit)

        Say(ply, "Info", string.format("Broke %d link(s) of %s.", count, Kit.Name(hit)))

        return count > 0
    end

    -- Putting the tool away (or switching to another tool) ends the selection, like ACF's tool does. [GUESS] that GMod calls TOOL:Holster for both.
    function TOOL:Holster()
        UnselectAll(self)
    end
end
