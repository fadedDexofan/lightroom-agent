local helper = require "spec_helper"

local function setup(opts)
    opts = opts or {}
    local exportSessionCalls = {}
    local catalog = helper.fakeCatalog({ photos = opts.photos or {}, folders = opts.folders })
    -- path -> false | "file" | "directory", as LrFileUtils.exists answers; unlisted paths are directories
    local paths = opts.paths or {}
    local createdDirs = {}
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrFileUtils = {
            exists = function(path)
                if paths[path] == nil then return "directory" end
                return paths[path]
            end,
            createAllDirectories = function(path)
                table.insert(createdDirs, path)
                if not opts.createFails then paths[path] = "directory" end
            end,
        },
        LrPathUtils = {
            child = function(dir, name) return dir .. "/" .. name end,
            parent = function(path) return (path:match("^(.*)/[^/]*$")) end,
            standardizePath = function(path) return (opts.links or {})[path] or path end,
            getStandardFilePath = function() return "/home/u" end,
        },
        LrExportSession = function(args)
            table.insert(exportSessionCalls, args)
            return {
                doExportOnCurrentTask = function() end,
                renditions = function() return helper.fakeRenditions(args) end,
            }
        end,
    })
    if opts.clock then
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrDate = { currentTime = opts.clock },
            LrFileUtils = { exists = function() return "directory" end },
            LrPathUtils = { child = function(dir, name) return dir .. "/" .. name end },
            LrExportSession = function(args)
                table.insert(exportSessionCalls, args)
                return {
                    doExportOnCurrentTask = function() end,
                    renditions = function() return helper.fakeRenditions(args) end,
                }
            end,
        })
    end
    package.loaded.ExportPresets = nil
    package.loaded.HandlerExport = nil
    return catalog, require "HandlerExport", exportSessionCalls, createdDirs
end

