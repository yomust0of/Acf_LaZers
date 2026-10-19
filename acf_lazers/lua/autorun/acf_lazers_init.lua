-- =========================================================================
-- acf_lazers_init.lua   (lua/autorun/)   REPLACEMENT, v2.1
--
-- What your version tried to do: check that ACF is there, then load lasers.lua.
-- What was wrong with it (all [SEEN] in the ACF source, details in the chat message):
--   * the hook "ACF_OnLoad" does not exist, so the function never ran. The real one is "ACF_OnLoadAddon"
--     (acf/hooks/hooks_sh.lua:7, fired at includes/gloader.lua:179)
--   * `ACF.Weapons` does not exist in this ACF, so that test could never pass either
--   * include("acf/shared/weapons/lasers.lua ETC") still had the stray " ETC", and that file doesn't exist anyway
--
-- This version keeps the intent (say whether ACF was found) and drops the include of a file that isn't there.
-- Nothing else depends on this file: the entities, the tool and the effect load by themselves.
--
-- WHY THE CHECK LIVES INSIDE HOOKS
--   Autorun files load alphabetically [KNOW, fairly sure], and "acf_lazers_init" sorts before "acf_loader"
--   (ACF's own autorun file). So when this file runs, the global ACF does not exist yet. Checking `if not ACF`
--   right here would complain even when ACF is installed.
-- =========================================================================

-- ACF finished loading (also fires again after the acf_reload console command).
hook.Add("ACF_OnLoadAddon", "ACFLazers_Startup", function()
    print("[ACF LaZers] ACF-3 detected.")

    -- The shared config file (lua/autorun/acf_lazers_config.lua) is needed by the entity, the tool and the effect.
    if not ACFLazers or not ACFLazers.Config then
        ErrorNoHalt("[ACF LaZers] lua/autorun/acf_lazers_config.lua is missing or failed to load!\n")
    end
end)

-- If ACF is not installed, "ACF_OnLoadAddon" never fires. By InitPostEntity every autorun file has finished,
-- so a still-missing ACF really is missing.
hook.Add("InitPostEntity", "ACFLazers_CheckACF", function()
    if not ACF then
        ErrorNoHalt("[ACF LaZers] ACF-3 is not installed or failed to load!\n")
    end
end)

