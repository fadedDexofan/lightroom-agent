require "spec_helper"

describe("PluginServerPolicy", function()
    local PluginServerPolicy

    before_each(function()
        package.loaded.PluginServerPolicy = nil
        PluginServerPolicy = require "PluginServerPolicy"
    end)

    describe("isSuperseded", function()
        it("treats only a readable, different token as proof of a newer instance", function()
            assert.is_true(PluginServerPolicy.isSuperseded("mine", "theirs"))
            assert.is_false(PluginServerPolicy.isSuperseded("mine", "mine"))
            assert.is_false(PluginServerPolicy.isSuperseded("mine", nil))
            assert.is_false(PluginServerPolicy.isSuperseded("mine", ""))
            assert.is_false(PluginServerPolicy.isSuperseded(nil, "theirs"))
        end)
    end)

    describe("staleRestart", function()
        it("does not restart while idle is within the soft threshold", function()
            local restart, suffix = PluginServerPolicy.staleRestart(89, 0)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it(
            "treats exactly-at-threshold idle as not yet past it (strict greater-than)",
            function() assert.is_false((PluginServerPolicy.staleRestart(90, 0))) end
        )

        it("restarts once idle passes the soft threshold with nothing in flight", function()
            local restart, suffix = PluginServerPolicy.staleRestart(91, 0)
            assert.is_true(restart)
            assert.are.equal("", suffix)
        end)

        it("defers the restart past the soft threshold while a request is genuinely in flight", function()
            local restart, suffix = PluginServerPolicy.staleRestart(91, 1)
            assert.is_false(restart)
            assert.are.equal("", suffix)
        end)

        it(
            "treats exactly-at-hard-cap idle as not yet past it while a request is in flight",
            function() assert.is_false((PluginServerPolicy.staleRestart(120, 1))) end
        )

        it("still restarts past the hard cap even if a request is in flight, to bound the wait", function()
            local restart, suffix = PluginServerPolicy.staleRestart(121, 1)
            assert.is_true(restart)
            assert.are.equal(" [hard cap, request still in flight]", suffix)
        end)
    end)

    describe("bindFailureLogDue", function()
        it("logs the first failure and repeats only once the interval has passed", function()
            assert.is_true(PluginServerPolicy.bindFailureLogDue(nil, 2000))
            assert.is_false(PluginServerPolicy.bindFailureLogDue(2000, 2009))
            assert.is_true(PluginServerPolicy.bindFailureLogDue(2000, 2010))
        end)
    end)
end)
