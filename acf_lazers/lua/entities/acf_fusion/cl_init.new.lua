-- =========================================================================
-- NEW (16.8). Goes to:  lua/entities/acf_fusion/cl_init.lua
--
-- THE ACF FUSION ENGINE, client part. Nothing to draw but the model itself (ACF's scalable base draws it at the size the server set).
-- =========================================================================

include("shared.lua")

assert(ACFLazers and ACFLazers.Config, "[acf_fusion] lua/autorun/acf_lazers_config.lua is missing or did not load")

function ENT:Draw()
    self.BaseClass.Draw(self) -- [SEEN acf_engine/cl_init.lua:166]
end
