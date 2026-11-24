local helper = require "spec_helper"

local function setup(imports)
    local photos = {
        helper.fakePhoto({ id = "1", path = "/1.jpg", fileName = "one.jpg" }),
        helper.fakePhoto({ id = "2", path = "/2.jpg", fileName = "two.jpg" }),
    }
    local catalog = helper.fakeCatalog({ photos = photos })
    local installed = {
        LrApplicationView = { getCurrentModuleName = function() return "library" end, switchToModule = function() end },
        LrDevelopController = {},
        LrSelection = { selectNone = function() end },
        LrTasks = { pcall = pcall, sleep = function() end },
        LrLogger = helper.defaultLrLogger(),
    }
    for name, module in pairs(imports or {}) do
        installed[name] = module
    end
    helper.installImport(installed)
    package.loaded.DevelopSession = nil
    package.loaded.PhotoBatch = nil
    package.loaded.DevelopBatch = nil
    return require "DevelopBatch", catalog
end

describe("DevelopBatch.run", function()
    it(
        "session_around_loop: works through every photo in one Develop session, committing its controller writes after the last",
        function()
            local events = {}
            local DevelopBatch, catalog = setup({
                LrApplicationView = {
                    getCurrentModuleName = function() return "develop" end,
                    switchToModule = function() end,
                },
                LrDevelopController = {
                    stopTracking = function(commit) events[#events + 1] = "commit " .. tostring(commit) end,
                },
            })
            local context = helper.requestContext()
            local states = {}

            DevelopBatch.run(context, catalog, {
                inputs = { "1", "2" },
                reserveSeconds = 0,
                prepare = function(_, state) states[#states + 1] = state end,
                each = function(photo, state)
                    states[#states + 1] = state
                    events[#events + 1] = "work " .. tostring(photo.localIdentifier)
                    context.ledger:record("setValue", true)
                    return {}
                end,
            })

            assert.are.same({ "work 1", "work 2", "commit true" }, events)
            assert.are.equal(3, #states)
            assert.is_table(states[1])
            assert.are.equal(states[1], states[2])
            assert.are.equal(states[1], states[3])
        end
    )

    it("results_as_data: replies with each photo's result under data.results", function()
        local DevelopBatch, catalog = setup()

        local reply = DevelopBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2" },
            reserveSeconds = 0,
            each = function() return { status = "done" } end,
        })

        assert.are.same(
            { { status = "done", photo_id = "1" }, { status = "done", photo_id = "2" } },
            reply.data.results
        )
    end)

    it(
        "confirm_reaches_reply: replies with the confirmed results only, the confirm's classes and its report",
        function()
            local DevelopBatch, catalog = setup()

            local reply = DevelopBatch.run(helper.requestContext(), catalog, {
                inputs = { "1", "2" },
                reserveSeconds = 0,
                each = function() return { status = "written" } end,
                confirm = function(results)
                    return {
                        confirmed = { results[1] },
                        unknown = { { photo_id = results[2].photo_id, reason = "read-back differs" } },
                        report = function(data)
                            if data then data.adjusted = { "by the report" } end
                            return { data = data, warnings = { "report warning" } }
                        end,
                    }
                end,
            })

            assert.are.same(
                { results = { { status = "written", photo_id = "1" } }, adjusted = { "by the report" } },
                reply.data
            )
            assert.are.same({ { photo_id = "2", reason = "read-back differs" } }, reply.unknown)
            assert.are.same({ "report warning" }, reply.warnings)
        end
    )

    it(
        "data_of_shapes_reply: builds data with the operation's dataOf from the read-back's confirmed results",
        function()
            local DevelopBatch, catalog = setup()
            package.loaded.DevelopReadBack = nil
            local DevelopReadBack = require "DevelopReadBack"
            local one, two = catalog:getPhotoByLocalId("1"), catalog:getPhotoByLocalId("2")
            one.getDevelopSettings = function() return { Exposure2012 = 0.5 } end
            two.getDevelopSettings = function() return {} end
            local context = helper.requestContext()
            local seen = {}

            local reply = DevelopBatch.run(context, catalog, {
                inputs = { "1", "2" },
                reserveSeconds = 0,
                each = function(photo)
                    local from = context.ledger:mark()
                    context.ledger:record("Set Develop Settings")
                    return {
                        written = {
                            photo = photo,
                            settings = { Exposure2012 = 0.5 },
                            before = { Exposure2012 = 0 },
                            from = from,
                            to = context.ledger:mark(),
                        },
                    }
                end,
                confirm = DevelopReadBack.confirm(context, catalog),
                dataOf = function(results)
                    local rows = {}
                    for index, result in ipairs(results) do
                        seen[index] = { photo_id = result.photo_id, stored = result.stored, written = result.written }
                        rows[index] = { photo_id = result.photo_id, settings = result.stored }
                    end
                    return { results = rows }
                end,
            })

            assert.are.equal(1, #seen)
            assert.are.equal("1", seen[1].photo_id)
            assert.are.same({ Exposure2012 = 0.5 }, seen[1].stored)
            assert.are.equal(one, seen[1].written.photo)
            assert.are.same({ results = { { photo_id = "1", settings = { Exposure2012 = 0.5 } } } }, reply.data)
            assert.are.same(
                { { photo_id = "2", reason = "Lightroom shows no Exposure2012 after the write" } },
                reply.unknown
            )
        end
    )
end)
