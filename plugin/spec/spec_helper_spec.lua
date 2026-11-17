local helper = require 'spec_helper'
local Reply = require 'Reply'

local outcomes = {
    { name = "a success", call = function() return 1 end, rejection = "but the call succeeded" },
    { name = "a refusal", call = function() Reply.refuse("refused text") end, rejection = "got" },
    { name = "not found", call = function() Reply.notFound("9") end, rejection = "got" },
    { name = "a plain error", call = function() error("plain text", 0) end, rejection = "got" },
}

local accepts = {
    refusalOf = { ["a refusal"] = "refused text" },
    unknownOf = { ["a plain error"] = "plain text" },
    notFoundOf = { ["not found"] = "9" },
}

describe("spec_helper class oracles", function()
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
                    assert.truthy(tostring(result):find(outcome.rejection, 1, true), tostring(result))
                end
            end)
        end
    end
end)
