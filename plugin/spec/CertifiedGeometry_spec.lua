local Store = require 'fake_mask_store'

local function point(x, y) return { x = x, y = y } end

local function canonical(value)
    local kind = type(value)
    if kind == "number" then return string.format("%.17g", value) end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "table" then return tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    if #keys == #value then
        local items = {}
        for index = 1, #value do items[index] = canonical(value[index]) end
        return "[" .. table.concat(items, ",") .. "]"
    end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    local fields = {}
    for index, key in ipairs(keys) do fields[index] = tostring(key) .. "=" .. canonical(value[key]) end
    return "{" .. table.concat(fields, ",") .. "}"
end

local MINTED = "^%x%x%x%x%x%x%x%x%-0000%-4000%-8000%-%x+$"

local function withNamedMints(value, names)
    if type(value) == "string" then
        local id = value:match("^S(.+)$") or value
        if not id:match(MINTED) then return value end
        if names[id] == nil then
            names.count = names.count + 1
            names[id] = "NEW" .. names.count
        end
        return (value == id and "" or "S") .. names[id]
    end
    if type(value) ~= "table" then return value end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local copy = {}
    for _, key in ipairs(keys) do copy[key] = withNamedMints(value[key], names) end
    return copy
end

local function writesOf(stores, photoId)
    return canonical(withNamedMints(stores[photoId].writes, { count = 0 }))
end

local function lightroomFillsDepthInfo(stored)
    for _, entry in ipairs(stored) do
        for _, component in ipairs(entry.CorrectionMasks) do
            if component.CorrectionRangeMask and component.CorrectionRangeMask.Type == -1 then
                component.CorrectionRangeMask.LuminanceDepthSampleInfo = "0 0.5 0.5"
            end
        end
    end
    return stored
end

local function lightroomColorRange()
    return Store.correction("Reds", { {
        What = "Mask/RangeMask", MaskID = "C1T1", MaskActive = true, MaskInverted = false, MaskBlendMode = 0,
        CorrectionRangeMask = {
            Type = 1, Version = 3, SampleType = 0, ColorAmount = 0.494949,
            PointModels = { "0.522527 0.888059 0.758296 0.050000 0.188000 0" },
        },
    } }, { CorrectionID = "C1" })
end

local CERTIFIED_RADIAL = { center = point(0.5, 0.5), width = 0.4, height = 0.3, rotation = 30, feather = 0 }

local function withRadial(fields)
    local args = { photo_id = "1", shape = "radial" }
    for key, value in pairs(CERTIFIED_RADIAL) do args[key] = value end
    for key, value in pairs(fields) do args[key] = value end
    return args
end

