local Contract = require 'Contract'
local Reply = require 'Reply'
local GradientGeometry = {}

local LINEAR = "linear"
local RADIAL = "radial"

local WHAT_OF_SHAPE = { [LINEAR] = "Mask/Gradient", [RADIAL] = "Mask/CircularGradient" }
local SHAPE_OF_WHAT = { ["Mask/Gradient"] = LINEAR, ["Mask/CircularGradient"] = RADIAL }

local SHAPE_FIELDS = {
    [LINEAR] = { "start", "end" },
    [RADIAL] = { "center", "width", "height", "rotation", "feather", "area" },
}
local POINT_FIELDS = { [LINEAR] = { "start", "end" }, [RADIAL] = { "center" } }
local OTHER_SHAPE = { [LINEAR] = RADIAL, [RADIAL] = LINEAR }

local BLEND_MODE_OF_MODE = { add = 0, subtract = 1 }
local MASK_VALUE_OF_MODE = { add = 1, subtract = 0 }
local AREA_INSIDE = "inside"
local AREA_OUTSIDE = "outside"

local DEFAULT_ROTATION_DEGREES = 0
local DEFAULT_FEATHER = 50
local MAX_STORED_TURN_DEGREES = 45
local QUARTER_TURN_DEGREES = 90
local HALF_TURN_DEGREES = 180
local RADIAL_VERSION = 2
local RADIAL_MIDPOINT = 50
local RADIAL_ROUNDNESS = 0
local MIN_LINEAR_LENGTH = 1e-6
local STORED_SCALE = 10 ^ Contract.STORED_MASK_DECIMAL_PLACES

local function fail(message)
    Reply.refuse(message)
end

local function givenFields(args, fields)
    local changes = {}
    for _, field in ipairs(fields) do changes[field] = args[field] end
    return changes
end

local function copyGeometry(geometry)
    local copy = {}
    for key, value in pairs(geometry) do
        if type(value) == "table" then
            copy[key] = { x = value.x, y = value.y }
        else
            copy[key] = value
        end
    end
    return copy
end

local function samePoint(left, right)
    return math.abs(left.x - right.x) < MIN_LINEAR_LENGTH and math.abs(left.y - right.y) < MIN_LINEAR_LENGTH
end

local function validateGeometry(shape, geometry)
    if shape == LINEAR and samePoint(geometry.start, geometry["end"]) then
        fail("start and end are the same point; a linear gradient needs two different points")
    end
end

function GradientGeometry.parseCreate(args)
    local shape = args.shape
    local geometry
    if shape == LINEAR then
        geometry = { start = args.start, ["end"] = args["end"] }
    else
        geometry = {
            center = args.center,
            width = args.width,
            height = args.height,
            rotation = args.rotation or DEFAULT_ROTATION_DEGREES,
            feather = args.feather or DEFAULT_FEATHER,
            area = args.area or AREA_INSIDE,
        }
    end
    validateGeometry(shape, geometry)
    return { shape = shape, geometry = geometry, maskId = args.mask_id, mode = args.mode or "add", name = args.name }
end

