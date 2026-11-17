local LrTasks = import 'LrTasks'
local LrUUID = import 'LrUUID'

local AIMaskData = require 'AIMaskData'
local CatalogWrite = require 'CatalogWrite'
local LocalSliders = require 'LocalSliders'
local Reply = require 'Reply'
local Log = require 'Log'
local DecimalText = require 'DecimalText'
local JsonValue = require 'JsonValue'
local MaskWriteAdmission = require 'MaskWriteAdmission'

local GuardedMaskWrite = {}

local READ_BACK_TIMEOUT_SECONDS = 3
local READ_BACK_POLL_SECONDS = 0.1
local TOLERANCE = 1e-5
local MAX_REPORTED_PROBLEMS = 6

local PAINT_WHAT = "Mask/Paint"
local LOCAL_ADJUSTMENT_PREFIX = "Local"

local DERIVED_FIELDS = {
    MaskSyncID = true,
    MaskValue = true,
    CorrectionSyncID = true,
    CorrectionReferenceX = true,
    CorrectionReferenceY = true,
    LocalCurveRefineSaturation = true,
    LuminanceDepthSampleInfo = true,
    Flipped = true,
}

local ENTRY_REQUIRED_FIELDS = { What = "string", CorrectionID = "string", CorrectionMasks = "table" }
local ENTRY_OPTIONAL_FIELDS = {
    CorrectionName = "string",
    CorrectionActive = "boolean",
    CorrectionAmount = "number",
    MainCurve = "table",
    RedCurve = "table",
    GreenCurve = "table",
    BlueCurve = "table",
}

local COMPONENT_OPTIONAL_FIELDS = {
    MaskID = "string",
    MaskActive = "boolean",
    MaskInverted = "boolean",
    MaskBlendMode = "number",
    MaskName = "string",
}

local COMPONENT_SCHEMAS = {
    ["Mask/Gradient"] = {
        required = { What = "string", ZeroX = "number", ZeroY = "number", FullX = "number", FullY = "number" },
        optional = {},
    },
    ["Mask/CircularGradient"] = {
        required = {
            What = "string", Top = "number", Left = "number", Bottom = "number", Right = "number",
            Angle = "number", Feather = "number", Midpoint = "number", Roundness = "number", Version = "number",
        },
        optional = {},
    },
    ["Mask/Aggregate"] = {
        required = { What = "string", Masks = "table" },
        optional = {},
    },
    ["Mask/Paint"] = {
        required = {
            What = "string", Dabs = "table", Radius = "number", Flow = "number", CenterWeight = "number",
        },
        optional = {},
    },
    ["Mask/RangeMask"] = {
        required = { What = "string", CorrectionRangeMask = "table" },
        optional = {},
    },
}

local RANGE_OPTIONAL_FIELDS = { Version = "number", SampleType = "number", Invert = "boolean" }
local RANGE_TYPE_FIELDS = {
    [1] = { ColorAmount = "number", PointModels = "table" },
    [2] = { LumRange = "string" },
    [-1] = { DepthRange = "string" },
}
local RANGE_TYPE_COLOR = 1

local function deepClone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deepClone(item)
    end
    return copy
end

GuardedMaskWrite.deepClone = deepClone

local function hasType(value, expected)
    if expected == "number" then
        return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    end
    return type(value) == expected
end

