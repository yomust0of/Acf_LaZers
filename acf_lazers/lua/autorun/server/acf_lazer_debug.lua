if SERVER then
    concommand.Add("acf_debug_limits", function(ply, cmd, args)
        if not IsValid(ply) then return end
        
        print("\n--- ACF LAZER LIMIT DIAGNOSTIC ---")
        print("1. Checking gmod.Limits table:")
        if gmod.Limits then
            for k, v in pairs(gmod.Limits) do
                if string.find(k, "acf_lazers") then
                    print("   Found registered limit: " .. tostring(k))
                end
            end
        else
            print("   WARNING: gmod.Limits table is nil!")
        end
        
        local limitName = "acf_lazers"
        local currentCount = ply:GetCount(limitName)
        local convar = GetConVar("sbox_max_" .. limitName)
        local checkResult = ply:CheckLimit(limitName)
        
        print("2. Player Status for '" .. limitName .. "':")
        print("   - Current Count: " .. currentCount)
        print("   - ConVar Max ('sbox_max_" .. limitName .. "'): " .. (convar and convar:GetInt() or "MISSING CONVAR"))
        print("   - ply:CheckLimit() returns: " .. tostring(checkResult))
        print("-------------------------------------\n")
        
        ply:ChatPrint("ACF Lazer Debug printed to server console (~).")
    end)
end