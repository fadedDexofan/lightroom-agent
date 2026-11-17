local helper = require 'spec_helper'
local Reply = require 'Reply'

local function writing(fn)
    return function()
        helper.requestContext().ledger:record("Set Rating")
        fn()
    end
end

local outcomes = {
    { name = "a success", call = function() return 1 end },
    { name = "a refusal", call = function() Reply.refuse("refused text") end },
    { name = "not found", call = function() Reply.notFound("9") end },
    { name = "a plain error", call = function() error("plain text", 0) end },
    { name = "a refusal after a write", call = writing(function() Reply.refuse("refused text") end) },
    { name = "not found after a write", call = writing(function() Reply.notFound("9") end) },
}

local accepts = {
    failedOf = { ["a refusal"] = "refused text", ["a plain error"] = "plain text" },
    unknownOf = { ["a refusal after a write"] = "refused text", ["not found after a write"] = "Photo not found: 9" },
    notFoundOf = { ["not found"] = "9" },
}

describe("spec_helper class oracles", function()
    before_each(function() helper.installImport({}) end)

    for oracle, accepted in pairs(accepts) do
        for _, outcome in ipairs(outcomes) do
            local wanted = accepted[outcome.name]
            it(oracle .. (wanted and " returns the text of " or " rejects ") .. outcome.name, function()
                local ok, result = pcall(helper[oracle], outcome.call)
                if wanted then
                    assert.is_true(ok, tostring(result))
                    assert.are.equal(wanted, result)
                else
                    assert.is_false(ok)
                    assert.truthy(tostring(result):find("expected ", 1, true), tostring(result))
                end
            end)
        end
    end
end)

describe("spec_helper.outcomeOf", function()
    before_each(function() helper.installImport({}) end)

    local written = function(context) context.ledger:record("Set Rating") end
    local cases = {
        { name = "a success", call = function() return 1 end, class = "answered", detail = { data = 1 } },
        { name = "a refusal before any write", call = function() Reply.refuse("refused text") end, class = "failed",
            detail = "refused text" },
        { name = "a plain error before any write", call = function() error("plain text", 0) end, class = "failed",
            detail = "plain text" },
        { name = "not found before any write", call = function() Reply.notFound("9") end, class = "answered",
            detail = { not_found = { "9" } } },
        { name = "a refusal after a write", call = function(context) written(context); Reply.refuse("refused text") end,
            class = "unknown", detail = "refused text; written before this stopped: Set Rating" },
    }
    for _, case in ipairs(cases) do
        it("derives " .. case.class .. " from " .. case.name, function()
            local class, detail = helper.outcomeOf(case.call)
            assert.are.same({ case.class, case.detail }, { class, detail })
        end)
    end
end)