describe("HandlerExport.exportPhotos", function()
    it("converts quality to Lightroom's 0 to 1 scale", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })
        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", quality = 50 })
        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })
        assert.are.equal(0.5, calls[1].exportSettings.LR_jpeg_quality)
        assert.are.equal(0.9, calls[2].exportSettings.LR_jpeg_quality)
    end)

    it("refuses a second export while one runs, and frees the lock afterwards", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local secondError
        local context = helper.requestContext(nil, {
            title = "export_photos",
            isCanceled = function()
                secondError = helper.failedOf(
                    function() Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" }) end
                )
                return false
            end,
        })
        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" }, context)
        assert.are.equal("export_photos is already running; wait for it to finish, then call again", secondError)

        assert.are.equal(1, #Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" }).data.files)
    end)

    it("stops waiting for an export stuck on one photo", function()
        local now = 1000
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p }, clock = function() return now end })
        local outcomes = {}
        local called = false
        Handler.exportPhotos(
            { photo_ids = { "1" }, destination = "/out" },
            helper.requestContext(nil, {
                isCanceled = function()
                    if called then return false end
                    called = true
                    now = now + 299
                    outcomes.at_299 = helper.failedOf(
                        function() Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" }) end
                    )
                    now = now + 1
                    outcomes.at_300 = #Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" }).data.files
                    return false
                end,
            })
        )
        assert.are.same(
            { at_299 = "export_photos is already running; wait for it to finish, then call again", at_300 = 1 },
            outcomes
        )
    end)

    it("lists inputs that match no photo as not_found, as given", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        local r = Handler.exportPhotos({ photo_ids = { "1", 999 }, destination = "/out" })
        assert.are.equal(1, #r.data.files)
        assert.are.same({ 999 }, r.not_found)
    end)

    it("stops at the request's budget and lists the photos it did not reach as remaining", function()
        local now = 0
        local photos = {
            helper.fakePhoto({ id = "1", path = "/a.jpg" }),
            helper.fakePhoto({ id = "2", path = "/b.jpg" }),
            helper.fakePhoto({ id = "3", path = "/c.jpg" }),
        }
        local _, Handler, calls = setup({ photos = photos, clock = function() return now end })
        local context = helper.requestContext(150, { report = function() now = now + 50 end })

        local r = Handler.exportPhotos({ photo_ids = { "1", "2", "/c.jpg" }, destination = "/out" }, context)

        assert.are.equal(2, #r.data.files)
        assert.are.same({ "/c.jpg" }, r.remaining)
        assert.are.equal(2, #calls)
    end)

    describe("rendition results", function()
        local function exportWith(renditions, args, writtenFiles, child)
            local p = helper.fakePhoto({ localIdentifier = 1, path = "/a.jpg" })
            local catalog = helper.fakeCatalog({ photos = { p } })
            local written = {}
            for _, path in ipairs(writtenFiles or {}) do
                written[path] = "file"
            end
            helper.installImport({
                LrApplication = { activeCatalog = function() return catalog end },
                LrLogger = helper.defaultLrLogger(),
                LrFileUtils = {
                    exists = function(path)
                        if path == "/out" or path == (args or {}).destination then return "directory" end
                        return written[path] or false
                    end,
                },
                LrPathUtils = { child = child or function(dir, name) return dir .. "/" .. name end },
                LrExportSession = function()
                    return {
                        doExportOnCurrentTask = function() end,
                        renditions = function()
                            local index = 0
                            return function()
                                index = index + 1
                                if renditions[index] then return index, renditions[index] end
                            end
                        end,
                    }
                end,
            })
            package.loaded.HandlerExport = nil
            local request = { photo_ids = { "1" }, destination = "/out" }
            for key, value in pairs(args or {}) do
                request[key] = value
            end
            return require("HandlerExport").exportPhotos(request)
        end

        it("lists the file Lightroom wrote, after renaming it to avoid a collision", function()
            local r = exportWith({
                {
                    destinationPath = "/out/a.jpg",
                    waitForRender = function() return true, "/out/a-2.jpg" end,
                },
            }, nil, { "/out/a-2.jpg" })
            assert.is_nil(r.failed)
            assert.are.same({ { photo_id = "1", path = "/out/a-2.jpg" } }, r.data.files)
        end)

        for _, case in ipairs({
            {
                name = "a later rendition raises",
                reason = "render engine failed",
                renditions = {
                    { waitForRender = function() return true, "/out/a.jpg" end },
                    { waitForRender = function() error("render engine failed", 0) end },
                },
            },
            {
                name = "naming the file raises after Lightroom confirmed it",
                reason = "path join failed",
                renditions = { { waitForRender = function() return true, "/out/a.jpg" end } },
                child = function() error("path join failed", 0) end,
            },
        }) do
            it("export_keeps_confirmed_file: lists a file Lightroom confirmed when " .. case.name, function()
                local r = exportWith(case.renditions, nil, { "/out/a.jpg" }, case.child)
                assert.are.same({ { photo_id = "1", path = "/out/a.jpg" } }, r.data.files)
                assert.is_nil(r.failed)
                assert.are.equal("1", r.unknown[1].photo_id)
                assert.truthy(r.unknown[1].reason:find(case.reason, 1, true))
                assert.truthy(r.unknown[1].reason:find("written before this stopped: Export photo 1", 1, true))
            end)
        end

        it("names a written file under the destination as the caller spelled it", function()
            local r = exportWith({
                {
                    destinationPath = "/tmp/out/a.jpg",
                    waitForRender = function() return true, "/tmp/out/a.jpg" end,
                },
            }, { destination = "/private/tmp/out" }, { "/tmp/out/a.jpg" })
            assert.are.same({ { photo_id = "1", path = "/private/tmp/out/a.jpg" } }, r.data.files)
        end)

        it("lists a skipped existing file's photo as skipped, not exported", function()
            local r = exportWith({}, { on_existing = "skip" })
            assert.is_nil(r.failed)
            assert.are.same({ "1" }, r.data.skipped)
            assert.are.same({}, r.data.files)
        end)

        for _, case in ipairs({
            {
                name = "a render Lightroom refused",
                reason = "could not be written",
                renditions = { { waitForRender = function() return false, "could not be written" end } },
            },
            {
                name = "a render that left no file",
                reason = "Lightroom wrote no file",
                renditions = { { waitForRender = function() return true, "/out/a.jpg" end } },
            },
            { name = "no rendition when not skipping", reason = "Lightroom rendered no file", renditions = {} },
        }) do
            it("reports " .. case.name .. " as unknown, naming the export and what it leaves on the photo", function()
                local r = exportWith(case.renditions)
                assert.is_nil(r.data)
                assert.is_nil(r.failed)
                assert.are.same({
                    {
                        photo_id = "1",
                        reason = case.reason
                            .. "; written before this stopped: Export photo 1"
                            .. " (one Export history step and the exported mark)",
                    },
                }, r.unknown)
            end)
        end

        it(
            "export_one_entry_per_photo: lists a photo whose renditions failed twice once, joining its reasons",
            function()
                local r = exportWith({
                    { waitForRender = function() return false, "could not be written" end },
                    { waitForRender = function() return true, "/out/a.jpg" end },
                })
                assert.is_nil(r.data)
                assert.is_nil(r.failed)
                assert.are.same({
                    {
                        photo_id = "1",
                        reason = "could not be written; Lightroom wrote no file"
                            .. "; written before this stopped: Export photo 1"
                            .. " (one Export history step and the exported mark)",
                    },
                }, r.unknown)
            end
        )

        for _, case in ipairs({ { raises = "export", outcome = "unknown" }, { raises = "session", outcome = "failed" } }) do
            it(
                "records an error on one photo ("
                    .. case.raises
                    .. ") as "
                    .. case.outcome
                    .. " and keeps the files already"
                    .. " written",
                function()
                    local photos = {
                        helper.fakePhoto({ id = "1", path = "/a.jpg" }),
                        helper.fakePhoto({ id = "2", path = "/b.jpg" }),
                        helper.fakePhoto({ id = "3", path = "/c.jpg" }),
                    }
                    local catalog = helper.fakeCatalog({ photos = photos })
                    helper.installImport({
                        LrApplication = { activeCatalog = function() return catalog end },
                        LrLogger = helper.defaultLrLogger(),
                        LrFileUtils = { exists = function(path) return path == "/out" and "directory" or "file" end },
                        LrPathUtils = { child = function(dir, name) return dir .. "/" .. name end },
                        LrExportSession = function(args)
                            local photo = args.photosToExport[1]
                            if case.raises == "session" and photo.localIdentifier == "2" then
                                error("render engine failed", 0)
                            end
                            return {
                                doExportOnCurrentTask = function()
                                    if case.raises == "export" and photo.localIdentifier == "2" then
                                        error("render engine failed", 0)
                                    end
                                end,
                                renditions = function()
                                    local done = false
                                    return function()
                                        if done then return nil end
                                        done = true
                                        return 1,
                                            {
                                                waitForRender = function()
                                                    return true, "/out/" .. photo.localIdentifier .. ".jpg"
                                                end,
                                            }
                                    end
                                end,
                            }
                        end,
                    })
                    package.loaded.HandlerExport = nil

                    local r =
                        require("HandlerExport").exportPhotos({ photo_ids = { "1", "2", "3" }, destination = "/out" })

                    assert.are.same(
                        { { photo_id = "1", path = "/out/1.jpg" }, { photo_id = "3", path = "/out/3.jpg" } },
                        r.data.files
                    )
                    local other = case.outcome == "failed" and "unknown" or "failed"
                    assert.is_nil(r[other])
                    assert.are.equal(1, #r[case.outcome])
                    assert.are.equal("2", r[case.outcome][1].photo_id)
                    assert.truthy(r[case.outcome][1].reason:find("render engine failed", 1, true))
                    assert.are.equal(
                        case.outcome == "unknown",
                        r[case.outcome][1].reason:find("Export history step", 1, true) ~= nil
                    )
                end
            )
        end
    end)

    it("reports rising progress with the photo currently being exported", function()
        local photos = {
            helper.fakePhoto({ id = "1", path = "/a.jpg", fileName = "a.jpg" }),
            helper.fakePhoto({ id = "2", path = "/b.jpg", fileName = "b.jpg" }),
        }
        local _, Handler, calls = setup({ photos = photos })
        local progress = {}
        local context = helper.requestContext(nil, {
            report = function(_, completed, total, message, title)
                progress[#progress + 1] = { completed, total, message, title, exported = #calls }
            end,
        })

        Handler.exportPhotos({ photo_ids = { "1", "2" }, destination = "/out" }, context)

        assert.are.same({
            { 0, 2, "a.jpg", "Exporting photos", exported = 0 },
            { 1, 2, "b.jpg", "Exporting photos", exported = 1 },
            { 2, 2, "Done", "Exporting photos", exported = 2 },
        }, progress)
    end)

    it("cancel keeps finished exports and leaves later photos untouched", function()
        local photos = {
            helper.fakePhoto({ id = "1", path = "/a.jpg" }),
            helper.fakePhoto({ id = "2", path = "/b.jpg" }),
            helper.fakePhoto({ id = "3", path = "/c.jpg" }),
            helper.fakePhoto({ id = "4", path = "/d.jpg" }),
            helper.fakePhoto({ id = "5", path = "/e.jpg" }),
        }
        local _, Handler, calls = setup({ photos = photos })
        local context = helper.requestContext(nil, { isCanceled = function() return #calls >= 2 end })

        local r = Handler.exportPhotos({ photo_ids = { "1", "2", "3", "4", "5" }, destination = "/out" }, context)

        assert.are.same({ "3", "4", "5" }, r.remaining)
        assert.are.same({ { photo_id = "1", path = "/out/1" }, { photo_id = "2", path = "/out/1" } }, r.data.files)
        assert.are.equal(2, #calls)
    end)

    it("exports found photos with default JPEG settings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.is_nil(r.failed)
        assert.are.equal(1, #r.data.files)
        assert.are.equal("/out", r.data.destination)
        assert.are.equal("JPEG", calls[1].exportSettings.LR_format)
    end)

    it("exports a photo named twice, by path and by id, once, and lists a repeated unknown id once", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "1", "/a.jpg", "1", "404", "404" }, destination = "/out" })

        assert.are.equal(1, #r.data.files)
        assert.are.same({ "404" }, r.not_found)
        assert.are.equal(1, #calls)
    end)

    it("creates a missing destination folder before exporting", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls, createdDirs = setup({ photos = { p }, paths = { ["/out/new"] = false } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out/new" })

        assert.is_nil(r.failed)
        assert.are.same({ "/out/new" }, createdDirs)
        assert.are.equal("/out/new", calls[1].exportSettings.LR_export_destinationPathPrefix)
    end)

    for _, case in ipairs({
        {
            what = "with the destination it created as written when it reached no photo",
            canceled = true,
            written = { "/out/new" },
            remaining = { "1" },
        },
        { what = "without written when a photo was exported into the folder it created", canceled = false },
    }) do
        it("answers " .. case.what, function()
            local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
            local _, Handler, calls, createdDirs = setup({ photos = { p }, paths = { ["/out/new"] = false } })
            local context = helper.requestContext(nil, { isCanceled = function() return case.canceled end })

            local class, result = helper.outcomeOf(
                function(ctx) return Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out/new" }, ctx) end,
                context
            )

            assert.are.equal("answered", class)
            assert.are.same({ "/out/new" }, createdDirs)
            assert.are.equal(case.canceled and 0 or 1, #calls)
            assert.are.same(case.written, result.written)
            assert.are.same(case.remaining, result.remaining)
        end)
    end

    it("leaves an existing destination folder alone", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, _, createdDirs = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.are.same({}, createdDirs)
    end)

    it("rejects a destination that is a file, without exporting", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p }, paths = { ["/out.jpg"] = "file" } })

        assert.are.equal(
            "destination is not a directory: /out.jpg",
            helper.failedOf(function() Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out.jpg" }) end)
        )
        assert.are.equal(0, #calls)
    end)

    it("says the folder could not be created when creating it fails", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p }, paths = { ["/ro/sub"] = false }, createFails = true })

        assert.are.equal(
            "could not create destination folder: /ro/sub",
            helper.failedOf(function() Handler.exportPhotos({ photo_ids = { "1" }, destination = "/ro/sub" }) end)
        )
        assert.are.equal(0, #calls)
    end)

    it("rejects a relative destination before creating anything", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        for destination, err in pairs({
            ["relative/x"] = "destination must be an absolute path",
            ["~x"] = "destination must be an absolute path",
        }) do
            local _, Handler, calls, createdDirs = setup({ photos = { p }, paths = { [destination] = false } })

            assert.are.equal(
                err,
                helper.failedOf(function() Handler.exportPhotos({ photo_ids = { "1" }, destination = destination }) end)
            )
            assert.are.same({}, createdDirs)
            assert.are.equal(0, #calls)
        end
    end)

    it("rejects a destination not written canonically, before creating anything", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        for _, destination in ipairs({ "/out/.", "/out//x", "/out/x/../y", "/out/./x", "/out/..", "/out\\x" }) do
            local _, Handler, calls, createdDirs = setup({ photos = { p }, paths = { [destination] = false } })

            local refusal = helper.failedOf(
                function() Handler.exportPhotos({ photo_ids = { "1" }, destination = destination }) end
            )

            assert.truthy(refusal:find("written canonically", 1, true))
            assert.are.same({}, createdDirs)
            assert.are.equal(0, #calls)
        end
    end)

    it("accepts one trailing separator on a destination", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out/" })

        assert.are.equal("/out", calls[1].exportSettings.LR_export_destinationPathPrefix)
    end)

    it("expands a leading ~/ to the home folder", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls, createdDirs = setup({ photos = { p }, paths = { ["/home/u/out"] = false } })

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "~/out" })

        assert.are.same({ "/home/u/out" }, createdDirs)
        assert.are.equal("/home/u/out", calls[1].exportSettings.LR_export_destinationPathPrefix)
        assert.are.equal("/home/u/out", r.data.destination)
    end)

    it("accepts only canonical Windows absolute paths on Windows", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ photos = { p } })
        _G.WIN_ENV = true
        finally(function() _G.WIN_ENV = nil end)
        local export = function(path)
            return function() return Handler.exportPhotos({ photo_ids = { "1" }, destination = path }) end
        end

        for _, path in ipairs({ "C:\\out", "\\\\srv\\s" }) do
            assert.are.equal(path, export(path)().data.destination)
        end
        for path, refusal in pairs({
            ["C:/out"] = "destination must be written canonically: \\ between names, no empty, '.' or '..' names",
            ["C:out"] = "destination must be an absolute path",
            ["/out"] = "destination must be an absolute path",
        }) do
            assert.are.equal(refusal, helper.failedOf(export(path)))
        end
    end)

    it("never lets Lightroom prompt about existing files", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })
        assert.are.equal("rename", calls[1].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "overwrite" })
        assert.are.equal("overwrite", calls[2].exportSettings.LR_collisionHandling)

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", on_existing = "skip" })
        assert.are.equal("skip", calls[3].exportSettings.LR_collisionHandling)
    end)

    describe("overwriting into a catalog folder", function()
        local function catalogSetup(extra)
            local opts = {
                photos = { helper.fakePhoto({ id = "2", path = "/archive/2025/IMG_1234.CR2" }) },
                folders = {
                    helper.fakeFolder("/archive/2025"),
                    helper.fakeFolder("/archive/2026"),
                    helper.fakeFolder("/f" .. "o\204\136" .. "to"),
                },
                links = { ["/link"] = "/archive/2026" },
            }
            for key, value in pairs(extra or {}) do
                opts[key] = value
            end
            return setup(opts)
        end

        it("refuses any catalog folder before rendering or creating anything, naming it and the ways out", function()
            for _, destination in ipairs({ "/archive/2026", "/archive/2025", "/ARCHIVE/2026", "/f\195\182to", "/link" }) do
                local _, Handler, calls, createdDirs = catalogSetup({ paths = { [destination] = false } })
                local err = helper.failedOf(
                    function()
                        Handler.exportPhotos({
                            photo_ids = { "2" },
                            destination = destination,
                            on_existing = "overwrite",
                        })
                    end
                )
                assert.truthy(err:find("a folder of this catalog", 1, true), err)
                assert.truthy(err:find(destination, 1, true), err)
                assert.truthy(err:find("outside the catalog or on_existing rename or skip", 1, true))
                assert.are.equal(0, #calls)
                assert.are.same({}, createdDirs)
            end
        end)

        it("still overwrites outside the catalog, and renames into a catalog folder", function()
            local _, Handler, calls = catalogSetup()
            Handler.exportPhotos({ photo_ids = { "2" }, destination = "/elsewhere", on_existing = "overwrite" })
            Handler.exportPhotos({ photo_ids = { "2" }, destination = "/archive/2026", on_existing = "rename" })
            assert.are.equal(2, #calls)
        end)
    end)

    it("applies width/height constraint", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", width = 2000 })

        local s = calls[1].exportSettings
        assert.is_true(s.LR_size_doConstrain)
        assert.are.equal("wh", s.LR_size_resizeType)
        assert.are.equal("pixels", s.LR_size_units)
        assert.are.equal(2000, s.LR_size_maxWidth)
        assert.are.equal(65000, s.LR_size_maxHeight)
        assert.is_true(s.LR_size_doNotEnlarge)
    end)

    it("maps format strings", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler, calls = setup({ photos = { p } })

        Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out", format = "tiff" })
        assert.are.equal("TIFF", calls[1].exportSettings.LR_format)
    end)

    it("answers only not_found and creates nothing when no photo matches", function()
        local _, Handler, calls, createdDirs = setup({ photos = {}, paths = { ["/out/new"] = false } })
        local r = Handler.exportPhotos({ photo_ids = { "missing" }, destination = "/out/new" })
        assert.is_nil(r.data)
        assert.are.same({ "missing" }, r.not_found)
        assert.are.equal(0, #calls)
        assert.are.same({}, createdDirs)
    end)

    it("resolves photos OUTSIDE the read-access gate", function()
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ photos = { p } })

        local r = Handler.exportPhotos({ photo_ids = { "/a.jpg" }, destination = "/out" })

        assert.are.equal(1, #r.data.files)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("runs the export after releasing catalog read access", function()
        -- Holding read access for the whole export wedged the bridge on
        -- macOS (issue #128). The lock must be released before
        -- doExportOnCurrentTask runs.
        local p = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local insideReadAccess = false
        local exportRanInsideReadAccess = nil
        local catalog = helper.fakeCatalog({ photos = { p } })
        local realWithRead = catalog.withReadAccessDo
        catalog.withReadAccessDo = function(self, fn)
            insideReadAccess = true
            realWithRead(self, fn)
            insideReadAccess = false
        end
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = { exists = function() return "directory" end },
            LrPathUtils = {},
            LrExportSession = function()
                return {
                    doExportOnCurrentTask = function() exportRanInsideReadAccess = insideReadAccess end,
                    renditions = function()
                        return helper.fakeRenditions({ photosToExport = { "x" }, exportSettings = {} })
                    end,
                }
            end,
        })
        package.loaded.ExportPresets = nil
        package.loaded.HandlerExport = nil
        local Handler = require "HandlerExport"

        local r = Handler.exportPhotos({ photo_ids = { "1" }, destination = "/out" })

        assert.are.equal(1, #r.data.files)
        assert.is_false(exportRanInsideReadAccess)
    end)
end)

describe("HandlerExport.exportPhotoMetadata", function()
    local JSON = require "JSON"
    local createdDirs

    local function setupMetadata(opts)
        opts = opts or {}
        createdDirs = {}
        local catalog = helper.fakeCatalog({ photos = opts.photos or {}, targetPhotos = opts.targetPhotos })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = {
                exists = function(path)
                    if opts.existingDir == path then return "directory" end
                    if opts.missingDir == path then return false end
                    local f = io.open(path, "r")
                    if f then
                        f:close()
                        return "file"
                    end
                    return false
                end,
                createAllDirectories = function(path) table.insert(createdDirs, path) end,
                delete = function(path)
                    if not opts.deleteFails then os.remove(path) end
                end,
            },
            LrPathUtils = {
                parent = function(path) return (path:match("^(.*)[/\\][^/\\]*$")) end,
                child = function(dir, name) return dir .. "/" .. name end,
                getStandardFilePath = function() return opts.home or "/home/u" end,
            },
            LrExportSession = function()
                return { doExportOnCurrentTask = function() end }
            end,
        })
        package.loaded.ExportPresets = nil
        package.loaded.HandlerExport = nil
        return catalog, require "HandlerExport"
    end

    local function tempJson()
        local base = os.tmpname()
        os.remove(base)
        return base .. ".json"
    end

    local function readJson(path)
        local file = assert(io.open(path, "r"))
        local text = file:read("*a")
        file:close()
        os.remove(path)
        return JSON:decode(text)
    end

    local function photoOne()
        local places = helper.fakeKeyword("Places")
        local paris = helper.fakeKeyword("Paris", { parent = places })
        return helper.fakePhoto({
            id = 11,
            uuid = "UUID-11",
            path = "/p/a.dng",
            fileName = "a.dng",
            fileFormat = "DNG",
            isVirtualCopy = false,
            dateTimeOriginalISO8601 = "2016-03-13T15:03:39",
            dimensions = { width = 3648, height = 5472 },
            croppedDimensions = { width = 3000, height = 4500 },
            rating = 4,
            title = "A title",
            caption = "",
            gps = { latitude = 51.5, longitude = -0.12 },
            gpsAltitude = 14,
            city = "London",
            keywords = { paris, helper.fakeKeyword("summer") },
        })
    end

    it("writes the given photos' metadata, with keyword paths, to the file", function()
        local p1 = photoOne()
        local p2 = helper.fakePhoto({
            id = 12,
            path = "/p/b.jpg",
            fileName = "b.jpg",
            keywords = {},
            pickStatus = -1,
            colorNameForLabel = "gray",
        })
        local _, Handler = setupMetadata({ photos = { p1, p2 } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11, 12 }, destination = out })

        assert.are.equal(2, r.data.exported)
        assert.is_nil(r.not_found)

        local data = readJson(out)
        assert.are.equal(2, data.version)
        assert.are.equal(2, data.count)
        local a = data.photos[1]
        assert.are.equal("11", a.photo_id)
        assert.are.equal("UUID-11", a.uuid)
        assert.are.equal("/p/a.dng", a.path)
        assert.are.equal("a.dng", a.filename)
        assert.are.equal("2016-03-13T15:03:39", a.capture_time)
        assert.are.equal("DNG", a.file_format)
        assert.is_false(a.is_virtual_copy)
        assert.are.same({ width = 3648, height = 5472 }, a.dimensions)
        assert.are.same({ width = 3000, height = 4500 }, a.cropped_dimensions)
        assert.are.equal(4, a.rating)
        assert.are.same({ "none", "none" }, { a.flag, a.color_label })
        assert.are.equal("A title", a.title)
        assert.are.same({ latitude = 51.5, longitude = -0.12, altitude = 14 }, a.gps)
        assert.are.equal("London", a.location.city)
        assert.are.same({ "Paris", "summer" }, a.keywords)
        assert.are.same({ "Places|Paris", "summer" }, a.keyword_paths)
        assert.is_nil(a.developSettings)

        local b = data.photos[2]
        assert.are.equal("12", b.photo_id)
        assert.are.same({ 0, "reject", "none" }, { b.rating, b.flag, b.color_label })
        assert.is_nil(b.gps)
        assert.is_nil(b.location)
        assert.are.same({}, b.keyword_paths)
    end)

    it("exports the current selection when photo_ids is omitted", function()
        local p1 = photoOne()
        local p2 = helper.fakePhoto({ id = 12, path = "/p/b.jpg", fileName = "b.jpg", keywords = {} })
        local catalog, Handler = setupMetadata({ photos = { p1, p2 }, targetPhotos = { p2 } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ destination = out })

        assert.are.equal(1, r.data.exported)
        assert.are.equal("12", readJson(out).photos[1].photo_id)
        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)

    it("reports unknown ids and still writes the photos it found", function()
        local _, Handler = setupMetadata({ photos = { photoOne() } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11, "nope" }, destination = out })

        assert.are.equal(1, r.data.exported)
        assert.are.same({ "nope" }, r.not_found)
        assert.are.equal(1, readJson(out).count)
    end)

    it("creates the destination folder when it does not exist", function()
        local out = tempJson()
        local dir = out:match("^(.*)[/\\][^/\\]*$")
        local _, Handler = setupMetadata({ photos = { photoOne() }, missingDir = dir })

        Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = out })
        os.remove(out)

        assert.are.same({ dir }, createdDirs)
    end)

    it("refuses an empty export and a relative destination", function()
        local _, Handler = setupMetadata({ photos = { photoOne() }, targetPhotos = {} })
        local out = tempJson()

        assert.are.equal(
            "No photos found to export metadata for",
            helper.failedOf(function() Handler.exportPhotoMetadata({ destination = out }) end)
        )
        local none = Handler.exportPhotoMetadata({ destination = out, photo_ids = { "nope" } })
        assert.is_nil(none.data)
        assert.are.same({ "nope" }, none.not_found)
        assert.is_nil(io.open(out, "r"))
        assert.are.equal(
            "destination must be an absolute path",
            helper.failedOf(
                function() Handler.exportPhotoMetadata({ destination = "out.json", photo_ids = { 11 } }) end
            )
        )
    end)

    it("refuses to replace an existing file unless overwrite is true", function()
        local _, Handler = setupMetadata({ photos = { photoOne() } })
        local out = tempJson()
        local f = assert(io.open(out, "w"))
        f:write("previous")
        f:close()

        assert.are.equal(
            "destination already exists: " .. out .. " (pass overwrite: true to replace it)",
            helper.failedOf(function() Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = out }) end)
        )
        local kept = assert(io.open(out, "r"))
        assert.are.equal("previous", kept:read("*a"))
        kept:close()

        Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = out, overwrite = true })

        assert.are.equal(1, readJson(out).count)
    end)

    it("refuses a file that appears at the destination while photos are read, creating no folder", function()
        local out = tempJson()
        local catalog, Handler =
            setupMetadata({ photos = { photoOne() }, missingDir = out:match("^(.*)[/\\][^/\\]*$") })
        local read = catalog.withReadAccessDo
        catalog.withReadAccessDo = function(self, fn)
            read(self, fn)
            local f = assert(io.open(out, "w"))
            f:write("raced")
            f:close()
        end

        assert.are.equal(
            "destination already exists: " .. out .. " (pass overwrite: true to replace it)",
            helper.failedOf(function() Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = out }) end)
        )
        local kept = assert(io.open(out, "r"))
        assert.are.equal("raced", kept:read("*a"))
        kept:close()
        os.remove(out)
        assert.are.same({}, createdDirs)
    end)

    it("accepts only canonical Windows absolute paths on Windows", function()
        local _, Handler = setupMetadata({ photos = { photoOne() }, targetPhotos = {} })
        _G.WIN_ENV = true
        finally(function() _G.WIN_ENV = nil end)

        for path, refusal in pairs({
            ["C:\\x.json"] = "No photos found to export metadata for",
            ["\\\\srv\\s\\x.json"] = "No photos found to export metadata for",
            ["C:/x.json"] = "destination must be written canonically: \\ between names, no empty, '.' or '..' names",
            ["C:x.json"] = "destination must be an absolute path",
            ["/x.json"] = "destination must be an absolute path",
        }) do
            assert.are.equal(
                refusal,
                helper.failedOf(function() Handler.exportPhotoMetadata({ destination = path }) end)
            )
        end
    end)

    for _, case in ipairs({
        {
            what = "fails a write that failed and whose partial new file it removed",
            fault = "write",
            class = "failed",
            left = nil,
        },
        {
            what = "answers unknown for a failed write whose partial new file stays",
            fault = "write",
            deleteFails = true,
            class = "unknown",
            left = "partial",
        },
        {
            what = "answers unknown for a failed write over a file it was told to overwrite",
            fault = "write",
            existed = true,
            class = "unknown",
            left = "partial",
        },
        { what = "fails an open that failed for a new file", fault = "open", class = "failed", left = nil },
        {
            what = "answers unknown for an open that failed over a file it was told to overwrite",
            fault = "open",
            existed = true,
            class = "unknown",
            left = "old",
        },
    }) do
        it(case.what, function()
            local _, Handler = setupMetadata({ photos = { photoOne() }, deleteFails = case.deleteFails })
            local out = tempJson()
            local realOpen = io.open
            if case.existed then
                local f = assert(realOpen(out, "w"))
                f:write("old")
                f:close()
            end
            io.open = function(path, mode)
                if path == out and mode == "w" and case.fault == "open" then return nil, "Permission denied" end
                local f = realOpen(path, mode)
                if path ~= out or mode ~= "w" or not f then return f end
                return setmetatable({
                    write = function(_, text)
                        f:write(text:sub(1, 5))
                        return nil, "No space left on device"
                    end,
                    close = function() return f:close() end,
                }, {})
            end

            local ok, class, err = pcall(
                helper.outcomeOf,
                function(context)
                    Handler.exportPhotoMetadata(
                        { photo_ids = { 11 }, destination = out, overwrite = case.existed },
                        context
                    )
                end
            )
            io.open = realOpen
            local left = realOpen(out, "r")
            local text = left and left:read("*a")
            if left then left:close() end
            os.remove(out)

            assert.is_true(ok, tostring(class))
            assert.are.equal(case.class, class, err)
            assert.truthy(err:find(case.fault == "open" and "Permission denied" or "No space left on device", 1, true))
            if case.class == "unknown" then
                assert.truthy(err:find("written before this stopped: " .. out, 1, true), err)
            end
            if case.left == "partial" then
                assert.are.equal(5, text and #text)
            else
                assert.are.equal(case.left, text)
            end
        end)
    end

    it("refuses a directory as destination", function()
        local _, Handler = setupMetadata({ photos = { photoOne() }, existingDir = "/data/dir.json" })

        assert.are.equal(
            "destination is a directory: /data/dir.json",
            helper.failedOf(
                function()
                    Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = "/data/dir.json", overwrite = true })
                end
            )
        )
    end)

    it("expands ~/ to the home folder", function()
        local out = tempJson()
        local home, name = out:match("^(.*)/([^/]*)$")
        local _, Handler = setupMetadata({ photos = { photoOne() }, home = home })

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11 }, destination = "~/" .. name })

        assert.are.equal(out, r.data.destination)
        assert.are.equal(1, readJson(out).count)
    end)

    it("writes a photo named twice, by id and by path, once", function()
        local _, Handler = setupMetadata({ photos = { photoOne() } })
        local out = tempJson()

        local r = Handler.exportPhotoMetadata({ photo_ids = { 11, 11, "/p/a.dng" }, destination = out })

        assert.are.equal(1, r.data.exported)
        assert.are.equal(1, readJson(out).count)
    end)

    it("refuses a selection larger than the per-call cap before reading it", function()
        local many = {}
        for i = 1, 1001 do
            many[i] = helper.fakePhoto({ id = i, path = "/p/" .. i .. ".jpg" })
        end
        local catalog, Handler = setupMetadata({ photos = {}, targetPhotos = many })
        local out = tempJson()

        assert.are.equal(
            "1001 photos are selected (or in the filmstrip); export at most 1000 at a time "
                .. "by selecting fewer or passing photo_ids",
            helper.failedOf(function() Handler.exportPhotoMetadata({ destination = out }) end)
        )
        assert.are.equal(0, catalog.getReadAccessCount())
    end)
