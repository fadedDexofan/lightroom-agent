local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Reply = require 'Reply'
local JSON = require 'JSON'
local PluginFiles = require 'PluginFiles'
local RunningLightroom = require 'RunningLightroom'

local MaskWriteAdmission = {}

local THROWAWAY_MARKER_FILE = "lrmcp-live-catalog.json"
local CERTIFY_COMMAND = "node tests/e2e/live/certify-mask-writes.mjs"

local function isThrowaway(catalog)
    local path = catalog:getPath()
    if type(path) ~= "string" then return false end
    return LrFileUtils.exists(LrPathUtils.child(LrPathUtils.parent(path), THROWAWAY_MARKER_FILE)) == "file"
end

local function stringList(value)
    if type(value) ~= "table" or #value == 0 then return nil end
    for _, item in ipairs(value) do
        if type(item) ~= "string" then return nil end
    end
    return value
end

local function readCertification()
    local path = PluginFiles.maskCertification()
    if LrFileUtils.exists(path) ~= "file" then return nil end
    local ok, record = pcall(function() return JSON:decode(LrFileUtils.readFile(path)) end)
    local lightroom = ok and type(record) == "table" and record.lightroom or nil
    if type(lightroom) ~= "table" or type(lightroom.version) ~= "string" or type(lightroom.build) ~= "string"
        or not stringList(record.process_versions) or type(record.certified_at) ~= "string" then
        return nil, "the certification file " .. path .. " is not a certification record"
    end
    return {
        version = lightroom.version,
        build = lightroom.build,
        process_versions = record.process_versions,
        certified_at = record.certified_at,
        checks = stringList(record.checks) or {},
    }
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

function MaskWriteAdmission.status(catalog)
    local status = {
        running = RunningLightroom.describe(),
        throwaway_catalog = isThrowaway(catalog),
        certification_file = PluginFiles.maskCertification(),
    }
    local certified, problem = readCertification()
    status.certified = certified
    local build = status.running.build
    status.admitted = status.throwaway_catalog
        or (build ~= nil and certified ~= nil and certified.build == build)
    if status.admitted then return status end
    if build == nil then
        status.reason = string.format(
            "Lightroom Classic %s reports no build number, so no certification can name it.", status.running.version)
    else
        status.reason = string.format(
            "Lightroom Classic %s (%s) is not certified for writing mask geometry (certified: %s). Run `%s`"
                .. " on the live kit's throwaway catalog to certify it.",
            status.running.version, build, certified and certified.build or problem or "none", CERTIFY_COMMAND)
    end
    return status
end

function MaskWriteAdmission.decide(catalog, processVersion)
    local status = MaskWriteAdmission.status(catalog)
    if status.admitted and not status.throwaway_catalog
        and not contains(status.certified.process_versions, tostring(processVersion)) then
        status.admitted = false
        status.reason = string.format(
            "The photo's process version (%s) was not exercised by the certification of Lightroom Classic %s"
                .. " (certified: %s).",
            tostring(processVersion), status.running.version, table.concat(status.certified.process_versions, ", "))
    end
    return status
end

function MaskWriteAdmission.requireAdmitted(catalog, processVersion)
    local decision = MaskWriteAdmission.decide(catalog, processVersion)
    if not decision.admitted then Reply.refuse(decision.reason) end
end

return MaskWriteAdmission
