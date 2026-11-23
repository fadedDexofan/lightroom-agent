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

local function outsideProblem(before, after)
    local changed = SettingsChanges.between(before, after, ProfileLook.inFamily)
    if #changed > 0 then return "settings outside the profile changed: " .. SettingsChanges.listed(changed) end
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

function ProfileLook.answer(photo, settings)
    local look = type(settings.Look) == "table" and settings.Look or {}
    return {
        photo_id = tostring(photo.localIdentifier),
        profile = ProfileLook.nameOf(settings),
        amount = type(look.Amount) == "number" and math.floor(look.Amount * 100 + 0.5) or nil,
    }
end

return ProfileLook