local CASES = {
    {
        name = "radial create and rotation update",
        handler = "HandlerGradientMasks", modules = { "GradientGeometry" },
        photos = { { id = "1" } },
        run = function(Handler)
            local created = Handler.createGradientMask(withRadial({ adjustments = { local_Exposure = 2 } }))
            Handler.updateGradientMask({ photo_id = "1", tool_id = created.tool_id, rotation = -30 })
        end,
    },
    {
        name = "linear create and end update",
        handler = "HandlerGradientMasks", modules = { "GradientGeometry" },
        photos = { { id = "1" } },
        run = function(Handler)
            local created = Handler.createGradientMask({
                photo_id = "1", shape = "linear", start = point(0.2, 0.3), ["end"] = point(0.6, 0.3),
                adjustments = { local_Exposure = 1 },
            })
            Handler.updateGradientMask({ photo_id = "1", tool_id = created.tool_id, ["end"] = point(0.7, 0.4) })
        end,
    },
    {
        name = "gradients on a turned photo, defaults, outside area and a subtracted component",
        handler = "HandlerGradientMasks", modules = { "GradientGeometry" },
        photos = { { id = "1", orientation = "BC" } },
        run = function(Handler)
            local linear = Handler.createGradientMask({
                photo_id = "1", shape = "linear", start = point(0.5, 0.9), ["end"] = point(0.5, 0.7),
            })
            Handler.createGradientMask(withRadial({ name = "Ellipse" }))
            Handler.createGradientMask({
                photo_id = "1", shape = "radial", center = point(0.3, 0.6), width = 0.5, height = 0.2,
                rotation = 60, area = "outside", mask_id = linear.mask_id, mode = "subtract",
            })
            Handler.updateGradientMask({ photo_id = "1", tool_id = linear.tool_id, start = point(0.4, 0.95) })
        end,
    },
    {
        name = "brush create and erase stroke",
        handler = "HandlerBrushMasks", modules = { "BrushStrokes", "ImageFrame" },
        photos = { { id = "1" } },
        run = function(Handler)
            local created = Handler.createBrushMask({
                photo_id = "1", strokes = { { points = { point(0.1, 0.85), point(0.4, 0.85) }, radius = 0.05 } },
                adjustments = { local_Exposure = 0.7 },
            })
            Handler.addBrushStrokes({
                photo_id = "1", tool_id = created.tool_id,
                strokes = { { points = { point(0.3, 0.85) }, radius = 0.04, erase = true } },
            })
        end,
    },
    {
        name = "brush feather, density and flow on a turned photo",
        handler = "HandlerBrushMasks", modules = { "BrushStrokes", "ImageFrame" },
        photos = { { id = "1", orientation = "BC" } },
        run = function(Handler)
            Handler.createBrushMask({
                photo_id = "1", name = "Face",
                strokes = {
                    { points = { point(0.2, 0.3), point(0.35, 0.32), point(0.5, 0.4) }, feather = 30, density = 0.537, flow = 0.37291 },
                    { points = { point(0.6, 0.6), point(0.62, 0.7) }, radius = 0.2, feather = 0 },
                },
            })
        end,
    },
    {
        name = "luminance, color and depth ranges",
        handler = "HandlerRangeMasks", modules = { "ImageFrame", "RangeMaskGeometry" },
        photos = { { id = "1", transformWrite = lightroomFillsDepthInfo } },
        run = function(Handler)
            Handler.createRangeMask({
                photo_id = "1", type = "luminance", luminance = { min = 0.6, max = 1 },
                adjustments = { local_Exposure = -1 },
            })
            Handler.createRangeMask({
                photo_id = "1", type = "color",
                color = { sample = { x = 0.048726, y = 0.060942, l = 0.570123, a = 0.961792, b = 0.817275 }, amount = 0.494949 },
                adjustments = { local_Exposure = -1 },
            })
            Handler.createRangeMask({
                photo_id = "1", type = "depth", depth = { min = 0.2, max = 0.5, falloff = 0 }, invert = true,
            })
        end,
    },
    {
        name = "ranges on a turned photo and a sample copied from another photo",
        handler = "HandlerRangeMasks", modules = { "ImageFrame", "RangeMaskGeometry" },
        photos = { { id = "1", orientation = "BC" }, { id = "2", entries = { lightroomColorRange() } } },
        run = function(Handler)
            local luminance = Handler.createRangeMask({
                photo_id = "1", type = "luminance", luminance = { min = 0, max = 0.25, falloff = 0.3 },
            })
            Handler.createRangeMask({
                photo_id = "1", type = "color", name = "Copy", invert = true, color = { amount = 0.2 },
                copy_sample_from = { photo_id = "2", mask_id = "C1", tool_id = "C1T1" },
            })
            Handler.createRangeMask({
                photo_id = "1", type = "color", mask_id = luminance.mask_id, mode = "subtract",
                color = { sample = { x = 0.9, y = 0.1, l = 0.1, a = 0.2, b = 0.3 } },
            })
        end,
    },
}

