local LrApplication = import "LrApplication"

local CatalogWrite = require "CatalogWrite"
local DevelopBatch = require "DevelopBatch"
local DevelopReadBack = require "DevelopReadBack"
local DevelopSession = require "DevelopSession"
local Reply = require "Reply"

local Handler = {}
local RESERVE_SECONDS = 30
local SETTLE_SECONDS = 5

local TREATMENTS = {
    color = { command = "color", grayscale = false },
    black_and_white = { command = "grayscale", grayscale = true },
}

local function profileOf(settings)
    local look = settings.Look
    if type(look) == "table" and type(look.Name) == "string" then return look.Name end
    return settings.CameraProfile
end

local function readSettings(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = DevelopReadBack.saved(photo) end)
    return settings
end

local function dispatchAndRead(context, catalog, photo, wanted)
    CatalogWrite.invoke(context, "quickDevelopSetTreatment", photo.quickDevelopSetTreatment, photo, wanted.command)
    local settings
    local changed = DevelopSession.waitFor(function()
        settings = readSettings(catalog, photo)
        return settings.ConvertToGrayscale == wanted.grayscale
    end, SETTLE_SECONDS)
    return changed, settings
end

local function convert(context, catalog, photo, state, name)
    local wanted = TREATMENTS[name]
    local before = profileOf(readSettings(catalog, photo))
    if not DevelopSession.selectAlone(catalog, photo, state) then
        Reply.refuse("Could not select photo " .. tostring(photo.localIdentifier) .. " alone")
    end
    local changed, settings = dispatchAndRead(context, catalog, photo, wanted)
    if not changed then
        changed, settings = dispatchAndRead(context, catalog, photo, wanted)
    end
    if not changed then
        error(
            "Lightroom did not change the treatment after two dispatches; ConvertToGrayscale reads "
                .. tostring(settings.ConvertToGrayscale),
            0
        )
    end
    return {
        treatment = name,
        convert_to_grayscale = settings.ConvertToGrayscale,
        profile = { before = before, after = profileOf(settings) },
    }
end

function Handler.set(args, context)
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESERVE_SECONDS,
        each = function(photo, state) return convert(context, catalog, photo, state, args.treatment) end,
    })
end

return Handler
