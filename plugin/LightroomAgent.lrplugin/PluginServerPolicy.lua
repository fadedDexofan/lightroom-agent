local Contract = require "Contract"

local BIND_FAILURE_LOG_INTERVAL_SECONDS = 10

-- The MCP server pings every HEARTBEAT_INTERVAL_SECONDS.
-- Treat the connection as stale only after missing roughly three pings in a
-- row, rather than the old fixed 300s idle window. This is what lets a
-- healthy-but-quiet interactive session run indefinitely without tripping a
-- full restart (Automaat review, PR #151: "idle and stale connections are
-- indistinguishable") while still detecting a genuinely dead peer (Windows
-- onClosed unreliability, issue #134) in under two minutes.
local STALE_RECONNECT_SECONDS = Contract.HEARTBEAT_INTERVAL_SECONDS * 3
-- If a request is in flight when the soft threshold above is hit, give it a
-- chance to finish rather than yanking the socket out from under it — but
-- only up to this hard cap past the soft threshold. If the peer is truly
-- dead the in-flight request was already unrecoverable, so the hard cap
-- guarantees we still restart instead of waiting forever on a hung handler.
-- Bounds the blast radius of a stale-triggered restart (Automaat review,
-- PR #151: "a tool call landing in the restart window loses its response").
local STALE_RESTART_HARD_CAP_SECONDS = STALE_RECONNECT_SECONDS + 30

local PluginServerPolicy = {}

-- Reload Plug-in loads a fresh Lua state and does NOT reliably cancel the
-- previous instance's server task (observed on LrC 15.5.1 macOS: the old
-- loop kept running and held a port until Lightroom quit). The two instances
-- share nothing but the disk, and every start rewrites the token file, so a
-- token that is no longer ours means a newer instance took over. An absent
-- or unreadable file proves nothing and must not stop a live server.
function PluginServerPolicy.isSuperseded(myToken, fileToken)
    return myToken ~= nil and fileToken ~= nil and fileToken ~= "" and fileToken ~= myToken
end

function PluginServerPolicy.staleRestart(idleSeconds, inFlightRequests)
    local inFlight = (inFlightRequests or 0) > 0
    local pastSoft = idleSeconds > STALE_RECONNECT_SECONDS
    local pastHard = idleSeconds > STALE_RESTART_HARD_CAP_SECONDS
    local restart = pastSoft and (not inFlight or pastHard)
    local suffix = (inFlight and pastHard) and " [hard cap, request still in flight]" or ""
    return restart, suffix
end

function PluginServerPolicy.bindFailureLogDue(lastLoggedAt, now)
    return lastLoggedAt == nil or now - lastLoggedAt >= BIND_FAILURE_LOG_INTERVAL_SECONDS
end

return PluginServerPolicy