local EXPECTED = {
    ["radial create and rotation update"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{Angle=30,Bottom=0.77990381056766578,Feather=0,Left=0.37679491924311226,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Radial Gradient\",MaskValue=1,Midpoint=50,Right=0.62320508075688774,Roundness=0,Top=0.22009618943233422,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Radial Gradient\",LocalExposure2012=0.5,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{Angle=-30,Bottom=0.47990381056766584,Feather=0,Left=0.27679491924311228,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Radial Gradient\",MaskSyncID=\"SNEW2\",MaskValue=1,Midpoint=50,Right=0.72320508075688772,Roundness=0,Top=0.52009618943233416,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Radial Gradient\",CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,LocalExposure2012=0.5,What=\"Correction\"}]]",
    ["linear create and end update"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.20000000000000001,FullY=0.29999999999999999,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.59999999999999998,ZeroY=0.29999999999999999}],CorrectionName=\"Linear Gradient\",LocalExposure2012=0.25,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.20000000000000001,FullY=0.29999999999999999,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.69999999999999996,ZeroY=0.40000000000000002}],CorrectionName=\"Linear Gradient\",CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,LocalExposure2012=0.25,What=\"Correction\"}]]",
    ["gradients on a turned photo, defaults, outside area and a subtracted component"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.90000000000000002,FullY=0.5,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.69999999999999996,ZeroY=0.5}],CorrectionName=\"Linear Gradient\",What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.90000000000000002,FullY=0.5,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.69999999999999996,ZeroY=0.5}],CorrectionName=\"Linear Gradient\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{Angle=30,Bottom=0.72320508075688772,Feather=0,Left=0.52009618943233416,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=false,MaskName=\"Radial Gradient\",MaskValue=1,Midpoint=50,Right=0.47990381056766584,Roundness=0,Top=0.27679491924311228,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Ellipse\",What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.90000000000000002,FullY=0.5,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.69999999999999996,ZeroY=0.5},{Angle=-30,Bottom=0.63273502691896255,Feather=50,Left=0.22524047358083543,MaskActive=true,MaskBlendMode=1,MaskID=\"NEW5\",MaskInverted=true,MaskName=\"Radial Gradient\",MaskValue=0,Midpoint=50,Right=0.97475952641916452,Roundness=0,Top=0.76726497308103736,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Linear Gradient\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{Angle=30,Bottom=0.72320508075688772,Feather=0,Flipped=true,Left=0.52009618943233416,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=false,MaskName=\"Radial Gradient\",MaskSyncID=\"SNEW4\",MaskValue=1,Midpoint=50,Right=0.47990381056766584,Roundness=0,Top=0.27679491924311228,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Ellipse\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS2\",LocalCurveRefineSaturation=100,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{FullX=0.94999999999999996,FullY=0.59999999999999998,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Linear Gradient\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/Gradient\",ZeroX=0.69999999999999996,ZeroY=0.5},{Angle=-30,Bottom=0.63273502691896255,Feather=50,Flipped=false,Left=0.22524047358083543,MaskActive=true,MaskBlendMode=1,MaskID=\"NEW5\",MaskInverted=true,MaskName=\"Radial Gradient\",MaskSyncID=\"SNEW5\",MaskValue=0,Midpoint=50,Right=0.97475952641916452,Roundness=0,Top=0.76726497308103736,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Linear Gradient\",CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{Angle=30,Bottom=0.72320508075688772,Feather=0,Flipped=true,Left=0.52009618943233416,MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=false,MaskName=\"Radial Gradient\",MaskSyncID=\"SNEW4\",MaskValue=1,Midpoint=50,Right=0.47990381056766584,Roundness=0,Top=0.27679491924311228,Version=2,What=\"Mask/CircularGradient\"}],CorrectionName=\"Ellipse\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS2\",LocalCurveRefineSaturation=100,What=\"Correction\"}]]",
    ["brush create and erase stroke"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Brush\",MaskValue=1,Masks=[{CenterWeight=0,Dabs=[\"d 0.100000 0.850000\",\"d 0.125000 0.850000\",\"d 0.150000 0.850000\",\"d 0.175000 0.850000\",\"d 0.200000 0.850000\",\"d 0.225000 0.850000\",\"d 0.250000 0.850000\",\"d 0.275000 0.850000\",\"d 0.300000 0.850000\",\"d 0.325000 0.850000\",\"d 0.350000 0.850000\",\"d 0.375000 0.850000\",\"d 0.400000 0.850000\"],Flow=1,MaskActive=true,MaskBlendMode=0,MaskInverted=false,MaskValue=1,Radius=0.050000000000000003,What=\"Mask/Paint\"}],What=\"Mask/Aggregate\"}],CorrectionName=\"Brush\",LocalExposure2012=0.17499999999999999,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Brush\",MaskSyncID=\"SNEW2\",MaskValue=1,Masks=[{CenterWeight=0,Dabs=[\"d 0.100000 0.850000\",\"d 0.125000 0.850000\",\"d 0.150000 0.850000\",\"d 0.175000 0.850000\",\"d 0.200000 0.850000\",\"d 0.225000 0.850000\",\"d 0.250000 0.850000\",\"d 0.275000 0.850000\",\"d 0.300000 0.850000\",\"d 0.325000 0.850000\",\"d 0.350000 0.850000\",\"d 0.375000 0.850000\",\"d 0.400000 0.850000\"],Flow=1,MaskActive=true,MaskBlendMode=0,MaskInverted=false,MaskValue=1,Radius=0.050000000000000003,What=\"Mask/Paint\"},{CenterWeight=0,Dabs=[\"d 0.300000 0.850000\"],Flow=1,MaskActive=true,MaskBlendMode=0,MaskInverted=false,MaskValue=0,Radius=0.040000000000000001,What=\"Mask/Paint\"}],What=\"Mask/Aggregate\"}],CorrectionName=\"Brush\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,LocalExposure2012=0.17499999999999999,What=\"Correction\"}]]",
    ["brush feather, density and flow on a turned photo"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Brush\",MaskValue=1,Masks=[{CenterWeight=0.34983700000000001,Dabs=[\"f 0.3729\",\"h 0.3498\",\"d 0.300000 0.800000\",\"d 0.304000 0.770000\",\"d 0.308000 0.740000\",\"d 0.312000 0.710000\",\"d 0.316000 0.680000\",\"d 0.320000 0.650000\",\"d 0.333333 0.625000\",\"d 0.346667 0.600000\",\"d 0.360000 0.575000\",\"d 0.373333 0.550000\",\"d 0.386667 0.525000\",\"d 0.400000 0.500000\"],Flow=0.37290000000000001,MaskActive=true,MaskBlendMode=0,MaskInverted=false,MaskValue=0.53700000000000003,Radius=0.066836000000000007,What=\"Mask/Paint\"},{CenterWeight=1,Dabs=[\"d 0.600000 0.400000\",\"d 0.633333 0.393333\",\"d 0.666667 0.386667\",\"d 0.700000 0.380000\"],Flow=1,MaskActive=true,MaskBlendMode=0,MaskInverted=false,MaskValue=1,Radius=0.078410999999999995,What=\"Mask/Paint\"}],What=\"Mask/Aggregate\"}],CorrectionName=\"Face\",What=\"Correction\"}]]",
    ["luminance, color and depth ranges"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.500000 0.600000 1.000000 1.000000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",LocalExposure2012=-0.25,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.500000 0.600000 1.000000 1.000000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,LocalExposure2012=-0.25,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{CorrectionRangeMask={ColorAmount=0.49494899999999997,PointModels=[\"0.570123 0.961792 0.817275 0.048726 0.060942 0\"],SampleType=0,Type=1,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=false,MaskName=\"Color Range\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Color Range\",LocalExposure2012=-0.25,What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.500000 0.600000 1.000000 1.000000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,LocalExposure2012=-0.25,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{CorrectionRangeMask={ColorAmount=0.49494899999999997,PointModels=[\"0.570123 0.961792 0.817275 0.048726 0.060942 0\"],SampleType=0,Type=1,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=false,MaskName=\"Color Range\",MaskSyncID=\"SNEW4\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Color Range\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS2\",LocalCurveRefineSaturation=100,LocalExposure2012=-0.25,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW5\",CorrectionMasks=[{CorrectionRangeMask={DepthRange=\"0.200000 0.200000 0.500000 0.500000\",SampleType=0,Type=-1,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW6\",MaskInverted=true,MaskName=\"Depth Range\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Depth Range\",What=\"Correction\"}]]",
    ["ranges on a turned photo and a sample copied from another photo"] = "[[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.000000 0.000000 0.250000 0.550000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.000000 0.000000 0.250000 0.550000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{CorrectionRangeMask={ColorAmount=0.20000000000000001,PointModels=[\"0.522527 0.888059 0.758296 0.188000 0.950000 0\"],SampleType=0,Type=1,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=true,MaskName=\"Color Range\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Copy\",What=\"Correction\"}],[{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW1\",CorrectionMasks=[{CorrectionRangeMask={LumRange=\"0.000000 0.000000 0.250000 0.550000\",SampleType=0,Type=2,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW2\",MaskInverted=false,MaskName=\"Luminance Range\",MaskSyncID=\"SNEW2\",MaskValue=1,What=\"Mask/RangeMask\"},{CorrectionRangeMask={ColorAmount=0.5,PointModels=[\"0.100000 0.200000 0.300000 0.100000 0.100000 0\"],SampleType=0,Type=1,Version=3},MaskActive=true,MaskBlendMode=1,MaskID=\"NEW5\",MaskInverted=false,MaskName=\"Color Range\",MaskValue=0,What=\"Mask/RangeMask\"}],CorrectionName=\"Luminance Range\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS1\",LocalCurveRefineSaturation=100,What=\"Correction\"},{CorrectionActive=true,CorrectionAmount=1,CorrectionID=\"NEW3\",CorrectionMasks=[{CorrectionRangeMask={ColorAmount=0.20000000000000001,PointModels=[\"0.522527 0.888059 0.758296 0.188000 0.950000 0\"],SampleType=0,Type=1,Version=3},MaskActive=true,MaskBlendMode=0,MaskID=\"NEW4\",MaskInverted=true,MaskName=\"Color Range\",MaskSyncID=\"SNEW4\",MaskValue=1,What=\"Mask/RangeMask\"}],CorrectionName=\"Copy\",CorrectionReferenceX=0.5,CorrectionReferenceY=0.5,CorrectionSyncID=\"CS2\",LocalCurveRefineSaturation=100,What=\"Correction\"}]]",
}

describe("stored geometry of the certified inputs", function()
    for _, case in ipairs(CASES) do
        it("stays byte for byte: " .. case.name, function()
            local Handler, stores = Store.guardedHandler(case.handler, case.modules, { photos = case.photos })

            case.run(Handler)

            assert.are.equal(EXPECTED[case.name], writesOf(stores, "1"))
        end)
    end
end)
