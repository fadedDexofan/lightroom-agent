local Contract = require "Contract"
local JsonValue = require "JsonValue"
local Reply = require "Reply"
local SettingsChanges = require "SettingsChanges"

local ProfileLook = {}

local FAMILY = {
    CameraProfile = true,
    CameraProfileDigest = true,
    Look = true,
    ConvertToGrayscale = true,
    ToggleStyleDigest = true,
    ToggleStyleAmount = true,
    MissingCameraProfile = true,
    AILook = true,
}

local AMOUNT_TOLERANCE = 1e-6

function ProfileLook.inFamily(key) return FAMILY[key] == true or (type(key) == "string" and key:match("^Table_") ~= nil) end

function ProfileLook.isAdaptive(look) return type(look) == "table" and look.isAdobeAdaptive == true end

function ProfileLook.adobeRaw(name)
    for _, profile in ipairs(Contract.ADOBE_RAW_PROFILES) do
        if profile.name == name then return profile end
    end
    Reply.refuse("set_profile offers no profile named " .. tostring(name))
end

function ProfileLook.requireNamedTarget(fileFormat, settings)
    if fileFormat ~= "RAW" then
        Reply.refuse("set_profile sets an Adobe Raw profile on a raw photo; this photo is " .. tostring(fileFormat))
    end
    if settings.ConvertToGrayscale == true then
        Reply.refuse("The photo is black and white: convert it with set_treatment first, then set its profile")
    end
    if ProfileLook.isAdaptive(settings.Look) then
        Reply.refuse(
            "The photo has the Adaptive profile "
                .. tostring(settings.Look.Name)
                .. ", which set_profile leaves as it is"
        )
    end
end

local function filled(value) return type(value) == "string" and value ~= "" end

local function expanded(look)
    return filled(look.UUID)
        and filled(look.Name)
        and type(look.Parameters) == "table"
        and next(look.Parameters) ~= nil
        and look.Stubbed ~= true
        and look.Stubbed ~= "true"
        and type(look.Amount) == "number"
        and look.Amount >= 0
end

function ProfileLook.requireAmountTarget(settings)
    local look = settings.Look
    if type(look) ~= "table" then Reply.refuse("The photo has no profile Look whose amount could be set") end
    if ProfileLook.isAdaptive(look) then
        Reply.refuse("The Adaptive profile " .. tostring(look.Name) .. " has no amount set_profile sets")
    end
    if not expanded(look) then
        Reply.refuse(
            "The photo's Look "
                .. tostring(look.Name)
                .. " is not an active profile Look (a stub, or without its UUID, name, parameters or amount), so set_profile"
                .. " sets no amount on it"
        )
    end
    if look.SupportsAmount == false then Reply.refuse("The profile " .. tostring(look.Name) .. " has no amount") end
    return look
end

function ProfileLook.withAmount(look, amount)
    local written = JsonValue.of(look)
    written.Amount = amount
    return written
end

local function outsideProblem(before, after, written, label)
    local changed = SettingsChanges.between(
        before,
        after,
        function(key) return ProfileLook.inFamily(key) or (written ~= nil and written[key] ~= nil) end
    )
    if #changed > 0 then
        return (label or "settings outside the profile changed") .. ": " .. SettingsChanges.listed(changed)
    end
end

