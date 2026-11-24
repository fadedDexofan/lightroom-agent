local helper = require "spec_helper"

local function setup(imports)
    local catalog = helper.fakeCatalog({
        photos = {
            helper.fakePhoto({ id = "1", path = "/1.jpg", fileName = "one.jpg" }),
            helper.fakePhoto({ id = "2", path = "/2.jpg", fileName = "two.jpg" }),
            helper.fakePhoto({ id = "3", path = "/3.jpg", fileName = "three.jpg" }),
            helper.fakePhoto({ id = "4", path = "/4.jpg", fileName = "four.jpg" }),
            helper.fakePhoto({ id = "5", path = "/5.jpg", fileName = "five.jpg" }),
        },
    })
    helper.installImport(imports or {})
    package.loaded.PhotoBatch = nil
    return require "PhotoBatch", catalog
end

local function watchingProgress(events, portions)
    return {
        LrProgressScope = function(args)
            events[#events + 1] = "opened " .. tostring(args.title)
            return {
                setCancelable = function() end,
                setPortionComplete = function(_, done, total) portions[#portions + 1] = { done, total } end,
                setCaption = function(_, caption) events[#events + 1] = "caption " .. tostring(caption) end,
                isCanceled = function() return false end,
                done = function() end,
            }
        end,
    }
end

local function showingProgress()
    local context = helper.requestContext()
    context.report = getmetatable(context).report
    return context
end

describe("PhotoBatch.run", function()
    it("stops_at_reserve: lists the photo that does not fit and every later one as remaining, as given", function()
        local PhotoBatch, catalog = setup()
        local answers, asked = { false, true, false }, 0
        local context = helper.requestContext(nil, {
            stopping = function()
                asked = asked + 1
                return answers[asked]
            end,
        })
        local seen = {}

        local batch = PhotoBatch.run(context, catalog, {
            inputs = { "1", "/2.jpg", 3 },
            reserveSeconds = 5,
            each = function(photo)
                seen[#seen + 1] = tostring(photo.localIdentifier)
                return { status = "done" }
            end,
        })

        assert.are.same({ "/2.jpg", 3 }, batch.remaining)
        assert.are.same({ "1" }, seen)
        assert.are.same({ { status = "done", photo_id = "1" } }, batch.results)
    end)

    it("duplicates_drop: acts once on a photo named by id and by path and names an unknown input once", function()
        local PhotoBatch, catalog = setup()
        local seen = {}

        local batch = PhotoBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/missing.jpg", "/1.jpg", "2", "/missing.jpg" },
            reserveSeconds = 0,
            each = function(photo, entry)
                seen[#seen + 1] = tostring(photo.localIdentifier) .. " as " .. tostring(entry.id)
                return { status = "done" }
            end,
        })

        assert.are.same({ "1 as 1", "2 as 2" }, seen)
        assert.are.same({ { status = "done", photo_id = "1" }, { status = "done", photo_id = "2" } }, batch.results)
        assert.are.same({ "/missing.jpg" }, batch.not_found)
        assert.are.same({}, batch.failed)
    end)

    it("duplicates_refuse: fails every input of a photo listed twice, naming both, without acting on it", function()
        local PhotoBatch, catalog = setup()
        local seen = {}

        local batch = PhotoBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2", "/1.jpg" },
            duplicates = "refuse",
            held = function(entry)
                if entry.index == 3 then return { remaining = true } end
            end,
            reserveSeconds = 0,
            each = function(photo)
                seen[#seen + 1] = tostring(photo.localIdentifier)
                return { status = "done" }
            end,
        })
        local seenWithInput = {}
        local ruled = PhotoBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/1.jpg", "2", "/3.jpg", "3", "4" },
            duplicates = "refuse",
            held = function(entry)
                if entry.index == 4 or entry.index == 6 then return { reason = "Refused before writing: rule" } end
            end,
            reserveSeconds = 0,
            each = function(photo, entry)
                seenWithInput[#seenWithInput + 1] = tostring(photo.localIdentifier) .. "@" .. entry.index
                return {}
            end,
        })

        assert.are.same({
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is 1" },
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is /1.jpg" },
        }, batch.failed)
        assert.are.same({ { status = "done", photo_id = "2" } }, batch.results)
        assert.are.same({ "2" }, seen)
        assert.are.same({}, batch.remaining)
        assert.are.same({ "2@3" }, seenWithInput)
        assert.are.same({
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is 1" },
            { photo_id = "1", reason = "listed twice, as 1 and /1.jpg; this is /1.jpg" },
            { photo_id = "3", reason = "listed twice, as /3.jpg and 3; this is /3.jpg" },
            { photo_id = "3", reason = "listed twice, as /3.jpg and 3; this is 3" },
            { photo_id = "4", reason = "Refused before writing: rule" },
        }, ruled.failed)
    end)

    it("classes_by_own_writes: files a raising photo as failed with no writes of its own, else unknown", function()
        local PhotoBatch, catalog = setup()
        local Reply = require "Reply"
        local context = helper.requestContext()

        local batch = PhotoBatch.run(context, catalog, {
            inputs = { "1", "2", "3", "4", "5" },
            reserveSeconds = 0,
            each = function(photo)
                local id = photo.localIdentifier
                if id == "1" then
                    context.ledger:record("rating of 1")
                    return { status = "done" }
                end
                if id == "2" then Reply.refuse("nothing to change") end
                if id == "3" then error("write rejected") end
                if id == "4" then
                    context.ledger:record("setValue", true)
                    Reply.refuse("the value did not read back")
                end
                context.ledger:record("rating of 5")
                error("write rejected")
            end,
        })

        assert.are.same(
            { { photo_id = "2", reason = "nothing to change" }, { photo_id = "3", reason = "write rejected" } },
            batch.failed
        )
        assert.are.same({
            { photo_id = "4", reason = "the value did not read back; written before this stopped: setValue" },
            { photo_id = "5", reason = "write rejected; written before this stopped: rating of 5" },
        }, batch.unknown)
        assert.are.same({ { status = "done", photo_id = "1" } }, batch.results)
    end)

    it("held_before_budget: gives a held photo its held class even once the budget is spent", function()
        local PhotoBatch, catalog = setup()
        local seen = {}
        local function heldBack(entry)
            if entry.index == 2 then return { remaining = true } end
            if entry.index == 3 then return { reason = "Refused before writing: rule" } end
        end
        local function each(photo)
            seen[#seen + 1] = tostring(photo.localIdentifier)
            return { status = "done" }
        end

        local spent = PhotoBatch.run(helper.requestContext(0), catalog, {
            inputs = { "1", "2", "3" },
            reserveSeconds = 1,
            held = heldBack,
            each = each,
        })
        local spentSeen = seen
        seen = {}
        local open = PhotoBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "/2.jpg", "3" },
            reserveSeconds = 0,
            held = function(entry)
                if entry.index == 2 then return { remaining = true } end
            end,
            each = each,
        })

        assert.are.same({ { photo_id = "3", reason = "Refused before writing: rule" } }, spent.failed)
        assert.are.same({ "1", "2" }, spent.remaining)
        assert.are.same({}, spentSeen)
        assert.are.same({ "1", "3" }, seen)
        assert.are.same({ "/2.jpg" }, open.remaining)
    end)

    it("prepares once, and only when a photo is attempted", function()
        local PhotoBatch, catalog = setup()
        local prepared = 0
        local operation = {
            inputs = { "1", "2" },
            reserveSeconds = 60,
            prepare = function() prepared = prepared + 1 end,
            each = function() return { status = "done" } end,
        }

        PhotoBatch.run(helper.requestContext(30), catalog, operation)
        assert.are.equal(0, prepared)

        PhotoBatch.run(helper.requestContext(), catalog, operation)
        assert.are.equal(1, prepared)
    end)

    it("asks for a reserve that grows with every photo started", function()
        local PhotoBatch, catalog = setup()
        local asked = {}
        local context = helper.requestContext(nil, {
            stopping = function(_, seconds)
                asked[#asked + 1] = seconds
                return false
            end,
        })
        PhotoBatch.run(context, catalog, {
            inputs = { "1", "2", "3" },
            reserveSeconds = function(started) return 1 + started end,
            each = function() return {} end,
        })

        assert.are.same({ 1, 2, 3 }, asked)
    end)

    it("keeps every photo's outcome when one photo's file name cannot be read for the progress caption", function()
        local PhotoBatch, catalog = setup()
        catalog:getPhotoByLocalId(3).getFormattedMetadata = function() error("photo vanished") end
        local seen = {}
        local batch = PhotoBatch.run(helper.requestContext(), catalog, {
            inputs = { "1", "2", "3" },
            held = function(entry)
                if entry.index == 1 then return { reason = "Refused before writing: rule" } end
            end,
            reserveSeconds = 0,
            progress = "Writing settings",
            each = function(photo)
                seen[#seen + 1] = tostring(photo.localIdentifier)
                return { status = "done" }
            end,
        })

        assert.are.same({ "2", "3" }, seen)
        assert.are.same({ { photo_id = "1", reason = "Refused before writing: rule" } }, batch.failed)
        assert.are.equal(2, #batch.results)
    end)

    it("progress_captions: shows progress under the title with each photo's file name, then Done", function()
        local events, portions = {}, {}
        local PhotoBatch, catalog = setup(watchingProgress(events, portions))

        PhotoBatch.run(showingProgress(), catalog, {
            inputs = { "1", "2" },
            reserveSeconds = 0,
            progress = "Applying presets",
            each = function(photo)
                events[#events + 1] = "work " .. tostring(photo.localIdentifier)
                return { status = "done" }
            end,
        })

        assert.are.same({
            "opened Applying presets",
            "caption one.jpg",
            "work 1",
            "caption two.jpg",
            "work 2",
            "caption Done",
        }, events)
        assert.are.same({ { 0, 2 }, { 1, 2 }, { 2, 2 } }, portions)
    end)

    it("no_progress_without_title: works through the photos without showing progress", function()
        local events, portions = {}, {}
        local PhotoBatch, catalog = setup(watchingProgress(events, portions))

        PhotoBatch.run(showingProgress(), catalog, {
            inputs = { "1", "2" },
            reserveSeconds = 0,
            each = function(photo)
                events[#events + 1] = "work " .. tostring(photo.localIdentifier)
                return { status = "done" }
            end,
        })

        assert.are.same({ "work 1", "work 2" }, events)
        assert.are.same({}, portions)
    end)

    it(
        "cancel_stops_at_boundary: starts no photo once its progress is cancelled, listing the rest as remaining",
        function()
            local cancelled, events = false, {}
            local PhotoBatch, catalog = setup({
                LrProgressScope = function(args)
                    events[#events + 1] = "opened " .. tostring(args.title)
                    return {
                        setCancelable = function() end,
                        setPortionComplete = function() end,
                        setCaption = function(_, caption) events[#events + 1] = "caption " .. tostring(caption) end,
                        isCanceled = function() return cancelled end,
                        done = function() end,
                    }
                end,
            })

            local batch = PhotoBatch.run(showingProgress(), catalog, {
                inputs = { "1", "/2.jpg", 3 },
                reserveSeconds = 0,
                progress = "Applying presets",
                each = function(photo)
                    events[#events + 1] = "work " .. tostring(photo.localIdentifier)
                    cancelled = true
                    return { status = "done" }
                end,
            })

            assert.are.same({ "opened Applying presets", "caption one.jpg", "work 1", "caption Done" }, events)
            assert.are.same({ "/2.jpg", 3 }, batch.remaining)
            assert.are.same({ { status = "done", photo_id = "1" } }, batch.results)
        end
    )

    it("confirm_counts_confirmed: counts only the results the confirm step confirms", function()
        local PhotoBatch, catalog = setup()
        local function confirmingPhoto(confirmedId)
            return function(results)
                local verdict = { confirmed = {}, failed = {}, unknown = {} }
                for _, result in ipairs(results) do
                    if result.photo_id == confirmedId then
                        verdict.confirmed[#verdict.confirmed + 1] = result
                    else
                        verdict.unknown[#verdict.unknown + 1] =
                            { photo_id = result.photo_id, reason = "read-back differs" }
                    end
                end
                return verdict
            end
        end
        local function operation(confirm)
            return {
                inputs = { "1", "2" },
                reserveSeconds = 0,
                each = function() return { status = "written" } end,
                confirm = confirm,
            }
        end

        local one = PhotoBatch.run(helper.requestContext(), catalog, operation(confirmingPhoto("1")))
        local none = PhotoBatch.run(helper.requestContext(), catalog, operation(confirmingPhoto(nil)))

        assert.are.same({ { status = "written", photo_id = "1" } }, one.results)
        assert.are.same({ { photo_id = "2", reason = "read-back differs" } }, one.unknown)
        assert.are.same({}, none.results)
        assert.are.same({
            { photo_id = "1", reason = "read-back differs" },
            { photo_id = "2", reason = "read-back differs" },
        }, none.unknown)
    end)
end)

describe("PhotoBatch.reply", function()
    it(
        "reply_data_only_for_results: builds data only from results, keeps the caller's parts, then the report's",
        function()
            local PhotoBatch, catalog = setup()
            local Reply = require "Reply"
            local reported = {}
            local function confirmingPhoto(confirmedId)
                return function(results)
                    local verdict = { confirmed = {}, unknown = {} }
                    for _, result in ipairs(results) do
                        if result.photo_id == confirmedId then
                            verdict.confirmed[#verdict.confirmed + 1] = result
                        else
                            verdict.unknown[#verdict.unknown + 1] =
                                { photo_id = result.photo_id, reason = "read-back differs" }
                        end
                    end
                    verdict.report = function(data)
                        reported[#reported + 1] = data or "no data"
                        if data then data.adjusted = { "by the report" } end
                        return { data = data, warnings = { "report warning" }, problem = "report problem" }
                    end
                    return verdict
                end
            end
            local function run(inputs, confirm)
                return PhotoBatch.run(helper.requestContext(), catalog, {
                    inputs = inputs,
                    reserveSeconds = 0,
                    each = function() return { status = "written" } end,
                    confirm = confirm,
                })
            end
            local built = {}
            local function dataOf(results)
                built[#built + 1] = #results
                return { written = #results }
            end
            local function own() return { problem = "own problem" } end

            local plain = PhotoBatch.reply(run({ "1", "/missing.jpg" }), dataOf)
            local confirmed = PhotoBatch.reply(run({ "1", "2" }, confirmingPhoto("1")), dataOf, own())
            local unconfirmed = PhotoBatch.reply(run({ "1", "2" }, confirmingPhoto(nil)), dataOf, own())
            local unresolved = PhotoBatch.reply(run({ "/missing.jpg" }, confirmingPhoto("1")), dataOf, own())

            assert.is_true(Reply.isParts(plain))
            assert.are.same({ written = 1 }, plain.data)
            assert.are.same({ "/missing.jpg" }, plain.not_found)
            assert.is_nil(plain.failed)
            assert.is_nil(plain.unknown)
            assert.is_nil(plain.warnings)
            assert.is_nil(plain.problem)

            assert.are.same({ written = 1, adjusted = { "by the report" } }, confirmed.data)
            assert.are.same({ { photo_id = "2", reason = "read-back differs" } }, confirmed.unknown)
            assert.are.same({ "report warning" }, confirmed.warnings)
            assert.are.equal("own problem; report problem", confirmed.problem)

            assert.is_nil(unconfirmed.data)
            assert.are.same({
                { photo_id = "1", reason = "read-back differs" },
                { photo_id = "2", reason = "read-back differs" },
            }, unconfirmed.unknown)
            assert.are.same({ "report warning" }, unconfirmed.warnings)
            assert.are.equal("own problem; report problem", unconfirmed.problem)

            assert.is_nil(unresolved.data)
            assert.are.same({ "/missing.jpg" }, unresolved.not_found)
            assert.are.equal("own problem", unresolved.problem)

            assert.are.same({ 1, 1 }, built)
            assert.are.same({ { written = 1, adjusted = { "by the report" } }, "no data" }, reported)
        end
    )
end)