end)

describe("HandlerExport.renderSource", function()
    local DETAIL = { photo_id = 7, tool = "get_photo_detail" }
    local function detailSetup(opts)
        opts = opts or {}
        local files, deleted, sessions = {}, {}, {}
        local folders = { ["/tmp/lightroom-agent-detail"] = not opts.noBase or nil }
        for _, name in ipairs(opts.leftovers or {}) do
            files["/tmp/lightroom-agent-detail/" .. name] = true
        end
        local catalog =
            helper.fakeCatalog({ photos = { helper.fakePhoto({ localIdentifier = 7, path = "/p/a.arw" }) } })
        helper.installImport({
            LrApplication = { activeCatalog = function() return catalog end },
            LrDate = { currentTime = function() return opts.now or 0 end },
            LrLogger = helper.defaultLrLogger(),
            LrFileUtils = {
                exists = function(path)
                    if path == "/tmp" or folders[path] then return "directory" end
                    for name in pairs(files) do
                        if name:sub(1, #path + 1) == path .. "/" then return "directory" end
                    end
                    return files[path] and "file" or false
                end,
                files = function(directory)
                    local list = {}
                    for path in pairs(files) do
                        if
                            path:sub(1, #directory + 1) == directory .. "/" and not path:find("/", #directory + 2, true)
                        then
                            list[#list + 1] = path
                        end
                    end
                    table.sort(list)
                    local i = 0
                    return function()
                        i = i + 1
                        return list[i]
                    end
                end,
                directoryEntries = function(directory)
                    local seen, list = {}, {}
                    for path in pairs(files) do
                        local child = path:sub(1, #directory + 1) == directory .. "/"
                            and path:match("^[^/]+", #directory + 2)
                        if child and not seen[child] then
                            seen[child] = true
                            list[#list + 1] = directory .. "/" .. child
                        end
                    end
                    table.sort(list)
                    local i = 0
                    return function()
                        i = i + 1
                        return list[i]
                    end
                end,
                delete = function(path)
                    if opts.deleteFails then return end
                    for name in pairs(files) do
                        if name == path or name:sub(1, #path + 1) == path .. "/" then files[name] = nil end
                    end
                    folders[path] = nil
                    deleted[#deleted + 1] = path
                end,
                createAllDirectories = function(path)
                    if opts.noBase then folders["/tmp/lightroom-agent-detail"] = true end
                    folders[path] = true
                end,
            },
            LrPathUtils = {
                parent = function(path) return path:match("^(.+)/[^/]+$") end,
                child = function(dir, name) return dir .. "/" .. name end,
                leafName = function(path) return path:match("[^/]+$") end,
                getStandardFilePath = function(name)
                    assert(name == "temp")
                    return "/tmp"
                end,
            },
            LrExportSession = function(args)
                if opts.sessionError then error(opts.sessionError, 0) end
                sessions[#sessions + 1] = args
                return {
                    doExportOnCurrentTask = function()
                        if opts.renderError then error(opts.renderError, 0) end
                    end,
                    renditions = function()
                        local done = false
                        return function()
                            if done then return nil end
                            done = true
                            local path = args.exportSettings.LR_export_destinationPathPrefix .. "/a.jpg"
                            files[path] = true
                            return 1,
                                {
                                    waitForRender = function()
                                        if opts.duringRender then opts.duringRender() end
                                        if opts.renderMessage then return false, opts.renderMessage end
                                        return true, path
                                    end,
                                }
                        end
                    end,
                }
            end,
        })
        package.loaded.ExportPresets = nil
        package.loaded.HandlerExport = nil
        return require "HandlerExport", sessions, files, deleted
    end

    it(
        "renders the photo at full size, quality 100, sRGB, unsharpened and unimported into its own temporary folder",
        function()
            local Handler, sessions = detailSetup()

            local r = Handler.renderSource({ photo_id = "/p/a.arw", tool = "get_photo_detail" })

            local folder = sessions[1].exportSettings.LR_export_destinationPathPrefix
            assert.matches("^/tmp/lightroom%-agent%-detail/[^/]+$", folder)
            assert.are.same({
                photo_id = "7",
                path = folder .. "/a.jpg",
                source = "export",
                left_on_photo = { "one Export history step", "the exported mark" },
            }, r)
            local s = sessions[1].exportSettings
            assert.are.same({ "JPEG", 1, "sRGB", false, false, false, "specificFolder", folder, false }, {
                s.LR_format,
                s.LR_jpeg_quality,
                s.LR_export_colorSpace,
                s.LR_size_doConstrain,
                s.LR_outputSharpeningOn,
                s.LR_reimportExportedPhoto,
                s.LR_export_destinationType,
                s.LR_export_destinationPathPrefix,
                s.LR_export_useSubfolder,
            })
            assert.is_falsy(s.LR_jpeg_useLimitSize)
            assert.is_nil(s.LR_jpeg_limitSize)
        end
    )

    it("renders each call into a folder of its own and leaves other calls' files alone", function()
        local Handler, sessions, files, deleted = detailSetup({ leftovers = { "other/b.jpg" } })
        local first = Handler.renderSource(DETAIL)
        local second = Handler.renderSource(DETAIL)
        assert.are_not.equal(
            sessions[1].exportSettings.LR_export_destinationPathPrefix,
            sessions[2].exportSettings.LR_export_destinationPathPrefix
        )
        assert.are_not.equal(first.path, second.path)
        assert.is_true(files[first.path])
        assert.is_true(files["/tmp/lightroom-agent-detail/other/b.jpg"])
        assert.are.same({}, deleted)
    end)

    it("removes render folders started longer ago than a hung export can last, and keeps newer ones", function()
        local base = "/tmp/lightroom-agent-detail/"
        local Handler, sessions, files = detailSetup({
            now = 1000,
            leftovers = {
                "700000-1/abandoned.jpg",
                "700001-2/recent.jpg",
                "other/b.jpg",
            },
        })

        Handler.renderSource(DETAIL)

        assert.is_nil(files[base .. "700000-1/abandoned.jpg"])
        assert.is_true(files[base .. "700001-2/recent.jpg"])
        assert.is_true(files[base .. "other/b.jpg"])
        assert.is_true(files[sessions[1].exportSettings.LR_export_destinationPathPrefix .. "/a.jpg"])
    end)

    for _, case in ipairs({
        { name = "an export error", opts = { renderError = "render engine failed" }, reason = "render engine failed" },
        {
            name = "a refused render",
            opts = { renderMessage = "AI Updates Recommended: Cancel" },
            reason = "AI Updates Recommended: Cancel",
        },
    }) do
        for _, args in ipairs({ DETAIL, { photo_id = 7, long_edge = 1728, tool = "render_photo" } }) do
            it(
                "reports "
                    .. case.name
                    .. " of a "
                    .. args.tool
                    .. " render as unknown, naming the export, and leaves no"
                    .. " file behind",
                function()
                    local Handler, _, files = detailSetup(case.opts)
                    local r = Handler.renderSource(args)
                    assert.is_nil(r.data)
                    assert.is_nil(r.failed)
                    assert.are.same({
                        {
                            photo_id = "7",
                            reason = case.reason
                                .. "; written before this stopped: Export photo 7 (one Export history step and the"
                                .. " exported mark)",
                        },
                    }, r.unknown)
                    assert.are.same({}, files)
                end
            )
        end
    end

    for _, case in ipairs({
        { name = "into an existing detail folder", opts = { sessionError = "session refused" }, removed = {} },
        {
            name = "after it created the detail folder too",
            opts = { sessionError = "session refused", noBase = true },
            removed = { "/tmp/lightroom-agent-detail" },
        },
    }) do
        it(
            "reports an export session that could not start "
                .. case.name
                .. " as failed, naming nothing left on the"
                .. " photo, and removes the folders it created",
            function()
                local Handler, _, files, deleted = detailSetup(case.opts)
                local r = Handler.renderSource(DETAIL)
                assert.is_nil(r.unknown)
                assert.are.same({ { photo_id = "7", reason = "session refused" } }, r.failed)
                assert.are.same({}, files)
                assert.matches("^/tmp/lightroom%-agent%-detail/[^/]+$", deleted[1])
                assert.are.same(case.removed, { unpack(deleted, 2) })
            end
        )
    end

    it(
        "answers unknown, naming the folder, when the folder it created could not be removed after the render"
            .. " failed to start",
        function()
            local Handler = detailSetup({ sessionError = "session refused", deleteFails = true })

            local r = Handler.renderSource(DETAIL)

            assert.is_nil(r.failed)
            assert.are.equal("7", r.unknown[1].photo_id)
            assert.matches(
                "^session refused; written before this stopped: /tmp/lightroom%-agent%-detail/[^/]+$",
                r.unknown[1].reason
            )
        end
    )

    it("answers an unknown photo with not_found", function()
        local Handler = detailSetup()
        assert.are.same({ 404 }, Handler.renderSource({ photo_id = 404, tool = "get_photo_detail" }).not_found)
    end)

    for _, args in ipairs({ DETAIL, { photo_id = 7, long_edge = 864, tool = "render_photo" } }) do
        it(
            "refuses a " .. args.tool .. " render while export_photos holds the lock, naming it and exporting nothing",
            function()
                local Handler, sessions = detailSetup()
                local inner
                local context = helper.requestContext(nil, {
                    title = "an_internal_action",
                    isCanceled = function()
                        inner = helper.failedOf(function() Handler.renderSource(args) end)
                        return false
                    end,
                })
                Handler.exportPhotos({ photo_ids = { "7" }, destination = "/tmp/lightroom-agent-detail" }, context)
                assert.are.equal("export_photos is already running; wait for it to finish, then call again", inner)
                assert.are.equal(1, #sessions)
            end
        )
    end

    for _, tool in ipairs({ "get_photo_detail", "render_photo" }) do
        it(
            "names " .. tool .. ", the tool the call gives, not its internal action, when its render holds the lock",
            function()
                local Handler
                local inner
                Handler = detailSetup({
                    duringRender = function()
                        inner = helper.failedOf(
                            function()
                                Handler.exportPhotos(
                                    { photo_ids = { "7" }, destination = "/tmp/out" },
                                    helper.requestContext(nil, { title = "export_photos" })
                                )
                            end
                        )
                    end,
                })
                Handler.renderSource(
                    { photo_id = 7, long_edge = 864, tool = tool },
                    helper.requestContext(nil, { title = "render_source" })
                )
                assert.are.equal(tool .. " is already running; wait for it to finish, then call again", inner)
            end
        )
    end

    it(
        "renders at the given long edge at quality 0.8, never enlarged and unsharpened, into a folder of its own",
        function()
            local Handler, sessions = detailSetup()

            local r = Handler.renderSource({ photo_id = "/p/a.arw", long_edge = 864, tool = "render_photo" })

            local s = sessions[1].exportSettings
            local folder = s.LR_export_destinationPathPrefix
            assert.matches("^/tmp/lightroom%-agent%-detail/[^/]+$", folder)
            assert.are.same({ "JPEG", 0.8, "sRGB", true, "longEdge", "pixels", 864, 864, true, false, false }, {
                s.LR_format,
                s.LR_jpeg_quality,
                s.LR_export_colorSpace,
                s.LR_size_doConstrain,
                s.LR_size_resizeType,
                s.LR_size_units,
                s.LR_size_maxWidth,
                s.LR_size_maxHeight,
                s.LR_size_doNotEnlarge,
                s.LR_outputSharpeningOn,
                s.LR_reimportExportedPhoto,
            })
            assert.are.same({
                photo_id = "7",
                path = folder .. "/a.jpg",
                source = "export",
                left_on_photo = { "one Export history step", "the exported mark" },
            }, r)
        end
    )
end)
