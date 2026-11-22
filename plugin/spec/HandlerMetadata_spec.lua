local helper = require "spec_helper"

local function readOne(Handler, args) return Handler.getPhotoMetadata({ photo_ids = { args.photo_id } }).data.photos[1] end

local function setup(photos)
    local catalog = helper.fakeCatalog({ photos = photos or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrTasks = { pcall = pcall },
        LrLogger = helper.defaultLrLogger(),
    })
    package.loaded.HandlerMetadata = nil
    return catalog, require "HandlerMetadata"
end

describe("HandlerMetadata.getPhotoMetadata", function()
    it("returns ordered single-photo metadata for mixed ids and paths, including repeats", function()
        local first = helper.fakePhoto({
            id = 1,
            path = "/first.jpg",
            title = "First",
            developSettings = { Exposure2012 = 0.5 },
        })
        local second = helper.fakePhoto({
            id = 2,
            path = "/second.jpg",
            rating = 4,
            developSettings = { Contrast2012 = 25 },
        })
        local catalog, Handler = setup({ first, second })
        local a = readOne(Handler, { photo_id = 1 })
        local b = readOne(Handler, { photo_id = 2 })
        local result = Handler.getPhotoMetadata({ photo_ids = { 2, "missing", "/first.jpg", 2, "999999999" } })
        assert.are.same({ b, a, b }, result.data.photos)
        assert.are.same({ "missing", "999999999" }, result.not_found)
        assert.is_false(catalog:getQueriedInsideReadAccess())
    end)

    it("answers an all-missing batch with not_found only, as given, and a found batch without not_found", function()
        local _, Handler = setup({ helper.fakePhoto({ id = 1 }) })
        local none = Handler.getPhotoMetadata({ photo_ids = { "missing", 404 } })
        assert.is_nil(none.data)
        assert.are.same({ "missing", 404 }, none.not_found)
        assert.is_nil(Handler.getPhotoMetadata({ photo_ids = { 1 } }).not_found)
    end)

    it("accepts the batch cap and never reads unrequested develop settings", function()
        local photos, ids = {}, {}
        for i = 1, 100 do
            photos[i] = helper.fakePhoto({ id = i })
            photos[i].getDevelopSettings = function() error("unrequested develop read") end
            ids[i] = i
        end
        local _, Handler = setup(photos)
        assert.are.equal(100, #Handler.getPhotoMetadata({ photo_ids = ids }).data.photos)
    end)

    it("reads a page of photos through batch reads, not one getter call per field and photo", function()
        local photos, inBatch = {}, false
        for i = 1, 3 do
            photos[i] = helper.fakePhoto({ id = i, title = "t" .. i, rating = i })
            for _, getter in ipairs({ "getRawMetadata", "getFormattedMetadata" }) do
                local original = photos[i][getter]
                photos[i][getter] = function(self, key)
                    if not inBatch then error("per-photo read of " .. key) end
                    return original(self, key)
                end
            end
        end
        local catalog, Handler = setup(photos)
        local batches = 0
        for _, name in ipairs({ "batchGetRawMetadata", "batchGetFormattedMetadata" }) do
            local original = catalog[name]
            catalog[name] = function(...)
                batches = batches + 1
                inBatch = true
                local ok, result = pcall(original, ...)
                inBatch = false
                if not ok then error(result, 0) end
                return result
            end
        end

        local r = Handler.getPhotoMetadata({ photo_ids = { 1, 2, 3 } })

        assert.are.same(
            { "t1", "t2", "t3" },
            { r.data.photos[1].title, r.data.photos[2].title, r.data.photos[3].title }
        )
        assert.are.equal(3, r.data.photos[3].rating)
        assert.is_true(batches <= 3)
    end)

    it("returns nonempty accessibility text and omits empty fields", function()
        local photo = helper.fakePhoto({ id = "1", altTextAccessibility = "A red barn", extDescrAccessibility = "" })
        local _, Handler = setup({ photo })
        assert.are.same({ alt_text = "A red barn" }, readOne(Handler, { photo_id = "1" }).accessibility)
        photo:setRawMetadata("extDescrAccessibility", "A barn beside a field")
        assert.are.equal(
            "A barn beside a field",
            readOne(Handler, { photo_id = "1" }).accessibility.extended_description
        )
        photo:setRawMetadata("altTextAccessibility", "")
        photo:setRawMetadata("extDescrAccessibility", "")
        assert.is_nil(readOne(Handler, { photo_id = "1" }).accessibility)
    end)

    it("fails instead of silently dropping alt text when Lightroom rejects the accessibility read", function()
        local photo = helper.fakePhoto({ id = "1", title = "Keep", rating = 5, altTextAccessibility = "A red barn" })
        local getRawMetadata = photo.getRawMetadata
        photo.getRawMetadata = function(self, key)
            if key == "altTextAccessibility" or key == "extDescrAccessibility" then error("unknown key") end
            return getRawMetadata(self, key)
        end
        local _, Handler = setup({ photo })

        assert.error_matches(function() Handler.getPhotoMetadata({ photo_ids = { "1" } }) end, "unknown key", 1, true)
    end)

    it("identifies a virtual copy and its master's catalog id", function()
        local master = helper.fakePhoto({ id = 7 })
        local copy =
            helper.fakePhoto({ id = 8, isVirtualCopy = true, masterPhoto = master, copyName = "Probe copy 4x5" })
        local _, Handler = setup({ master, copy })

        local r = readOne(Handler, { photo_id = "8" })

        assert.is_true(r.is_virtual_copy)
        assert.are.same({ master_photo_id = "7", copy_name = "Probe copy 4x5" }, r.virtual_copy)
    end)

    it("lists a master's virtual copies by catalog id", function()
        local copies = { helper.fakePhoto({ id = 8 }), helper.fakePhoto({ id = 9 }) }
        local master = helper.fakePhoto({ id = 7, isVirtualCopy = false, virtualCopies = copies })
        local _, Handler = setup({ master })

        local r = readOne(Handler, { photo_id = "7" })

        assert.is_false(r.is_virtual_copy)
        assert.are.same({ copy_photo_ids = { "8", "9" } }, r.virtual_copy)
    end)

    it("reports folder stack position, collapse state, top and ordered members", function()
        local top = helper.fakePhoto({ id = 7 })
        local photo = helper.fakePhoto({
            id = 8,
            isInStackInFolder = true,
            stackPositionInFolder = 2,
            stackInFolderIsCollapsed = false,
            topOfStackInFolderContainingPhoto = top,
        })
        photo:setRawMetadata("stackInFolderMembers", { top, photo })
        local _, Handler = setup({ top, photo })

        local r = readOne(Handler, { photo_id = "8" })

        assert.are.same(
            { position = 2, is_collapsed = false, top_photo_id = "7", member_photo_ids = { "7", "8" } },
            r.stack
        )
        photo:setRawMetadata("stackPositionInFolder", 1)
        photo:setRawMetadata("stackInFolderIsCollapsed", true)
        assert.is_true(readOne(Handler, { photo_id = "8" }).stack.is_collapsed)
    end)

    it("omits copy and stack groups when the photo has neither", function()
        local photo = helper.fakePhoto({ id = 7, isVirtualCopy = false, virtualCopies = {}, isInStackInFolder = false })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "7" })

        assert.is_false(r.is_virtual_copy)
        assert.is_nil(r.virtual_copy)
        assert.is_nil(r.stack)
    end)

    it("reads member lists once without reading member metadata", function()
        local members = {}
        for i = 1, 1000 do
            members[i] = { localIdentifier = i, getRawMetadata = function() error("member read") end }
        end
        local meta = {
            id = 7,
            virtualCopies = members,
            isInStackInFolder = true,
            stackInFolderMembers = members,
            topOfStackInFolderContainingPhoto = members[1],
        }
        local photo = helper.fakePhoto(meta)
        local reads = {}
        local original = photo.getRawMetadata
        photo.getRawMetadata = function(self, key)
            reads[key] = (reads[key] or 0) + 1
            return original(self, key)
        end
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "7" })

        assert.are.equal(1000, #r.virtual_copy.copy_photo_ids)
        assert.are.equal(1000, #r.stack.member_photo_ids)
        assert.are.equal(1, reads.virtualCopies)
        assert.are.equal(1, reads.stackInFolderMembers)
    end)

    it("returns full metadata for a found photo", function()
        local photo = helper.fakePhoto({
            id = "42",
            path = "/p/sunset.jpg",
            fileName = "sunset.jpg",
            rating = 5,
            colorNameForLabel = "red",
            pickStatus = 1,
            keywords = {
                helper.fakeKeyword("summer"),
                helper.fakeKeyword("beach", { parent = helper.fakeKeyword("Places") }),
            },
            cameraMake = "Canon",
            cameraModel = "R5",
            developSettings = {
                Exposure2012 = 0.5,
                WhiteBalance = "Custom",
                ConvertToGrayscale = true,
                ToneCurveName2012 = "Custom",
                ToneCurvePV2012 = { 0, 0, 64, 48, 255, 255 },
                ToneCurvePV2012Red = { 0, 0, 255, 250 },
            },
        })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "42" })

        assert.are.equal("42", r.photo_id)
        assert.are.equal("/p/sunset.jpg", r.path)
        assert.are.equal(5, r.rating)
        assert.are.equal("red", r.color_label)
        assert.are.equal("pick", r.flag)
        assert.are.equal("Canon", r.camera_make)
        assert.is_nil(r.developSettings)
        assert.are.same({ "summer", "beach" }, r.keywords)
        assert.are.same({ "summer", "Places|beach" }, r.keyword_paths)
    end)

    it("names every field outside the develop section in snake_case", function()
        local top = helper.fakePhoto({ localIdentifier = 7 })
        local photo = helper.fakePhoto({
            localIdentifier = 8,
            path = "/p/a.jpg",
            fileName = "a.jpg",
            rating = 2,
            colorNameForLabel = "red",
            pickStatus = 1,
            title = "t",
            caption = "c",
            headline = "h",
            altTextAccessibility = "alt",
            extDescrAccessibility = "ext",
            dateTimeOriginal = "d",
            dateTimeDigitized = "d",
            cameraMake = "m",
            cameraModel = "m",
            cameraSerialNumber = "s",
            lens = "l",
            isoSpeedRating = "100",
            focalLength = "50",
            focalLength35mm = "50",
            aperture = "f/2",
            shutterSpeed = "1/100",
            exposureBias = "0",
            exposureProgram = "p",
            meteringMode = "m",
            flash = "f",
            dimensions = "1x1",
            fileSize = "1",
            fileFormat = "JPG",
            artist = "a",
            software = "s",
            gps = { latitude = 1, longitude = 2 },
            gpsAltitude = 3,
            location = "l",
            city = "c",
            stateProvince = "s",
            country = "c",
            isoCountryCode = "c",
            creator = "c",
            copyright = "c",
            copyrightState = "c",
            rightsUsageTerms = "r",
            copyrightInfoUrl = "u",
            creatorUrl = "u",
            isVirtualCopy = true,
            masterPhoto = top,
            copyName = "copy",
            isInStackInFolder = true,
            stackPositionInFolder = 2,
            stackInFolderIsCollapsed = false,
            topOfStackInFolderContainingPhoto = top,
            keywords = { helper.fakeKeyword("k") },
        })
        photo:setRawMetadata("stackInFolderMembers", { top, photo })
        local _, Handler = setup({ top, photo })

        local record = readOne(Handler, { photo_id = 8 })

        local wrong = {}
        local function check(value, where)
            for key, item in pairs(value) do
                if type(key) == "string" and not key:match("^[a-z][a-z0-9_]*$") then
                    wrong[#wrong + 1] = where .. key
                end
                if type(item) == "table" then check(item, where .. tostring(key) .. ".") end
            end
        end
        check(record, "")
        assert.are.same({}, wrong)
        assert.are.equal("8", record.photo_id)
        assert.are.same({ "location", "copyright", "gps", "accessibility" }, {
            record.location and "location",
            record.copyright and "copyright",
            record.gps and "gps",
            record.accessibility and "accessibility",
        })
    end)

    it("exposes IPTC location, GPS, and copyright metadata", function()
        local photo = helper.fakePhoto({
            id = "7",
            path = "/p/street.jpg",
            fileName = "street.jpg",
            title = "Main Street",
            caption = "Downtown at dusk",
            headline = "Evening commute",
            location = "5th Avenue",
            city = "New York",
            stateProvince = "NY",
            country = "USA",
            isoCountryCode = "US",
            gps = { latitude = 40.7128, longitude = -74.006 },
            gpsAltitude = 10.5,
            creator = "Jane Doe",
            copyright = "© Jane Doe",
            copyrightState = "Copyrighted",
            rightsUsageTerms = "All rights reserved",
        })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "7" })

        assert.are.equal("Main Street", r.title)
        assert.are.equal("Downtown at dusk", r.caption)
        assert.are.equal("5th Avenue", r.location.sublocation)
        assert.are.equal("New York", r.location.city)
        assert.are.equal("NY", r.location.state_province)
        assert.are.equal("USA", r.location.country)
        assert.are.equal("US", r.location.iso_country_code)
        assert.are.equal(40.7128, r.gps.latitude)
        assert.are.equal(-74.006, r.gps.longitude)
        assert.are.equal(10.5, r.gps.altitude)
        assert.are.equal("Jane Doe", r.copyright.creator)
        assert.are.equal("Copyrighted", r.copyright.status)
    end)

    it("omits gps, location, and copyright groups when empty", function()
        local photo = helper.fakePhoto({ id = "8", path = "/p/no-gps.jpg", fileName = "no-gps.jpg" })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "8" })
        assert.is_nil(r.gps)
        assert.is_nil(r.location)
        assert.is_nil(r.copyright)
    end)

    it("omits the gps group when the raw table carries no coordinates", function()
        local photo = helper.fakePhoto({ id = "10", fileName = "empty-gps.jpg", gps = {} })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "10" })
        assert.is_nil(r.gps)
    end)

    it("falls back to lookup by path when local id misses", function()
        local photo = helper.fakePhoto({
            id = "99",
            path = "/match-by-path.jpg",
            fileName = "f.jpg",
        })
        local _, Handler = setup({ photo })

        local r = readOne(Handler, { photo_id = "/match-by-path.jpg" })
        assert.are.equal("/match-by-path.jpg", r.path)
    end)

    it("resolves the photo OUTSIDE the read-access gate", function()
        local photo = helper.fakePhoto({ id = "99", path = "/p.jpg", fileName = "p.jpg" })
        local catalog, Handler = setup({ photo })

        readOne(Handler, { photo_id = "/p.jpg" })

        assert.is_false(catalog.getQueriedInsideReadAccess())
    end)
