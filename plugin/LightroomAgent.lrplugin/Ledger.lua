local LrTasks = import "LrTasks"

local Ledger = {}
Ledger.__index = Ledger

function Ledger.new() return setmetatable({ entries = {} }, Ledger) end

function Ledger:record(what, byController)
    self.entries[#self.entries + 1] = { what = what, byController = byController == true }
end

function Ledger:mark() return #self.entries end

function Ledger:controllerWroteSince(mark)
    for index = mark + 1, #self.entries do
        if self.entries[index].byController then return true end
    end
    return false
end

function Ledger:undone(mark, upTo)
    for index = mark + 1, upTo or #self.entries do
        self.entries[index].undone = true
    end
end

function Ledger:since(mark, upTo)
    local seen, names = {}, {}
    for index = mark + 1, upTo or #self.entries do
        local entry = self.entries[index]
        if not entry.undone and not seen[entry.what] then
            seen[entry.what] = true
            names[#names + 1] = entry.what
        end
    end
    return names
end

function Ledger:live() return self:since(0) end

function Ledger:attempt(fn, ...)
    local mark = self:mark()
    local ok, value = LrTasks.pcall(fn, ...)
    if ok then return true, value end
    return false, value, self:since(mark)
end

return Ledger
