describe("PhotoLookup.findByPath", function()
    local NFC, NFD = "/w\196\133.jpg", "/wa\204\168.jpg"

    local function lookup(storedPath)
        package.loaded.PhotoLookup = nil
        local PhotoLookup = require "PhotoLookup"
        local photo = {
            localIdentifier = 1,
            getRawMetadata = function(_, key)
                if key == "path" then return storedPath end
                return nil
            end,
        }
        local catalog = {
            findPhotoByPath = function(_, path) return path == storedPath and photo or nil end,
        }
        return PhotoLookup, catalog, photo
    end

    it("finds a decomposed catalog path from a composed one", function()
        local PhotoLookup, catalog, photo = lookup(NFD)
        assert.are.equal(photo, PhotoLookup.findByPath(catalog, NFC))
        assert.are.equal(photo, PhotoLookup.resolveOne(catalog, NFC))
    end)

    it("finds a composed catalog path from a decomposed one", function()
        local PhotoLookup, catalog, photo = lookup(NFC)
        assert.are.equal(photo, PhotoLookup.findByPath(catalog, NFD))
    end)

    it("returns nil for a path in neither form", function()
        local PhotoLookup, catalog = lookup(NFD)
        assert.is_nil(PhotoLookup.findByPath(catalog, "/other\196\133.jpg"))
    end)
end)

local function fakePhoto(id, path, state)
    local meta = { path = path, uuid = path and ("uuid-" .. tostring(id)) or nil }
    return {
        localIdentifier = id,
        __path = path,
        __meta = meta,
        getRawMetadata = function(_, key)
            if key == "path" and state then state.pathReads = state.pathReads + 1 end
            return meta[key]
        end,
    }
end

-- Makes `copies` virtual copies of `master`, as Lightroom reports them: each
-- copy reports the master's path.
local function linkCopies(master, copies)
    master.__meta.virtualCopies = copies
    for _, copy in ipairs(copies) do
        copy.__meta.masterPhoto = master
    end
end

local function fakeCatalog(photos)
    local state = { findPhotoByPathCalls = 0, directCalls = 0, batchCalls = 0 }
    local catalog = {
        -- One photo per path: for a master and its virtual copies, whichever
        -- comes first here.
        findPhotoByPath = function(_, path)
            state.findPhotoByPathCalls = state.findPhotoByPathCalls + 1
            for _, p in ipairs(photos) do
                if p.__path == path then return p end
            end
            return nil
        end,
        getPhotoByLocalId = function(_, id)
            state.directCalls = state.directCalls + 1
            assert.are.equal("number", type(id))
            for _, p in ipairs(photos) do
                if p.localIdentifier == id then return p end
            end
            return fakePhoto(id, nil)
        end,
        batchGetRawMetadata = function(_, list, keys)
            state.batchCalls = state.batchCalls + 1
            local out = {}
            for _, p in ipairs(list) do
                local values = {}
                for _, key in ipairs(keys) do
                    values[key] = p:getRawMetadata(key)
                end
                out[p] = values
            end
            return out
        end,
    }
    return catalog, state
end

local PhotoLookup
local function loadModule()
    package.loaded.PhotoLookup = nil
    PhotoLookup = require "PhotoLookup"
end

