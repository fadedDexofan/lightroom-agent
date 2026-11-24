local LrApplication = import "LrApplication"
local LrDate = import "LrDate"
local LrDevelopController = import "LrDevelopController"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrStringUtils = import "LrStringUtils"
local LrTasks = import "LrTasks"

local AIMaskData = require "AIMaskData"
local CatalogWrite = require "CatalogWrite"
local Contract = require "Contract"
local PathForms = require "PathForms"
local PhotoBatch = require "PhotoBatch"
local PhotoLookup = require "PhotoLookup"
local ProfileLook = require "ProfileLook"
local SettingsChanges = require "SettingsChanges"
local DevelopBatch = require "DevelopBatch"
local DevelopCurves = require "DevelopCurves"
local DevelopReadBack = require "DevelopReadBack"
local DevelopSession = require "DevelopSession"
local AIMaskCompute = require "AIMaskCompute"
local GuardedMaskWrite = require "GuardedMaskWrite"
local HandlerSnapshots = require "HandlerSnapshots"
local Log = require "Log"
local MaskWriteAdmission = require "MaskWriteAdmission"
local JSON = require "JSON"
local JsonValue = require "JsonValue"
local Reply = require "Reply"

local DevelopHandler = {}

local SETTINGS_BATCH_RESERVE_SECONDS = 10

local function batchReserve(gates, computesAIMasks)
    return SETTINGS_BATCH_RESERVE_SECONDS
        + gates * CatalogWrite.WAIT_SECONDS
        + (computesAIMasks and Contract.AI_MASK_COMPUTE_WAIT_SECONDS or 0)
end

local function verifiedIds(checked)
    local ids = {}
    for _, result in ipairs(checked) do
        if DevelopReadBack.confirmed(result) then ids[#ids + 1] = result.photo_id end
    end
    return ids
end

local function savedOf(catalog, photo)
    local settings
    catalog:withReadAccessDo(function() settings = DevelopReadBack.saved(photo) end)
    return settings
end
local STYLE_KEYS = {}
for _, key in ipairs(Contract.DEVELOP_KEYS) do
    if key.style then STYLE_KEYS[key.name] = true end
end

local function callPresetMethod(preset, methodName)
    local method = preset and preset[methodName]
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method, preset)
    if not ok then return nil end
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

    for _, preset in ipairs(LrApplication.getDevelopPresetsForPlugin(_PLUGIN) or {}) do
        table.insert(entries, presetEntry(preset, "Plugin Develop Presets", "plugin"))
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
    if uuid == nil then return false end
    for index = 2, #matches do
        if matches[index].uuid ~= uuid then return false end
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
        if uuidMatches and nameMatches and folderMatches and scopeMatches then table.insert(matches, entry) end
    end
    if #matches == 0 then Reply.refuse("Preset not found") end
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
    if valueType == "number" or valueType == "string" or valueType == "boolean" then return value, true end
    if valueType ~= "table" or depth >= 6 or seen[value] then return nil, false end

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
    if type(settings) ~= "table" then Reply.refuse("Preset settings are unavailable") end
    local normalized, supported = cloneSerializable(settings, 0, {})
    if not supported then Reply.refuse("Preset settings contain unsupported nested values") end
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
        if not VOLATILE_SETTING_KEYS[key] then out[key] = withoutVolatileIds(item) end
    end
    return out
end

local ASCII_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

local function isPunctuationOnly(token)
    for index = 1, #token do
        if not ASCII_PUNCTUATION:find(token:sub(index, index), 1, true) then return false end
    end
    return true
end

