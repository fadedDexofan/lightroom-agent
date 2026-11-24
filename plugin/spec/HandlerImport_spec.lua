local helper = require "spec_helper"

-- Mirrors the real SDK: LrFileUtils.exists returns 'file' / 'directory' / false,
-- and LrFileUtils.isDirectory is intentionally absent (nil on some Lightroom
-- Classic runtimes -- issue #129).
--
-- Two omissions here are deliberate and load-bearing:
--   * no `extension` -- that field lives on LrPathUtils, not LrFileUtils.
--   * no `files`     -- the handler must walk nested subfolders via
--                       recursiveFiles; a plain files() walk misses them.
-- Providing either would let a regression to the wrong API pass green, which
-- is precisely how both bugs shipped.
local function fakeFileUtils(opts)
    local function volumeForm(p)
        local form = p
        if opts.caseInsensitiveVolume then form = form:lower() end
        if opts.normalizationInsensitiveVolume then form = form:gsub("e\204\129", "\195\169") end
        return form
    end
    local function matches(known, p)
        for candidate in pairs(known or {}) do
            if volumeForm(candidate) == volumeForm(p) then return true end
        end
        return false
    end
    return {
        exists = function(p)
            if matches(opts.directories, p) then return "directory" end
            if matches(opts.exists, p) then return "file" end
            return false
        end,
        directoryEntries = function(dir)
            local entries = {}
            for _, known in ipairs({ opts.exists or {}, opts.directories or {} }) do
                for p in pairs(known) do
                    if p:match("^(.*)/[^/]+$") == dir then
                        local listed = (opts.listedParent or {})[dir]
                        entries[#entries + 1] = listed and listed .. p:sub(#dir + 1) or p
                    end
                end
            end
            table.sort(entries)
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
        copy = function(source, target)
            if opts.copyLeavesFile then opts.exists[target] = true end
            if opts.copyFails or opts.copyLeavesFile then return false end
            opts.exists[target] = true
            opts.copies = opts.copies or {}
            opts.copies[#opts.copies + 1] = { source, target }
            return true
        end,
        createAllDirectories = function(dir)
            opts.directories = opts.directories or {}
            opts.directories[dir] = true
            return true
        end,
        fileAttributes = function(p) return { fileSize = (opts.sizes or {})[p] or 1 } end,
        readFile = function(p) return (opts.contents or {})[p] or "same" end,
        chooseUniqueFileName = function(p) return (p:gsub("(%.[^.]+)$", "-2%1")) end,
        recursiveFiles = function(_)
            local i = 0
            local list = opts.dirContents or {}
            return function()
                i = i + 1
                return list[i]
            end
        end,
    }
end

-- extension() belongs to LrPathUtils in the real SDK.
local function fakePathUtils()
    return {
        extension = function(p) return p:match("%.([^.]+)$") or "" end,
        removeExtension = function(p) return (p:gsub("%.[^.]+$", "")) end,
        leafName = function(p) return p:match("([^/]+)$") end,
        parent = function(p) return p:match("^(.+)/[^/]+$") end,
        child = function(parent, child) return parent .. "/" .. child end,
        getStandardFilePath = function(name)
            assert(name == "home")
            return "/home/u"
        end,
    }
end

local function setup(opts)
    local catalog = helper.fakeCatalog({
        collectionSets = opts.collectionSets,
        collections = opts.collections or {},
        photos = opts.photos,
        folders = opts.folders,
        writeAccessAborts = opts.writeAccessAborts,
    })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { pcall = pcall, sleep = function() end },
        LrFileUtils = fakeFileUtils(opts.fs or {}),
        LrPathUtils = fakePathUtils(),
    })
    package.loaded.HandlerImport = nil
    return catalog, require "HandlerImport"
end

local function importedPaths(catalog)
    local paths = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        paths[#paths + 1] = photo:getRawMetadata("path")
    end
    return paths
end

describe("HandlerImport.importPhotos", function()
    describe("collection_name", function()
        local function folder(extra)
            local opts = {
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/b.jpg" } },
            }
            for key, value in pairs(extra) do
                opts[key] = value
            end
            return setup(opts)
        end

        it("refuses a collection that does not exist before importing", function()
            local catalog, Handler = folder({})
            assert.are.equal(
                "Collection not found: Trip",
                helper.failedOf(function() Handler.importPhotos({ source_path = "/dir", collection_name = "Trip" }) end)
            )
            assert.are.equal(0, #catalog:getAllPhotos())
        end)

        it("refuses a smart collection before importing", function()
            local smart = helper.fakeCollection("Smart", {}, { smart = true })
            local catalog, Handler = folder({ collections = { smart } })
            assert.are.equal(
                "Cannot add or remove photos in a smart collection: Smart",
                helper.failedOf(
                    function() Handler.importPhotos({ source_path = "/dir", collection_name = "Smart" }) end
                )
            )
            assert.are.equal(0, #catalog:getAllPhotos())
        end)

        it("adds new and already cataloged photos, including to a nested path", function()
            local nested = helper.fakeCollection("City", {})
            local set = helper.fakeCollectionSet("Trips", { collections = { nested } })
            local existing = helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" })
            local _, Handler = folder({ collectionSets = { set }, photos = { existing } })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Trips / City" })

            assert.are.equal(2, r.data.added_to_collection)
            assert.are.equal(2, #nested.getAddedPhotos())
        end)
    end)

    describe("a file Lightroom cannot import", function()
        it("still imports the others, reports it and fills the collection", function()
            local collection = helper.fakeCollection("Shoot", {})
            local catalog, Handler = setup({
                collections = { collection },
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/bad.jpg", "/dir/c.jpg" } },
            })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/dir/bad.jpg" then error("dng_error_bad_format") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" })

            assert.is_not_nil(r.failed)
            assert.are.equal(2, r.data.imported)
            assert.are.equal("/dir/bad.jpg", r.failed[1].path)
            assert.truthy(r.failed[1].reason:find("dng_error_bad_format", 1, true))
            assert.are.equal(2, #collection.getAddedPhotos())
        end)

        it("reports a photo whose write was abandoned because the catalog stayed busy", function()
            local collection = helper.fakeCollection("Shoot", {})
            local imports = 0
            local catalog, Handler = setup({
                collections = { collection },
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/b.jpg" } },
                writeAccessAborts = function(name)
                    if name ~= "Import Photo" then return false end
                    imports = imports + 1
                    return imports == 2
                end,
            })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" })

            assert.is_not_nil(r.failed)
            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
            assert.are.equal("/dir/b.jpg", r.failed[1].path)
            assert.truthy(r.failed[1].reason:find("busy", 1, true))
            assert.are.equal(1, r.data.added_to_collection)
        end)

        it("reports photos that could not be added to the collection", function()
            local collection = helper.fakeCollection("Shoot", {})
            local catalog, Handler = setup({
                collections = { collection },
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg" } },
                writeAccessAborts = function(name) return name == "Add Imported Photos to Collection" end,
            })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" })

            assert.are.equal(1, r.data.imported)
            assert.are.equal(0, r.data.added_to_collection)
            assert.are.equal(0, #collection.getAddedPhotos())
            assert.is_nil(r.failed)
            assert.truthy(r.problem:find("not added to collection Shoot", 1, true))
            assert.truthy(r.problem:find("busy", 1, true))
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        it("reports a collection deleted during the import as a problem, keeping the imported photos", function()
            local collections = { helper.fakeCollection("Shoot", {}) }
            local catalog, Handler = setup({
                collections = collections,
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg" } },
                writeAccessAborts = function(name)
                    if name ~= "Add Imported Photos to Collection" then collections[1] = nil end
                    return false
                end,
            })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" })

            assert.are.equal(1, r.data.imported)
            assert.are.equal(0, r.data.added_to_collection)
            assert.truthy(r.problem:find("not added to collection Shoot: Collection not found: Shoot", 1, true))
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        it("reports every file as failed, with nothing achieved, when the catalog stays busy throughout", function()
            local catalog, Handler = setup({
                fs = { directories = { ["/dir"] = true }, dirContents = { "/dir/a.jpg", "/dir/b.jpg" } },
                writeAccessAborts = function(name) return name == "Import Photo" end,
            })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_nil(r.data)
            assert.are.same({ "/dir/a.jpg", "/dir/b.jpg" }, { r.failed[1].path, r.failed[2].path })
            assert.truthy(r.failed[1].reason:find("busy", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("refuses a single file the busy catalog would not take, as having changed nothing", function()
            local _, Handler = setup({
                fs = { exists = { ["/a.jpg"] = true } },
                writeAccessAborts = function(name) return name == "Import Photo" end,
            })
            local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/a.jpg" }) end)
            assert.matches("/a.jpg: ", refusal, 1, true)
            assert.matches("busy", refusal, 1, true)
        end)

        it("names the file when a single import fails", function()
            local catalog, Handler = setup({ fs = { exists = { ["/a.jpg"] = true } } })
            catalog.addPhoto = function() error("dng_error_bad_format") end
            local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/a.jpg" }) end)
            assert.truthy(refusal:find("/a.jpg: ", 1, true))
        end)
    end)

    it("skips the contents of a library package chosen as the source", function()
        local _, Handler = setup({
            fs = {
                directories = { ["/x.lrdata"] = true },
                dirContents = { "/x.lrdata/0/a.dng" },
            },
        })
        local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/x.lrdata" }) end)
        assert.truthy(refusal:find("library packages", 1, true))
    end)

    it("skips files inside library packages", function()
        local catalog, Handler = setup({
            fs = {
                directories = { ["/dir"] = true },
                dirContents = { "/dir/top.jpg", "/dir/Cat Previews.lrdata/0/a.dng", "/dir/x.LRLIBRARY/b.jpg" },
            },
        })
        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(1, r.data.imported)
        assert.are.equal(2, r.data.skipped_package_files)
        assert.are.same({ "/dir/top.jpg" }, importedPaths(catalog))
    end)

    describe("source_path and copy_to", function()
        it("expand a leading ~/ to the home folder", function()
            local fs =
                { directories = { ["/home/u/card"] = true }, exists = {}, dirContents = { "/home/u/card/a.jpg" } }
            local catalog, Handler = setup({ fs = fs })

            local r = Handler.importPhotos({ source_path = "~/card", copy_to = "~/archive" })

            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/home/u/archive/a.jpg" }, importedPaths(catalog))
        end)

        it("must be absolute, checked before anything is imported", function()
            local fs = { directories = { ["/card"] = true, card = true }, dirContents = { "/card/a.jpg" } }
            for _, case in ipairs({
                { args = { source_path = "card" }, message = "source_path must be an absolute path" },
                { args = { source_path = "/card", copy_to = "archive" }, message = "copy_to must be an absolute path" },
            }) do
                local catalog, Handler = setup({ fs = fs })

                local refusal = helper.failedOf(function() Handler.importPhotos(case.args) end)

                assert.truthy(refusal:find(case.message, 1, true))
                assert.are.equal(0, #catalog:getAllPhotos())
            end
        end)
    end)

    describe("copy_to", function()
        it("imports a copy that keeps subfolders and brings sidecars along", function()
            local fs = {
                directories = { ["/card"] = true },
                exists = { ["/card/d/a.arw"] = true },
                dirContents = { "/card/d/a.arw", "/card/d/a.jpg", "/card/d/a.xmp" },
            }
            local catalog, Handler = setup({ fs = fs })

            local r = Handler.importPhotos({ source_path = "/card", copy_to = "/archive" })

            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/archive/d/a.arw" }, importedPaths(catalog))
            local copied = {}
            for _, pair in ipairs(fs.copies) do
                copied[pair[2]] = pair[1]
            end
            assert.are.equal("/card/d/a.arw", copied["/archive/d/a.arw"])
            assert.are.equal("/card/d/a.jpg", copied["/archive/d/a.jpg"])
            assert.are.equal("/card/d/a.xmp", copied["/archive/d/a.xmp"])
        end)

        it("keeps the whole file name when Lightroom lists the source under /tmp for a /private/tmp source", function()
            local fs = {
                directories = { ["/private/tmp/card"] = true },
                exists = { ["/tmp/card/eb_fringe.png"] = true },
                dirContents = { "/tmp/card/eb_fringe.png" },
            }
            local catalog, Handler = setup({ fs = fs })

            Handler.importPhotos({ source_path = "/private/tmp/card", copy_to = "/archive" })

            assert.are.same({ "/archive/eb_fringe.png" }, importedPaths(catalog))
        end)

        it("reuses an identical copy and renames a different file in the way", function()
            local fs = {
                exists = { ["/card/a.jpg"] = true, ["/archive/a.jpg"] = true },
                sizes = { ["/archive/a.jpg"] = 1 },
            }
            local catalog, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/archive" })
            assert.is_nil(fs.copies)
            assert.are.same({ "/archive/a.jpg" }, importedPaths(catalog))

            fs.sizes["/archive/a.jpg"] = 2
            fs.exists["/card/b.jpg"] = true
            fs.exists["/archive/b.jpg"] = true
            fs.sizes["/archive/b.jpg"] = 2
            Handler.importPhotos({ source_path = "/card/b.jpg", copy_to = "/archive" })
            assert.are.equal("/archive/b-2.jpg", fs.copies[1][2])
        end)

        it("does not reuse a same-size file with different content", function()
            local fs = {
                exists = { ["/card/a.arw"] = true, ["/archive/a.arw"] = true },
                contents = { ["/card/a.arw"] = "new", ["/archive/a.arw"] = "old" },
            }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.equal("/archive/a-2.arw", fs.copies[1][2])
        end)

        it("still copies a missing companion when reusing the main file", function()
            local fs = {
                exists = { ["/card/a.arw"] = true, ["/card/a.xmp"] = true, ["/archive/a.arw"] = true },
            }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.same({ { "/card/a.xmp", "/archive/a.xmp" } }, fs.copies)
        end)

        it("copies a single raw's sidecar JPEG unless JPEGs stay separate", function()
            local fs = { exists = { ["/card/a.arw"] = true, ["/card/a.jpg"] = true } }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
            assert.are.same({ { "/card/a.arw", "/archive/a.arw" }, { "/card/a.jpg", "/archive/a.jpg" } }, fs.copies)

            local separate = { exists = { ["/card/a.arw"] = true, ["/card/a.jpg"] = true } }
            local _, SeparateHandler = setup({ fs = separate })
            SeparateHandler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive", separate_jpegs = true })
            assert.are.same({ { "/card/a.arw", "/archive/a.arw" } }, separate.copies)
        end)

        it(
            "brings a single raw's companions by the folder import's rule, a .jpe and an upper-case .XMP included",
            function()
                local fs = { exists = { ["/card/a.arw"] = true, ["/card/a.jpe"] = true, ["/card/a.XMP"] = true } }
                local _, Handler = setup({ fs = fs })
                Handler.importPhotos({ source_path = "/card/a.arw", copy_to = "/archive" })
                table.sort(fs.copies, function(left, right) return left[1] < right[1] end)
                assert.are.same({
                    { "/card/a.XMP", "/archive/a.XMP" },
                    { "/card/a.arw", "/archive/a.arw" },
                    { "/card/a.jpe", "/archive/a.jpe" },
                }, fs.copies)
            end
        )

        it("brings a single raw's companion when the folder lists its entries under another spelling of it", function()
            local fs = {
                exists = { ["/tmp/card/a.arw"] = true, ["/tmp/card/a.xmp"] = true, ["/private/tmp/card/a.xmp"] = true },
                listedParent = { ["/tmp/card"] = "/private/tmp/card" },
            }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = "/tmp/card/a.arw", copy_to = "/archive" })
            assert.are.same({ "/private/tmp/card/a.xmp", "/archive/a.xmp" }, fs.copies[2])
        end)

        it("brings a single raw's companion whose name is in another Unicode form than the source path", function()
            local nfc, nfd = "/card/caf\195\169", "/card/cafe\204\129"
            local fs = { exists = { [nfc .. ".arw"] = true, [nfd .. ".xmp"] = true } }
            local _, Handler = setup({ fs = fs })
            Handler.importPhotos({ source_path = nfc .. ".arw", copy_to = "/archive" })
            assert.are.same({ nfd .. ".xmp", "/archive/caf\195\169.xmp" }, fs.copies[2])
        end)

        it("answers unknown for a single import whose copy failed after it created the copy_to folder", function()
            local _, Handler = setup({ fs = { copyFails = true, exists = { ["/card/a.jpg"] = true } } })

            local message = helper.unknownOf(
                function() Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/archive" }) end
            )

            assert.are.equal("/card/a.jpg: could not copy /card/a.jpg to /archive/a.jpg", message)
        end)

        for _, case in ipairs({
            {
                what = "fails a single import whose copy left no file",
                fs = { copyFails = true },
                class = "failed",
                message = "/card/a.jpg: could not copy /card/a.jpg to /archive/a.jpg",
            },
            {
                what = "answers unknown, naming the copy, for a single import whose failed copy left a file",
                fs = { copyLeavesFile = true },
                class = "unknown",
                message = "/card/a.jpg: could not copy /card/a.jpg to /archive/a.jpg; written before this stopped:"
                    .. " /archive/a.jpg",
            },
        }) do
            it(case.what .. " in an existing copy_to folder", function()
                case.fs.exists = { ["/card/a.jpg"] = true }
                case.fs.directories = { ["/archive"] = true }
                local _, Handler = setup({ fs = case.fs })

                local class, message = helper.outcomeOf(
                    function(context)
                        Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/archive" }, context)
                    end
                )

                assert.are.equal(case.class, class)
                assert.are.equal(case.message, message)
            end)
        end

        it(
            "answers unknown for a single copied file the busy catalog would not take, naming the copy left on disk",
            function()
                local catalog, Handler = setup({
                    fs = { exists = { ["/card/a.jpg"] = true } },
                    writeAccessAborts = function(name) return name == "Import Photo" end,
                })

                local class, message = helper.outcomeOf(
                    function(context)
                        Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/archive" }, context)
                    end
                )

                assert.are.equal("unknown", class)
                assert.truthy(message:find("busy", 1, true), message)
                assert.truthy(message:find("written before this stopped: /archive, /archive/a.jpg", 1, true), message)
                assert.are.same({}, importedPaths(catalog))
            end
        )
    end)

    describe("files already in the catalog", function()
        local function setupFolder(existingPaths, dirContents)
            local photos = {}
            for _, path in ipairs(existingPaths) do
                photos[#photos + 1] = helper.fakePhoto({ path = path, id = path })
            end
            return setup({
                photos = photos,
                fs = { directories = { ["/dir"] = true }, dirContents = dirContents },
            })
        end

        it("adds the new photo and reports the existing ones", function()
            local catalog, Handler = setupFolder(
                { "/dir/a.arw", "/dir/b.jpg" },
                { "/dir/a.arw", "/dir/b.jpg", "/dir/c.arw" }
            )
            local added = {}
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                added[#added + 1] = path
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.same({ "/dir/c.arw" }, added)
            assert.are.equal(1, r.data.imported)
            assert.are.equal(2, r.data.already_in_catalog)
            assert.is_nil(r.remaining)
            assert.is_false(catalog:getQueriedInsideWriteAccess())
        end)

        it("does not count a sidecar JPEG as already in the catalog", function()
            local _, Handler = setupFolder({ "/dir/a.arw" }, { "/dir/a.arw", "/dir/a.jpg" })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.are.equal(1, r.data.skipped_sidecar_jpegs)
        end)

        it("reports a single file that is already in the catalog", function()
            local catalog, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/a.arw", id = "/dir/a.arw" }) },
                fs = { exists = { ["/dir/a.arw"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.arw" })

            assert.is_nil(r.failed)
            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("counts a file renamed in case only as already in the catalog", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.arw", id = "/dir/A.arw" }) },
                fs = {
                    caseInsensitiveVolume = true,
                    directories = { ["/dir"] = true },
                    dirContents = { "/dir/a.arw", "/dir/new.arw" },
                    exists = { ["/dir/a.arw"] = true, ["/dir/new.arw"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.are.equal(1, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
        end)

        it("counts a lowercase path to an all-caps file on a case-insensitive volume", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.JPG", id = "/dir/A.JPG" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/A.JPG"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
        end)

        describe("on a case-sensitive volume", function()
            local function volume(extra)
                local files = { ["/dir/A.jpg"] = true, ["/dir/a.jpg"] = true }
                for path in pairs(extra.exists or {}) do
                    files[path] = true
                end
                local fs = {
                    directories = { ["/dir"] = true, ["/dest"] = true },
                    dirContents = extra.dirContents,
                    exists = files,
                }
                local catalog, Handler = setup({ photos = extra.photos, fs = fs })
                local added = {}
                local addPhoto = catalog.addPhoto
                catalog.addPhoto = function(self, path)
                    added[#added + 1] = path
                    return addPhoto(self, path)
                end
                catalog.getFolderByPath = function(_, folderPath)
                    local inFolder = {}
                    for _, photo in ipairs(catalog:getAllPhotos()) do
                        if photo:getRawMetadata("path"):match("^(.*)/[^/]+$") == folderPath then
                            inFolder[#inFolder + 1] = photo
                        end
                    end
                    return { getPhotos = function() return inFolder end }
                end
                return Handler, added, fs
            end

            it("refuses a file beside a catalog entry that differs only in case", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }) },
                })

                local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/dir/a.jpg" }) end)

                assert.truthy(refusal:find("/dir/a.jpg: differs only in case from /dir/A.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("lists the file in failed and counts the catalog entry in a folder import", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }) },
                    dirContents = { "/dir/A.jpg", "/dir/a.jpg" },
                })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(0, r.data.imported)
                assert.are.equal(1, r.data.already_in_catalog)
                assert.is_not_nil(r.failed)
                assert.are.equal(1, #r.failed)
                assert.are.equal("/dir/a.jpg", r.failed[1].path)
                assert.truthy(r.failed[1].reason:find("differs only in case from /dir/A.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("imports the first of two spellings in one call and refuses the second", function()
                local Handler, added = volume({ dirContents = { "/dir/A.jpg", "/dir/a.jpg" } })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(1, r.data.imported)
                assert.are.same({ "/dir/A.jpg" }, added)
                assert.are.equal("/dir/a.jpg", r.failed[1].path)
            end)

            it("refuses it from the other side too", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }) },
                })

                local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/dir/A.jpg" }) end)

                assert.truthy(refusal:find("differs only in case from /dir/a.jpg", 1, true))
                assert.are.same({}, added)
            end)

            it("counts both spellings when the catalog already holds both", function()
                local Handler, added = volume({
                    photos = {
                        helper.fakePhoto({ path = "/dir/A.jpg", id = "/dir/A.jpg" }),
                        helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }),
                    },
                    dirContents = { "/dir/A.jpg", "/dir/a.jpg" },
                })

                local r = Handler.importPhotos({ source_path = "/dir" })

                assert.are.equal(0, r.data.imported)
                assert.are.equal(2, r.data.already_in_catalog)
                assert.is_nil(r.failed)
                assert.are.same({}, added)
            end)

            it("refuses a copy_to target before copying the file", function()
                local Handler, added, fs = volume({
                    photos = { helper.fakePhoto({ path = "/dest/A.jpg", id = "/dest/A.jpg" }) },
                    exists = { ["/card/a.jpg"] = true, ["/dest/A.jpg"] = true },
                })

                local refusal = helper.failedOf(
                    function() Handler.importPhotos({ source_path = "/card/a.jpg", copy_to = "/dest" }) end
                )

                assert.truthy(refusal:find("/dest/a.jpg: differs only in case from /dest/A.jpg", 1, true))
                assert.is_nil(fs.copies)
                assert.are.same({}, added)
            end)

            it("still counts the exact path as already in the catalog", function()
                local Handler, added = volume({
                    photos = { helper.fakePhoto({ path = "/dir/a.jpg", id = "/dir/a.jpg" }) },
                })

                local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

                assert.are.equal(0, r.data.imported)
                assert.are.equal(1, r.data.already_in_catalog)
                assert.are.same({}, added)
            end)
        end)

        it("counts an extension renamed to another case on a case-insensitive volume", function()
            local _, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/A.ARW", id = "/dir/A.ARW" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/a.ARW"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.ARW" })

            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
        end)

        it("counts a path spelled in another case as the catalog entry", function()
            local catalog, Handler = setup({
                photos = { helper.fakePhoto({ path = "/dir/q.jpg", id = "/dir/q.jpg" }) },
                fs = { caseInsensitiveVolume = true, exists = { ["/dir/q.jpg"] = true } },
            })

            local r = Handler.importPhotos({ source_path = "/dir/Q.jpg" })

            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("leaves already_in_catalog out when nothing was there", function()
            local _, Handler = setupFolder({}, { "/dir/a.arw" })

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_nil(r.data.already_in_catalog)
        end)

        it("counts an NFC folder listing against the NFD path in the catalog", function()
            local catalog, Handler = setupFolder({ "/dir/cafe\204\129.jpg" }, { "/dir/caf\195\169.jpg" })
            catalog.addPhoto = function() error("failed to import photo") end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_nil(r.failed)
            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.is_nil(r.failed)
        end)

        it("keeps the count of added photos and names the file that failed", function()
            local catalog, Handler = setupFolder({}, { "/dir/a.arw", "/dir/bad.arw" })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/dir/bad.arw" then error("failed to import photo") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_not_nil(r.failed)
            assert.are.equal(1, r.data.imported)
            assert.are.equal(1, #r.failed)
            assert.are.equal("/dir/bad.arw", r.failed[1].path)
        end)

        it("answers unknown, naming addPhoto, for a file Lightroom added before addPhoto raised", function()
            local catalog, Handler = setupFolder({}, { "/dir/a.arw", "/dir/bad.arw" })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                local photo = addPhoto(self, path)
                if path == "/dir/bad.arw" then error("failed to import photo", 0) end
                return photo
            end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_nil(r.failed)
            assert.are.same(
                { { path = "/dir/bad.arw", reason = "failed to import photo; written before this stopped: addPhoto" } },
                r.unknown
            )
        end)

        it("still surfaces a file that fails for another reason", function()
            local catalog, Handler = setupFolder({ "/dir/a.arw" }, { "/dir/a.arw", "/dir/bad.arw", "/dir/c.arw" })
            catalog.addPhoto = function() error("failed to import photo") end

            local r = Handler.importPhotos({ source_path = "/dir" })

            assert.is_not_nil(r.failed)
            assert.are.equal(2, #r.failed)
            assert.truthy(r.failed[1].reason:find("failed to import photo", 1, true))
        end)
    end)

    describe("a folder spelled in another case", function()
        local function caseSensitiveVolume(extra)
            local opts = {
                folders = extra.folders,
                photos = extra.photos,
                fs = {
                    directories = extra.directories
                        or { ["/root"] = true, ["/root/Dir2"] = true, ["/root/dir2"] = true },
                    dirContents = extra.dirContents,
                    exists = extra.exists or {},
                },
            }
            local catalog, Handler = setup(opts)
            local added = {}
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                added[#added + 1] = path
                return addPhoto(self, path)
            end
            return Handler, added, catalog
        end

        local function catalogWithDir2()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            return {
                folders = { helper.fakeFolder("/root", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
            }
        end

        it("refuses the file instead of letting Lightroom file it under the other folder", function()
            local setupOpts = catalogWithDir2()
            setupOpts.dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg" }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({}, added)
            assert.is_not_nil(r.failed)
            assert.are.equal(0, r.data.imported)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.are.equal("/root/dir2/a.jpg", r.failed[1].path)
            assert.truthy(r.failed[1].reason:find("differs only in case from /root/Dir2", 1, true))
            assert.is_nil(r.remaining)
        end)

        it("answers again when the folder is imported a second time", function()
            local setupOpts = catalogWithDir2()
            setupOpts.dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg" }
            local Handler = caseSensitiveVolume(setupOpts)

            local first = Handler.importPhotos({ source_path = "/root" })
            local second = Handler.importPhotos({ source_path = "/root" })

            assert.are.same(first, second)
        end)

        it("imports the first spelling of a new folder and refuses the second", function()
            local Handler, added = caseSensitiveVolume({
                dirContents = { "/root/Dir2/a.jpg", "/root/dir2/a.jpg", "/root/Dir2/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/Dir2/a.jpg", "/root/Dir2/b.jpg" }, added)
            assert.are.equal(2, r.data.imported)
            assert.are.equal(1, #r.failed)
            assert.are.equal("/root/dir2/a.jpg", r.failed[1].path)
        end)

        it("refuses a file below a case-variant ancestor folder", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/sub/a.jpg", id = "1" })
            local Handler, added = caseSensitiveVolume({
                folders = {
                    helper.fakeFolder("/root", {}, {
                        helper.fakeFolder("/root/Dir2", {}, {
                            helper.fakeFolder("/root/Dir2/sub", { photo }),
                        }),
                    }),
                },
                photos = { photo },
                directories = {
                    ["/root"] = true,
                    ["/root/Dir2"] = true,
                    ["/root/dir2"] = true,
                    ["/root/Dir2/sub"] = true,
                    ["/root/dir2/sub"] = true,
                },
                dirContents = { "/root/dir2/sub/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({}, added)
            assert.are.equal("/root/dir2/sub/b.jpg", r.failed[1].path)
        end)

        it("raises for a single file", function()
            local setupOpts = catalogWithDir2()
            setupOpts.exists = { ["/root/dir2/a.jpg"] = true }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/root/dir2/a.jpg" }) end)

            assert.truthy(refusal:find("differs only in case from /root/Dir2", 1, true))
            assert.are.same({}, added)
        end)

        it("refuses a case-variant folder that the copy would create", function()
            local Handler, added = caseSensitiveVolume({
                directories = { ["/src"] = true, ["/dest"] = true },
                dirContents = { "/src/Dir2/a.jpg", "/src/dir2/b.jpg" },
                exists = { ["/src/Dir2/a.jpg"] = true, ["/src/dir2/b.jpg"] = true },
            })

            local r = Handler.importPhotos({ source_path = "/src", copy_to = "/dest" })

            assert.are.same({ "/dest/Dir2/a.jpg" }, added)
            assert.are.equal(1, r.data.imported)
            assert.are.equal("/src/dir2/b.jpg", r.failed[1].path)
        end)

        it("remembers a folder only once its file is in the catalog", function()
            local Handler, added, catalog = caseSensitiveVolume({
                dirContents = { "/root/Dir2/a.jpg", "/root/dir2/b.jpg" },
            })
            local addPhoto = catalog.addPhoto
            catalog.addPhoto = function(self, path)
                if path == "/root/Dir2/a.jpg" then error("failed to import photo") end
                return addPhoto(self, path)
            end

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/dir2/b.jpg" }, added)
            assert.are.equal("/root/Dir2/a.jpg", r.failed[1].path)
            assert.are.equal(1, r.data.imported)
        end)

        it("copies nothing into a case-variant folder", function()
            local setupOpts = catalogWithDir2()
            setupOpts.directories = { ["/dir"] = true, ["/root"] = true, ["/root/Dir2"] = true, ["/root/dir2"] = true }
            setupOpts.dirContents = { "/dir/a.jpg" }
            setupOpts.exists = { ["/dir/a.jpg"] = true }
            local Handler, added = caseSensitiveVolume(setupOpts)

            local r = Handler.importPhotos({ source_path = "/dir", copy_to = "/root/dir2" })

            assert.are.same({}, added)
            assert.are.equal(1, #r.failed)
        end)

        it("treats the folder as the same one on a case-insensitive volume", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local catalog, Handler = setup({
                folders = { helper.fakeFolder("/root", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
                fs = {
                    caseInsensitiveVolume = true,
                    directories = { ["/root"] = true, ["/root/Dir2"] = true },
                    dirContents = { "/root/dir2/a.jpg" },
                    exists = { ["/root/Dir2/a.jpg"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/root/dir2" })

            assert.is_nil(r.failed)
            assert.are.equal(1, r.data.already_in_catalog)
            assert.are.equal(1, #catalog:getAllPhotos())
        end)

        it("reads a catalog folder path with a trailing separator as the same folder", function()
            local photo = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local Handler, added = caseSensitiveVolume({
                folders = { helper.fakeFolder("/root/", {}, { helper.fakeFolder("/root/Dir2", { photo }) }) },
                photos = { photo },
                dirContents = { "/root/Dir2/a.jpg", "/root/Dir2/b.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/Dir2/b.jpg" }, added)
            assert.is_nil(r.failed)
        end)

        it("keeps a folder that is itself in the catalog in both spellings", function()
            local upper = helper.fakePhoto({ path = "/root/Dir2/a.jpg", id = "1" })
            local lower = helper.fakePhoto({ path = "/root/dir2/b.jpg", id = "2" })
            local Handler, added = caseSensitiveVolume({
                folders = {
                    helper.fakeFolder("/root", {}, {
                        helper.fakeFolder("/root/Dir2", { upper }),
                        helper.fakeFolder("/root/dir2", { lower }),
                    }),
                },
                photos = { upper, lower },
                dirContents = { "/root/dir2/b.jpg", "/root/dir2/c.jpg" },
            })

            local r = Handler.importPhotos({ source_path = "/root" })

            assert.are.same({ "/root/dir2/c.jpg" }, added)
            assert.is_nil(r.failed)
        end)
    end)

    describe("RAW+JPEG pairs", function()
        local function importFolder(dirContents, args)
            local catalog, Handler = setup({
                fs = {
                    directories = { ["/dir"] = true },
                    dirContents = dirContents,
                },
            })
            args = args or {}
            args.source_path = "/dir"
            return Handler.importPhotos(args), importedPaths(catalog)
        end

        for _, case in ipairs({
            { name = "lowercase pair", files = { "/dir/a.cr3", "/dir/a.jpg" }, kept = { "/dir/a.cr3" } },
            { name = "mixed extension case", files = { "/dir/a.CR3", "/dir/a.jpg" }, kept = { "/dir/a.CR3" } },
            {
                name = "mixed extension case on a jpeg",
                files = { "/dir/A.nef", "/dir/A.jpg" },
                kept = { "/dir/A.nef" },
            },
            { name = "jpeg listed before the raw", files = { "/dir/a.JPEG", "/dir/a.arw" }, kept = { "/dir/a.arw" } },
            { name = "jpe extension", files = { "/dir/a.nef", "/dir/a.jpe" }, kept = { "/dir/a.nef" } },
            {
                name = "several jpegs for one raw",
                files = { "/dir/a.raf", "/dir/a.jpg", "/dir/a.jpeg" },
                kept = { "/dir/a.raf" },
            },
        }) do
            it("leaves out the JPEG: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.kept, paths)
                assert.are.equal(1, r.data.imported)
                assert.are.equal(#case.files - 1, r.data.skipped_sidecar_jpegs)
                assert.is_nil(r.data.skipped_by_extension)
            end)
        end

        for _, case in ipairs({
            { name = "JPEG without a raw", files = { "/dir/a.jpg", "/dir/b.cr3" } },
            { name = "same name in another folder", files = { "/dir/one/a.cr3", "/dir/two/a.jpg" } },
            { name = "non-JPEG next to a raw", files = { "/dir/a.cr3", "/dir/a.tif", "/dir/a.heic" } },
            { name = "JPEG next to a non-raw", files = { "/dir/a.png", "/dir/a.jpg" } },
            { name = "name differing in case", files = { "/dir/A.nef", "/dir/a.JPG" } },
            { name = "JPEG next to a DNG", files = { "/dir/a.dng", "/dir/a.jpg" } },
            { name = "JPEG next to an uppercase DNG", files = { "/dir/a.DNG", "/dir/a.JPEG" } },
        }) do
            it("keeps every file: " .. case.name, function()
                local r, paths = importFolder(case.files)

                assert.are.same(case.files, paths)
                assert.is_nil(r.data.skipped_sidecar_jpegs)
            end)
        end

        it("keeps the JPEG as its own photo with separate_jpegs", function()
            local files = { "/dir/a.cr3", "/dir/a.jpg" }

            local r, paths = importFolder(files, { separate_jpegs = true })

            assert.are.same(files, paths)
            assert.is_nil(r.data.skipped_sidecar_jpegs)
        end)

        it("adds only the raw to the collection and to remaining_paths", function()
            local added = {}
            local collection = {
                getName = function() return "Shoot" end,
                isSmartCollection = function() return false end,
                addPhotos = function(_, photos) added = photos end,
            }
            local catalog, Handler = setup({
                collections = { collection },
                fs = {
                    directories = { ["/dir"] = true },
                    dirContents = { "/dir/a.cr3", "/dir/a.jpg", "/dir/b.cr3", "/dir/b.jpg" },
                },
            })
            local context = helper.requestContext(nil, {
                isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
            })

            local r = Handler.importPhotos({ source_path = "/dir", collection_name = "Shoot" }, context)

            assert.are.same({ "/dir/b.cr3" }, r.remaining)
            assert.are.equal(1, #added)
            assert.are.equal("/dir/a.cr3", added[1]:getRawMetadata("path"))
            assert.are.equal(2, r.data.skipped_sidecar_jpegs)
        end)

        for _, volume in ipairs({
            { name = "case-sensitive volume", caseInsensitiveVolume = false },
            { name = "case-insensitive volume", caseInsensitiveVolume = true },
        }) do
            for _, case in ipairs({
                { name = "lowercase raw", jpeg = "/dir/a.jpg", raw = "/dir/a.cr3" },
                { name = "uppercase raw", jpeg = "/dir/S1.JPG", raw = "/dir/S1.ARW" },
                { name = "jpeg extension", jpeg = "/dir/a.jpeg", raw = "/dir/a.nef" },
                { name = "mixed-case raw extension", jpeg = "/dir/a.jpg", raw = "/dir/a.Cr3" },
            }) do
                it("refuses a lone JPEG and names the raw as on disk: " .. case.name .. ", " .. volume.name, function()
                    local catalog, Handler = setup({
                        fs = {
                            caseInsensitiveVolume = volume.caseInsensitiveVolume,
                            exists = { [case.jpeg] = true, [case.raw] = true },
                        },
                    })

                    local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = case.jpeg }) end)

                    assert.truthy(refusal:find("Import " .. case.raw .. " instead", 1, true))
                    assert.are.same({}, importedPaths(catalog))
                end)
            end
        end

        it("uses the JPEG's name on disk when the path spells it in another case", function()
            local catalog, Handler = setup({
                fs = {
                    caseInsensitiveVolume = true,
                    exists = { ["/dir/S1.JPG"] = true, ["/dir/S1.ARW"] = true },
                },
            })

            local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/dir/s1.jpg" }) end)

            assert.truthy(refusal:find("Import /dir/S1.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("imports a JPEG whose name on disk differs from its raw's, however the path spells it", function()
            local catalog, Handler = setup({
                fs = {
                    caseInsensitiveVolume = true,
                    exists = { ["/dir/q.jpg"] = true, ["/dir/Q.ARW"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/dir/Q.jpg" })

            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/dir/Q.jpg" }, importedPaths(catalog))
        end)

        it("prefers the exact name when a case-sensitive volume holds both spellings", function()
            local catalog, Handler = setup({
                fs = {
                    exists = { ["/dir/A.jpg"] = true, ["/dir/a.jpg"] = true, ["/dir/A.ARW"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg" })

            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        it("names the raw as on disk when the path uses another Unicode form", function()
            local catalog, Handler = setup({
                fs = {
                    caseInsensitiveVolume = true,
                    normalizationInsensitiveVolume = true,
                    exists = { ["/dir/caf\195\169.jpg"] = true, ["/dir/caf\195\169.ARW"] = true },
                },
            })

            local refusal = helper.failedOf(
                function() Handler.importPhotos({ source_path = "/dir/cafe\204\129.jpg" }) end
            )

            assert.truthy(refusal:find("Import /dir/caf\195\169.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("names a mixed-case raw extension as on disk across Unicode forms on a case-sensitive volume", function()
            local catalog, Handler = setup({
                fs = {
                    normalizationInsensitiveVolume = true,
                    exists = { ["/dir/caf\195\169.jpg"] = true, ["/dir/caf\195\169.ArW"] = true },
                },
            })

            local refusal = helper.failedOf(
                function() Handler.importPhotos({ source_path = "/dir/cafe\204\129.jpg" }) end
            )

            assert.truthy(refusal:find("Import /dir/caf\195\169.ArW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        for _, case in ipairs({
            {
                name = "NFD path, NFC disk",
                path = "/dir/Cafe\204\129.jpg",
                exists = { ["/dir/Caf\195\169.jpg"] = true, ["/dir/caf\195\169.ARW"] = true },
            },
            {
                name = "NFC path, NFD disk",
                path = "/dir/Caf\195\169.jpg",
                exists = { ["/dir/Cafe\204\129.jpg"] = true, ["/dir/cafe\204\129.ARW"] = true },
            },
        }) do
            for _, volume in ipairs({
                { name = "case-sensitive volume", caseInsensitiveVolume = false },
                { name = "case-insensitive volume", caseInsensitiveVolume = true },
            }) do
                it(
                    "imports a JPEG in another Unicode form beside a raw whose stem differs in case: "
                        .. case.name
                        .. ", "
                        .. volume.name,
                    function()
                        local catalog, Handler = setup({
                            fs = {
                                caseInsensitiveVolume = volume.caseInsensitiveVolume,
                                normalizationInsensitiveVolume = true,
                                exists = case.exists,
                            },
                        })

                        local r = Handler.importPhotos({ source_path = case.path })

                        assert.are.equal(1, r.data.imported)
                        assert.are.same({ case.path }, importedPaths(catalog))
                    end
                )
            end
        end

        it("refuses a JPEG in another Unicode form whose raw has the same stem as on disk", function()
            local catalog, Handler = setup({
                fs = {
                    caseInsensitiveVolume = true,
                    normalizationInsensitiveVolume = true,
                    exists = { ["/dir/Caf\195\169.jpg"] = true, ["/dir/Caf\195\169.ARW"] = true },
                },
            })

            local refusal = helper.failedOf(
                function() Handler.importPhotos({ source_path = "/dir/Cafe\204\129.jpg" }) end
            )

            assert.truthy(refusal:find("Import /dir/Caf\195\169.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        for _, case in ipairs({
            {
                name = "NFD path, NFC jpeg, NFD raw",
                path = "/dir/Cafe\204\129.jpg",
                exists = { ["/dir/Caf\195\169.jpg"] = true, ["/dir/Cafe\204\129.ARW"] = true },
                raw = "/dir/Cafe\204\129.ARW",
            },
            {
                name = "NFC path, NFC jpeg, NFD raw",
                path = "/dir/Caf\195\169.jpg",
                exists = { ["/dir/Caf\195\169.jpg"] = true, ["/dir/Cafe\204\129.ARW"] = true },
                raw = "/dir/Cafe\204\129.ARW",
            },
            {
                name = "NFD path, NFD jpeg, NFC raw",
                path = "/dir/Cafe\204\129.jpg",
                exists = { ["/dir/Cafe\204\129.jpg"] = true, ["/dir/Caf\195\169.ARW"] = true },
                raw = "/dir/Caf\195\169.ARW",
            },
        }) do
            for _, volume in ipairs({
                { name = "case-sensitive volume", caseInsensitiveVolume = false },
                { name = "case-insensitive volume", caseInsensitiveVolume = true },
            }) do
                it(
                    "refuses a JPEG whose raw has the same stem in another Unicode form on disk: "
                        .. case.name
                        .. ", "
                        .. volume.name,
                    function()
                        local catalog, Handler = setup({
                            fs = {
                                caseInsensitiveVolume = volume.caseInsensitiveVolume,
                                normalizationInsensitiveVolume = true,
                                exists = case.exists,
                            },
                        })

                        local refusal = helper.failedOf(
                            function() Handler.importPhotos({ source_path = case.path }) end
                        )

                        assert.truthy(refusal:find("Import " .. case.raw .. " instead", 1, true))
                        assert.are.same({}, importedPaths(catalog))
                    end
                )
            end
        end

        it("matches the on-disk name across Unicode forms and case together", function()
            local catalog, Handler = setup({
                fs = {
                    caseInsensitiveVolume = true,
                    normalizationInsensitiveVolume = true,
                    exists = { ["/dir/caf\195\169.jpg"] = true, ["/dir/caf\195\169.ARW"] = true },
                },
            })

            local refusal = helper.failedOf(
                function() Handler.importPhotos({ source_path = "/dir/Cafe\204\129.jpg" }) end
            )

            assert.truthy(refusal:find("Import /dir/caf\195\169.ARW instead", 1, true))
            assert.are.same({}, importedPaths(catalog))
        end)

        it("imports a JPEG in another Unicode form when no raw is beside it", function()
            local _, Handler = setup({
                fs = {
                    normalizationInsensitiveVolume = true,
                    exists = { ["/dir/caf\195\169.jpg"] = true },
                },
            })

            local r = Handler.importPhotos({ source_path = "/dir/cafe\204\129.jpg" })

            assert.are.equal(1, r.data.imported)
        end)

        it("imports a lone JPEG beside its raw with separate_jpegs", function()
            local catalog, Handler = setup({ fs = { exists = { ["/dir/a.jpg"] = true, ["/dir/a.cr3"] = true } } })

            local r = Handler.importPhotos({ source_path = "/dir/a.jpg", separate_jpegs = true })

            assert.are.equal(1, r.data.imported)
            assert.are.same({ "/dir/a.jpg" }, importedPaths(catalog))
        end)

        for _, case in ipairs({
            { name = "JPEG with no raw beside it", source = "/dir/a.jpg", others = { "/dir/a.png" } },
            { name = "JPEG beside a DNG", source = "/dir/a.jpg", others = { "/dir/a.dng", "/dir/a.DNG" } },
            { name = "raw with a JPEG beside it", source = "/dir/a.cr3", others = { "/dir/a.jpg" } },
            { name = "folder named like the raw", source = "/dir/a.jpg", directoryNamed = "/dir/a.cr3" },
            { name = "raw whose name differs in case", source = "/dir/q.jpg", others = { "/dir/Q.ARW" } },
            { name = "raw in another folder", source = "/dir/a.jpg", others = { "/dir/sub/a.cr3" } },
        }) do
            it("imports a single file: " .. case.name, function()
                local exists = { [case.source] = true }
                for _, other in ipairs(case.others or {}) do
                    exists[other] = true
                end
                local catalog, Handler = setup({
                    fs = {
                        caseInsensitiveVolume = true,
                        exists = exists,
                        directories = case.directoryNamed and { [case.directoryNamed] = true } or {},
                    },
                })

                local r = Handler.importPhotos({ source_path = case.source })

                assert.are.equal(1, r.data.imported)
                assert.are.same({ case.source }, importedPaths(catalog))
            end)
        end
    end)

    it("cancel keeps imports already committed and returns unprocessed paths", function()
        local catalog, Handler = setup({
            fs = {
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.jpg", "/dir/c.jpg" },
            },
        })
        local context = helper.requestContext(nil, {
            isCanceled = function() return #catalog:getAllPhotos() >= 1 end,
        })

        local r = Handler.importPhotos({ source_path = "/dir" }, context)

        assert.are.equal(1, r.data.imported)
        assert.are.same({ "/dir/b.jpg", "/dir/c.jpg" }, r.remaining)
        assert.are.equal(1, #catalog:getAllPhotos())
    end)

    it("imports nothing and lists every file as remaining when the budget is spent before the first", function()
        local catalog, Handler = setup({
            fs = {
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.jpg" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" }, helper.requestContext(30))

        assert.is_nil(r.data)
        assert.are.same({ "/dir/a.jpg", "/dir/b.jpg" }, r.remaining)
        assert.are.equal(0, #catalog:getAllPhotos())
    end)

    it("imports a single photo", function()
        local _, Handler = setup({
            fs = { exists = { ["/photo.jpg"] = true }, directories = {} },
        })

        local r = Handler.importPhotos({ source_path = "/photo.jpg" })

        assert.is_nil(r.failed)
        assert.are.equal(1, r.data.imported)
    end)

    it("refuses a source path that does not exist, naming it", function()
        local _, Handler = setup({ fs = { exists = {} } })
        assert.are.equal(
            "Source path does not exist: /missing.jpg",
            helper.failedOf(function() Handler.importPhotos({ source_path = "/missing.jpg" }) end)
        )
    end)

    it("imports multiple photos from directory and filters extensions", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.txt", "/dir/c.png", "/dir/d.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(3, r.data.imported)
    end)

    it("imports photos nested in subfolders", function()
        -- Photo libraries are organized as shoot/roll subfolders, so the source
        -- directory usually holds no photos itself. An immediate-directory walk
        -- enumerated nothing and failed with "No photos found to import"; the
        -- walk has to recurse.
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/roll1/a.jpg",
                    "/dir/roll1/scans/b.tif",
                    "/dir/roll2/c.arw",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.is_nil(r.failed)
        assert.are.equal(3, r.data.imported)
    end)

    it("imports camera raw formats beyond Canon, Nikon and Sony, in any case", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/a.RAF",
                    "/dir/b.CR3",
                    "/dir/c.orf",
                    "/dir/d.rw2",
                    "/dir/e.pef",
                    "/dir/f.srw",
                    "/dir/g.3fr",
                    "/dir/h.iiq",
                    "/dir/i.HEIC",
                    "/dir/j.hif",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(10, r.data.imported)
        assert.is_nil(r.data.skipped_by_extension)
        assert.is_nil(r.data.skipped_by_extension)
    end)

    it("reports the files it skipped by extension", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.raf", "/dir/a.xmp", "/dir/b.xmp", "/dir/notes.txt", "/dir/README" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(1, r.data.imported)
        assert.are.same({ xmp = 2, txt = 1, [""] = 1 }, r.data.skipped_by_extension)
    end)

    it("names the skipped extensions when a folder has no importable photos", function()
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/clip.mov", "/dir/clip.xmp" },
            },
        })

        local refusal = helper.failedOf(function() Handler.importPhotos({ source_path = "/dir" }) end)

        assert.truthy(refusal:find("skipped files by extension: mov: 1, xmp: 1", 1, true))
    end)

    it("acquires catalog write access per photo, not once for the batch", function()
        -- A batch-wide write lock wedges the bridge for the whole multi-minute
        -- import (issue #128); each photo must get its own short transaction so
        -- the exclusive lock is released between photos.
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.png", "/dir/c.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(3, r.data.imported)
        assert.are.equal(3, catalog:getWriteAccessCount())
    end)
end)
