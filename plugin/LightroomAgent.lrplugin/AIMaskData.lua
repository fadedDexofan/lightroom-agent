local AIMaskData = {}

AIMaskData.KIND = "Mask/Image"
local COMPUTED_KEYS = {
    "MaskDigest", "InputDigest", "InputDigestVersion", "LocalInputDigest", "LocalInputDigestVersion", "ModelVersion",
    "FullMaskSize", "Origin", "ReferencePoint", "WholeImageArea", "MaskSyncID", "ErrorReason",
}
AIMaskData.COMPUTATION_MARKER_KEY = "MaskDigest"

local COMPUTED = {}
for _, key in ipairs(COMPUTED_KEYS) do COMPUTED[key] = true end

function AIMaskData.isComputed(key)
    return COMPUTED[key] == true
end

local ERROR_REASONS = {
    [1] = "no result",
    [2] = "model unavailable or not loaded",
    [3] = "another failure",
    [4] = "model could not be downloaded",
}

function AIMaskData.errorReasonText(reason)
    local meaning = ERROR_REASONS[reason]
    return "ErrorReason " .. tostring(reason) .. (meaning and ", " .. meaning or "")
end

function AIMaskData.containsAIMasks(settings)
    local groups = type(settings) == "table" and settings.MaskGroupBasedCorrections
    if type(groups) ~= "table" then
        return false
    end
    for _, correction in ipairs(groups) do
        local masks = type(correction) == "table" and correction.CorrectionMasks
        if type(masks) == "table" then
            for _, mask in ipairs(masks) do
                if type(mask) == "table" and mask.What == AIMaskData.KIND then
                    return true
                end
            end
        end
    end
    return false
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

function AIMaskData.withoutComputedData(settings)
    if not AIMaskData.containsAIMasks(settings) then
        return settings
    end
    local stripped = shallowCopy(settings)
    stripped.MaskGroupBasedCorrections = {}
    for groupIndex, correction in ipairs(settings.MaskGroupBasedCorrections) do
        local strippedCorrection = correction
        if type(correction) == "table" then
            strippedCorrection = shallowCopy(correction)
        end
        if type(correction) == "table" and type(correction.CorrectionMasks) == "table" then
            strippedCorrection.CorrectionMasks = {}
            for maskIndex, mask in ipairs(correction.CorrectionMasks) do
                local strippedMask = mask
                if type(mask) == "table" then
                    strippedMask = shallowCopy(mask)
                    if mask.What == AIMaskData.KIND then
                        for _, key in ipairs(COMPUTED_KEYS) do
                            strippedMask[key] = nil
                        end
                    end
                end
                strippedCorrection.CorrectionMasks[maskIndex] = strippedMask
            end
        end
        stripped.MaskGroupBasedCorrections[groupIndex] = strippedCorrection
    end
    return stripped
end

local function failed(component)
    return type(component.ErrorReason) == "number" and component.ErrorReason ~= 0
end

local function computed(component)
    local digest = component[AIMaskData.COMPUTATION_MARKER_KEY]
    return type(digest) == "string" and digest ~= ""
end

function AIMaskData.componentState(component)
    if failed(component) then return "failed" end
    if computed(component) then return "computed" end
    return "pending"
end

function AIMaskData.uncomputed(correction)
    for _, component in ipairs(type(correction) == "table" and type(correction.CorrectionMasks) == "table"
        and correction.CorrectionMasks or {}) do
        if type(component) == "table" and component.What == AIMaskData.KIND and not failed(component)
            and not computed(component) then
            return true
        end
    end
    return false
end

function AIMaskData.computeState(correction)
    local components = type(correction) == "table" and correction.CorrectionMasks
    if type(components) ~= "table" then return "pending" end
    local sawAIMask, allComputed = false, true
    for _, component in ipairs(components) do
        if type(component) == "table" and component.What == AIMaskData.KIND then
            sawAIMask = true
            if failed(component) then return "failed" end
            if not computed(component) then allComputed = false end
        end
    end
    if not sawAIMask then return "none" end
    return allComputed and "computed" or "pending"
end

return AIMaskData
