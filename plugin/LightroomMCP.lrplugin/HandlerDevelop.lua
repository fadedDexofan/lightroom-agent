local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import 'LrTasks'

local AIMaskData = require 'AIMaskData'
local CatalogWrite = require 'CatalogWrite'
local Contract = require 'Contract'
local PathForms = require 'PathForms'
local PhotoLookup = require 'PhotoLookup'
local DevelopBatch = require 'DevelopBatch'
local DevelopCurves = require 'DevelopCurves'
local DevelopReadBack = require 'DevelopReadBack'
local DevelopSession = require 'DevelopSession'
local AIMaskCompute = require 'AIMaskCompute'
local GuardedMaskWrite = require 'GuardedMaskWrite'
local Log = require 'Log'
local JSON = require 'JSON'
local JsonValue = require 'JsonValue'
local Reply = require 'Reply'

local DevelopHandler = {}

local SETTINGS_BATCH_RESERVE_SECONDS = 10

local function batchReserve(gates, computesAIMasks)
    return SETTINGS_BATCH_RESERVE_SECONDS + gates * CatalogWrite.WAIT_SECONDS
        + (computesAIMasks and Contract.AI_MASK_COMPUTE_WAIT_SECONDS or 0)
end
local STYLE_KEYS = {}
for _, key in ipairs(Contract.DEVELOP_KEYS) do
    if key.style then STYLE_KEYS[key.name] = true end
end

local function idStrings(values)
    local ids = {}
    for index, value in ipairs(values) do ids[index] = tostring(value) end
    return ids
end

local function callPresetMethod(preset, methodName)
    local method = preset and preset[methodName]
    if type(method) ~= "function" then
        return nil
    end
    local ok, value = pcall(method, preset)
    if not ok then
        return nil
    end
    return value
end

local function presetEntry(preset, folder, scope)
    return {
        preset = preset,
        name = callPresetMethod(preset, "getName"),
        folder = folder,
        scope = scope,
        uuid = callPresetMethod(preset, "getUuid"),
        file = callPresetMethod(preset, "getFile"),
    }
end

local function allDevelopPresetEntries()
    local entries = {}
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
        for _, preset in ipairs(folder:getDevelopPresets()) do
            table.insert(entries, presetEntry(preset, folder:getName(), "lightroom"))
        end
    end

    if _PLUGIN and type(LrApplication.getDevelopPresetsForPlugin) == "function" then
        local pluginPresets = LrApplication.getDevelopPresetsForPlugin(_PLUGIN) or {}
        for _, preset in ipairs(pluginPresets) do
            table.insert(entries, presetEntry(preset, "Plugin Develop Presets", "plugin"))
        end
    end

    return entries
end

local function presetSummary(entry)
    return {
        name = entry.name,
        folder = entry.folder,
        scope = entry.scope,
        uuid = entry.uuid,
        file = entry.file,
    }
end

local function sharesOneUuid(matches)
    local uuid = matches[1].uuid
    if uuid == nil then
        return false
    end
    for index = 2, #matches do
        if matches[index].uuid ~= uuid then
            return false
        end
    end
    return true
end

