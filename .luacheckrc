std = "lua51"
max_line_length = false
exclude_files = { "plugin/LightroomAgent.lrplugin/JSON.lua", "lua_modules" }

read_globals = {}
for line in io.lines("lightroom.yml") do
    local name = line:match("^  ([%w_]+):")
    if name then read_globals[#read_globals + 1] = name end
end

files["plugin/spec"] = {
    std = "+busted",
    globals = { "require", io = { fields = { "open" } }, table = { fields = { "sort" } } },
    read_globals = { package = { fields = { "searchpath" } } },
}

files["plugin/LightroomAgent.lrplugin/HandlerDevelop.lua"] = { ignore = { "241/autoFunctions" } }
