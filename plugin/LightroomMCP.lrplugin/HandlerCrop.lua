local LrApplication = import 'LrApplication'

local ImageFrame = require 'ImageFrame'
local PhotoLookup = require 'PhotoLookup'

local Handler = {}

local CENTER = { x = 0.5, y = 0.5 }
local DECIMALS = 1e6

local function round(value)
    return math.floor(value * DECIMALS + 0.5) / DECIMALS
end

local function stated(frame, args)
    if args.rectangle ~= nil then return ImageFrame.cropOfRectangle(frame, args.rectangle, args.angle) end
    local crop = ImageFrame.largestCrop(frame, args.aspect, args.center or CENTER, args.angle)
    local scale = args.scale or 1
    return { center = crop.center, width = crop.width * scale, height = crop.height * scale, angle = crop.angle }
end

local function cropFor(read, args)
    if args.relative_to ~= "crop" then return stated(read, args) end
    local current = ImageFrame.currentCrop(read)
    local inner = stated({ dimensions = { width = current.width, height = current.height } }, args)
    return ImageFrame.withinCrop(read, current, inner)
end

local function described(photo, read, crop)
    local rectangle = ImageFrame.rectangleOf(read, crop)
    for key, value in pairs(rectangle) do rectangle[key] = round(value) end
    return {
        photo_id = tostring(photo.localIdentifier),
        rectangle = rectangle,
        angle = round(crop.angle),
        size = { width = math.floor(crop.width + 0.5), height = math.floor(crop.height + 0.5) },
    }
end

local function opened(args, context)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local read = ImageFrame.read(catalog, photo)
    local warning = ImageFrame.of(read).warning
    if warning then context:warn(warning) end
    return photo, read
end

function Handler.read(args, context)
    local photo, read = opened(args, context)
    return described(photo, read, ImageFrame.currentCrop(read))
end

function Handler.plan(args, context)
    local photo, read = opened(args, context)
    local crop = cropFor(read, args)
    local plan = described(photo, read, crop)
    plan.settings = ImageFrame.cropSettingsFor(read, crop)
    return plan
end

return Handler