local function findPreset(args)
    local matches = {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        local uuidMatches = args.preset_uuid == nil or entry.uuid == args.preset_uuid
        local nameMatches = args.preset_name == nil or entry.name == args.preset_name
        local folderMatches = args.preset_folder == nil or entry.folder == args.preset_folder
        local scopeMatches = args.preset_scope == nil or entry.scope == args.preset_scope
        if uuidMatches and nameMatches and folderMatches and scopeMatches then
            table.insert(matches, entry)
        end
    end
    if #matches == 0 then
        Reply.refuse("Preset not found")
    end
    -- Lightroom can expose the same preset more than once (for example, as a
    -- favourite and in its original group). Those aliases share one UUID, so
    -- a UUID selector is still exact even when the flattened folder list has
    -- multiple entries for it.
    if #matches > 1 and args.preset_uuid == nil and not sharesOneUuid(matches) then
        Reply.refuse("Preset selector is ambiguous; provide preset_uuid or preset_folder")
    end
    return matches[1]
end

local function cloneSerializable(value, depth, seen)
    local valueType = type(value)
    if valueType == "number" or valueType == "string" or valueType == "boolean" then
        return value, true
    end
    if valueType ~= "table" or depth >= 6 or seen[value] then
        return nil, false
    end

    seen[value] = true
    local out = {}
    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then
            seen[value] = nil
            return nil, false
        end
        count = count + 1
        if count > 2000 then
            seen[value] = nil
            return nil, false
        end
        local cloned, supported = cloneSerializable(item, depth + 1, seen)
        if not supported then
            seen[value] = nil
            return nil, false
        end
        out[key] = cloned
    end
    seen[value] = nil
    return out, true
end

local function normalizedPresetSettings(preset)
    local settings = callPresetMethod(preset, "getSetting")
    if type(settings) ~= "table" then
        Reply.refuse("Preset settings are unavailable")
    end
    local normalized, supported = cloneSerializable(settings, 0, {})
    if not supported then
        Reply.refuse("Preset settings contain unsupported nested values")
    end
    return normalized
end

-- Lightroom mints a fresh CorrectionID/MaskID on every getSetting() call, so
-- they identify a read rather than the preset. Comparing them made every
-- masked preset (all the Adaptive/AI ones) differ from itself.
local VOLATILE_SETTING_KEYS = {
    CorrectionID = true,
    MaskID = true,
}

local function withoutVolatileIds(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        if not VOLATILE_SETTING_KEYS[key] then
            out[key] = withoutVolatileIds(item)
        end
    end
    return out
end

function DevelopHandler.listDevelopPresets(args)
    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0
    local query = args.query and LrStringUtils.lower(args.query)
    local out = {}
    local count = 0
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if (not args.folder or entry.folder == args.folder)
            and (not query or LrStringUtils.lower(entry.name or ""):find(query, 1, true)) then
            count = count + 1
            if count > offset and #out < limit then
                table.insert(out, {
                    name = entry.name,
                    folder = entry.folder,
                    scope = entry.scope,
                    uuid = entry.uuid,
                })
            end
        end
    end

    Log.info(string.format("Listed %d develop presets", #out))

    return {
        presets = out,
        count = count,
        has_more = offset + #out < count,
    }
end

function DevelopHandler.getDevelopPreset(args)
    local entry = findPreset(args)
    local settings = normalizedPresetSettings(entry.preset)
    local result = presetSummary(entry)
    result.settings = settings
    result.setting_count = #JsonValue.sortedKeys(settings)
    return result
end

function DevelopHandler.compareDevelopPresets(args)
    local base = findPreset(args.base)
    local candidate = findPreset(args.candidate)
    local baseSettings = normalizedPresetSettings(base.preset)
    local candidateSettings = normalizedPresetSettings(candidate.preset)
    local keys = {}
    for key, _ in pairs(baseSettings) do keys[key] = true end
    for key, _ in pairs(candidateSettings) do keys[key] = true end

    local keyList = {}
    for key, _ in pairs(keys) do table.insert(keyList, key) end
    table.sort(keyList)

    local changes = {}
    for _, key in ipairs(keyList) do
        local before = withoutVolatileIds(baseSettings[key])
        local after = withoutVolatileIds(candidateSettings[key])
        if not JsonValue.equal(before, after) then
            local change = {
                key = key,
                before_present = baseSettings[key] ~= nil,
                after_present = candidateSettings[key] ~= nil,
            }
            if before ~= nil then change.before = before end
            if after ~= nil then change.after = after end
            table.insert(changes, change)
        end
    end

    return {
        base = presetSummary(base),
        candidate = presetSummary(candidate),
        changes = changes,
        changed_count = #changes,
    }
end

function DevelopHandler.createDevelopPreset(args)
    args.photo_id = tostring(args.photo_id)

    if not _PLUGIN or type(LrApplication.addDevelopPresetForPlugin) ~= "function" then
        Reply.refuse("Plugin preset creation is unavailable")
    end
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if entry.scope == "plugin" and entry.name == args.preset_name then
            Reply.refuse("Plugin preset already exists; use a versioned preset_name")
        end
    end

    local catalog = LrApplication.activeCatalog()
    local sourceSettings
    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    catalog:withReadAccessDo(function()
        sourceSettings = photo:getDevelopSettings()
    end)

    local presetSettings = {}
    for _, key in ipairs(args.settings) do
        local value = DevelopCurves.read(sourceSettings, key)
        if value == nil then
            Reply.refuse("Source photo has no develop setting: " .. key)
        end
        presetSettings[key] = value
    end
    presetSettings = DevelopCurves.forWrite(presetSettings)

    local preset = LrApplication.addDevelopPresetForPlugin(_PLUGIN, args.preset_name, presetSettings)
    if not preset then error("Lightroom did not create the plugin preset") end
    local entry = presetEntry(preset, "Plugin Develop Presets", "plugin")
    local result = presetSummary(entry)
    result.visible_in_develop = false
    result.message = "Created plugin-managed Develop preset checkpoint"
    Log.info(string.format("Created plugin preset %s from photo %s", args.preset_name, args.photo_id))
    return result
end

local function requireLeafFilename(filename)
    if filename == "." or filename == ".." or LrPathUtils.leafName(filename) ~= filename then
        Reply.refuse("filename must be a leaf filename without path separators")
    end
end

function DevelopHandler.exportDevelopPreset(args)
    local entry = findPreset(args)
    local source = entry.file
    if type(source) ~= "string" or source == "" or LrFileUtils.exists(source) ~= "file" then
        Reply.refuse("Preset has no exportable backing file")
    end

    local sourceExtension = LrPathUtils.extension(source)
    if type(sourceExtension) ~= "string" or sourceExtension == "" then
        Reply.refuse("Preset backing file has no extension")
    end
    local filename = args.filename or LrPathUtils.leafName(source)
    requireLeafFilename(filename)
    local requestedExtension = LrPathUtils.extension(filename)
    if requestedExtension == "" then
        filename = filename .. "." .. sourceExtension
    elseif requestedExtension:lower() ~= sourceExtension:lower() then
        Reply.refuse("filename extension must match preset backing file: ." .. sourceExtension)
    end

    local destinationDir = PathForms.absolute(args.destination_dir, "destination_dir")
    if LrFileUtils.exists(destinationDir) == false then
        LrFileUtils.createAllDirectories(destinationDir)
    end
    if LrFileUtils.exists(destinationDir) ~= "directory" then
        Reply.refuse("destination_dir is not a directory")
    end

    local destination = LrPathUtils.child(destinationDir, filename)
    if LrFileUtils.exists(destination) then
        Reply.refuse("destination preset already exists; choose a new filename")
    end
    local copied, copyError = LrFileUtils.copy(source, destination)
    if not copied then
        error("Preset export failed: " .. tostring(copyError))
    end

    local result = presetSummary(entry)
    result.destination = destination
    result.message = "Exported Develop preset without overwriting existing files"
    Log.info(string.format("Exported preset %s to %s", tostring(entry.name), destination))
    return result
end


local containsAIMasks = AIMaskData.containsAIMasks
local withoutComputedAIMaskData = AIMaskData.withoutComputedData

local function filtersOf(settings)
    local filterList = settings and settings.FilterList
    local filters = type(filterList) == "table" and filterList.Filters
    return type(filters) == "table" and filters or {}
end

local function enhanceFilterOf(settings)
    local found
    for _, filter in ipairs(filtersOf(settings)) do
        if type(filter) == "table" and filter.Name == "Enhance" then found = filter end
    end
    return found
end

local function presetContainsAIMasks(preset)
    return containsAIMasks(callPresetMethod(preset, "getSetting"))
end

local PRESET_AI_MASKS = "the preset's AI masks"

local function applyPreset(catalog, selectedPreset, photo)
    DevelopSession.flushIfShowing(catalog, photo)
    CatalogWrite.run(catalog, "Apply Develop Preset", function()
        if selectedPreset.scope == "plugin" then
            photo:applyDevelopPreset(selectedPreset.preset, _PLUGIN)
        else
            photo:applyDevelopPreset(selectedPreset.preset)
        end
    end)
end

local DRY_RUN_DETAIL_LIMIT = 5
local DRY_RUN_DETAIL_BUDGET = 12000
local DRY_RUN_MISSING_BUDGET = 4000

local function previewValue(value)
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return { type = "table", entries = count }
    end
    if type(value) == "string" and #value > 128 then
        return { type = "string", length = #value, prefix = value:sub(1, 128) }
    end
    return value
end

local function previewDevelopSettings(catalog, resolved, settings, declaredPresetOnly, masks)
    if masks then
        local planned = { MaskGroupBasedCorrections = masks }
        for key, value in pairs(settings) do
            if key ~= "MaskGroupBasedCorrections" then planned[key] = value end
        end
        settings = planned
    end
    local result = {
        dry_run = true,
        targets = 0,
        changed_targets = 0,
        missing = {},
        missing_count = 0,
        missing_indices = {},
        missing_truncated = false,
        details = {},
        detail_limit = DRY_RUN_DETAIL_LIMIT,
        detail_truncated = false,
        setting_totals = {},
    }
    if declaredPresetOnly then
        result.preview_scope = "readable_declared_preset_settings"
        result.unknown_current_totals = {}
        result.unknown_effects = { "SDK-generated values, including GrainSeed", "Preset bookkeeping" }
    end
    local keys = JsonValue.sortedKeys(settings)
    local normalized = withoutVolatileIds(withoutComputedAIMaskData(settings))
    local detailBytes, missingBytes = 0, 0
    for index, entry in ipairs(resolved) do
        if not entry.photo then
            result.missing_count = result.missing_count + 1
            result.missing_indices[#result.missing_indices + 1] = index
            local id = tostring(entry.id)
            local bytes = #JSON:encode(id)
            if not result.missing_truncated and missingBytes + bytes <= DRY_RUN_MISSING_BUDGET then
                result.missing[#result.missing + 1] = id
                missingBytes = missingBytes + bytes
            else
                result.missing_truncated = true
            end
        else
            result.targets = result.targets + 1
            local current
            catalog:withReadAccessDo(function() current = entry.photo:getDevelopSettings() end)
            current = withoutVolatileIds(withoutComputedAIMaskData(current))
            if masks and current.MaskGroupBasedCorrections == nil then current.MaskGroupBasedCorrections = {} end
            local detail = { id = tostring(entry.id), changes = {} }
            local changed = false
            for _, key in ipairs(keys) do
                if declaredPresetOnly and current[key] == nil then
                    result.unknown_current_totals[key] = (result.unknown_current_totals[key] or 0) + 1
                elseif not JsonValue.equal(current[key], normalized[key]) then
                    changed = true
                    result.setting_totals[key] = (result.setting_totals[key] or 0) + 1
                    detail.changes[#detail.changes + 1] = {
                        key = key,
                        before_present = current[key] ~= nil,
                        after_present = normalized[key] ~= nil,
                        before = previewValue(current[key]),
                        after = previewValue(normalized[key]),
                    }
                end
            end
            if changed then result.changed_targets = result.changed_targets + 1 end
            if #result.details < DRY_RUN_DETAIL_LIMIT then
                local bytes = #JSON:encode(detail)
                if detailBytes + bytes <= DRY_RUN_DETAIL_BUDGET then
                    result.details[#result.details + 1] = detail
                    detailBytes = detailBytes + bytes
                else
                    result.detail_truncated = true
                end
            else
                result.detail_truncated = true
            end
        end
    end
    while #result.details > 0 and #JSON:encode(result) > 20000 do
        table.remove(result.details)
        result.detail_truncated = true
    end
    while #result.missing > 0 and #JSON:encode(result) > 20000 do
        table.remove(result.missing)
        result.missing_truncated = true
    end
    return result
end

local function requireAIMaskCompute(toolName, entries)
    if entries[1] then AIMaskCompute.requireSupported(toolName, entries[1].photo) end
end

function DevelopHandler.applyDevelopPreset(args, context)
    args.photo_ids = idStrings(args.photo_ids)
    local selectedPreset = findPreset(args)

    local catalog = LrApplication.activeCatalog()
    local appliedCount = 0

    -- Resolve outside the write gate: the lookup scans the catalog and does
    -- not write, so holding the exclusive gate across it only serializes
    -- every other handler behind it.
    local entries, missingIds, resolved = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if args.dry_run then
        return previewDevelopSettings(catalog, resolved, normalizedPresetSettings(selectedPreset.preset), true)
    end
    local written = {}
    local presetSettings = normalizedPresetSettings(selectedPreset.preset)
    local aiPreset = presetContainsAIMasks(selectedPreset.preset)
    if aiPreset then requireAIMaskCompute(context.title, entries) end
    local reserveSeconds = batchReserve(aiPreset and 2 or 1, aiPreset)

    local remaining, failed, unknown = {}, {}, {}
    local stopped = false
    local aiUpdated = 0
    for _, resolvedEntry in ipairs(entries) do
        local photo = resolvedEntry.photo
        if stopped or #remaining > 0 or context:stopping(reserveSeconds) then
            remaining[#remaining + 1] = resolvedEntry.id
        else
            local photoId = tostring(photo.localIdentifier)
            local entriesBefore = aiPreset and GuardedMaskWrite.readEntries(catalog, photo)
            local applied, applyError = LrTasks.pcall(applyPreset, catalog, selectedPreset, photo)
            if not applied and Reply.refusalOf(applyError) then
                failed[#failed + 1] = { photo_id = photoId, reason = Reply.refusalOf(applyError) }
                stopped = true
            elseif not applied then
                written[#written + 1] = { photo = photo, settings = presetSettings, error = Reply.messageOf(applyError) }
                stopped = true
            else
                written[#written + 1] = { photo = photo, settings = presetSettings }
                local computed, notComputed = true, nil
                if aiPreset then
                    computed, notComputed = LrTasks.pcall(AIMaskCompute.run, context, catalog, photo,
                        { subject = PRESET_AI_MASKS, before = entriesBefore })
                    if computed then aiUpdated = aiUpdated + 1 end
                end
                if not computed then
                    unknown[#unknown + 1] = {
                        photo_id = photoId,
                        reason = Reply.messageOf(notComputed) .. "; the preset was applied, so"
                            .. " check the photo's AI masks in Develop before writing to it",
                    }
                else
                    appliedCount = appliedCount + 1
                end
            end
        end
    end

    Log.info(string.format("Applied preset %s to %d photos (AI masks recomputed: %d, not computed: %d)",
        selectedPreset.name, appliedCount, aiUpdated, #unknown))

    return DevelopReadBack.parts(DevelopReadBack.check(catalog, written), {
        applied = appliedCount,
        preset = selectedPreset.name,
        folder = selectedPreset.folder,
        scope = selectedPreset.scope,
        uuid = selectedPreset.uuid,
        ai_updated = aiUpdated,
    }, {
        failed = failed, unknown = unknown, not_found = missingIds, remaining = remaining,
    })
end

local function copyMasks(context, catalog, photo, masks, aiMasks)
    local write = { description = "Copy Develop Settings", build = function() return masks end }
    if not aiMasks then return GuardedMaskWrite.apply(catalog, photo, write).previous end
    write.subject = "the copied AI masks"
    write.replaces = true
    return AIMaskCompute.run(context, catalog, photo, write).previous
end

local function replaceMasks(context, catalog, photo, target, masks, aiMasks, processVersion, wrote)
    if processVersion ~= nil and processVersion ~= target.processVersion then
        GuardedMaskWrite.preflight(catalog, photo, processVersion)
        DevelopSession.flushIfShowing(catalog, photo)
        CatalogWrite.run(catalog, "Copy Develop Settings", function()
            wrote[#wrote + 1] = "the process version " .. tostring(processVersion)
            photo:applyDevelopSettings({ ProcessVersion = processVersion }, "Copy Develop Settings")
        end)
    end
    local previous = copyMasks(context, catalog, photo, masks, aiMasks)
    wrote[#wrote + 1] = "the masks"
    return previous
end

local function refusedBeforeWriting(err, wrote)
    return #wrote == 0 and Reply.refusalOf(err) or nil
end

local function afterWriting(wrote, reason)
    if #wrote == 0 then return reason end
    return "after " .. table.concat(wrote, " and ") .. " were written: " .. reason
end

function DevelopHandler.copyDevelopSettings(args, context)
    args.source_id = tostring(args.source_id)
    args.target_ids = idStrings(args.target_ids)

    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local source = PhotoLookup.requireOne(catalog, args.source_id)
    catalog:withReadAccessDo(function()
        sourceSettings = source:getDevelopSettings()
    end)

    local toApply = {}
    if args.settings then
        for _, key in ipairs(args.settings) do
            toApply[key] = DevelopCurves.read(sourceSettings, key)
        end
    else
        for key, value in pairs(sourceSettings) do
            if key ~= "orientation" and key ~= "FilterList" then toApply[key] = value end
        end
        local filterNames = {}
        for _, filter in ipairs(filtersOf(sourceSettings)) do
            filterNames[#filterNames + 1] = type(filter) == "table" and tostring(filter.Name) or "unnamed"
        end
        if #filterNames > 0 then
            context:warn("A full copy leaves out the source's FilterList (" .. table.concat(filterNames, ", ")
                .. "): Lightroom computes those results for each image, so each target keeps its own")
        end
    end
    if type(toApply.MaskGroupBasedCorrections) == "table" and #toApply.MaskGroupBasedCorrections > 0 then
        local safe, reason = LrTasks.pcall(GuardedMaskWrite.preflight, catalog, source)
        if not safe then
            Reply.refuse("The source masks cannot be copied safely: " .. tostring(reason)
                .. " Name the settings to copy with settings to leave masks out.")
        end
    end
    toApply = DevelopCurves.forWrite(withoutComputedAIMaskData(toApply))

    local copiedCount = 0
    local masks, rest = nil, toApply
    if not args.settings then
        masks = type(toApply.MaskGroupBasedCorrections) == "table" and toApply.MaskGroupBasedCorrections or {}
    end
    local entries, missingIds, resolved = PhotoLookup.resolveDistinct(catalog, args.target_ids)
    if args.dry_run then
        return previewDevelopSettings(catalog, resolved, toApply, false, masks)
    end
    local written = {}
    if masks then
        rest = {}
        for key, value in pairs(toApply) do
            if key ~= "MaskGroupBasedCorrections" then rest[key] = value end
        end
    end

    local aiMasks = masks ~= nil and containsAIMasks({ MaskGroupBasedCorrections = masks })
    if aiMasks then requireAIMaskCompute(context.title, entries) end
    local reserveSeconds = batchReserve(masks == nil and 1 or aiMasks and 4 or 3, aiMasks)

    local remaining, failed, computed, masksRemoved = {}, {}, {}, {}
    for _, entry in ipairs(entries) do
        if #remaining > 0 or context:stopping(reserveSeconds) then
            remaining[#remaining + 1] = entry.id
        else
            local photoId = tostring(entry.photo.localIdentifier)
            local settings
            catalog:withReadAccessDo(function() settings = entry.photo:getDevelopSettings() or {} end)
            local existing = settings.MaskGroupBasedCorrections
            local target = { processVersion = settings.ProcessVersion, maskCount = type(existing) == "table" and #existing or 0 }
            local before = args.settings and DevelopReadBack.before(settings) or nil
            local wrote = {}
            local masked, previous = true, nil
            if masks and (#masks > 0 or target.maskCount > 0) then
                masked, previous = LrTasks.pcall(replaceMasks, context, catalog, entry.photo, target, masks, aiMasks,
                    rest.ProcessVersion, wrote)
            end
            if not masked and refusedBeforeWriting(previous, wrote) then
                failed[#failed + 1] = { photo_id = photoId, reason = refusedBeforeWriting(previous, wrote) }
            elseif not masked then
                written[#written + 1] = {
                    photo = entry.photo, settings = rest,
                    error = afterWriting(wrote, "the masks could not be copied: " .. Reply.messageOf(previous)),
                }
            else
                local ok, reason = LrTasks.pcall(function()
                    DevelopSession.flushIfShowing(catalog, entry.photo)
                    CatalogWrite.run(catalog, "Copy Develop Settings", function()
                        entry.photo:applyDevelopSettings(rest, "Copy Develop Settings")
                    end)
                end)
                if ok then
                    copiedCount = copiedCount + 1
                    written[#written + 1] = { photo = entry.photo, settings = rest }
                    if aiMasks then computed[#computed + 1] = photoId end
                    if masks and #masks == 0 and previous and #previous > 0 then
                        masksRemoved[#masksRemoved + 1] = { photo_id = photoId, count = #previous }
                    end
                elseif refusedBeforeWriting(reason, wrote) then
                    failed[#failed + 1] = { photo_id = photoId, reason = refusedBeforeWriting(reason, wrote) }
                else
                    written[#written + 1] = {
                        photo = entry.photo, settings = rest, before = before,
                        error = afterWriting(wrote, tostring(reason)),
                    }
                end
            end
        end
    end

    Log.info(string.format("Copied develop settings from %s to %d photos (AI masks computed: %d)",
        args.source_id, copiedCount, #computed))

    return DevelopReadBack.parts(DevelopReadBack.check(catalog, written), {
        copied = copiedCount,
        computed = aiMasks and computed or nil,
        masks_removed = #masksRemoved > 0 and masksRemoved or nil,
    }, { failed = failed, not_found = missingIds, remaining = remaining })
end

local styleMatchSerial = 0

function DevelopHandler.matchPhotoStyle(args, context)
    local sourceId = tostring(args.reference_id)
    local targetIds = idStrings(args.target_ids)
    local catalog = LrApplication.activeCatalog()
    local source = PhotoLookup.requireOne(catalog, sourceId)
    local resolved = PhotoLookup.resolveMany(catalog, targetIds)
    for _, entry in ipairs(resolved) do
        if entry.photo and entry.photo.localIdentifier == source.localIdentifier then
            Reply.refuse('Reference photo must not appear in target_ids')
        end
    end

    local settings, grayscale = {}, nil
    catalog:withReadAccessDo(function()
        local reference = source:getDevelopSettings()
        grayscale = reference.ConvertToGrayscale == true
        for key in pairs(STYLE_KEYS) do settings[key] = DevelopCurves.read(reference, key) end
    end)
    local results, failures, unknowns, missing, written, remaining = {}, {}, {}, {}, {}, {}
    local snapshots = require 'HandlerSnapshots'
    for _, entry in ipairs(resolved) do
        if not entry.photo then
            missing[#missing + 1] = tostring(entry.id)
        elseif #remaining > 0 or context:stopping(batchReserve(2, false)) then
            remaining[#remaining + 1] = entry.id
        else
            local photoId = tostring(entry.photo.localIdentifier)
            local current
            catalog:withReadAccessDo(function() current = entry.photo:getDevelopSettings() or {} end)
            if (current.ConvertToGrayscale == true) ~= grayscale then
                failures[#failures + 1] = {
                    photo_id = photoId,
                    reason = "treatment differs from the reference; convert it with set_treatment, then match",
                }
            else
                local changed = 0
                for key, value in pairs(settings) do
                    if not JsonValue.equal(value, DevelopCurves.read(current, key)) then changed = changed + 1 end
                end
                styleMatchSerial = styleMatchSerial + 1
                local name = string.format('Style match from %s at %.3f #%d',
                    tostring(source.localIdentifier), LrDate.currentTime(), styleMatchSerial)
                local snapshot
                local ok, reason = LrTasks.pcall(function()
                    snapshot = snapshots.create({ photo_id = photoId, name = name }).snapshot
                    DevelopSession.flushIfShowing(catalog, entry.photo)
                    CatalogWrite.run(catalog, 'Match Photo Style', function()
                        entry.photo:applyDevelopSettings(DevelopCurves.forWrite(settings))
                    end)
                    written[#written + 1] = { photo = entry.photo, settings = settings }
                    results[#results + 1] = { photo_id = photoId, snapshot = snapshot, settings_changed = changed }
                end)
                if not ok then
                    if snapshot then
                        written[#written + 1] = {
                            photo = entry.photo, settings = settings,
                            error = Reply.messageOf(reason) .. "; the style was not confirmed stored and recovery"
                                .. " snapshot " .. tostring(snapshot.name) .. " was kept",
                        }
                    elseif Reply.refusalOf(reason) then
                        failures[#failures + 1] = { photo_id = photoId, reason = Reply.refusalOf(reason) }
                    else
                        unknowns[#unknowns + 1] = {
                            photo_id = photoId,
                            reason = Reply.messageOf(reason) .. "; a recovery snapshot may have been created and the"
                                .. " style was not applied: read the photo's snapshots with list_develop_snapshots"
                                .. " before retrying",
                        }
                    end
                end
            end
        end
    end
    return DevelopReadBack.parts(DevelopReadBack.check(catalog, written),
        { reference_id = tostring(source.localIdentifier), matched = #results, results = results },
        { failed = failures, unknown = unknowns, not_found = missing, remaining = remaining })
end

function DevelopHandler.setDevelopSettings(args)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)

    DevelopSession.flushIfShowing(catalog, photo)
    CatalogWrite.run(catalog, "Set Develop Settings", function()
        photo:applyDevelopSettings(DevelopCurves.forWrite(args.settings), "Set Develop Settings")
    end)
    Log.info(string.format("Set develop settings on photo %s", tostring(photo.localIdentifier)))

    local checked = DevelopReadBack.check(catalog, { { photo = photo, settings = args.settings } })
    return DevelopReadBack.parts(checked, { photo_id = checked[1].photo_id, settings = checked[1].stored })
end

-- AI Denoise is not a plain develop key: Lightroom stores it as an "Enhance"
-- filter carrying data computed for that one image, so applyDevelopSettings
-- cannot create it and copying it between photos breaks it. LrC 15 exposes
-- the Develop panel's own path instead (LrDevelopController.setEnhance /
-- changeDenoiseAmount), which only acts on the photo active in Develop.
-- So the handler drives Develop: select one photo, let the panel catch up,
-- apply, move on. Lightroom computes the denoise itself in the background.
-- The Enhance panel updates asynchronously after the active photo changes:
-- right after a switch it can still describe the previous photo, or report
-- Denoise unavailable until the new image has loaded.
local DENOISE_PANEL_SETTLE_SECONDS = 0.5
local DENOISE_PANEL_TIMEOUT_SECONDS = 8
local DENOISE_CONFIRM_TIMEOUT_SECONDS = 1.5
local DENOISE_SAVE_TIMEOUT_SECONDS = 5
local DENOISE_LAST_PHOTO_AND_RESTORE_SECONDS = 60

local waitFor = DevelopSession.waitFor

-- Ground truth for "already has Denoise", independent of the panel, which may
-- still describe the previously active photo. Any Enhance filter counts.
local function enhanceDigest(catalog, photo)
    local filter
    catalog:withReadAccessDo(function() filter = enhanceFilterOf(photo:getDevelopSettings()) end)
    return filter and tostring(filter.CompressedSettings or "")
end

local function waitForSavedChange(catalog, photo, before)
    return waitFor(function()
        local now = enhanceDigest(catalog, photo)
        return now ~= nil and now ~= before
    end, DENOISE_SAVE_TIMEOUT_SECONDS)
end

local function denoisePhoto(catalog, photo, amount)
    LrTasks.sleep(DENOISE_PANEL_SETTLE_SECONDS)
    local panel
    waitFor(function()
        panel = LrDevelopController.getEnhancePanelState()
        return panel ~= nil and panel.denoiseEnabled
    end, DENOISE_PANEL_TIMEOUT_SECONDS)
    local digestBefore = enhanceDigest(catalog, photo)
    local hasDenoise = digestBefore ~= nil
    if not panel then
        Reply.refuse("Develop panel state unavailable")
    elseif not panel.denoiseEnabled then
        Reply.refuse("Denoise is not available for this photo")
    elseif hasDenoise and panel.denoiseState and panel.denoiseAmount == amount then
        return { status = "unchanged" }
    elseif catalog:getTargetPhoto() ~= photo then
        Reply.refuse("another photo became active before Denoise was applied")
    end

    local change = hasDenoise and panel.denoiseState and true or false
    if change then
        LrDevelopController.changeDenoiseAmount(amount)
    else
        LrDevelopController.setEnhance("denoise", true, amount)
    end
    local confirmed = waitFor(function()
        local now = LrDevelopController.getEnhancePanelState()
        return catalog:getTargetPhoto() == photo
            and now ~= nil and now.denoiseState and now.denoiseAmount == amount
    end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
    if not confirmed then
        error("the Develop panel did not show the new amount; check this photo", 0)
    end
    if not waitForSavedChange(catalog, photo, digestBefore) then
        local reverted = change
        if change then
            LrTasks.pcall(function() LrDevelopController.changeDenoiseAmount(panel.denoiseAmount) end)
            reverted = waitFor(function()
                local now = LrDevelopController.getEnhancePanelState()
                return now ~= nil and now.denoiseAmount == panel.denoiseAmount
            end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
        end
        local savedSince = waitFor(function()
            return enhanceDigest(catalog, photo) ~= digestBefore
        end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
        if reverted and not savedSince then
            Reply.refuse("Lightroom did not save the change; it can drop a change made while it is still computing"
                .. " Denoise for this photo. Call again once the Activity Center is idle.")
        end
        error("Lightroom did not confirm saving the Denoise change in time and may have saved it since;"
            .. " read this photo's Denoise state before retrying", 0)
    end
    return {
        status = change and "amount_changed" or "applied",
        previous_amount = change and panel.denoiseAmount or nil,
    }
end

function DevelopHandler.applyDenoise(args, context)
    local amount = args.amount
    DevelopSession.requireControllerFunctions("apply_denoise",
        { "getEnhancePanelState", "setEnhance", "changeDenoiseAmount" }, "Lightroom Classic 15")

    local catalog = LrApplication.activeCatalog()
    local reply = DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = args.restore_selection ~= false,
        reserveSeconds = DENOISE_LAST_PHOTO_AND_RESTORE_SECONDS,
        prepare = function()
            DevelopSession.openDevelop(function() return LrDevelopController.getEnhancePanelState() ~= nil end)
        end,
        each = function(photo, state)
            if not DevelopSession.activate(catalog, photo, state) then
                Reply.refuse("could not select the photo in Develop")
            end
            return denoisePhoto(catalog, photo, amount)
        end,
    })
    if reply.data then
        context:warn("Denoise runs in Lightroom's background; the Activity Center shows progress.")
    end
    return reply
end

local PROCESS_VERSION_PHOTO_AND_RESTORE_SECONDS = 60

local PROCESS_VERSIONS = {
    ["Version 1"] = 1, ["Version 2"] = 2, ["Version 3"] = 3,
    ["Version 4"] = 4, ["Version 5"] = 5, ["Version 6"] = 6,
}

local function refuseMaskedDowngrade(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = photo:getDevelopSettings() end)
    if type(settings) ~= "table" then
        Reply.refuse("Could not check the photo's masks before downgrading")
    end
    local masks = settings.MaskGroupBasedCorrections
    if masks ~= nil and type(masks) ~= "table" then
        Reply.refuse("Could not read the photo's masks before downgrading")
    end
    if masks and next(masks) ~= nil then
        Reply.refuse("Process-version downgrades are refused on photos with masks;"
            .. " keep the current version to preserve mask editing")
    end
end

local function changeProcessVersion(catalog, photo, version, state)
    DevelopSession.openPhoto(catalog, photo, state)
    local previous = LrDevelopController.getProcessVersion()
    if not PROCESS_VERSIONS[previous] then
        Reply.refuse("Lightroom returned an unknown process version")
    end
    if previous == version then
        return { status = "unchanged", previous_version = previous, new_version = previous }
    end
    if PROCESS_VERSIONS[version] < PROCESS_VERSIONS[previous] then refuseMaskedDowngrade(catalog, photo) end
    if catalog:getTargetPhoto() ~= photo then
        Reply.refuse("another photo became active before the version change")
    end
    LrDevelopController.setProcessVersion(version)
    local confirmed = DevelopSession.waitFor(function()
        return catalog:getTargetPhoto() == photo and LrDevelopController.getProcessVersion() == version
    end, 5)
    if not confirmed then
        local current = catalog:getTargetPhoto() == photo and LrDevelopController.getProcessVersion() or "unreadable"
        error("Lightroom did not confirm " .. version .. "; the photo reads " .. tostring(current), 0)
    end
    return { status = "changed", previous_version = previous, new_version = version }
end

function DevelopHandler.setProcessVersion(args, context)
    DevelopSession.requireControllerFunctions("set_process_version", { "getProcessVersion", "setProcessVersion" })
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = args.restore_selection ~= false,
        reserveSeconds = PROCESS_VERSION_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state) return changeProcessVersion(catalog, photo, args.version, state) end,
    })
end

local AUTO_TONE_KEYS = {
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012",
    "Vibrance", "Saturation",
}
local AUTO_WHITE_BALANCE_KEYS = { "WhiteBalance", "Temperature", "Tint" }
local AUTO_PHOTO_AND_RESTORE_SECONDS = 60
local AUTO_SETTLE_TIMEOUT_SECONDS = Contract.AUTO_CHANGE_WAIT_SECONDS

local function autoValues(catalog, photo, keys)
    local values = {}
    catalog:withReadAccessDo(function()
        local settings = photo:getDevelopSettings()
        for _, key in ipairs(keys) do values[key] = settings[key] end
    end)
    return values
end

local function sameAutoValues(first, second, keys)
    for _, key in ipairs(keys) do
        if first[key] ~= second[key] then return false end
    end
    return true
end

local function autoOperation(catalog, photo, name, keys, apply)
    local before = autoValues(catalog, photo, keys)
    apply()
    DevelopSession.flushPendingEdits()
    local previous, stable, elapsed = before, 0, 0
    local settled = waitFor(function()
        if catalog:getTargetPhoto() ~= photo then
            error("another photo became active while applying Auto", 0)
        end
        local current = autoValues(catalog, photo, keys)
        stable = sameAutoValues(previous, current, keys) and stable + 0.1 or 0
        previous = current
        elapsed = elapsed + 0.1
        return elapsed >= 2 and stable >= 1 and not sameAutoValues(before, current, keys)
    end, AUTO_SETTLE_TIMEOUT_SECONDS)
    if settled then return end
    if sameAutoValues(before, previous, keys) then
        error(string.format("%s was requested but no change was observed within %d s; it may still be applied,"
            .. " so read this photo's settings before writing to it", name, AUTO_SETTLE_TIMEOUT_SECONDS), 0)
    end
    error("Auto settings did not settle; check this photo before retrying", 0)
end

local function autoPhoto(catalog, photo, args)
    if args.tone then
        autoOperation(catalog, photo, "Auto Tone", AUTO_TONE_KEYS, LrDevelopController.setAutoTone)
    end
    if args.white_balance then
        autoOperation(catalog, photo, "Auto White Balance", AUTO_WHITE_BALANCE_KEYS,
            LrDevelopController.setAutoWhiteBalance)
    end
    return { status = "applied" }
end

function DevelopHandler.applyAutoAdjustments(args, context)
    local autoFunctions = {}
    if args.tone then autoFunctions[#autoFunctions + 1] = "setAutoTone" end
    if args.white_balance then autoFunctions[#autoFunctions + 1] = "setAutoWhiteBalance" end
    DevelopSession.requireControllerFunctions("apply_auto_adjustments", autoFunctions, "Lightroom Classic 7.4")
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = AUTO_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state)
            DevelopSession.openPhoto(catalog, photo, state)
            return autoPhoto(catalog, photo, args)
        end,
    })
end

local RESET_PHOTO_AND_RESTORE_SECONDS = 60

function DevelopHandler.resetDevelopAdjustments(args, context)
    DevelopSession.requireControllerFunctions("reset_develop_adjustments", { "resetAllDevelopAdjustments" })
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESET_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state)
            DevelopSession.openPhoto(catalog, photo, state)
            LrDevelopController.resetAllDevelopAdjustments()
            DevelopSession.flushPendingEdits()
            return { status = "reset" }
        end,
    })
end

return DevelopHandler
