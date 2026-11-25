local LrTasks = import "LrTasks"

local Contract = require "Contract"
local GuardedMaskWrite = require "GuardedMaskWrite"
local JsonValue = require "JsonValue"
local LocalSliders = require "LocalSliders"
local MaskCurves = require "MaskCurves"
local MaskPointColors = require "MaskPointColors"
local Reply = require "Reply"

local MaskValues = {}

local SAVED_POLL_SECONDS = 0.1
local SLIDERS_STEP = "Set Mask Adjustments"
local CURVES_STEP = "Set Mask Curves"
local SWATCH_STEPS = {
    add = "Add Point Color Swatch",
    update = "Update Point Color Swatch",
    delete = "Delete Point Color Swatch",
    clear = "Clear Point Color Swatches",
}
local COPY_STEP = "Copy Mask Adjustments"
local IDENTITY_FIELDS = {
    What = true,
    CorrectionMasks = true,
    CorrectionID = true,
    CorrectionSyncID = true,
    CorrectionName = true,
    CorrectionReferenceX = true,
    CorrectionReferenceY = true,
    CorrectionActive = true,
}
local COLORS_KEY = "LocalPointColors"
local VARIANCE_KEY = "LocalColorVariance"

local function savedIds(entries)
    local ids = {}
    for _, entry in ipairs(entries) do
        if entry.CorrectionID ~= nil then ids[#ids + 1] = tostring(entry.CorrectionID) end
    end
    return #ids > 0 and table.concat(ids, ", ") or "none"
end

local function entryOf(photo, entries, maskId)
    local index, entry = GuardedMaskWrite.findCorrection(entries, maskId)
    if entry == nil then
        Reply.refuse(
            string.format(
                "Mask %s is not in the saved settings of photo %s (saved masks: %s); a mask made in"
                    .. " Develop in the last few seconds may not be saved yet",
                tostring(maskId),
                tostring(photo.localIdentifier),
                savedIds(entries)
            )
        )
    end
    return index, entry
end

local DECODERS = {
    adjustments = function(entry)
        local adjustments = {}
        for _, slider in ipairs(LocalSliders.list) do
            local stored = entry[slider.stored]
            adjustments[slider.name] = stored == nil and LocalSliders.neutralOf(slider)
                or LocalSliders.valueOf(slider, stored)
        end
        return adjustments
    end,
    curves = function(entry)
        local curves = {}
        for _, channel in ipairs(MaskCurves.channels) do
            curves[channel.name] = MaskCurves.ofEntry(entry, channel)
        end
        return curves
    end,
    swatches = function(entry)
        return MaskPointColors.indexed(MaskPointColors.fromStored(entry[COLORS_KEY], entry[VARIANCE_KEY]))
    end,
}
local ALL_KINDS = { "adjustments", "curves", "swatches" }

local function decode(entry, kinds)
    local values = {}
    for _, kind in ipairs(kinds) do
        values[kind] = DECODERS[kind](entry)
    end
    return values
end

local function writtenValues(entry, kinds)
    local values = {}
    for _, kind in ipairs(kinds) do
        if kind == "swatches" and MaskPointColors.unreadableIndex(entry[COLORS_KEY]) then
            values.swatch_count = #entry[COLORS_KEY]
        else
            values[kind] = DECODERS[kind](entry)
        end
    end
    return values
end

local function kindsOf(change)
    local kinds = {}
    if change.adjustments then kinds[#kinds + 1] = "adjustments" end
    if change.curves then kinds[#kinds + 1] = "curves" end
    if change.swatch then kinds[#kinds + 1] = "swatches" end
    return kinds
end

function MaskValues.storeAdjustments(entry, adjustments)
    for _, slider in ipairs(LocalSliders.list) do
        local value = adjustments and adjustments[slider.name]
        if value ~= nil then entry[slider.stored] = LocalSliders.storedOf(slider, value) end
    end
end

function MaskValues.read(catalog, photo, maskId, kinds)
    local _, entry = entryOf(photo, GuardedMaskWrite.readEntries(catalog, photo), maskId)
    return decode(entry, kinds or ALL_KINDS)
end

function MaskValues.requireSaved(catalog, photo, maskId)
    entryOf(photo, GuardedMaskWrite.readEntries(catalog, photo), maskId)
end

MaskValues.savedEntry = entryOf

function MaskValues.adjustmentsOf(entry, requested)
    local all, picked = DECODERS.adjustments(entry), {}
    for name in pairs(requested) do
        picked[name] = all[name]
    end
    return picked
end

local function sliderEdit(slider, value)
    local stored = LocalSliders.storedOf(slider, value)
    local fields = { { key = slider.stored, value = stored } }
    return {
        name = slider.name,
        fieldsFor = function() return fields end,
        holds = function(entry)
            local current = entry[slider.stored]
            if current == nil then current = LocalSliders.storedNeutralOf(slider.stored) end
            return JsonValue.equal(current, stored)
        end,
        describe = function(field, actual)
            if type(actual) ~= "number" then return nil end
            return string.format(
                "%s: wrote %s, Lightroom stored %s",
                slider.name,
                tostring(LocalSliders.valueOf(slider, field.value)),
                tostring(LocalSliders.valueOf(slider, actual))
            )
        end,
    }
end

local function pointsText(strings) return type(strings) == "table" and table.concat(strings, " ") or "nothing" end

local function curveEdit(channel, points)
    local fields = { { key = channel.stored, value = MaskCurves.toStored(points) }, { key = channel.extended } }
    return {
        name = channel.name .. " curve",
        fieldsFor = function() return fields end,
        holds = function(entry) return JsonValue.equal(MaskCurves.ofEntry(entry, channel), points) end,
        describe = function(field, actual)
            if field.key ~= channel.stored then return nil end
            return string.format(
                "%s curve: wrote %s, Lightroom stored %s",
                channel.name,
                pointsText(field.value),
                pointsText(actual)
            )
        end,
    }
end

local function requireSwatch(maskId, index, count)
    if index > count then
        Reply.refuse(
            string.format("No swatch at index %d on mask %s (the mask has %d)", index, tostring(maskId), count)
        )
    end
end

local function swatchCountText(value) return type(value) == "table" and (#value .. " entries") or "nothing" end

local function describeSwatchList(field, actual)
    return string.format(
        "Point Color %s: wrote %s, Lightroom stored %s",
        field.key,
        swatchCountText(field.value),
        swatchCountText(actual)
    )
end

local function swatchUpdate(maskId, swatch)
    local index, patch = swatch.index, swatch.fields
    local function swatchesOf(entry)
        local swatches = MaskPointColors.fromStored(entry[COLORS_KEY], entry[VARIANCE_KEY])
        requireSwatch(maskId, index, #swatches)
        return swatches
    end
    local function storedOf(entry)
        local merged = MaskPointColors.merge(swatchesOf(entry)[index], patch)
        MaskPointColors.requireOrderedRanges(merged, index)
        return MaskPointColors.toStored(merged)
    end
    return {
        name = "Point Color swatch " .. index,
        fieldsFor = function(entry)
            local colors, variances = {}, {}
            for position, text in ipairs(entry[COLORS_KEY]) do
                colors[position] = text
                variances[position] = MaskPointColors.storedVariance(entry[VARIANCE_KEY], position)
            end
            colors[index], variances[index] = storedOf(entry)
            return { { key = COLORS_KEY, value = colors }, { key = VARIANCE_KEY, value = variances } }
        end,
        holds = function(entry)
            local color, variance = storedOf(entry)
            return JsonValue.equal(swatchesOf(entry)[index], MaskPointColors.fromStored({ color }, { variance })[1])
        end,
        describe = function(field, actual)
            return string.format(
                "Point Color swatch %d: wrote %s, Lightroom stored %s",
                index,
                tostring(field.value[index]),
                type(actual) == "table" and tostring(actual[index]) or "nothing"
            )
        end,
    }
end

local function swatchDelete(maskId, swatch)
    local index = swatch.index
    return {
        name = "the deletion of Point Color swatch " .. index,
        fieldsFor = function(entry)
            local colors, variances = {}, {}
            for position, text in ipairs(entry[COLORS_KEY]) do
                if position ~= index then
                    colors[#colors + 1] = text
                    variances[#variances + 1] = MaskPointColors.storedVariance(entry[VARIANCE_KEY], position)
                end
            end
            if #colors == 0 then return { { key = COLORS_KEY }, { key = VARIANCE_KEY } } end
            return { { key = COLORS_KEY, value = colors }, { key = VARIANCE_KEY, value = variances } }
        end,
        holds = function(entry)
            requireSwatch(maskId, index, type(entry[COLORS_KEY]) == "table" and #entry[COLORS_KEY] or 0)
            return false
        end,
        describe = describeSwatchList,
    }
end

local function swatchesClear()
    return {
        name = "clearing the Point Color swatches",
        fieldsFor = function() return { { key = COLORS_KEY }, { key = VARIANCE_KEY } } end,
        holds = function(entry) return entry[COLORS_KEY] == nil and entry[VARIANCE_KEY] == nil end,
        describe = describeSwatchList,
    }
end

local function swatchAdd(maskId, swatch)
    local added = MaskPointColors.newSwatch(swatch.fields)
    local function existing(entry)
        local swatches = MaskPointColors.fromStored(entry[COLORS_KEY], entry[VARIANCE_KEY])
        if #swatches >= Contract.POINT_COLOR.max_swatches then
            Reply.refuse(
                string.format(
                    "Mask %s already holds %d Point Color swatches, the most Lightroom allows",
                    tostring(maskId),
                    Contract.POINT_COLOR.max_swatches
                )
            )
        end
        for index, held in ipairs(swatches) do
            if MaskPointColors.sameSource(held, added) then
                Reply.refuse(
                    string.format(
                        "Mask %s already has a swatch with that source color at index %d; nothing" .. " was added",
                        tostring(maskId),
                        index
                    )
                )
            end
        end
        MaskPointColors.requireOrderedRanges(added, #swatches + 1)
        return swatches
    end
    return {
        name = "the new Point Color swatch",
        fieldsFor = function(entry)
            local count = #existing(entry)
            local colors, variances = {}, {}
            for position = 1, count do
                colors[position] = entry[COLORS_KEY][position]
                variances[position] = MaskPointColors.storedVariance(entry[VARIANCE_KEY], position)
            end
            colors[count + 1], variances[count + 1] = MaskPointColors.toStored(added)
            return { { key = COLORS_KEY, value = colors }, { key = VARIANCE_KEY, value = variances } }
        end,
        holds = function(entry)
            existing(entry)
            return false
        end,
        describe = describeSwatchList,
    }
end

local SWATCH_EDITS = { add = swatchAdd, update = swatchUpdate, delete = swatchDelete, clear = swatchesClear }

local function valueText(value)
    if type(value) == "table" then return table.concat(value, " ") end
    return value == nil and "nothing" or tostring(value)
end

local function copyEdit(sourceId, source)
    local function valueKeys(target)
        local keys, seen = {}, {}
        for _, entry in ipairs({ source, target }) do
            for key in pairs(entry) do
                if not IDENTITY_FIELDS[key] and not seen[key] then
                    seen[key] = true
                    keys[#keys + 1] = key
                end
            end
        end
        table.sort(keys)
        return keys
    end
    return {
        name = "the adjustments of mask " .. tostring(sourceId),
        fieldsFor = function(target)
            local fields = {}
            for _, key in ipairs(valueKeys(target)) do
                fields[#fields + 1] = { key = key, value = GuardedMaskWrite.deepClone(source[key]) }
            end
            return fields
        end,
        holds = function(target)
            for _, key in ipairs(valueKeys(target)) do
                if not JsonValue.equal(target[key], source[key]) then return false end
            end
            return true
        end,
        describe = function(field, actual)
            return string.format(
                "%s: wrote %s, Lightroom stored %s",
                field.key,
                valueText(field.value),
                valueText(actual)
            )
        end,
    }
end

local function editsOf(maskId, change)
    local edits = {}
    for _, slider in ipairs(LocalSliders.list) do
        local value = change.adjustments and change.adjustments[slider.name]
        if value ~= nil then edits[#edits + 1] = sliderEdit(slider, value) end
    end
    for _, channel in ipairs(MaskCurves.channels) do
        local points = change.curves and change.curves[channel.name]
        if points ~= nil then edits[#edits + 1] = curveEdit(channel, points) end
    end
    if change.swatch then edits[#edits + 1] = SWATCH_EDITS[change.swatch.action](maskId, change.swatch) end
    return edits
end

local function historyStepOf(change)
    if change.swatch then return SWATCH_STEPS[change.swatch.action] end
    if change.curves then return CURVES_STEP end
    return SLIDERS_STEP
end

local function pending(entry, edits)
    local differing = {}
    for _, edit in ipairs(edits) do
        if not edit.holds(entry) then differing[#differing + 1] = edit end
    end
    return differing
end

local function planned(entry, edits)
    local plan = {}
    for _, edit in ipairs(edits) do
        plan[#plan + 1] = { name = edit.name, describe = edit.describe, fields = edit.fieldsFor(entry) }
    end
    return plan
end

local function apply(entry, plan)
    for _, step in ipairs(plan) do
        for _, field in ipairs(step.fields) do
            entry[field.key] = field.value
        end
    end
end

local function keysOf(plan)
    local keys = {}
    for _, step in ipairs(plan) do
        for _, field in ipairs(step.fields) do
            keys[#keys + 1] = field.key
        end
    end
    return keys
end

local function mismatchesOf(index, plan)
    local byPath = {}
    for _, step in ipairs(plan) do
        for _, field in ipairs(step.fields) do
            byPath[tostring(index) .. "." .. field.key] = { step = step, field = field }
        end
    end
    return function(expected, actual)
        local mismatches, described = {}, {}
        for _, path in ipairs(JsonValue.differences(expected, actual)) do
            local fieldPath = path:match("^(%d+%.[^.]+)")
            local named = fieldPath and byPath[fieldPath]
            local text = named
                and named.step.describe(named.field, type(actual[index]) == "table" and actual[index][named.field.key])
            if text == nil then
                mismatches[#mismatches + 1] = path .. " changed"
            elseif not described[fieldPath] then
                described[fieldPath] = true
                mismatches[#mismatches + 1] = text
            end
        end
        return mismatches
    end
end

local function submitEdits(context, catalog, photo, maskId, description, kinds, editsFrom)
    local index, before, plan
    local submitted = GuardedMaskWrite.submit(context, catalog, photo, {
        description = description,
        unchanged = function(entries)
            local _, current = entryOf(photo, entries, maskId)
            return #pending(current, editsFrom(entries)) == 0
        end,
        build = function(snapshot)
            local edits = editsFrom(snapshot)
            local entry
            index, entry = entryOf(photo, snapshot, maskId)
            before = GuardedMaskWrite.deepClone(entry)
            plan = planned(entry, pending(entry, edits))
            if #plan == 0 then return nil end
            apply(entry, plan)
            entry.CorrectionActive = true
            return snapshot
        end,
        mismatches = function(expected, actual) return mismatchesOf(index, plan)(expected, actual) end,
    })
    if plan == nil then
        local _, current = entryOf(photo, submitted.entries, maskId)
        local values = writtenValues(current, kinds)
        return { before = values, after = values, written = {} }
    end
    if #plan > 0 and before.CorrectionActive == false then
        context:warn(
            string.format(
                "mask %s was hidden (CorrectionActive false); this write showed it again, as"
                    .. " Lightroom's own sliders do",
                tostring(maskId)
            )
        )
    end
    return {
        before = writtenValues(before, kinds),
        after = writtenValues(submitted.entries[index], kinds),
        written = keysOf(plan),
    }
end

function MaskValues.write(context, catalog, photo, maskId, change)
    local edits = editsOf(maskId, change)
    return submitEdits(
        context,
        catalog,
        photo,
        maskId,
        historyStepOf(change),
        kindsOf(change),
        function() return edits end
    )
end

function MaskValues.copy(context, catalog, photo, sourceId, targetId)
    return submitEdits(context, catalog, photo, targetId, COPY_STEP, {}, function(entries)
        local _, source = entryOf(photo, entries, sourceId)
        return { copyEdit(sourceId, source) }
    end)
end

function MaskValues.waitUntilSaved(catalog, photo, maskId, subject)
    local waited = 0
    while GuardedMaskWrite.findCorrection(GuardedMaskWrite.readEntries(catalog, photo), maskId) == nil do
        if waited >= Contract.NEW_MASK_SAVE_WAIT_SECONDS then
            Reply.refuse(
                string.format(
                    "Lightroom did not save %s %s within %s s",
                    subject,
                    tostring(maskId),
                    tostring(Contract.NEW_MASK_SAVE_WAIT_SECONDS)
                )
            )
        end
        LrTasks.sleep(SAVED_POLL_SECONDS)
        waited = waited + SAVED_POLL_SECONDS
    end
end

return MaskValues