end)

describe("HandlerMetadata.setGps", function()
    it("writes latitude and longitude to found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", gps = { latitude = 1, longitude = 2 } })
        local _, Handler = setup({ p1, p2 })

        local r = Handler.setGps({ photo_ids = { "1", "2" }, latitude = 48.5818, longitude = 7.7509 })

        assert.are.equal(2, r.data.updated)
        assert.are.same({ latitude = 48.5818, longitude = 7.7509 }, p1:getRawMetadata("gps"))
        assert.are.same({ latitude = 48.5818, longitude = 7.7509 }, p2:getRawMetadata("gps"))
    end)

    it("leaves altitude alone unless one is given", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gpsAltitude = 12 })
        local _, Handler = setup({ p1 })

        Handler.setGps({ photo_ids = { "1" }, latitude = 0, longitude = 0 })
        assert.are.equal(12, p1:getRawMetadata("gpsAltitude"))

        Handler.setGps({ photo_ids = { "1" }, latitude = 0, longitude = 0, altitude = 140.5 })
        assert.are.equal(140.5, p1:getRawMetadata("gpsAltitude"))
    end)

    it("clears altitude with clear_altitude", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gpsAltitude = 3000 })
        local _, Handler = setup({ p1 })

        Handler.setGps({ photo_ids = { "1" }, latitude = 54.4, longitude = 18.6, clear_altitude = true })

        assert.is_nil(p1:getRawMetadata("gpsAltitude"))
    end)

    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        Handler.setGps({ photo_ids = { "1" }, latitude = 1, longitude = 1 })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })

        local r = Handler.setGps({ photo_ids = { "1", "missing" }, latitude = 1, longitude = 1 })

        assert.are.equal(1, r.data.updated)
        assert.are.same({ "missing" }, r.not_found)
    end)
