local helper = require 'spec_helper'

local function load(clock, scopes)
    helper.installImport({
        LrDate = { currentTime = function() return clock.now end },
        LrProgressScope = function(options)
            local scope = { options = options, portions = {}, cancelled = false, finished = false }
            function scope.setCancelable() end
            function scope.setPortionComplete(_, done, total) scope.portions[#scope.portions + 1] = { done, total } end
            function scope.setCaption() end
            function scope.isCanceled() return scope.cancelled end
            function scope.done() scope.finished = true end
            scopes[#scopes + 1] = scope
            return scope
        end,
    })
    package.loaded.RequestContext = nil
    return require 'RequestContext'
end

describe("RequestContext", function()
    it("derives its deadline from the budget the server sent", function()
        local clock = { now = 100 }
        local RequestContext = load(clock, {})
        local context = RequestContext.new("export_photos", 30000)
        assert.are.equal(30, context:timeLeft())
        clock.now = 125
        assert.are.equal(5, context:timeLeft())
        assert.is_false(context:stopping(5))
        assert.is_true(context:stopping(6))
    end)

    it("sets no deadline without a budget", function()
        local clock = { now = 100 }
        local context = load(clock, {}).new("ping", nil)
        clock.now = 1e9
        assert.are.equal(math.huge, context:timeLeft())
        assert.is_false(context:stopping(3600))
    end)

    it("stops when cancelled by the server or from the progress scope", function()
        local scopes = {}
        local RequestContext = load({ now = 0 }, scopes)
        local byServer = RequestContext.new("a", 30000)
        byServer.cancelled = true
        assert.is_true(byServer:stopping(0))
        local byScope = RequestContext.new("b", 30000)
        byScope:report(0, 2, "first")
        scopes[1].cancelled = true
        assert.is_true(byScope:isCanceled())
    end)

    it("opens a progress scope on first report and sends only increasing progress", function()
        local scopes, sent = {}, {}
        local context = load({ now = 0 }, scopes).new("apply_denoise", 30000, function(progress)
            sent[#sent + 1] = progress.progress
        end)
        context:finish()
        assert.are.equal(0, #scopes)
        context:report(0, 3, "a")
        context:report(1, 3, "b")
        context:report(1, 3, "b again")
        context:report(3, 3, "c")
        context:finish()
        assert.are.equal(1, #scopes)
        assert.are.same({ 0, 1, 3 }, sent)
        assert.is_true(scopes[1].finished)
    end)
end)
