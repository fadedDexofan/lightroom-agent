local CatalogWrite = require "CatalogWrite"
local Log = require "Log"
local PhotoLookup = require "PhotoLookup"
local Reply = require "Reply"

local PhotoWrites = {}

function PhotoWrites.each(context, catalog, operation)
    local entries, notFound = PhotoLookup.resolveDistinct(catalog, operation.photo_ids)
    if #entries == 0 then return Reply.parts({ not_found = notFound }) end
    CatalogWrite.run(context, catalog, operation.title, function()
        for _, entry in ipairs(entries) do
            operation.write(function(method, ...) return CatalogWrite.call(context, entry.photo, method, ...) end)
        end
    end)
    Log.info(string.format("%s: %d photos", operation.title, #entries))
    local data = operation.data or {}
    data.updated = #entries
    return Reply.parts({ data = data, not_found = notFound })
end

return PhotoWrites
