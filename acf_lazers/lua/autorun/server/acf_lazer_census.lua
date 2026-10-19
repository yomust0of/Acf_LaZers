-- =========================================================================
-- EXERCISE FILE: acf_lazer_census.lua     (NEW, optional, yours to fill in)
-- Put it at:  lua/autorun/server/acf_lazer_census.lua     ("server" folder = only the server runs it)
--
-- GOAL: a console command  acf_lazer_list  that prints one line per lazer on the map. Like an E2 doing
--   findByClass("acf_lazer") and then foreach(...) { print(...) }.
--
-- It does nothing harmful as delivered: it prints a header and a "TODO" line. Work through the stages in order.
-- To test: save the file, then in the game console (as the host / in singleplayer) type
--     lua_run include("autorun/server/acf_lazer_census.lua")      <- re-loads this file without restarting the map
--     acf_lazer_list                                              <- runs your command
-- (autorun files also load by themselves whenever the map loads.)
--
-- You can't break the lazers with this file: it only READS.
--
-- STAGE 1  (5 min)  Print how many lazers exist.
--   Pieces:  ents.FindByClass("acf_lazer")  gives you a TABLE of entities.   #something  is "how many items" (E2: entities():count())
-- STAGE 2  (10 min) Print one line per lazer: its caliber and whether it is firing.
--   Pieces:  for _, lazer in ipairs(list) do ... end         (E2: foreach(_, L:entity = list) { ... })
--            lazer:GetCaliber()   <- defined in entities/acf_lazer/shared.lua (line 27 in the v3 file)
--            lazer.Firing         <- a plain field the lazer sets itself (init.lua SetFiringState, line 177 in the v3 file)
--            string.format("%g mm | firing: %s", caliber, tostring(firing))     (E2: format("%s", X))
-- STAGE 3  (15 min) Make it not crash. Add: the owner's name, and the health in percent.
--   Pieces:  lazer.ACF.Health / lazer.ACF.MaxHealth      <- ACF fills this table in. BUT it can be missing for a moment after spawn.
--            IsValid(thing)                              <- "is this a real, living entity?"  (E2: ->isValid)
--            if not something then ... end               <- the guard. What should the line say if lazer.ACF is nil?
--            lazer.Owner                                 <- set by ACF when the tool spawns it. Could be nil or invalid (player left!).
--   Finish with: if the list is empty print "no lazers on the map" and stop.
--
-- When you're done (or stuck, or bored), paste the file to me and I'll review it like a code review, not like a test.
-- =========================================================================

-- concommand.Add(name, function(ply, cmd, args) ... end) = "when someone types NAME in the console, run this function".
-- ply is the player who typed it (nil if typed in the server console). [KNOW]
concommand.Add("acf_lazer_list", function(ply, cmd, args)
    print("---- ACF lazers ----")

    -- STAGE 1: put your code here, replacing the line below

    print("TODO: write stage 1")
end)
