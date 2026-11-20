local helper = require 'spec_helper'

local function setup(settingsById)
    local photos = {}
    for id, settings in pairs(settingsById) do
        local photo = helper.fakePhoto({ id = id, path = "/" .. id .. ".arw" })
        photo.getDevelopSettings = function() return settings end
        photos[#photos + 1] = photo
    end
    local catalog = helper.fakeCatalog({ photos = photos })
    helper.installImport({ LrApplication = { activeCatalog = function() return catalog end }, LrLogger = helper.defaultLrLogger() })
    package.loaded.HandlerLensProfile = nil
    return catalog, require 'HandlerLensProfile'
end

describe("HandlerLensProfile.read", function()
    it("reports each photo's lens profile as Lightroom stores it, inside one read gate with no query in it", function()
        local catalog, Handler = setup({
            ["7"] = {
                LensProfileEnable = 1, LensProfileSetup = "LensDefaults", LensProfileName = "Adobe (Sony FE 16-35mm F2.8 GM)",
                LensProfileFilename = "Sony FE 16-35mm.lcp", LensProfileDigest = "ABC", LensProfileIsEmbedded = false,
                LensProfileDistortionScale = 100, LensProfileVignettingScale = 0, Exposure2012 = 1,
            },
            ["9"] = { LensProfileEnable = 0 },
        })

        local reply = Handler.read({ photo_ids = { "7", "9", "404" } })

        assert.are.same({
            { photo_id = "7", lens_profile = {
                enabled = true, setup = "LensDefaults", name = "Adobe (Sony FE 16-35mm F2.8 GM)",
                filename = "Sony FE 16-35mm.lcp", embedded = false, distortion_scale = 100, vignetting_scale = 0,
            } },
            { photo_id = "9", lens_profile = { enabled = false } },
        }, reply.data.photos)
        assert.are.same({ "404" }, reply.not_found)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)
