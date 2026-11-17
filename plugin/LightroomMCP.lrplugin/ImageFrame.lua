local Log = require 'Log'
local Reply = require 'Reply'

local ImageFrame = {}

local atan2 = math.atan2 or math.atan

local CROPPED_FROM_DISPLAYED = {
    AB = function(u, v) return u, v end,
    BA = function(u, v) return 1 - u, v end,
    CD = function(u, v) return 1 - u, 1 - v end,
    DC = function(u, v) return u, 1 - v end,
    CB = function(u, v) return v, u end,
    BC = function(u, v) return v, 1 - u end,
    AD = function(u, v) return 1 - v, 1 - u end,
    DA = function(u, v) return 1 - v, u end,
}

local FIT_TOLERANCE = 1e-9

local CROP_DEFAULTS = { CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1, CropAngle = 0 }

local WARPS = {
    { key = "PerspectiveUpright", neutral = 0 },
    { key = "PerspectiveVertical", neutral = 0 },
    { key = "PerspectiveHorizontal", neutral = 0 },
    { key = "PerspectiveRotate", neutral = 0 },
    { key = "PerspectiveScale", neutral = 100 },
    { key = "PerspectiveAspect", neutral = 0 },
    { key = "PerspectiveX", neutral = 0 },
    { key = "PerspectiveY", neutral = 0 },
    { key = "LensManualDistortionAmount", neutral = 0 },
}

local function orientationMapOf(orientation)
    local map = type(orientation) == "string" and CROPPED_FROM_DISPLAYED[orientation] or nil
    if not map then
        Reply.refuse(string.format("The photo reports the orientation %s, which this tool cannot map to the stored"
            .. " mask frame, so nothing was written", tostring(orientation)))
    end
    return map
end

local function inverseOf(map)
    local originX, originY = map(0, 0)
    local acrossX, acrossY = map(1, 0)
    local downX, downY = map(0, 1)
    acrossX, acrossY, downX, downY = acrossX - originX, acrossY - originY, downX - originX, downY - originY
    return function(x, y)
        local offsetX, offsetY = x - originX, y - originY
        return offsetX * acrossX + offsetY * acrossY, offsetX * downX + offsetY * downY
    end, acrossX == 0
end

local function pixelSizeOf(dimensions)
    local width = type(dimensions) == "table" and tonumber(dimensions.width) or nil
    local height = type(dimensions) == "table" and tonumber(dimensions.height) or nil
    if width == nil or height == nil or width <= 0 or height <= 0 then
        Reply.refuse("Lightroom reports no pixel size for this photo, so positions in its displayed frame cannot"
            .. " be mapped to the stored mask frame")
    end
    return width, height
end

local function settingOf(settings, key)
    local value = tonumber(settings[key])
    if value == nil then return CROP_DEFAULTS[key] end
    return value
end