end)

describe("HandlerMetadata.setLocation", function()
    it("writes the given IPTC location fields to found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", city = "Paris" })
        local _, Handler = setup({ p1, p2 })

        local r = Handler.setLocation({
            photo_ids = { "1", "2" },
            sublocation = "Nelson-Atkins Museum of Art",
            city = "Kansas City",
            state_province = "Missouri",
            country = "United States",
            iso_country_code = "US",
        })

        assert.are.equal(2, r.data.updated)
        assert.are.same({ "sublocation", "city", "state_province", "country", "iso_country_code" }, r.data.fields)
        for _, p in ipairs({ p1, p2 }) do
            assert.are.equal("Nelson-Atkins Museum of Art", p:getRawMetadata("location"))
            assert.are.equal("Kansas City", p:getRawMetadata("city"))
            assert.are.equal("Missouri", p:getRawMetadata("stateProvince"))
            assert.are.equal("United States", p:getRawMetadata("country"))
            assert.are.equal("US", p:getRawMetadata("isoCountryCode"))
        end
    end)

    it("leaves fields that are not given unchanged", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", city = "Sydney", country = "Australia" })
        local _, Handler = setup({ p1 })

        local r = Handler.setLocation({ photo_ids = { "1" }, sublocation = "Bondi Beach" })

        assert.are.same({ "sublocation" }, r.data.fields)
        assert.are.equal("Bondi Beach", p1:getRawMetadata("location"))
        assert.are.equal("Sydney", p1:getRawMetadata("city"))
        assert.are.equal("Australia", p1:getRawMetadata("country"))
    end)

    it("clears a field given as an empty string", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", location = "Old venue", city = "Berlin" })
        local _, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, sublocation = "" })

        -- Not nil: Lightroom stores nil on these fields as the text "nil".
        assert.are.equal("", p1:getRawMetadata("location"))
        assert.are.equal("Berlin", p1:getRawMetadata("city"))
    end)

    it("does not touch GPS", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", gps = { latitude = 1, longitude = 2 } })
        local _, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, city = "Rotorua" })

        assert.are.same({ latitude = 1, longitude = 2 }, p1:getRawMetadata("gps"))
    end)

    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        Handler.setLocation({ photo_ids = { "1" }, city = "Memphis" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })

        local r = Handler.setLocation({ photo_ids = { "1", "missing" }, city = "Munich" })

        assert.are.equal(1, r.data.updated)
        assert.are.same({ "missing" }, r.not_found)
    end)
