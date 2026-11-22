local LrApplication = import "LrApplication"

local CatalogWrite = require "CatalogWrite"
local Contract = require "Contract"
local DevelopBatch = require "DevelopBatch"
local MaskCreate = require "HandlerMaskCreate"

local MaskBatchHandler = {}

local GATES_PER_PHOTO = 3

function MaskBatchHandler.createMaskBatch(args, context)
    local values = args.adjustments or {}
    local catalog = LrApplication.activeCatalog()
    return DevelopBatch.run(context, catalog, {
        inputs = args.photo_ids,
        restoreView = false,
        reserveSeconds = GATES_PER_PHOTO * CatalogWrite.WAIT_SECONDS + Contract.AI_MASK_COMPUTE_WAIT_SECONDS,
        each = function(photo)
            local created = MaskCreate.createAIMask(context, catalog, photo, args.type, values)
            return { status = "created", mask_id = created.mask_id, adjustments = created.adjustments }
        end,
    })
end

return MaskBatchHandler
