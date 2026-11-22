local LrApplication = import "LrApplication"
local DecimalText = require "DecimalText"
local PhotoLookup = require "PhotoLookup"
local PhotoWrites = require "PhotoWrites"
local Reply = require "Reply"

local Handler = {}
local FIELD_IDS = { "aiScore", "aiReason" }

function Handler.setAiMetadata(args, context)
    local score, reason = args.score, args.reason

    return PhotoWrites.each(context, LrApplication.activeCatalog(), {
        photo_ids = args.photo_ids,
        title = "Set AI Metadata",
        write = function(call)
            if score ~= nil then
                local value
                if score ~= "" then value = DecimalText.number(score) end
                call("setPropertyForPlugin", _PLUGIN, "aiScore", value)
            end
            if reason ~= nil then
                local value
                if reason ~= "" then value = reason end
                call("setPropertyForPlugin", _PLUGIN, "aiReason", value)
            end
        end,
    })
end

function Handler.getAiMetadata(args)
    local catalog = LrApplication.activeCatalog()
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, args.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    local photos = {}
    for i, entry in ipairs(entries) do
        photos[i] = entry.photo
    end
    local values = catalog:batchGetPropertyForPlugin(photos, _PLUGIN, FIELD_IDS)
    local results = {}
    for i, photo in ipairs(photos) do
        local fields = values[photo] or {}
        results[i] = {
            photo_id = tostring(photo.localIdentifier),
            score = DecimalText.parse(fields.aiScore),
            reason = fields.aiReason,
        }
    end
    return Reply.parts({ data = { photos = results }, not_found = notFound })
end

return Handler