local function present(...)
    local found = {}
    for index = 1, select("#", ...) do
        local problem = select(index, ...)
        if problem ~= nil then found[#found + 1] = problem end
    end
    return found
end

local function settle(problems)
    if #problems > 0 then Reply.refuse(table.concat(problems, "; ")) end
end

function ProfileLook.requireNamed(before, after, profile)
    local look = type(after.Look) == "table" and after.Look or {}
    local problems = {}
    if after.CameraProfile ~= profile.camera_profile then
        problems[#problems + 1] = "CameraProfile reads "
            .. tostring(after.CameraProfile)
            .. ", not "
            .. profile.camera_profile
    end
    if after.MissingCameraProfile == true then
        problems[#problems + 1] = "Lightroom reports the camera profile missing"
    end
    if look.UUID ~= profile.look_uuid or look.Name ~= profile.name then
        problems[#problems + 1] = "the photo shows the profile " .. tostring(look.Name) .. ", not " .. profile.name
    end
    if after.ConvertToGrayscale ~= before.ConvertToGrayscale then problems[#problems + 1] = "the treatment changed" end
    problems[#problems + 1] = outsideProblem(before, after)
    settle(problems)
end

local function withoutLookAmount(settings)
    local copy = JsonValue.of(settings)
    if type(copy.Look) == "table" then copy.Look.Amount = nil end
    return copy
end

function ProfileLook.requireAmount(before, after, amount)
    local look = type(after.Look) == "table" and after.Look or {}
    local problems = {}
    if type(look.Amount) ~= "number" or math.abs(look.Amount - amount) > AMOUNT_TOLERANCE then
        problems[#problems + 1] = "the profile's amount reads " .. tostring(look.Amount) .. ", not " .. tostring(amount)
    end
    local changed = SettingsChanges.between(withoutLookAmount(before), withoutLookAmount(after))
    if #changed > 0 then
        problems[#problems + 1] = "settings other than the profile's amount changed: "
            .. SettingsChanges.listed(changed)
    end
    settle(problems)
end

local function blank(value)
    if value == nil or value == "" then return nil end
    return value
end

function ProfileLook.leftReason(source, target)
    local sourceKind, targetKind = blank(source.kind), blank(target.kind)
    if sourceKind == nil or targetKind == nil then return "the file kind of one of the photos is unknown" end
    if sourceKind == "DNG" or targetKind == "DNG" then
        return "a DNG's profile is not copied: whether it holds raw data is not established"
    end
    local sourceRaw, targetRaw = sourceKind == "RAW", targetKind == "RAW"
    if sourceRaw ~= targetRaw then return "a profile moves only between two raw or two non-raw photos" end
    local sourceModel, targetModel = blank(source.model), blank(target.model)
    if sourceRaw then
        if sourceModel == nil or targetModel == nil then return "the camera model of one of the photos is unknown" end
        if sourceModel ~= targetModel then
            return "another camera body ("
                .. sourceModel
                .. ", "
                .. targetModel
                .. "): a raw profile is copied only within one camera model"
        end
    end
    if ProfileLook.isAdaptive(source.settings.Look) or ProfileLook.isAdaptive(target.settings.Look) then
        return "an Adaptive profile is neither copied nor replaced"
    end
    if (source.settings.ConvertToGrayscale == true) ~= (target.settings.ConvertToGrayscale == true) then
        return "the treatments differ (colour and black and white): convert the target with set_treatment first"
    end
    local restriction = type(source.settings.Look) == "table" and blank(source.settings.Look.CameraModelRestriction)
    if restriction and restriction ~= targetModel then
        return "the profile is made for " .. tostring(restriction) .. " only"
    end
    return nil
end

function ProfileLook.identity(settings)
    local look = type(settings.Look) == "table" and settings.Look or {}
    return { CameraProfile = settings.CameraProfile, Name = look.Name, UUID = look.UUID, Amount = look.Amount }
end

function ProfileLook.nameOf(settings)
    local look = type(settings.Look) == "table" and settings.Look or {}
    return look.Name or settings.CameraProfile
end

function ProfileLook.sameProfile(left, right)
    return JsonValue.equal(JsonValue.of(ProfileLook.identity(left)), JsonValue.of(ProfileLook.identity(right)))
end

local function profileProblem(after, expected)
    if ProfileLook.sameProfile(after, expected) then return nil end
    return "the photo shows the profile "
        .. tostring(ProfileLook.nameOf(after))
        .. " (amount "
        .. tostring((type(after.Look) == "table" and after.Look or {}).Amount)
        .. "), not "
        .. tostring(ProfileLook.nameOf(expected))
end

local function treatmentProblem(before, after)
    if (before.ConvertToGrayscale == true) ~= (after.ConvertToGrayscale == true) then return "the treatment changed" end
end

function ProfileLook.requirePasted(before, after, source)
    settle(present(profileProblem(after, source), treatmentProblem(before, after), outsideProblem(before, after)))
end

function ProfileLook.finalProblem(before, after, expected, written)
    local problems = present(
        profileProblem(after, expected),
        treatmentProblem(before, after),
        outsideProblem(before, after, written, "settings the copy did not write changed")
    )
    if #problems > 0 then return table.concat(problems, "; ") end
end

function ProfileLook.answer(photo, settings)
    local look = type(settings.Look) == "table" and settings.Look or {}
    return {
        photo_id = tostring(photo.localIdentifier),
        profile = ProfileLook.nameOf(settings),
        amount = type(look.Amount) == "number" and math.floor(look.Amount * 100 + 0.5) or nil,
    }
end

return ProfileLook
