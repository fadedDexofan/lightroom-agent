local LrUndo = import 'LrUndo'

local CatalogWrite = require 'CatalogWrite'

local HandlerUndo = {}

function HandlerUndo.undoLastStep(_, context)
    local undone = false
    if LrUndo.canUndo() then
        CatalogWrite.invoke(context, "Undo", LrUndo.undo)
        undone = true
    end
    return {
        undone = undone,
        can_undo = LrUndo.canUndo(),
        message = undone and "Lightroom can merge recent plug-in writes into one undo step, so check every recent edit."
            or nil,
    }
end

return HandlerUndo
