local PathForms = require 'PathForms'

local NFC = "/Zdj\196\153cia/w\196\133\197\188.jpg"
local NFD = "/Zdje\204\168cia/wa\204\168z\204\135.jpg"

describe("PathForms", function()
    it("converts between composed and decomposed paths", function()
        assert.are.equal(NFD, PathForms.toNfd(NFC))
        assert.are.equal(NFC, PathForms.toNfc(NFD))
    end)

    it("treats the two forms as one path and different letters as different", function()
        assert.is_true(PathForms.same(NFC, NFD))
        assert.is_false(PathForms.same("/w\197\186.jpg", "/w\197\188.jpg"))
        assert.is_false(PathForms.same("/A.jpg", "/a.jpg"))
    end)

    it("does not compose into characters that NFC excludes", function()
        assert.are.equal("/\206\185.jpg", PathForms.toNfc("/\206\185.jpg"))
        assert.are.equal("/\206\185.jpg", PathForms.toNfc("/\225\190\190.jpg"))
        assert.are.equal("/\195\133.jpg", PathForms.toNfc("/\226\132\171.jpg"))
    end)

    it("converts Hangul syllables with and without a final consonant", function()
        local composed = "/\236\130\172\236\167\132/\234\176\128.jpg"
        local decomposed = "/\225\132\137\225\133\161\225\132\140\225\133\181\225\134\171"
            .. "/\225\132\128\225\133\161.jpg"
        assert.are.equal(decomposed, PathForms.toNfd(composed))
        assert.are.equal(composed, PathForms.toNfc(decomposed))
        assert.is_true(PathForms.same(composed, decomposed))
    end)

    it("leaves ASCII and unmapped text unchanged", function()
        assert.is_true(PathForms.isAscii("/plain/a.jpg"))
        assert.is_false(PathForms.isAscii(NFC))
        assert.are.equal("/\229\134\153\231\156\159.jpg", PathForms.toNfd("/\229\134\153\231\156\159.jpg"))
        assert.are.equal("/\229\134\153\231\156\159.jpg", PathForms.toNfc("/\229\134\153\231\156\159.jpg"))
    end)
end)

describe("PathForms.relative", function()
    it("finds a file under a root spelled with or without macOS's /private prefix", function()
        assert.are.equal("d/eb_fringe.png", PathForms.relative("/private/tmp/src", "/tmp/src/d/eb_fringe.png"))
        assert.are.equal("a.png", PathForms.relative("/tmp/src", "/private/tmp/src/a.png"))
        assert.are.equal("a.jpg", PathForms.relative("/private/var/folders/out/", "/var/folders/out/a.jpg"))
    end)

    it("finds a file under a root spelled the same way", function()
        assert.are.equal("d/a.arw", PathForms.relative("/card", "/card/d/a.arw"))
    end)

    it("finds a file under a root in the other Unicode form", function()
        assert.are.equal("a.jpg", PathForms.relative("/w\196\133", "/wa\204\168/a.jpg"))
    end)

    it("answers nil for a file outside the root", function()
        assert.is_nil(PathForms.relative("/card", "/cardx/a.arw"))
        assert.is_nil(PathForms.relative("/private/tmp/src", "/tmp/other/a.png"))
    end)
end)
