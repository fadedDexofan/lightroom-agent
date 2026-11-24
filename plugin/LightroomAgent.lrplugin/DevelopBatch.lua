local DevelopSession = require "DevelopSession"
local PhotoBatch = require "PhotoBatch"

local DevelopBatch = {}

function DevelopBatch.run(context, catalog, operation)
    local state
    local batch = PhotoBatch.run(context, catalog, {
        inputs = operation.inputs,
        reserveSeconds = operation.reserveSeconds,
        duplicates = operation.duplicates,
        held = operation.held,
        progress = context.title,
        prepare = operation.prepare and function(photo) operation.prepare(photo, state) end,
        each = function(photo, entry) return operation.each(photo, state, entry) end,
        around = function(loop)
            DevelopSession.run(context, catalog, operation.restoreView, function(sessionState)
                state = sessionState
                loop()
            end)
        end,
        confirm = operation.confirm,
    })
    return PhotoBatch.reply(batch, operation.dataOf or function(results) return { results = results } end)
end

return DevelopBatch
