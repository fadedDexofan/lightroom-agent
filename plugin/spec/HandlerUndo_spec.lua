local helper = require "spec_helper"

local function setup(states)
    local reads, undos = 0, 0
    helper.installImport({
        LrUndo = {
            canUndo = function()
                reads = reads + 1
                return states[reads]
            end,
            undo = function() undos = undos + 1 end,
        },
    })
    package.loaded.HandlerUndo = nil
    return require "HandlerUndo", function() return reads, undos end
end

describe("HandlerUndo.undoLastStep", function()
    it("undoes exactly once and reports the post-call availability", function()
        local handler, counts = setup({ true, false })
        local result = handler.undoLastStep()
        assert.is_true(result.undone)
        assert.is_false(result.can_undo)
        assert.truthy(result.message:find("merge", 1, true))
        local reads, undos = counts()
        assert.are.equal(2, reads)
        assert.are.equal(1, undos)
    end)

    it("reports another available undo without invoking it", function()
        local handler, counts = setup({ true, true })
        local result = handler.undoLastStep()
        assert.is_true(result.undone)
        assert.is_true(result.can_undo)
        local _, undos = counts()
        assert.are.equal(1, undos)
    end)

    it("succeeds without undoing when history is empty", function()
        local handler, counts = setup({ false, false })
        assert.are.same({ undone = false, can_undo = false }, handler.undoLastStep())
        local _, undos = counts()
        assert.are.equal(0, undos)
    end)
end)
