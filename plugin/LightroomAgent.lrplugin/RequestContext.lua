local LrDate = import 'LrDate'
local LrProgressScope = import 'LrProgressScope'

local Ledger = require 'Ledger'

local RequestContext = {}
RequestContext.__index = RequestContext

function RequestContext.new(title, budgetMs, sendProgress)
    return setmetatable({
        title = title,
        cancelled = false,
        deadline = LrDate.currentTime() + budgetMs / 1000,
        lastProgress = -1,
        sendProgress = sendProgress,
        warnings = {},
        ledger = Ledger.new(),
    }, RequestContext)
end

function RequestContext:isCanceled()
    return self.cancelled or (self.scope ~= nil and self.scope:isCanceled())
end

function RequestContext:timeLeft()
    return self.deadline - LrDate.currentTime()
end

function RequestContext:stopping(reserveSeconds)
    return self:isCanceled() or self:timeLeft() < reserveSeconds
end

function RequestContext:report(progress, total, message)
    if not self.scope then
        self.scope = LrProgressScope { title = self.title, caption = "Starting" }
        self.scope:setCancelable(true)
    end
    self.scope:setPortionComplete(progress, math.max(total, 1))
    self.scope:setCaption(tostring(message))
    if self.sendProgress and progress > self.lastProgress then
        self.lastProgress = progress
        self.sendProgress({ progress = progress, total = total, message = tostring(message) })
    end
end

function RequestContext:warn(text)
    self.warnings[#self.warnings + 1] = text
end

function RequestContext:finish()
    if self.scope then self.scope:done() end
end

return RequestContext