local function warningOf(settings)
    local active = {}
    for _, warp in ipairs(WARPS) do
        local value = tonumber(settings[warp.key])
        if value ~= nil and value ~= warp.neutral then active[#active + 1] = warp.key .. " " .. tostring(value) end
    end
    if #active == 0 then return nil end
    return "Upright, Transform or manual distortion is active (" .. table.concat(active, ", ") .. "): Lightroom"
        .. " renders masks through those corrections and exposes no inverse for them, so a position read off a"
        .. " preview can land up to about 0.05 of the frame away near the edges (none at the centre); check the render"
end

function ImageFrame.of(photo)
    local cropFromDisplayed = orientationMapOf(photo.orientation)
    local displayedFromCrop, swapsAxes = inverseOf(cropFromDisplayed)
    local storedWidth, storedHeight = pixelSizeOf(photo.dimensions)
    if swapsAxes then storedWidth, storedHeight = storedHeight, storedWidth end

    local settings = photo.settings or {}
    local radians = math.rad(settingOf(settings, "CropAngle"))
    local cosine, sine = math.cos(radians), math.sin(radians)
    local originX = settingOf(settings, "CropLeft") * storedWidth
    local originY = settingOf(settings, "CropTop") * storedHeight
    local spanX = (settingOf(settings, "CropRight") - settingOf(settings, "CropLeft")) * storedWidth
    local spanY = (settingOf(settings, "CropBottom") - settingOf(settings, "CropTop")) * storedHeight
    local cropWidth = spanX * cosine + spanY * sine
    local cropHeight = spanY * cosine - spanX * sine

    local function toStored(u, v)
        local p, q = cropFromDisplayed(u, v)
        local x = originX + p * cropWidth * cosine - q * cropHeight * sine
        local y = originY + p * cropWidth * sine + q * cropHeight * cosine
        return x / storedWidth, y / storedHeight
    end

    local function toDisplayed(x, y)
        local offsetX, offsetY = x * storedWidth - originX, y * storedHeight - originY
        return displayedFromCrop((offsetX * cosine + offsetY * sine) / cropWidth,
            (offsetY * cosine - offsetX * sine) / cropHeight)
    end

    local displayedWidth, displayedHeight = cropWidth, cropHeight
    if swapsAxes then displayedWidth, displayedHeight = cropHeight, cropWidth end

    local cornerX, cornerY = toStored(0, 0)
    local acrossX, acrossY = toStored(1, 0)
    local downX, downY = toStored(0, 1)
    acrossX = (acrossX - cornerX) * storedWidth / displayedWidth
    acrossY = (acrossY - cornerY) * storedHeight / displayedWidth
    downX = (downX - cornerX) * storedWidth / displayedHeight
    downY = (downY - cornerY) * storedHeight / displayedHeight

    local function turned(degrees, transpose)
        local angle = math.rad(degrees)
        local x, y = math.cos(angle), math.sin(angle)
        if transpose then return math.deg(atan2(x * downX + y * downY, x * acrossX + y * acrossY)) end
        return math.deg(atan2(x * acrossY + y * downY, x * acrossX + y * downX))
    end

    return {
        toStored = toStored,
        toDisplayed = toDisplayed,
        storedSize = { width = storedWidth, height = storedHeight },
        displayedSize = { width = displayedWidth, height = displayedHeight },
        turnToStored = function(degrees) return turned(degrees, false) end,
        turnToDisplayed = function(degrees) return turned(degrees, true) end,
        longEdgeToStored = function(fraction)
            return fraction * math.max(displayedWidth, displayedHeight) / math.max(storedWidth, storedHeight)
        end,
        warning = warningOf(settings),
    }
end

local function reachOf(crop)
    local radians = math.rad(crop.angle)
    local cosine, sine = math.abs(math.cos(radians)), math.abs(math.sin(radians))
    return (crop.width * cosine + crop.height * sine) / 2, (crop.width * sine + crop.height * cosine) / 2
end

local function fitScaleOf(width, height, crop)
    local reachX, reachY = reachOf(crop)
    local x, y = crop.center.x * width, crop.center.y * height
    return math.min(math.min(x, width - x) / reachX, math.min(y, height - y) / reachY)
end

local function scaled(crop, scale)
    return { center = crop.center, width = crop.width * scale, height = crop.height * scale, angle = crop.angle }
end

function ImageFrame.cropOfRectangle(photo, rectangle, angle)
    local width, height = pixelSizeOf(photo.dimensions)
    return {
        center = { x = (rectangle.left + rectangle.right) / 2, y = (rectangle.top + rectangle.bottom) / 2 },
        width = (rectangle.right - rectangle.left) * width,
        height = (rectangle.bottom - rectangle.top) * height,
        angle = angle,
    }
end

function ImageFrame.largestCrop(photo, aspect, center, angle)
    local width, height = pixelSizeOf(photo.dimensions)
    local unit = { center = center, width = aspect.width, height = aspect.height, angle = angle }
    return scaled(unit, fitScaleOf(width, height, unit))
end

function ImageFrame.rectangleOf(photo, crop)
    local width, height = pixelSizeOf(photo.dimensions)
    local halfX, halfY = crop.width / 2 / width, crop.height / 2 / height
    return {
        left = crop.center.x - halfX, top = crop.center.y - halfY,
        right = crop.center.x + halfX, bottom = crop.center.y + halfY,
    }
end

function ImageFrame.cropSettingsFor(photo, crop)
    local width, height = pixelSizeOf(photo.dimensions)
    local scale = fitScaleOf(width, height, crop)
    if scale < 1 - FIT_TOLERANCE then
        local largest = ImageFrame.rectangleOf(photo, scaled(crop, math.max(scale, 0)))
        Reply.refuse(string.format("The crop leaves the photo at angle %s, so its corners would be empty; the largest"
            .. " frame with this centre, angle and aspect is left %.4f, top %.4f, right %.4f, bottom %.4f",
            tostring(crop.angle), largest.left, largest.top, largest.right, largest.bottom))
    end
    local displayedFromCrop = inverseOf(orientationMapOf(photo.orientation))
    local uncropped = ImageFrame.of({ orientation = photo.orientation, dimensions = photo.dimensions })
    local radians = math.rad(crop.angle)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local function corner(p, q)
        local u, v = displayedFromCrop(p, q)
        local x = crop.center.x * width + (u - 0.5) * crop.width * cosine - (v - 0.5) * crop.height * sine
        local y = crop.center.y * height + (u - 0.5) * crop.width * sine + (v - 0.5) * crop.height * cosine
        return uncropped.toStored(x / width, y / height)
    end
    local left, top = corner(0, 0)
    local right, bottom = corner(1, 1)
    if left >= right or top >= bottom then
        Reply.refuse(string.format("At angle %g this frame's turned corners cross in Lightroom's crop keys; set_crop does"
            .. " not write crossed corners until Lightroom is shown to keep them. Use a smaller angle or an aspect closer"
            .. " to square", crop.angle))
    end
    local acrossX, acrossY = corner(1, 0)
    local stored = uncropped.storedSize
    return {
        CropLeft = left, CropTop = top, CropRight = right, CropBottom = bottom,
        CropAngle = math.deg(atan2((acrossY - top) * stored.height, (acrossX - left) * stored.width)),
    }
end

function ImageFrame.currentCrop(photo)
    local width, height = pixelSizeOf(photo.dimensions)
    local cropped = ImageFrame.of(photo)
    local uncropped = ImageFrame.of({ orientation = photo.orientation, dimensions = photo.dimensions })
    local function corner(u, v)
        local x, y = uncropped.toDisplayed(cropped.toStored(u, v))
        return x * width, y * height
    end
    local originX, originY = corner(0, 0)
    local acrossX, acrossY = corner(1, 0)
    local downX, downY = corner(0, 1)
    acrossX, acrossY, downX, downY = acrossX - originX, acrossY - originY, downX - originX, downY - originY
    return {
        center = { x = (originX + (acrossX + downX) / 2) / width, y = (originY + (acrossY + downY) / 2) / height },
        width = math.sqrt(acrossX * acrossX + acrossY * acrossY),
        height = math.sqrt(downX * downX + downY * downY),
        angle = math.deg(atan2(acrossY, acrossX)),
    }
end

function ImageFrame.withinCrop(photo, current, inner)
    local width, height = pixelSizeOf(photo.dimensions)
    local radians = math.rad(current.angle)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local alongX, alongY = (inner.center.x - 0.5) * current.width, (inner.center.y - 0.5) * current.height
    return {
        center = {
            x = current.center.x + (alongX * cosine - alongY * sine) / width,
            y = current.center.y + (alongX * sine + alongY * cosine) / height,
        },
        width = inner.width, height = inner.height, angle = current.angle + inner.angle,
    }
end

function ImageFrame.read(catalog, photo)
    local read = {}
    catalog:withReadAccessDo(function()
        read.orientation = photo:getRawMetadata("orientation")
        read.dimensions = photo:getRawMetadata("dimensions")
        read.settings = photo:getDevelopSettings()
    end)
    Log.info("Photo " .. tostring(photo.localIdentifier) .. " reports orientation " .. tostring(read.orientation))
    return read
end

function ImageFrame.forPhoto(catalog, photo)
    return ImageFrame.of(ImageFrame.read(catalog, photo))
end

return ImageFrame