local function addProblem(problems, text)
    problems[#problems + 1] = text
end

local function checkFields(item, required, optional, isAllowedExtra, where, problems, before)
    local function unchanged(name)
        return before ~= nil and JsonValue.equal(item[name], before[name])
    end
    for name, expected in pairs(required) do
        local value = item[name]
        if not unchanged(name) then
            if value == nil then
                addProblem(problems, where .. ": missing " .. name)
            elseif not hasType(value, expected) then
                addProblem(problems, where .. ": " .. name .. " must be a " .. expected)
            end
        end
    end
    for name, value in pairs(item) do
        if required[name] == nil and not unchanged(name) then
            local expected = optional[name]
            if expected ~= nil then
                if not hasType(value, expected) then
                    addProblem(problems, where .. ": " .. name .. " must be a " .. expected)
                end
            elseif not DERIVED_FIELDS[name] and not isAllowedExtra(name) then
                addProblem(problems, where .. ": unexpected field " .. tostring(name))
            end
        end
    end
end

local function never() return false end

local function isLocalAdjustment(name)
    return type(name) == "string" and name:sub(1, #LOCAL_ADJUSTMENT_PREFIX) == LOCAL_ADJUSTMENT_PREFIX
end

local function validateRange(range, where, problems)
    if type(range) ~= "table" then
        addProblem(problems, where .. ": CorrectionRangeMask must be a table")
        return
    end
    local typeFields = RANGE_TYPE_FIELDS[range.Type]
    if typeFields == nil then
        addProblem(problems, where .. ": unsupported range Type " .. tostring(range.Type)
            .. " (only luminance 2, color 1 and depth -1 are supported)")
        return
    end
    local required = { Type = "number" }
    for name, expected in pairs(typeFields) do required[name] = expected end
    checkFields(range, required, RANGE_OPTIONAL_FIELDS, never, where, problems)
    if range.Type == RANGE_TYPE_COLOR and type(range.PointModels) == "table" then
        if #range.PointModels ~= 1 then
            addProblem(problems, where .. ": a color range needs exactly one PointModels entry")
        elseif type(range.PointModels[1]) ~= "string" then
            addProblem(problems, where .. ": PointModels entry must be a string")
        end
    end
end

local function validateComponent(component, where, problems)
    if type(component) ~= "table" then
        addProblem(problems, where .. ": not a table")
        return
    end
    if component.What == AIMaskData.KIND then return end
    local schema = COMPONENT_SCHEMAS[component.What]
    if schema == nil then
        addProblem(problems, where .. ": unknown mask type " .. tostring(component.What))
        return
    end
    local optional = {}
    for name, expected in pairs(COMPONENT_OPTIONAL_FIELDS) do optional[name] = expected end
    for name, expected in pairs(schema.optional) do optional[name] = expected end
    checkFields(component, schema.required, optional, never, where, problems)
    if component.What == "Mask/Aggregate" and type(component.Masks) == "table" then
        for index, child in ipairs(component.Masks) do
            validateComponent(child, where .. ".Masks[" .. index .. "]", problems)
        end
    elseif component.What == "Mask/RangeMask" then
        validateRange(component.CorrectionRangeMask, where, problems)
    end
end

local function heldComponent(component, before)
    for _, held in ipairs(type(before) == "table" and type(before.CorrectionMasks) == "table" and before.CorrectionMasks or {}) do
        if JsonValue.equal(held, component) then return true end
    end
    return false
end

local function validateEntry(entry, where, problems, before)
    if type(entry) ~= "table" or entry.What ~= "Correction" then
        addProblem(problems, where .. ": not a Correction")
        return
    end
    checkFields(entry, ENTRY_REQUIRED_FIELDS, ENTRY_OPTIONAL_FIELDS, isLocalAdjustment, where, problems, before)
    if type(entry.CorrectionMasks) ~= "table" then return end
    if #entry.CorrectionMasks == 0 then
        addProblem(problems, where .. ": no mask components")
        return
    end
    for index, component in ipairs(entry.CorrectionMasks) do
        if not heldComponent(component, before) then
            local at = where .. ".CorrectionMasks[" .. index .. "]"
            if type(component) == "table" and type(component.MaskID) ~= "string" then
                addProblem(problems, at .. ": missing MaskID")
            end
            validateComponent(component, at, problems)
        end
    end
end

function GuardedMaskWrite.formatProblems(entries)
    local problems = {}
    for index, entry in ipairs(entries) do validateEntry(entry, "existing mask " .. index, problems) end
    table.sort(problems)
    return problems
end

local function newId()
    return LrUUID.generateUUID():upper()
end

local function nameAdded(proposed)
    for _, entry in ipairs(proposed) do
        if type(entry) == "table" then
            if entry.CorrectionID == nil then entry.CorrectionID = newId() end
            for _, component in ipairs(type(entry.CorrectionMasks) == "table" and entry.CorrectionMasks or {}) do
                if type(component) == "table" and component.MaskID == nil then component.MaskID = newId() end
            end
        end
    end
end

local function plannedEntries(read, proposed)
    local byId, plan = {}, {}
    for _, entry in ipairs(read) do
        if entry.CorrectionID ~= nil then byId[tostring(entry.CorrectionID)] = entry end
    end
    for index, entry in ipairs(proposed) do
        local before = entry.CorrectionID ~= nil and byId[tostring(entry.CorrectionID)] or nil
        plan[index] = { preserved = before ~= nil and JsonValue.equal(before, entry), before = before }
    end
    return plan
end

local function describeProblems(problems)
    local shown = {}
    for index = 1, math.min(#problems, MAX_REPORTED_PROBLEMS) do
        shown[index] = problems[index]
    end
    local text = table.concat(shown, "; ")
    if #problems > MAX_REPORTED_PROBLEMS then
        text = text .. string.format("; and %d more", #problems - MAX_REPORTED_PROBLEMS)
    end
    return text
end

local function closeEnough(left, right)
    return math.abs(left - right) <= TOLERANCE * math.max(1, math.abs(left))
end

local function numbersIn(text)
    local numbers = {}
    for token in text:gmatch("%S+") do numbers[#numbers + 1] = DecimalText.parse(token) end
    return numbers
end

local function isNumberList(text)
    return text:match("^[%d%.%-%s]+$") ~= nil
end

local function sameNumberList(expected, actual)
    if not (isNumberList(expected) and isNumberList(actual)) then return false end
    local left, right = numbersIn(expected), numbersIn(actual)
    if #left == 0 or #left ~= #right then return false end
    for index = 1, #left do
        if left[index] == nil or right[index] == nil or not closeEnough(left[index], right[index]) then
            return false
        end
    end
    return true
end

local STATE_TOKENS = { f = true, h = true }
local POSITION_TOKEN = "d"

local function dabParts(dab)
    local tag, rest = tostring(dab):match("^(%a+)%s*(.*)$")
    return tag, numbersIn(rest or "")
end

local function splitStateTokens(dabs)
    local positions, tokens = {}, { f = {}, h = {} }
    for _, dab in ipairs(dabs) do
        local tag, numbers = dabParts(dab)
        if STATE_TOKENS[tag] then
            tokens[tag][#tokens[tag] + 1] = numbers[1]
        else
            positions[#positions + 1] = dab
        end
    end
    return positions, tokens
end

local function sameStateTokens(expected, actual)
    if #expected == 0 or #actual == 0 then return true end
    if #expected ~= #actual then return false end
    for index, value in ipairs(expected) do
        if value == nil or actual[index] == nil or not closeEnough(value, actual[index]) then return false end
    end
    return true
end

local function compareDabs(expected, actual, where, problems)
    local expectedPositions, expectedTokens = splitStateTokens(expected)
    local actualPositions, actualTokens = splitStateTokens(actual)
    if #expectedPositions ~= #actualPositions then
        addProblem(problems, where .. ": dab count changed from " .. #expectedPositions .. " to " .. #actualPositions)
        return
    end
    for tag in pairs(STATE_TOKENS) do
        if not sameStateTokens(expectedTokens[tag], actualTokens[tag]) then
            addProblem(problems, where .. ": " .. tag .. " token changed")
        end
    end
    for index, dab in ipairs(expectedPositions) do
        local expectedTag, expectedNumbers = dabParts(dab)
        local actualTag, actualNumbers = dabParts(actualPositions[index])
        local compared = expectedTag == POSITION_TOKEN and 2 or 1
        local same = expectedTag == actualTag and #actualNumbers >= compared
        for position = 1, compared do
            same = same and expectedNumbers[position] ~= nil and actualNumbers[position] ~= nil
                and closeEnough(expectedNumbers[position], actualNumbers[position])
        end
        if not same then addProblem(problems, where .. ": dab " .. index .. " changed") end
    end
end

local function pathOf(parent, name)
    if type(name) == "number" then return parent .. "[" .. name .. "]" end
    return parent .. "." .. tostring(name)
end

local function isLocalAdjustmentOmittedAtDefault(name, expected, actual)
    return actual == nil and isLocalAdjustment(name) and type(expected) == "number"
        and closeEnough(expected, LocalSliders.storedNeutralOf(name))
end

local function compareValue(name, expected, actual, parent, problems, valueIsWritten)
    if DERIVED_FIELDS[name] and not (valueIsWritten and name == "MaskValue") then return end
    local where = pathOf(parent, name)
    if type(expected) == "table" then
        if type(actual) ~= "table" then
            addProblem(problems, where .. ": lost after the write")
            return
        end
        if name == "Dabs" then
            compareDabs(expected, actual, where, problems)
            return
        end
        if #expected ~= #actual then
            addProblem(problems, where .. ": count changed from " .. #expected .. " to " .. #actual)
            return
        end
        for key, value in pairs(expected) do
            if not (expected.What == AIMaskData.KIND and AIMaskData.isComputed(key)) then
                compareValue(key, value, actual[key], where, problems,
                    expected.What == PAINT_WHAT or expected.What == AIMaskData.KIND)
            end
        end
        return
    end
    local same
    if type(expected) == "number" then
        same = (type(actual) == "number" and closeEnough(expected, actual))
            or isLocalAdjustmentOmittedAtDefault(name, expected, actual)
    elseif type(expected) == "string" then
        same = actual == expected or (type(actual) == "string" and sameNumberList(expected, actual))
    elseif expected == false then
        same = actual == false or actual == nil
    else
        same = actual == expected
    end
    if not same then
        addProblem(problems, where .. ": wrote " .. tostring(expected) .. ", read back " .. tostring(actual))
    end
end

local function mismatchesFor(plan)
    return function(expected, actual)
        local problems = {}
        if #expected ~= #actual then
            addProblem(problems, string.format("mask count changed: wrote %d, read back %d", #expected, #actual))
            return problems
        end
        for index, entry in ipairs(expected) do
            if plan[index] and plan[index].preserved then
                for _, path in ipairs(JsonValue.differences(entry, actual[index])) do
                    addProblem(problems, string.format("masks[%d], left alone by this call, changed at %s", index, path))
                end
            else
                compareValue(index, entry, actual[index], "masks", problems)
            end
        end
        table.sort(problems)
        return problems
    end
end

local function entriesOf(settings)
    return deepClone(settings.MaskGroupBasedCorrections or {}), settings.ProcessVersion
end

local function readEntries(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    return entriesOf(settings)
end

function GuardedMaskWrite.readEntries(catalog, photo)
    return (readEntries(catalog, photo))
end

function GuardedMaskWrite.inspect(catalog, photo)
    local entries, processVersion = readEntries(catalog, photo)
    return {
        process_version = processVersion,
        mask_count = #entries,
        schema_problems = GuardedMaskWrite.formatProblems(entries),
    }
end

local function writeEntries(context, catalog, photo, description, entries)
    CatalogWrite.developSettings(context, catalog, photo, description, function()
        return { MaskGroupBasedCorrections = entries }
    end)
end

local function readBackUntilMatching(catalog, photo, expected, mismatchesOf)
    local waited = 0
    while true do
        local actual = readEntries(catalog, photo)
        local mismatches = mismatchesOf(expected, actual)
        if #mismatches == 0 or waited >= READ_BACK_TIMEOUT_SECONDS then
            return actual, mismatches
        end
        LrTasks.sleep(READ_BACK_POLL_SECONDS)
        waited = waited + READ_BACK_POLL_SECONDS
    end
end

function GuardedMaskWrite.restore(context, catalog, photo, previous, from, to)
    to = to or context.ledger:mark()
    local beforeRestore = context.ledger:mark()
    local wrote = LrTasks.pcall(writeEntries, context, catalog, photo, "Restore masks", previous)
    if not wrote then return false end
    local read, _, mismatches = LrTasks.pcall(readBackUntilMatching, catalog, photo, previous, JsonValue.differences)
    if not (read and #mismatches == 0) then return false end
    context.ledger:undone(from, to)
    context.ledger:undone(beforeRestore)
    return true
end

local function failAfterRollback(context, catalog, photo, previous, problems, mark)
    local restored = GuardedMaskWrite.restore(context, catalog, photo, previous, mark)
    local summary = describeProblems(problems)
    Log.warn(string.format("Guarded mask write failed (restored=%s): %s", tostring(restored), summary))
    if restored then
        Reply.refuse("Lightroom did not keep the mask data that was written, so the photo's previous masks were"
            .. " restored: " .. summary)
    end
    error("Lightroom did not keep the mask data that was written, and the previous masks could not be"
        .. " confirmed restored; check the photo's masks in Develop: " .. summary, 0)
end

function GuardedMaskWrite.submit(context, catalog, photo, spec)
    if spec.unchanged then
        local current = GuardedMaskWrite.readEntries(catalog, photo)
        if spec.unchanged(current) then return { previous = current, entries = current } end
    end
    local previous, proposed, sent, settings
    local mark = context.ledger:mark()
    local wrote, writeError = LrTasks.pcall(CatalogWrite.developSettings, context, catalog, photo, spec.description,
        function()
            settings = photo:getDevelopSettings()
            previous = entriesOf(settings)
            proposed = spec.build(deepClone(previous), settings)
            if proposed == nil then return nil end
            sent = true
            return { MaskGroupBasedCorrections = deepClone(proposed) }
        end)
    if not wrote and not sent then error(writeError, 0) end
    if not wrote then
        failAfterRollback(context, catalog, photo, previous, { "Lightroom rejected the write: " .. tostring(writeError) },
            mark)
    end
    if proposed == nil then return { previous = previous, entries = previous, settings = settings } end

    local read, actual, mismatches = LrTasks.pcall(readBackUntilMatching, catalog, photo, proposed, spec.mismatches)
    if not read then
        mismatches = { "the masks could not be read back: " .. tostring(actual) }
    end
    if #mismatches == 0 and spec.readBackProblem then
        local problem = spec.readBackProblem(actual)
        if problem then mismatches = { problem } end
    end
    if #mismatches > 0 then
        failAfterRollback(context, catalog, photo, previous, mismatches, mark)
    end
    return { previous = previous, entries = actual, settings = settings }
end

function GuardedMaskWrite.apply(context, catalog, photo, spec)
    local plan
    local admission = MaskWriteAdmission.status(catalog)
    return GuardedMaskWrite.submit(context, catalog, photo, {
        description = spec.description,
        build = function(entries, settings)
            MaskWriteAdmission.requireAdmitted(admission, settings.ProcessVersion)
            local read = deepClone(entries)
            local proposed = spec.build(entries)
            if type(proposed) ~= "table" then error("mask change produced no mask list", 0) end
            nameAdded(proposed)
            plan = plannedEntries(read, proposed)
            local problems = {}
            for index, entry in ipairs(proposed) do
                if not plan[index].preserved then
                    validateEntry(entry, "new mask " .. index, problems, plan[index].before)
                end
            end
            if #problems > 0 then
                table.sort(problems)
                Reply.refuse("The requested mask change does not match the format this tool was tested with: "
                    .. describeProblems(problems))
            end
            return proposed
        end,
        mismatches = function(expected, actual) return mismatchesFor(plan)(expected, actual) end,
        readBackProblem = spec.readBackProblem,
    })
end

function GuardedMaskWrite.newCorrection(name, components)
    return {
        What = "Correction",
        CorrectionName = name,
        CorrectionActive = true,
        CorrectionAmount = 1,
        CorrectionMasks = components,
    }
end

function GuardedMaskWrite.findCorrection(entries, maskId)
    for index, entry in ipairs(entries) do
        if entry.CorrectionID ~= nil and tostring(entry.CorrectionID) == tostring(maskId) then
            return index, entry
        end
    end
    return nil
end

function GuardedMaskWrite.findComponent(entries, toolId)
    for entryIndex, entry in ipairs(entries) do
        for componentIndex, component in ipairs(entry.CorrectionMasks or {}) do
            if component.MaskID ~= nil and tostring(component.MaskID) == tostring(toolId) then
                return entryIndex, componentIndex, component
            end
        end
    end
    return nil
end


return GuardedMaskWrite