describe("PhotoLookup.resolveMany", function()
    before_each(loadModule)

    local function numbered(n)
        local photos = {}
        for i = 1, n do
            photos[i] = fakePhoto(i, "/" .. i .. ".jpg")
        end
        local catalog, state = fakeCatalog(photos)
        return photos, catalog, state
    end

    it("resolves numeric ids through getPhotoByLocalId and one uuid read", function()
        local photos, catalog, state = numbered(5)

        local r = PhotoLookup.resolveMany(catalog, { "2", 5, "999" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(photos[5], r[2].photo)
        assert.is_nil(r[3].photo)
        assert.are.equal(3, state.directCalls)
        assert.are.equal(1, state.batchCalls)
    end)

    it("looks each distinct id up once", function()
        local photos, catalog, state = numbered(3)

        local r = PhotoLookup.resolveMany(catalog, { "1", "1", "1" })

        assert.are.equal(photos[1], r[3].photo)
        assert.are.equal(1, state.directCalls)
    end)

    for _, id in ipairs({ "1.0", "0x1", " 1", "01", "001" }) do
        it("does not resolve the non-canonical id '" .. id .. "'", function()
            local _, catalog, state = numbered(3)

            assert.is_nil(PhotoLookup.resolveOne(catalog, id))
            assert.are.equal(0, state.directCalls)
        end)
    end

    for _, ids in ipairs({ { "1", "01" }, { "01", "1" }, { 1, "001" } }) do
        local label = tostring(ids[1]) .. "' and '" .. tostring(ids[2])
        it("resolves only the canonical id of '" .. label .. "'", function()
            local photos, catalog = numbered(3)

            local r = PhotoLookup.resolveMany(catalog, ids)

            for i, id in ipairs(ids) do
                local canonical = type(id) == "number" or id == "1"
                assert.are.equal(canonical and photos[1] or nil, r[i].photo)
            end
        end)
    end

    it("resolves by path", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "/a.jpg", "/b.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
    end)

    it("resolves a mixed batch (some by id, some by path)", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local p3 = fakePhoto(3, "/c.jpg")
        local catalog = fakeCatalog({ p1, p2, p3 })

        local r = PhotoLookup.resolveMany(catalog, { "1", "/b.jpg", "3" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p2, r[2].photo)
        assert.are.equal(p3, r[3].photo)
    end)

    it("returns nil for unknown ids without erroring", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })

        local r = PhotoLookup.resolveMany(catalog, { "1", "999", "/missing.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.is_nil(r[2].photo)
        assert.is_nil(r[3].photo)
    end)

    it("preserves input order in results", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local p2 = fakePhoto(2, "/b.jpg")
        local catalog, _ = fakeCatalog({ p1, p2 })

        local r = PhotoLookup.resolveMany(catalog, { "/b.jpg", "1", "/a.jpg", "2" })

        assert.are.equal(p2, r[1].photo)
        assert.are.equal(p1, r[2].photo)
        assert.are.equal(p1, r[3].photo)
        assert.are.equal(p2, r[4].photo)
    end)

    it("handles empty input", function()
        local catalog, _ = fakeCatalog({})
        local r = PhotoLookup.resolveMany(catalog, {})
        assert.are.equal(0, #r)
    end)

    it("looks each distinct path up once", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, state = fakeCatalog({ p1 })

        local r = PhotoLookup.resolveMany(catalog, { "/a.jpg", "/a.jpg" })

        assert.are.equal(p1, r[1].photo)
        assert.are.equal(p1, r[2].photo)
        assert.are.equal(1, state.findPhotoByPathCalls)
    end)

    it("does not resolve a path that differs only in case", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        -- Lightroom may match a path ignoring case
        catalog.findPhotoByPath = function() return p1 end

        assert.is_nil(PhotoLookup.resolveOne(catalog, "/A.JPG"))
    end)

    -- The lookup runs per call on every handler that resolves ids, so on a
    -- large catalog its cost is the handler's cost. These pin that down.
    it("never reads paths when every id is numeric", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 5 do
            photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state)
        end
        local catalog = fakeCatalog(photos)

        PhotoLookup.resolveMany(catalog, { "1", "2" })

        assert.are.equal(0, state.pathReads)
    end)

    it("reads only the requested photo's path when resolving a path", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 100 do
            photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state)
        end
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/2.jpg" })

        assert.are.equal(photos[2], r[1].photo)
        assert.are.equal(1, state.pathReads)
    end)

    it("reads no path for a path that matches nothing", function()
        local state = { pathReads = 0 }
        local photos = {}
        for i = 1, 10 do
            photos[i] = fakePhoto(i, "/" .. i .. ".jpg", state)
        end
        local catalog = fakeCatalog(photos)

        local r = PhotoLookup.resolveMany(catalog, { "/missing.jpg" })

        assert.is_nil(r[1].photo)
        assert.are.equal(0, state.pathReads)
    end)

    it("resolves a path shared with virtual copies to the master", function()
        local master = fakePhoto(1, "/shared.nef")
        local virtualCopy = fakePhoto(2, "/shared.nef")
        linkCopies(master, { virtualCopy })
        local catalog = fakeCatalog({ master, virtualCopy })

        local r = PhotoLookup.resolveMany(catalog, { "/shared.nef" })

        assert.are.equal(master, r[1].photo)
    end)

    it("resolves to the master even when the path lookup returns a virtual copy", function()
        local master = fakePhoto(1, "/shared.nef")
        local copyA = fakePhoto(2, "/shared.nef")
        local copyB = fakePhoto(3, "/shared.nef")
        linkCopies(master, { copyA, copyB })
        local catalog = fakeCatalog({ copyB, master, copyA })

        assert.are.equal(master, PhotoLookup.resolveOne(catalog, "/shared.nef"))
    end)

    it("resolves a shared path to the master while ids name the virtual copies", function()
        local master = fakePhoto(1, "/shared.nef")
        local copyA = fakePhoto(2, "/shared.nef")
        local copyB = fakePhoto(3, "/shared.nef")
        linkCopies(master, { copyA, copyB })
        local catalog = fakeCatalog({ copyB, master, copyA })

        local r = PhotoLookup.resolveMany(catalog, { "2", "/shared.nef", "3" })

        assert.are.equal(copyA, r[1].photo)
        assert.are.equal(master, r[2].photo)
        assert.are.equal(copyB, r[3].photo)
    end)
end)

describe("PhotoLookup.resolveOne", function()
    before_each(loadModule)

    it("returns the matching photo by local id", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        assert.are.equal(p1, PhotoLookup.resolveOne(catalog, "1"))
    end)

    it("returns the matching photo by path", function()
        local p1 = fakePhoto(1, "/a.jpg")
        local catalog, _ = fakeCatalog({ p1 })
        assert.are.equal(p1, PhotoLookup.resolveOne(catalog, "/a.jpg"))
    end)

    it("returns nil when nothing matches", function()
        local catalog, _ = fakeCatalog({})
        assert.is_nil(PhotoLookup.resolveOne(catalog, "missing"))
    end)
end)