end)

describe("HandlerMetadata.setMetadata", function()
    it("writes and clears accessibility text on multiple photos", function()
        local photos = { helper.fakePhoto({ id = "1" }), helper.fakePhoto({ id = "2" }) }
        local _, Handler = setup(photos)
        local r = Handler.setMetadata({
            photo_ids = { "1", "2" },
            alt_text = "A red barn",
            extended_description = "A barn beside a field",
        })
        assert.are.equal(2, r.data.updated)
        assert.are.same({ "alt_text", "extended_description" }, r.data.fields)
        for _, photo in ipairs(photos) do
            assert.are.equal("A red barn", photo:getRawMetadata("altTextAccessibility"))
            assert.are.equal("A barn beside a field", photo:getRawMetadata("extDescrAccessibility"))
        end
        Handler.setMetadata({ photo_ids = { "1", "2" }, title = "New" })
        for _, photo in ipairs(photos) do
            assert.are.equal("A red barn", photo:getRawMetadata("altTextAccessibility"))
        end
        Handler.setMetadata({ photo_ids = { "1", "2" }, alt_text = "", extended_description = "" })
        for _, photo in ipairs(photos) do
            assert.are.equal("", photo:getRawMetadata("altTextAccessibility"))
            assert.are.equal("", photo:getRawMetadata("extDescrAccessibility"))
        end
    end)

    it("answers failed for a write Lightroom fails inside the gate, which the transaction rolls back", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg" })
        p2.setRawMetadata = function() error("unknown key: title", 0) end
        local _, Handler = setup({ p1, p2 })

        assert.are.same({ "failed", "unknown key: title" }, {
            helper.outcomeOf(
                function(context) Handler.setMetadata({ photo_ids = { "1", "2" }, title = "New" }, context) end
            ),
        })
    end)

    it("writes every given field to found photos", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local p2 = helper.fakePhoto({ id = "2", path = "/b.jpg", title = "Old" })
        local _, Handler = setup({ p1, p2 })

        local r = Handler.setMetadata({
            photo_ids = { "1", "2" },
            title = "Dunluce Castle",
            caption = "Ruins on the Causeway Coast",
            headline = "Northern Ireland",
            creator = "Matthew Pearon",
            copyright = "© 2025 Matthew Pearon; All rights reserved.",
            rights_usage_terms = "No reuse without permission",
            copyright_info_url = "https://example.com/licensing",
            creator_url = "https://example.com",
        })

        assert.are.equal(2, r.data.updated)
        assert.are.same({
            "title",
            "caption",
            "headline",
            "creator",
            "copyright",
            "rights_usage_terms",
            "copyright_info_url",
            "creator_url",
        }, r.data.fields)
        for _, p in ipairs({ p1, p2 }) do
            assert.are.equal("Dunluce Castle", p:getRawMetadata("title"))
            assert.are.equal("Ruins on the Causeway Coast", p:getRawMetadata("caption"))
            assert.are.equal("Northern Ireland", p:getRawMetadata("headline"))
            assert.are.equal("Matthew Pearon", p:getRawMetadata("creator"))
            assert.are.equal("© 2025 Matthew Pearon; All rights reserved.", p:getRawMetadata("copyright"))
            assert.are.equal("No reuse without permission", p:getRawMetadata("rightsUsageTerms"))
            assert.are.equal("https://example.com/licensing", p:getRawMetadata("copyrightInfoUrl"))
            assert.are.equal("https://example.com", p:getRawMetadata("creatorUrl"))
        end
    end)

    it("leaves fields that are not given unchanged", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", title = "Keep", copyright = "© 2024" })
        local _, Handler = setup({ p1 })

        Handler.setMetadata({ photo_ids = { "1" }, creator = "Matthew Pearon" })

        assert.are.equal("Keep", p1:getRawMetadata("title"))
        assert.are.equal("© 2024", p1:getRawMetadata("copyright"))
        assert.are.equal("Matthew Pearon", p1:getRawMetadata("creator"))
    end)

    it("clears a field given as an empty string", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg", caption = "Old caption", title = "Keep" })
        local _, Handler = setup({ p1 })

        Handler.setMetadata({ photo_ids = { "1" }, caption = "" })

        -- Not nil: Lightroom stores nil on these fields as the text "nil".
        assert.are.equal("", p1:getRawMetadata("caption"))
        assert.are.equal("Keep", p1:getRawMetadata("title"))
    end)

    it("resolves photos OUTSIDE the write-access gate", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local catalog, Handler = setup({ p1 })

        Handler.setMetadata({ photo_ids = { "1" }, title = "T" })

        assert.is_false(catalog.getQueriedInsideWriteAccess())
    end)

    it("reports unknown photos instead of claiming a silent success", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })

        local r = Handler.setMetadata({ photo_ids = { "1", "missing" }, title = "T" })

        assert.are.equal(1, r.data.updated)
        assert.are.same({ "missing" }, r.not_found)
    end)
end)

describe("HandlerMetadata writes when no photo_id is known", function()
    for _, case in ipairs({
        { "setGps", { latitude = 1, longitude = 2 } },
        { "setLocation", { city = "Kyoto" } },
        { "setMetadata", { title = "t" } },
    }) do
        it(case[1] .. " answers with not_found and no data, writing nothing", function()
            local catalog, Handler = setup({})
            local args = case[2]
            args.photo_ids = { 404 }
            local reply = Handler[case[1]](args)
            assert.is_nil(reply.data)
            assert.are.same({ 404 }, reply.not_found)
            assert.are.equal(0, catalog.getWriteAccessCount())
        end)
    end

    it("counts a photo named twice once", function()
        local p1 = helper.fakePhoto({ id = "1", path = "/a.jpg" })
        local _, Handler = setup({ p1 })
        assert.are.same(
            { data = { updated = 1 } },
            Handler.setGps({ photo_ids = { "1", "/a.jpg" }, latitude = 1, longitude = 2 })
        )
    end)
end)
