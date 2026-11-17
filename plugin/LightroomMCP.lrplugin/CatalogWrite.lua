local Contract = require 'Contract'
local Reply = require 'Reply'

local CatalogWrite = {}

CatalogWrite.WAIT_SECONDS = Contract.CATALOG_WRITE_WAIT_SECONDS

function CatalogWrite.run(catalog, title, fn, alreadyWritten)
    local outcome = catalog:withWriteAccessDo(title, fn, { timeout = CatalogWrite.WAIT_SECONDS })
    if outcome ~= "aborted" then return end
    local busy = "The catalog stayed busy with another write for " .. CatalogWrite.WAIT_SECONDS
        .. " s, so Lightroom did not run " .. title
    if alreadyWritten then error(busy .. "; " .. alreadyWritten, 0) end
    Reply.refuse(busy)
end

return CatalogWrite