local function queryTokens(query)
    local tokens = {}
    for token in LrStringUtils.lower(query):gmatch("%S+") do
        if not isPunctuationOnly(token) then tokens[#tokens + 1] = token end
    end
    if #tokens == 0 then
        Reply.refuse(
            "The query "
                .. string.format("%q", query)
                .. " has no word to search: it holds only ASCII punctuation"
                .. " and spaces; leave query out to list every preset"
        )
    end
    return tokens
end

local function presetMatches(entry, tokens)
    local text = LrStringUtils.lower(tostring(entry.folder or "") .. " " .. (entry.name or ""))
    for _, token in ipairs(tokens) do
        if not text:find(token, 1, true) then return false end
    end
    return true
end

function DevelopHandler.listDevelopPresets(args)
    local limit = args.limit or Contract.DEFAULT_PAGE_LIMIT
    local offset = args.offset or 0
    local tokens = args.query and queryTokens(args.query)
    local out = {}
    local count = 0
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if (not args.folder or entry.folder == args.folder) and (not tokens or presetMatches(entry, tokens)) then
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
    for key, _ in pairs(baseSettings) do
        keys[key] = true
    end
    for key, _ in pairs(candidateSettings) do
        keys[key] = true
    end

    local keyList = {}
    for key, _ in pairs(keys) do
        table.insert(keyList, key)
    end
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

function DevelopHandler.createDevelopPreset(args, context)
    for _, entry in ipairs(allDevelopPresetEntries()) do
        if entry.scope == "plugin" and entry.name == args.preset_name then
            Reply.refuse("Plugin preset already exists; use a versioned preset_name")
        end
    end

    local catalog = LrApplication.activeCatalog()
    local sourceSettings
    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local photo = PhotoLookup.requireOne(catalog, args.photo_ids[1])
    sourceSettings = savedOf(catalog, photo)

    local presetSettings = {}
    for _, key in ipairs(args.settings) do
        local value = DevelopCurves.read(sourceSettings, key)
        if value == nil then Reply.refuse("Source photo has no develop setting: " .. key) end
        presetSettings[key] = value
    end
    presetSettings = DevelopCurves.forWrite(presetSettings)

    local preset = CatalogWrite.invoke(
        context,
        "the plugin preset " .. args.preset_name,
        LrApplication.addDevelopPresetForPlugin,
        _PLUGIN,
        args.preset_name,
        presetSettings
    )
    if not preset then error("Lightroom did not create the plugin preset") end
    local entry = presetEntry(preset, "Plugin Develop Presets", "plugin")
    local result = presetSummary(entry)
    result.visible_in_develop = false
    result.message = "Created plugin-managed Develop preset checkpoint"
    Log.info(string.format("Created plugin preset %s from photo %s", args.preset_name, args.photo_ids[1]))
    return result
end

local function requireLeafFilename(filename)
    if filename == "." or filename == ".." or LrPathUtils.leafName(filename) ~= filename then
        Reply.refuse("filename must be a leaf filename without path separators")
    end
end

function DevelopHandler.exportDevelopPreset(args, context)
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
    CatalogWrite.createFolder(context, destinationDir)
    if LrFileUtils.exists(destinationDir) ~= "directory" then Reply.refuse("destination_dir is not a directory") end

    local destination = LrPathUtils.child(destinationDir, filename)
    if LrFileUtils.exists(destination) then Reply.refuse("destination preset already exists; choose a new filename") end
    CatalogWrite.copyFile(context, source, destination)

    local result = presetSummary(entry)
    result.destination = destination
    result.message = "Exported Develop preset without overwriting existing files"
    Log.info(string.format("Exported preset %s to %s", tostring(entry.name), destination))
    return result
end

local containsAIMasks = AIMaskData.containsAIMasks
local withoutComputedAIMaskData = AIMaskData.withoutComputedData

local function filtersOf(settings)
    local filterList = settings.FilterList
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

local function presetContainsAIMasks(preset) return containsAIMasks(callPresetMethod(preset, "getSetting")) end

local PRESET_AI_MASKS = "the preset's AI masks"

local function applyPreset(context, catalog, selectedPreset, photo)
    CatalogWrite.run(context, catalog, "Apply Develop Preset", function()
        if selectedPreset.scope == "plugin" then
            CatalogWrite.call(context, photo, "applyDevelopPreset", selectedPreset.preset, _PLUGIN)
        else
            CatalogWrite.call(context, photo, "applyDevelopPreset", selectedPreset.preset)
        end
    end)
end

local DRY_RUN_DETAIL_LIMIT = 5
local DRY_RUN_DETAIL_BUDGET = 12000
local DRY_RUN_MISSING_BUDGET = 4000

local function previewValue(value)
    if type(value) == "table" then
        local count = 0
        for _ in pairs(value) do
            count = count + 1
        end
        return { type = "table", entries = count }
    end
    if type(value) == "string" and #value > 128 then
        return { type = "string", length = #value, prefix = value:sub(1, 128) }
    end
    return value
end

local function previewDevelopSettings(catalog, resolved, settings, declaredPresetOnly, masks, extraChange)
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
            local current = withoutVolatileIds(withoutComputedAIMaskData(savedOf(catalog, entry.photo)))
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
            local extra = extraChange and extraChange(entry.photo, current)
            if extra then
                changed = true
                result.setting_totals[extra.key] = (result.setting_totals[extra.key] or 0) + 1
                detail.changes[#detail.changes + 1] = extra
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

function DevelopHandler.applyDevelopPreset(args, context)
    local selectedPreset = findPreset(args)

    local catalog = LrApplication.activeCatalog()

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
    local reserveSeconds = batchReserve(aiPreset and 2 or 1, aiPreset)

    local remaining = {}
    local stopped = false
    local aiUpdated = 0
    for _, resolvedEntry in ipairs(entries) do
        local photo = resolvedEntry.photo
        if stopped or #remaining > 0 or context:stopping(reserveSeconds) then
            remaining[#remaining + 1] = resolvedEntry.id
        else
            local from = context.ledger:mark()
            local entriesBefore, before
            local applied, problem = LrTasks.pcall(function()
                before = DevelopReadBack.before(savedOf(catalog, photo))
                entriesBefore = aiPreset and GuardedMaskWrite.readEntries(catalog, photo)
                applyPreset(context, catalog, selectedPreset, photo)
            end)
            local computed = applied
            if applied and aiPreset then
                local notComputed
                computed, notComputed = LrTasks.pcall(
                    AIMaskCompute.run,
                    context,
                    catalog,
                    photo,
                    { subject = PRESET_AI_MASKS, before = entriesBefore }
                )
                if computed then
                    aiUpdated = aiUpdated + 1
                else
                    problem = Reply.messageOf(notComputed)
                        .. "; check the photo's AI masks in Develop before writing to it"
                end
            end
            if computed then
                written[#written + 1] = { photo = photo, settings = presetSettings, before = before }
            else
                written[#written + 1] = {
                    photo = photo,
                    settings = presetSettings,
                    before = before,
                    error = Reply.messageOf(problem),
                    from = from,
                    to = context.ledger:mark(),
                }
                stopped = not applied
            end
        end
    end

    local checked = DevelopReadBack.check(context, catalog, written)
    local appliedCount = #verifiedIds(checked)
    Log.info(
        string.format(
            "Applied preset %s to %d photos (AI masks recomputed: %d)",
            selectedPreset.name,
            appliedCount,
            aiUpdated
        )
    )

    return DevelopReadBack.parts(checked, {
        applied = appliedCount,
        preset = selectedPreset.name,
        folder = selectedPreset.folder,
        scope = selectedPreset.scope,
        uuid = selectedPreset.uuid,
        ai_updated = aiUpdated,
    }, { not_found = missingIds, remaining = remaining })
end

local function isOurs(entry, profile)
    local read, text = LrTasks.pcall(LrFileUtils.readFile, entry.file)
    if not read or type(text) ~= "string" or not text:find('crs:UUID="' .. profile.preset_uuid .. '"', 1, true) then
        return false
    end
    local declared = callPresetMethod(entry.preset, "getSetting")
    local look = type(declared) == "table" and declared.Look
    return type(look) == "table" and look.UUID == profile.look_uuid
end

local function profilePreset(profile)
    local matches, seen = {}, {}
    for _, entry in ipairs(allDevelopPresetEntries()) do
        local alias = entry.uuid ~= nil and seen[entry.uuid]
        if
            not alias
            and entry.scope == "lightroom"
            and entry.folder == Contract.PROFILE_PRESET_GROUP
            and entry.name == profile.preset_name
        then
            matches[#matches + 1] = entry
            if entry.uuid ~= nil then seen[entry.uuid] = true end
        end
    end
    local where = profile.preset_name .. " in " .. Contract.PROFILE_PRESET_GROUP
    if #matches == 0 then
        Reply.refuse("Lightroom lists no preset " .. where .. ": reinstall the plug-in, then restart Lightroom")
    end
    if #matches > 1 then
        Reply.refuse(
            "Lightroom lists two presets "
                .. where
                .. ": remove the one that is not lightroom-agent's, then restart Lightroom"
        )
    end
    if not isOurs(matches[1], profile) then
        Reply.refuse(
            "The preset "
                .. where
                .. " is not lightroom-agent's: rename or remove it, then reinstall the plug-in and restart Lightroom"
        )
    end
    return matches[1]
end

function DevelopHandler.setProfile(args, context)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_ids[1])
    if args.profile ~= nil then
        local profile = ProfileLook.adobeRaw(args.profile)
        local preset = profilePreset(profile)
        local before
        CatalogWrite.run(context, catalog, "Set Profile", function()
            before = JsonValue.of(DevelopReadBack.saved(photo))
            ProfileLook.requireNamedTarget(photo:getRawMetadata("fileFormat"), before)
            CatalogWrite.call(context, photo, "applyDevelopPreset", preset.preset)
        end)
        local after = DevelopReadBack.afterWrite(context, catalog, photo)
        ProfileLook.requireNamed(before, after, profile)
        return ProfileLook.answer(photo, after)
    end
    local amount = args.amount / 100
    local before
    CatalogWrite.developSettings(context, catalog, photo, "Set Profile Amount", function()
        before = JsonValue.of(DevelopReadBack.saved(photo))
        return { Look = ProfileLook.withAmount(ProfileLook.requireAmountTarget(before), amount) }
    end)
    local after = DevelopReadBack.afterWrite(context, catalog, photo)
    ProfileLook.requireAmount(before, after, amount)
    return ProfileLook.answer(photo, after)
end

local function copyMasks(context, catalog, photo, masks, aiMasks)
    local write = { description = "Copy Develop Settings", build = function() return masks end }
    if not aiMasks then return GuardedMaskWrite.apply(context, catalog, photo, write).previous end
    write.subject = "the copied AI masks"
    write.replaces = true
    local computed = AIMaskCompute.run(context, catalog, photo, write)
    return computed.previous, AIMaskCompute.changesSince(catalog, photo, computed.settings)
end

local function replaceMasks(context, catalog, photo, target, masks, aiMasks, processVersion)
    if processVersion ~= nil and processVersion ~= target.processVersion then
        GuardedMaskWrite.precheck(catalog, photo, masks, processVersion)
        CatalogWrite.developSettings(
            context,
            catalog,
            photo,
            "Set Process Version " .. tostring(processVersion),
            function() return { ProcessVersion = processVersion } end
        )
    end
    return copyMasks(context, catalog, photo, masks, aiMasks)
end

local function identitiesOf(catalog, photos)
    local raw = catalog:batchGetRawMetadata(photos, { "fileFormat" }) or {}
    local formatted = catalog:batchGetFormattedMetadata(photos, { "cameraModel" }) or {}
    return function(photo, settings)
        return {
            kind = (raw[photo] or {}).fileFormat,
            model = (formatted[photo] or {}).cameraModel,
            settings = settings,
        }
    end
end

local function copyKeys(context, catalog, photo, settings, before, from, rest, masks, aiMasks)
    local existing = settings.MaskGroupBasedCorrections
    local target = {
        processVersion = settings.ProcessVersion,
        maskCount = type(existing) == "table" and #existing or 0,
    }
    local masked, previous, refreshed = true, nil, nil
    if masks and (#masks > 0 or target.maskCount > 0) then
        masked, previous, refreshed =
            LrTasks.pcall(replaceMasks, context, catalog, photo, target, masks, aiMasks, rest.ProcessVersion)
    end
    if not masked then
        return {
            photo = photo,
            settings = rest,
            before = before,
            from = from,
            to = context.ledger:mark(),
            error = "the masks could not be copied: " .. Reply.messageOf(previous),
        }
    end
    local ok, reason = LrTasks.pcall(function()
        CatalogWrite.developSettings(context, catalog, photo, "Copy Develop Settings", function() return rest end)
    end)
    if not ok then
        return {
            photo = photo,
            settings = rest,
            before = before,
            from = from,
            to = context.ledger:mark(),
            error = Reply.messageOf(reason),
        }
    end
    return {
        photo = photo,
        settings = rest,
        before = before,
        from = from,
        to = context.ledger:mark(),
        masksRemoved = masks and #masks == 0 and previous and #previous > 0 and #previous or nil,
        refreshed = refreshed or {},
    }
end

local function pasteProfile(context, catalog, source, sourceSettings, photo, before, clipboard)
    if source:copySettings("custom", { look = true }) == false then return "not copied" end
    clipboard.taken = true
    local mark = context.ledger:mark()
    local pasted = CatalogWrite.invoke(context, "pasteSettings", function() return photo:pasteSettings() end)
    local after = DevelopReadBack.afterWrite(context, catalog, photo)
    if pasted == false and #SettingsChanges.between(before, JsonValue.of(after)) == 0 then
        context.ledger:undone(mark)
        return "not pasted"
    end
    ProfileLook.requirePasted(before, after, sourceSettings)
    return "pasted"
end

local function maskCountOf(settings)
    local masks = settings.MaskGroupBasedCorrections
    return type(masks) == "table" and #masks or 0
end

function DevelopHandler.copyDevelopSettings(args, context)
    local catalog = LrApplication.activeCatalog()
    local sourceSettings

    -- Resolved OUTSIDE the read gate: the lookup runs catalog queries.
    local source = PhotoLookup.requireOne(catalog, args.source_photo_id)
    sourceSettings = savedOf(catalog, source)

    local profileUnit = args.settings == nil
    local toApply, absent = {}, {}
    if args.settings then
        for _, key in ipairs(args.settings) do
            if key == Contract.PROFILE_UNIT then
                profileUnit = true
            else
                toApply[key] = DevelopCurves.read(sourceSettings, key)
                if toApply[key] == nil then absent[#absent + 1] = key end
            end
        end
        if #absent > 0 and not profileUnit and next(toApply) == nil then
            Reply.refuse("The source has no " .. table.concat(absent, ", ") .. ": nothing to copy")
        end
    else
        for key, value in pairs(sourceSettings) do
            if key ~= "orientation" and key ~= "FilterList" and not ProfileLook.inFamily(key) then
                toApply[key] = value
            end
        end
        local filterNames = {}
        for _, filter in ipairs(filtersOf(sourceSettings)) do
            filterNames[#filterNames + 1] = type(filter) == "table" and tostring(filter.Name) or "unnamed"
        end
        if #filterNames > 0 then
            context:warn(
                "A full copy leaves out the source's FilterList ("
                    .. table.concat(filterNames, ", ")
                    .. "): Lightroom computes those results for each image, so each target keeps its own"
            )
        end
    end
    if type(toApply.MaskGroupBasedCorrections) == "table" and #toApply.MaskGroupBasedCorrections > 0 then
        local safe, reason = LrTasks.pcall(
            MaskWriteAdmission.requireAdmitted,
            MaskWriteAdmission.status(catalog),
            sourceSettings.ProcessVersion
        )
        if not safe then
            Reply.refuse(
                "The source's masks cannot be copied: "
                    .. Reply.messageOf(reason)
                    .. " Name the settings to copy with settings to leave masks out."
            )
        end
    end
    toApply = DevelopCurves.forWrite(withoutComputedAIMaskData(toApply))

    local masks, rest = nil, toApply
    if not args.settings then
        masks = type(toApply.MaskGroupBasedCorrections) == "table" and toApply.MaskGroupBasedCorrections or {}
    end
    local entries, missingIds, resolved = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    local photos = { source }
    for _, entry in ipairs(entries) do
        photos[#photos + 1] = entry.photo
    end
    local identityOf = identitiesOf(catalog, photos)
    local sourceIdentity = identityOf(source, sourceSettings)
    local function leftReason(photo, settings)
        return profileUnit and ProfileLook.leftReason(sourceIdentity, identityOf(photo, settings)) or nil
    end
    local profilesLeft, leftWithKeys = {}, {}
    local absentProblem = #absent > 0 and "the source has no " .. table.concat(absent, ", ") .. ", so it was not copied"
        or nil
    if args.dry_run then
        if absentProblem then context:warn(absentProblem) end
        local preview = previewDevelopSettings(catalog, resolved, toApply, false, masks, function(photo, current)
            local reason = leftReason(photo, current)
            if reason then
                profilesLeft[#profilesLeft + 1] = { photo_id = tostring(photo.localIdentifier), reason = reason }
            elseif profileUnit and not ProfileLook.sameProfile(sourceSettings, current) then
                return {
                    key = "profile",
                    before = ProfileLook.nameOf(current),
                    after = ProfileLook.nameOf(sourceSettings),
                }
            end
        end)
        if profileUnit then preview.profiles_left = profilesLeft end
        return preview
    end
    local onlyProfile = next(toApply) == nil and masks == nil
    local written, unchanged, clipboard = {}, {}, {}
    if masks then
        rest = {}
        for key, value in pairs(toApply) do
            if key ~= "MaskGroupBasedCorrections" then rest[key] = value end
        end
    end
    local requested = {}
    for key in pairs(toApply) do
        requested[key] = true
        for _, derived in ipairs(DevelopReadBack.derivedFrom(key)) do
            requested[derived] = true
        end
    end
    if masks then requested.MaskGroupBasedCorrections = true end

    local aiMasks = masks ~= nil and containsAIMasks({ MaskGroupBasedCorrections = masks })
    local reserveSeconds = batchReserve(masks == nil and 1 or aiMasks and 4 or 3, aiMasks)

    local remaining, failed = {}, {}
    for _, entry in ipairs(entries) do
        if #remaining > 0 or context:stopping(reserveSeconds) then
            remaining[#remaining + 1] = entry.id
        else
            local read, settings = LrTasks.pcall(savedOf, catalog, entry.photo)
            if not read then
                failed[#failed + 1] =
                    { photo_id = tostring(entry.photo.localIdentifier), reason = Reply.messageOf(settings) }
            else
                local photoId = tostring(entry.photo.localIdentifier)
                local before = DevelopReadBack.before(settings)
                local snapshot = JsonValue.of(settings)
                local from = context.ledger:mark()
                local left = leftReason(entry.photo, settings)
                local pastes = profileUnit and not left and not ProfileLook.sameProfile(sourceSettings, settings)
                local refusal
                if pastes and masks and (#masks > 0 or maskCountOf(settings) > 0) then
                    local admitted, problem = LrTasks.pcall(
                        GuardedMaskWrite.precheck,
                        catalog,
                        entry.photo,
                        masks,
                        rest.ProcessVersion or settings.ProcessVersion
                    )
                    if not admitted then refusal = "the masks could not be copied: " .. Reply.messageOf(problem) end
                end
                local pasted, outcome = true, "kept"
                if pastes and not refusal then
                    pasted, outcome = LrTasks.pcall(
                        pasteProfile,
                        context,
                        catalog,
                        source,
                        sourceSettings,
                        entry.photo,
                        snapshot,
                        clipboard
                    )
                end
                if outcome == "not copied" then
                    refusal = "Lightroom did not copy the source's profile, so nothing was written to the photo"
                end
                if refusal then
                    failed[#failed + 1] = { photo_id = photoId, reason = refusal }
                elseif not pasted then
                    written[#written + 1] = {
                        photo = entry.photo,
                        settings = {},
                        before = before,
                        from = from,
                        to = context.ledger:mark(),
                        error = "the profile could not be copied: " .. Reply.messageOf(outcome),
                    }
                else
                    local profileLeft = left
                        or (outcome == "not pasted" and "Lightroom did not paste the profile")
                        or nil
                    if profileLeft then
                        profilesLeft[#profilesLeft + 1] = { photo_id = photoId, reason = profileLeft }
                    end
                    local expected = outcome == "pasted" and sourceSettings or snapshot
                    local function finalCheck(stored)
                        return ProfileLook.finalProblem(snapshot, stored, expected, requested)
                    end
                    if onlyProfile and profileLeft then
                        failed[#failed + 1] = { photo_id = photoId, reason = "the profile was left: " .. profileLeft }
                    elseif onlyProfile and outcome == "kept" then
                        unchanged[#unchanged + 1] = photoId
                    elseif onlyProfile then
                        written[#written + 1] = {
                            photo = entry.photo,
                            settings = {},
                            before = before,
                            from = from,
                            to = context.ledger:mark(),
                            compare = finalCheck,
                        }
                    else
                        if profileLeft and args.settings then
                            leftWithKeys[#leftWithKeys + 1] = "photo " .. photoId .. ": " .. profileLeft
                        elseif profileLeft then
                            context:warn("A full copy left the profile of photo " .. photoId .. ": " .. profileLeft)
                        end
                        local copied =
                            copyKeys(context, catalog, entry.photo, settings, before, from, rest, masks, aiMasks)
                        local refreshed, skipped = {}, {}
                        for key in pairs(requested) do
                            skipped[key] = true
                        end
                        for _, change in ipairs(copied.refreshed or {}) do
                            if not requested[change.key] then
                                refreshed[#refreshed + 1] = change
                                skipped[change.key] = true
                            end
                        end
                        copied.compare = function(stored)
                            local problem = ProfileLook.finalProblem(snapshot, stored, expected, skipped)
                            if #refreshed == 0 then return problem end
                            local refresh = AIMaskCompute.changedMoreText(refreshed)
                            return problem and problem .. "; " .. refresh or refresh
                        end
                        written[#written + 1] = copied
                    end
                end
            end
        end
    end

    local checked = DevelopReadBack.check(context, catalog, written)
    local copied, computed, masksRemoved = 0, {}, {}
    for index, result in ipairs(checked) do
        if DevelopReadBack.confirmed(result) then
            copied = copied + 1
            computed[#computed + 1] = result.photo_id
            if written[index].masksRemoved then
                masksRemoved[#masksRemoved + 1] = { photo_id = result.photo_id, count = written[index].masksRemoved }
            end
        end
    end
    Log.info(string.format("Copied develop settings from %s to %d photos", args.source_photo_id, copied))
    local problems = {}
    if #leftWithKeys > 0 then
        problems[#problems + 1] = "the profile was left on " .. table.concat(leftWithKeys, "; ")
    end
    problems[#problems + 1] = absentProblem
    if clipboard.taken then
        context:warn(
            "Lightroom's Develop clipboard now holds the profile of photo "
                .. tostring(source.localIdentifier)
                .. ": Paste Settings in Lightroom pastes that profile until the next Copy"
        )
    end

    return DevelopReadBack.parts(checked, (copied > 0 or #unchanged > 0) and {
        copied = copied,
        unchanged = #unchanged > 0 and unchanged or nil,
        computed = aiMasks and computed or nil,
        masks_removed = #masksRemoved > 0 and masksRemoved or nil,
        profiles_left = #profilesLeft > 0 and profilesLeft or nil,
    } or nil, {
        failed = failed,
        not_found = missingIds,
        remaining = remaining,
        problem = #problems > 0 and table.concat(problems, "; ") or nil,
    })
end

local styleMatchSerial = 0

function DevelopHandler.matchPhotoStyle(args, context)
    local catalog = LrApplication.activeCatalog()
    local source = PhotoLookup.requireOne(catalog, args.reference_photo_id)
    local settings, grayscale

    local function readReference()
        if settings then return end
        local style = {}
        catalog:withReadAccessDo(function()
            local reference = DevelopReadBack.saved(source)
            grayscale = reference.ConvertToGrayscale == true
            for key in pairs(STYLE_KEYS) do
                style[key] = DevelopCurves.read(reference, key)
            end
        end)
        settings = style
    end

    local function matchOne(photo)
        local current = savedOf(catalog, photo)
        if (current.ConvertToGrayscale == true) ~= grayscale then
            Reply.refuse("treatment differs from the reference; convert it with set_treatment, then match")
        end
        local photoId = tostring(photo.localIdentifier)
        local changed = 0
        for key, value in pairs(settings) do
            if not JsonValue.equal(value, DevelopCurves.read(current, key)) then changed = changed + 1 end
        end
        styleMatchSerial = styleMatchSerial + 1
        local name = string.format(
            "Style match from %s at %.3f #%d",
            tostring(source.localIdentifier),
            LrDate.currentTime(),
            styleMatchSerial
        )
        local snapshot
        local written = DevelopReadBack.attempt(
            context,
            photo,
            settings,
            DevelopReadBack.before(current),
            function(entry)
                snapshot = HandlerSnapshots.createVerified(context, catalog, photo, name, false)
                entry.kept = "the style was not confirmed stored and recovery snapshot "
                    .. tostring(snapshot.name)
                    .. " was kept"
                CatalogWrite.developSettings(
                    context,
                    catalog,
                    photo,
                    "Match Photo Style",
                    function() return DevelopCurves.forWrite(settings) end
                )
            end
        )
        return { written = written, match = { photo_id = photoId, snapshot = snapshot, settings_changed = changed } }
    end

    local batch = PhotoBatch.run(context, catalog, {
        inputs = args.photo_ids,
        reserveSeconds = batchReserve(2, false),
        progress = "Matching photo style",
        around = function(body, entries)
            for _, entry in ipairs(entries) do
                if entry.photo.localIdentifier == source.localIdentifier then
                    Reply.refuse("Reference photo must not appear in photo_ids")
                end
            end
            readReference()
            return body()
        end,
        each = matchOne,
        confirm = DevelopReadBack.confirm(context, catalog),
    })
    readReference()
    return PhotoBatch.reply(batch, function(results)
        local matched = {}
        for index, result in ipairs(results) do
            matched[index] = result.match
        end
        return { reference_id = tostring(source.localIdentifier), matched = #matched, results = matched }
    end)
end

local READ_BACK_PER_PHOTO_SECONDS = 0.1

local function writeSettings(context, catalog, photo, settings)
    local before
    local from = context.ledger:mark()
    CatalogWrite.developSettings(context, catalog, photo, "Set Develop Settings", function()
        before = DevelopReadBack.before(DevelopReadBack.saved(photo))
        return DevelopCurves.forWrite(settings)
    end)
    Log.info(string.format("Set develop settings on photo %s", tostring(photo.localIdentifier)))
    return DevelopReadBack.entry(photo, settings, before, from, context.ledger:mark())
end

function DevelopHandler.setDevelopSettings(args, context)
    local catalog = LrApplication.activeCatalog()
    local photo = PhotoLookup.requireOne(catalog, args.photo_id)
    local checked = DevelopReadBack.check(context, catalog, { writeSettings(context, catalog, photo, args.settings) })
    local failed, unknown = DevelopReadBack.classify(checked)
    local report = DevelopReadBack.report(checked, { photo_id = checked[1].photo_id, settings = checked[1].stored })
    return Reply.parts({
        data = report.data,
        failed = failed,
        unknown = unknown,
        warnings = report.warnings,
        problem = report.problem,
    })
end

function DevelopHandler.setDevelopSettingsBatch(args, context)
    local catalog = LrApplication.activeCatalog()
    local items, inputs = args.photos, {}
    for index, item in ipairs(items) do
        inputs[index] = item.photo_id
    end
    return DevelopBatch.run(context, catalog, {
        inputs = inputs,
        duplicates = "refuse",
        reserveSeconds = function(started) return batchReserve(1) + READ_BACK_PER_PHOTO_SECONDS * (started + 1) end,
        held = function(entry)
            local item = items[entry.index]
            if item.remaining then return { remaining = true } end
            if item.refused then return { reason = item.refused } end
        end,
        each = function(photo, _, entry)
            return { written = writeSettings(context, catalog, photo, items[entry.index].settings) }
        end,
        confirm = DevelopReadBack.confirm(context, catalog),
        dataOf = function(results)
            local rows = {}
            for index, result in ipairs(results) do
                rows[index] = { photo_id = result.photo_id, settings = result.stored }
            end
            return { results = rows }
        end,
    })
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
    catalog:withReadAccessDo(function() filter = enhanceFilterOf(DevelopReadBack.saved(photo)) end)
    return filter and tostring(filter.CompressedSettings or "")
end

local function waitForSavedChange(catalog, photo, before)
    return waitFor(function()
        local now = enhanceDigest(catalog, photo)
        return now ~= nil and now ~= before
    end, DENOISE_SAVE_TIMEOUT_SECONDS)
end

local function denoisePhoto(context, catalog, photo, amount)
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
        CatalogWrite.develop(context, "changeDenoiseAmount", amount)
    else
        CatalogWrite.develop(context, "setEnhance", "denoise", true, amount)
    end
    local confirmed = waitFor(function()
        local now = LrDevelopController.getEnhancePanelState()
        return catalog:getTargetPhoto() == photo and now ~= nil and now.denoiseState and now.denoiseAmount == amount
    end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
    if not confirmed then error("the Develop panel did not show the new amount; check this photo", 0) end
    if not waitForSavedChange(catalog, photo, digestBefore) then
        local reverted = change
        if change then
            LrTasks.pcall(CatalogWrite.develop, context, "changeDenoiseAmount", panel.denoiseAmount)
            reverted = waitFor(function()
                local now = LrDevelopController.getEnhancePanelState()
                return now ~= nil and now.denoiseAmount == panel.denoiseAmount
            end, DENOISE_CONFIRM_TIMEOUT_SECONDS)
        end
        if reverted then
            error(
                string.format(
                    "Lightroom did not confirm saving the Denoise change in time; the panel shows the"
                        .. " previous amount %s again, but Lightroom may still save either amount: read this photo's Denoise"
                        .. " state before retrying",
                    tostring(panel.denoiseAmount)
                ),
                0
            )
        end
        error(
            "Lightroom did not confirm saving the Denoise change in time and may have saved it since;"
                .. " read this photo's Denoise state before retrying",
            0
        )
    end
    return {
        status = change and "amount_changed" or "applied",
        previous_amount = change and panel.denoiseAmount or nil,
    }
end

function DevelopHandler.applyDenoise(args, context)
    local amount = args.amount
    DevelopSession.requireControllerFunctions(
        "apply_denoise",
        { "getEnhancePanelState", "setEnhance", "changeDenoiseAmount" }
    )

    local catalog = LrApplication.activeCatalog()
    local reply = DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = args.restore_selection ~= false,
        reserveSeconds = DENOISE_LAST_PHOTO_AND_RESTORE_SECONDS,
        prepare = function()
            DevelopSession.openDevelop(function() return LrDevelopController.getEnhancePanelState() ~= nil end)
        end,
        each = function(photo, state)
            if not DevelopSession.selectAlone(catalog, photo, state) then
                Reply.refuse("could not select the photo in Develop")
            end
            return denoisePhoto(context, catalog, photo, amount)
        end,
    })
    if reply.data then context:warn("Denoise runs in Lightroom's background; the Activity Center shows progress.") end
    return reply
end

local PROCESS_VERSION_PHOTO_AND_RESTORE_SECONDS = 60

local PROCESS_VERSIONS = {
    ["Version 1"] = 1,
    ["Version 2"] = 2,
    ["Version 3"] = 3,
    ["Version 4"] = 4,
    ["Version 5"] = 5,
    ["Version 6"] = 6,
}

local function refuseMaskedDowngrade(catalog, photo)
    local masks = savedOf(catalog, photo).MaskGroupBasedCorrections
    if masks and next(masks) ~= nil then
        Reply.refuse(
            "Process-version downgrades are refused on photos with masks;"
                .. " keep the current version to preserve mask editing"
        )
    end
end

local function changeProcessVersion(context, catalog, photo, version, state)
    DevelopSession.openPhoto(catalog, photo, state)
    local previous = LrDevelopController.getProcessVersion()
    if not PROCESS_VERSIONS[previous] then Reply.refuse("Lightroom returned an unknown process version") end
    if previous == version then return { status = "unchanged", previous_version = previous, new_version = previous } end
    if PROCESS_VERSIONS[version] < PROCESS_VERSIONS[previous] then refuseMaskedDowngrade(catalog, photo) end
    if catalog:getTargetPhoto() ~= photo then Reply.refuse("another photo became active before the version change") end
    CatalogWrite.develop(context, "setProcessVersion", version)
    local confirmed = DevelopSession.waitFor(
        function() return catalog:getTargetPhoto() == photo and LrDevelopController.getProcessVersion() == version end,
        5
    )
    if not confirmed then
        local current = catalog:getTargetPhoto() == photo and LrDevelopController.getProcessVersion() or "unreadable"
        error("Lightroom did not confirm " .. version .. "; the photo reads " .. tostring(current), 0)
    end
    return { status = "changed", previous_version = previous, new_version = version }
end

function DevelopHandler.setProcessVersion(args, context)
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = args.restore_selection ~= false,
        reserveSeconds = PROCESS_VERSION_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state) return changeProcessVersion(context, catalog, photo, args.version, state) end,
    })
end

local AUTO_TONE_KEYS = {
    "Exposure2012",
    "Contrast2012",
    "Highlights2012",
    "Shadows2012",
    "Whites2012",
    "Blacks2012",
    "Vibrance",
    "Saturation",
}
local AUTO_WHITE_BALANCE_KEYS = { "WhiteBalance", "Temperature", "Tint" }
local AUTO_PHOTO_AND_RESTORE_SECONDS = 60
local AUTO_SETTLE_TIMEOUT_SECONDS = Contract.AUTO_CHANGE_WAIT_SECONDS

local function autoValues(catalog, photo, keys)
    local values = {}
    catalog:withReadAccessDo(function()
        local settings = DevelopReadBack.saved(photo)
        for _, key in ipairs(keys) do
            values[key] = settings[key]
        end
    end)
    return values
end

local function sameAutoValues(first, second, keys)
    for _, key in ipairs(keys) do
        if first[key] ~= second[key] then return false end
    end
    return true
end

local function autoOperation(context, catalog, photo, name, keys, controllerFunction)
    local before = autoValues(catalog, photo, keys)
    CatalogWrite.develop(context, controllerFunction)
    DevelopSession.commitPendingEdits()
    local previous, stable, elapsed = before, 0, 0
    local settled = waitFor(function()
        if catalog:getTargetPhoto() ~= photo then error("another photo became active while applying Auto", 0) end
        local current = autoValues(catalog, photo, keys)
        stable = sameAutoValues(previous, current, keys) and stable + 0.1 or 0
        previous = current
        elapsed = elapsed + 0.1
        return elapsed >= 2 and stable >= 1 and not sameAutoValues(before, current, keys)
    end, AUTO_SETTLE_TIMEOUT_SECONDS)
    if settled then return end
    if sameAutoValues(before, previous, keys) then
        error(
            string.format(
                "%s was requested but no change was observed within %d s; it may still be applied,"
                    .. " so read this photo's settings before writing to it",
                name,
                AUTO_SETTLE_TIMEOUT_SECONDS
            ),
            0
        )
    end
    error("Auto settings did not settle; check this photo before retrying", 0)
end

local function autoPhoto(context, catalog, photo, args)
    if args.tone then autoOperation(context, catalog, photo, "Auto Tone", AUTO_TONE_KEYS, "setAutoTone") end
    if args.white_balance then
        autoOperation(context, catalog, photo, "Auto White Balance", AUTO_WHITE_BALANCE_KEYS, "setAutoWhiteBalance")
    end
    return { status = "applied" }
end

function DevelopHandler.applyAutoAdjustments(args, context)
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = AUTO_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state)
            DevelopSession.openPhoto(catalog, photo, state)
            return autoPhoto(context, catalog, photo, args)
        end,
    })
end

local RESET_PHOTO_AND_RESTORE_SECONDS = 60
local RESET_LANDING_WAIT_SECONDS = Contract.RESET_LANDING_WAIT_SECONDS

local function resetPhoto(context, catalog, photo)
    local before = savedOf(catalog, photo)
    if catalog:getTargetPhoto() ~= photo then
        Reply.refuse("another photo became active before the reset; nothing was reset")
    end
    CatalogWrite.develop(context, "resetAllDevelopAdjustments")
    DevelopSession.commitPendingEdits()
    LrTasks.sleep(RESET_LANDING_WAIT_SECONDS)
    if #DevelopReadBack.changedEdits(before, savedOf(catalog, photo)) == 0 then
        error(
            string.format(
                "no edit a reset clears (develop sliders, crop, Upright, profile, masks, spots, Enhance)"
                    .. " changed in the saved settings %d s after the reset: the photo may have had nothing to reset, since an"
                    .. " unedited photo reads the same before and after, or Lightroom may not have reset it; read the photo before"
                    .. " retrying",
                RESET_LANDING_WAIT_SECONDS
            ),
            0
        )
    end
    return { status = "reset" }
end

function DevelopHandler.resetDevelopAdjustments(args, context)
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = true,
        reserveSeconds = RESET_PHOTO_AND_RESTORE_SECONDS,
        each = function(photo, state)
            DevelopSession.openPhoto(catalog, photo, state)
            return resetPhoto(context, catalog, photo)
        end,
    })
end

return DevelopHandler
