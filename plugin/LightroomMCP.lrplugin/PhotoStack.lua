local PhotoStack = {}

local RAW_KEYS = { 'isInStackInFolder', 'stackPositionInFolder', 'stackInFolderIsCollapsed',
    'topOfStackInFolderContainingPhoto' }

function PhotoStack.withRawKeys(keys)
    local all = {}
    for _, key in ipairs(keys) do all[#all + 1] = key end
    for _, key in ipairs(RAW_KEYS) do all[#all + 1] = key end
    return all
end

local function idOf(photo)
    return photo and tostring(photo.localIdentifier)
end

function PhotoStack.of(raw, members)
    if not raw.isInStackInFolder then return nil end
    local stack = {
        position = raw.stackPositionInFolder,
        is_collapsed = raw.stackInFolderIsCollapsed == true,
        top_photo_id = idOf(raw.topOfStackInFolderContainingPhoto),
    }
    if members and #members > 0 then
        stack.member_photo_ids = {}
        for i, member in ipairs(members) do stack.member_photo_ids[i] = idOf(member) end
    end
    return stack
end

function PhotoStack.isCollapsedTop(stack)
    return stack ~= nil and stack.is_collapsed and stack.position == 1
end

return PhotoStack