local ALL_FIELDS = {}
for _, shape in ipairs({ LINEAR, RADIAL }) do
    for _, field in ipairs(SHAPE_FIELDS[shape]) do ALL_FIELDS[#ALL_FIELDS + 1] = field end
end

function GradientGeometry.parseUpdate(args)
    return { toolId = args.tool_id, changes = givenFields(args, ALL_FIELDS) }
end

local function round(value)
    return math.floor(value * STORED_SCALE + 0.5) / STORED_SCALE
end

local function mappedPoints(shape, geometry, mapPoint)
    local carried = copyGeometry(geometry)
    for _, field in ipairs(POINT_FIELDS[shape]) do
        local x, y = mapPoint(geometry[field].x, geometry[field].y)
        carried[field] = { x = round(x), y = round(y) }
    end
    return carried
end

local function turnWithin45(rotation)
    if math.abs(rotation) <= MAX_STORED_TURN_DEGREES then return rotation, false end
    local turn = rotation % HALF_TURN_DEGREES
    if turn > QUARTER_TURN_DEGREES then turn = turn - HALF_TURN_DEGREES end
    if math.abs(turn) <= MAX_STORED_TURN_DEGREES then return turn, false end
    return turn > 0 and turn - QUARTER_TURN_DEGREES or turn + QUARTER_TURN_DEGREES, true
end

function GradientGeometry.toStoredFrame(shape, geometry, frame)
    local stored = mappedPoints(shape, geometry, frame.toStored)
    if shape == RADIAL then
        stored.width = geometry.width * frame.displayedSize.width / frame.storedSize.width
        stored.height = geometry.height * frame.displayedSize.height / frame.storedSize.height
        stored.rotation = round(frame.turnToStored(geometry.rotation))
    end
    return stored
end

function GradientGeometry.toDisplayedFrame(shape, geometry, frame)
    local displayed = mappedPoints(shape, geometry, frame.toDisplayed)
    if shape == RADIAL then
        local width, height = geometry.width * frame.storedSize.width, geometry.height * frame.storedSize.height
        local turn, swapped = turnWithin45(round(frame.turnToDisplayed(geometry.rotation)))
        if swapped then width, height = height, width end
        displayed.width = round(width / frame.displayedSize.width)
        displayed.height = round(height / frame.displayedSize.height)
        displayed.rotation = round(turn)
    end
    return displayed
end

function GradientGeometry.geometryOf(component, ratio)
    local shape = SHAPE_OF_WHAT[component.What]
    if shape == nil then return nil end
    if shape == LINEAR then
        return shape, {
            start = { x = round(component.FullX), y = round(component.FullY) },
            ["end"] = { x = round(component.ZeroX), y = round(component.ZeroY) },
        }
    end
    local radians = math.rad(component.Angle)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local boxHalfWidth = (component.Right - component.Left) / 2 * ratio
    local boxHalfHeight = (component.Bottom - component.Top) / 2
    return shape, {
        center = {
            x = round((component.Left + component.Right) / 2),
            y = round((component.Top + component.Bottom) / 2),
        },
        width = round(2 * math.abs(boxHalfWidth * cosine + boxHalfHeight * sine) / ratio),
        height = round(2 * math.abs(boxHalfHeight * cosine - boxHalfWidth * sine)),
        rotation = round(component.Angle),
        feather = round(component.Feather),
        area = component.MaskInverted and AREA_OUTSIDE or AREA_INSIDE,
    }
end

function GradientGeometry.mergeChanges(shape, geometry, changes)
    for field in pairs(changes) do
        local belongs = false
        for _, own in ipairs(SHAPE_FIELDS[shape]) do belongs = belongs or own == field end
        if not belongs then
            fail(string.format("%s only applies to %s gradients, but this tool is a %s gradient",
                field, OTHER_SHAPE[shape], shape))
        end
    end
    local merged = copyGeometry(geometry)
    for field, value in pairs(changes) do merged[field] = value end
    validateGeometry(shape, merged)
    return merged
end

function GradientGeometry.applyGeometry(shape, component, geometry, ratio)
    if shape == LINEAR then
        component.FullX = geometry.start.x
        component.FullY = geometry.start.y
        component.ZeroX = geometry["end"].x
        component.ZeroY = geometry["end"].y
        return component
    end
    local storedTurn, axesSwapped = turnWithin45(geometry.rotation)
    local radians = math.rad(storedTurn)
    local cosine, sine = math.cos(radians), math.sin(radians)
    local semiWidth, semiHeight = geometry.width / 2 * ratio, geometry.height / 2
    if axesSwapped then semiWidth, semiHeight = semiHeight, semiWidth end
    local boxHalfWidth = (semiWidth * cosine - semiHeight * sine) / ratio
    local boxHalfHeight = semiWidth * sine + semiHeight * cosine
    component.Left = geometry.center.x - boxHalfWidth
    component.Right = geometry.center.x + boxHalfWidth
    component.Top = geometry.center.y - boxHalfHeight
    component.Bottom = geometry.center.y + boxHalfHeight
    component.Angle = storedTurn
    component.Feather = geometry.feather
    component.MaskInverted = geometry.area == AREA_OUTSIDE
    component.Flipped = nil
    return component
end

function GradientGeometry.newComponent(shape, geometry, mode, aspect)
    local component = {
        What = WHAT_OF_SHAPE[shape],
        MaskActive = true,
        MaskInverted = false,
        MaskBlendMode = BLEND_MODE_OF_MODE[mode],
        MaskValue = MASK_VALUE_OF_MODE[mode],
        MaskName = shape == LINEAR and "Linear Gradient" or "Radial Gradient",
    }
    if shape == RADIAL then
        component.Midpoint = RADIAL_MIDPOINT
        component.Roundness = RADIAL_ROUNDNESS
        component.Version = RADIAL_VERSION
    end
    return GradientGeometry.applyGeometry(shape, component, geometry, aspect)
end

return GradientGeometry
