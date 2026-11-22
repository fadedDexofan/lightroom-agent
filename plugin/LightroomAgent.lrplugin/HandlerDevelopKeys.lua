local LrApplication = import 'LrApplication'
local LrDevelopController = import 'LrDevelopController'
local LrTasks = import 'LrTasks'

local DevelopReadBack = require 'DevelopReadBack'
local DevelopSession = require 'DevelopSession'
local MaskSelection = require 'MaskSelection'
local PhotoLookup = require 'PhotoLookup'
local RunningLightroom = require 'RunningLightroom'

local Handler = {}

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function rangesOf(keys)
    local ranges = {}
    for _, key in ipairs(keys or {}) do
        local ok, low, high = LrTasks.pcall(LrDevelopController.getRange, key)
        if ok and isFinite(low) and isFinite(high) and low < high then ranges[key] = { low, high } end
    end
    return ranges
end

function Handler.ranges(args, context)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local photoId = tostring(photo.localIdentifier)
    local processVersion
    catalog:withReadAccessDo(function() processVersion = DevelopReadBack.saved(photo).ProcessVersion end)
    local running = RunningLightroom.describe()
    return DevelopSession.withPhoto(context, catalog, photo, function()
        local result = {
            photo_id = photoId,
            lightroom = { version = running.version, build = running.build },
            process_version = processVersion,
            ranges = rangesOf(args.keys),
        }
        if args.mask_id ~= nil then
            result.local_ranges = MaskSelection.withMaskSelected(catalog, photo, args.mask_id, function()
                return rangesOf(args.local_keys)
            end)
        end
        return result
    end)
end

return Handler
