local LrApplication = import "LrApplication"
local LrDevelopController = import "LrDevelopController"
local LrTasks = import "LrTasks"

local CatalogWrite = require "CatalogWrite"
local DecimalText = require "DecimalText"
local DevelopReadBack = require "DevelopReadBack"
local DevelopSession = require "DevelopSession"
local PhotoLookup = require "PhotoLookup"
local Reply = require "Reply"

local Handler = {}
local SLIDERS = {
    { key = "amount", parameter = "LensBlurAmount", stored = "BlurAmount" },
    { key = "cat_eye", parameter = "LensBlurCatEye", stored = "CatEyeAmount" },
    { key = "highlights_boost", parameter = "LensBlurHighlightsBoost", stored = "HighlightsBoost" },
}

local function sdk(fn, ...)
    local ok, value = LrTasks.pcall(fn, ...)
    if not ok then error(tostring(value), 0) end
    return value
end

local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end

local function close(a, b) return finite(a) and finite(b) and math.abs(a - b) <= 0.001 end

local function target(args)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_ids[1])
    local settings
    catalog:withReadAccessDo(function() settings = DevelopReadBack.saved(photo) end)
    local legacy = { [5.0] = "Version 1", [5.7] = "Version 2" }
    local version = legacy[DecimalText.parse(settings.ProcessVersion)]
    -- Opening legacy photos in Develop can materialize defaults before rejection.
    if version then Reply.refuse("Lens Blur needs Process Version 3 or later; this photo uses " .. version) end
    return catalog, photo
end

local function assertActive(catalog, photo)
    if catalog:getTargetPhoto() ~= photo then error("Another photo became active; Lens Blur stopped") end
end

local function focalRange(value)
    if type(value) ~= "string" then return nil end
    local points = {}
    for token in value:gmatch("%S+") do
        local number = DecimalText.parse(token)
        if not finite(number) then return nil end
        points[#points + 1] = number
    end
    if #points ~= 4 then return nil end
    return { near = points[2], far = points[3] }
end

local function read(catalog, photo)
    assertActive(catalog, photo)
    local active = sdk(LrDevelopController.getValue, "LensBlurActive")
    if active ~= nil and type(active) ~= "boolean" then error("Lightroom returned an invalid Lens Blur state") end
    local result = { active = active == true, unavailable = {} }
    for _, slider in ipairs(SLIDERS) do
        result[slider.key] = sdk(LrDevelopController.getValue, slider.parameter)
        if result[slider.key] == nil then result.unavailable[#result.unavailable + 1] = slider.key end
    end
    result.focal_range_raw = sdk(LrDevelopController.getValue, "LensBlurFocalRange")
    result.focal_range = focalRange(result.focal_range_raw)
    result.bokeh = sdk(LrDevelopController.getSelectedLensBlurBokeh)
    if not result.focal_range then result.unavailable[#result.unavailable + 1] = "focal_range" end
    if not result.bokeh then result.unavailable[#result.unavailable + 1] = "bokeh" end
    return result
end

local function stored(photo)
    return sdk(function() return DevelopReadBack.saved(photo).LensBlur or {} end)
end

local function flush(catalog, photo)
    assertActive(catalog, photo)
    sdk(DevelopSession.releaseTracking)
    LrTasks.sleep(5)
    assertActive(catalog, photo)
end

local function write(context, catalog, photo, parameter, value, matches)
    assertActive(catalog, photo)
    sdk(CatalogWrite.develop, context, "setValue", parameter, value)
    if
        parameter == "LensBlurActive"
        and not DevelopSession.waitFor(function()
            assertActive(catalog, photo)
            return sdk(LrDevelopController.getValue, parameter) == value
        end, 20)
    then
        error("Lightroom did not finish changing LensBlurActive; Lens Blur stopped; earlier changes may remain")
    end
    flush(catalog, photo)
    local controllerValue, savedSettings
    if
        not DevelopSession.waitFor(function()
            assertActive(catalog, photo)
            controllerValue, savedSettings = sdk(LrDevelopController.getValue, parameter), stored(photo)
            return matches(controllerValue, savedSettings)
        end, 10)
    then
        error(
            "Lightroom did not save "
                .. parameter
                .. " (controller="
                .. tostring(controllerValue)
                .. ", saved Active="
                .. tostring(savedSettings and savedSettings.Active)
                .. ", saved BlurAmount="
                .. tostring(savedSettings and savedSettings.BlurAmount)
                .. "); Lens Blur stopped; earlier changes may remain"
        )
    end
end

local function setActive(context, catalog, photo, active)
    if not active and sdk(LrDevelopController.getValue, "LensBlurActive") ~= true and stored(photo).Active ~= true then
        return
    end
    write(
        context,
        catalog,
        photo,
        "LensBlurActive",
        active,
        function(value, settings) return value == active and settings.Active == active end
    )
end

function Handler.get(args, context)
    local catalog, photo = target(args)
    return DevelopSession.withPhoto(context, catalog, photo, function()
        local result = read(catalog, photo)
        result.photo_id = tostring(photo.localIdentifier)
        return result
    end)
end

function Handler.set(args, context)
    local catalog, photo = target(args)
    return DevelopSession.withPhoto(context, catalog, photo, function()
        local adjustments = args.bokeh ~= nil or args.focal_range ~= nil
        for _, slider in ipairs(SLIDERS) do
            adjustments = adjustments or args[slider.key] ~= nil
        end
        if adjustments or args.active == true then setActive(context, catalog, photo, true) end
        for _, slider in ipairs(SLIDERS) do
            local wanted = args[slider.key]
            if wanted ~= nil then
                write(
                    context,
                    catalog,
                    photo,
                    slider.parameter,
                    wanted,
                    function(value, settings) return close(value, wanted) and close(settings[slider.stored], wanted) end
                )
            end
        end
        if args.focal_range then
            local near, far = args.focal_range.near, args.focal_range.far
            local encoded = table.concat({
                DecimalText.significant(near - 80, 10),
                DecimalText.significant(near, 10),
                DecimalText.significant(far, 10),
                DecimalText.significant(far + 80, 10),
            }, " ")
            write(context, catalog, photo, "LensBlurFocalRange", encoded, function(value, settings)
                local current, saved = focalRange(value), focalRange(settings.FocalRange)
                return current
                    and saved
                    and close(current.near, near)
                    and close(current.far, far)
                    and close(saved.near, near)
                    and close(saved.far, far)
            end)
        end
        if args.bokeh then
            assertActive(catalog, photo)
            local previous = sdk(LrDevelopController.getSelectedLensBlurBokeh)
            local before = stored(photo)
            sdk(CatalogWrite.develop, context, "setLensBlurBokeh", args.bokeh)
            flush(catalog, photo)
            local saved = DevelopSession.waitFor(function()
                assertActive(catalog, photo)
                if sdk(LrDevelopController.getSelectedLensBlurBokeh) ~= args.bokeh then return false end
                if previous == args.bokeh then return true end
                local current = stored(photo)
                for _, key in ipairs({
                    "BokehShape",
                    "BokehShapeDetail",
                    "BokehAspect",
                    "BokehRotation",
                    "SphericalAberration",
                }) do
                    if current[key] ~= before[key] then return true end
                end
                return false
            end, 10)
            if not saved then error("Lightroom did not save Lens Blur bokeh; earlier changes may remain") end
        end
        if args.active == false then setActive(context, catalog, photo, false) end
        local result = read(catalog, photo)
        result.photo_id = tostring(photo.localIdentifier)
        return result
    end)
end

return Handler
