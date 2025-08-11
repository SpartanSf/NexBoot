local fs = peripherals.locate("file system")
local useRectangles = true

fs.createPartition("system")

local serpentFile = fs.open("bios:serpent.lua", "r")
local serpent = load(serpentFile.read("a"), "serpent", "t", _ENV)()
serpentFile.close()

local function parse_bdf(filename)
    local glyphs = {}
    local file = assert(fs.open(filename, "r"))
    local content = file.read("a")
    file.close()

    local current = nil
    local in_bitmap = false

    for line in content:gmatch("[^\r\n]+") do
        if line:match("^STARTCHAR") then
            current = { name = line:match("^STARTCHAR%s+(.+)") }
        elseif current and line:match("^ENCODING") then
            local enc = line:match("^ENCODING%s+([%-]?%d+)")
            current.encoding = tonumber(enc)
        elseif current and line:match("^DWIDTH") then
            local d = line:match("^DWIDTH%s+([%-]?%d+)")
            current.dwidth = tonumber(d)
            current.width = current.width or current.dwidth
        elseif current and line:match("^BBX") then
            local w, h, xoff, yoff = line:match("^BBX%s+([%-]?%d+)%s+([%-]?%d+)%s+([%-]?%d+)%s+([%-]?%d+)")
            if w then
                current.width   = tonumber(w)
                current.height  = tonumber(h)
                current.xoffset = tonumber(xoff)
                current.yoffset = tonumber(yoff)
            end
        elseif current and line:match("^BITMAP") then
            current.bitmap = {}
            in_bitmap = true
        elseif in_bitmap then
            if line:match("^ENDCHAR") then
                local encoding = current.encoding or -1
                local width  = current.width  or current.dwidth or 8
                local height = current.height or (#current.bitmap) or 8
                local xoff   = current.xoffset or 0
                local yoff   = current.yoffset or 0
                glyphs[encoding] = {
                    encoding = encoding,
                    width    = width,
                    height   = height,
                    xoffset  = xoff,
                    yoffset  = yoff,
                    bitmap   = current.bitmap
                }
                current = nil
                in_bitmap = false
            else
                local hex = line:match("^%s*([0-9A-Fa-f]+)%s*$") or "0"
                local val = tonumber(hex, 16) or 0
                local bits = #hex * 4

                local expectedBits = current.width and math.max(bits, math.ceil(current.width / 8) * 8) or bits
                if bits < expectedBits then
                    val = bit32.lshift(val, expectedBits - bits)
                    bits = expectedBits
                end

                table.insert(current.bitmap, { val = val, bits = bits })
            end
        end
    end

    return glyphs
end

local glyphs = parse_bdf("bios:ibm.bdf")

local rectCache = {}
local bit_band   = bit32.band
local bit_lshift = bit32.lshift
local bit_rshift = bit32.rshift

local function mergeSpans(spans)
    table.sort(spans, function(a,b) return a[1] < b[1] end)
    local merged = {}
    local cur = nil
    for _, span in ipairs(spans) do
        if not cur then
            cur = {span[1], span[2]}
        else
            if span[1] <= cur[2] + 1 then
                if span[2] > cur[2] then cur[2] = span[2] end
            else
                table.insert(merged, cur)
                cur = {span[1], span[2]}
            end
        end
    end
    if cur then table.insert(merged, cur) end
    return merged
end

local function buildRectangles(glyph)
    local w = glyph.width or 0
    local h = glyph.height or 0
    local xo = glyph.xoffset or 0
    local yo = glyph.yoffset or 0
    local bm = glyph.bitmap or {}

    local active = {}
    local finished = {}

    for row=1,h do
        local rowinfo = bm[row] or {val=0, bits=w}
        local val, bits = rowinfo.val, rowinfo.bits

        local spans = {}
        local mask = bit_lshift(1, bits - 1)
        local x = 0
        while x < w do
            if bit_band(val, mask) ~= 0 then
                local sx = x
                repeat
                    x = x + 1
                    mask = bit_rshift(mask, 1)
                until x >= w or bit_band(val, mask) == 0
                table.insert(spans, {sx, x - 1})
            else
                x = x + 1
                mask = bit_rshift(mask, 1)
            end
        end

        local mergedSpans = mergeSpans(spans)

        local next_active = {}

        for _, span in ipairs(mergedSpans) do
            local sx, ex = span[1], span[2]
            local key = sx * 65536 + ex

            local rect = active[key]
            if rect then
                rect.h = rect.h + 1
                next_active[key] = rect
                active[key] = nil
            else
                next_active[key] = {x1=sx, x2=ex, y1=row, h=1}
            end
        end

        for _, rect in pairs(active) do
            table.insert(finished, rect)
        end

        active = next_active
    end

    for _, rect in pairs(active) do
        table.insert(finished, rect)
    end

    local out = {}
    for _, r in ipairs(finished) do
        local top, bottom = r.y1, r.y1 + r.h - 1
        table.insert(out, {
            x1 = r.x1 + xo,
            y1 = (top - 1) - yo,
            x2 = r.x2 + xo,
            y2 = (bottom - 1) - yo
        })
    end

    return out
end

if fs.exists("bios:rectcache.lua") then
    local rectCacheFile = fs.open("bios:rectcache.lua","r")
    rectCache, _ = load(rectCacheFile.read("a"), "rectcache", "t", _ENV)()
    rectCacheFile.close()
end

local foundDiff = false
if useRectangles then
    for code = 1, 255 do
        local glyph = glyphs[code]
        if glyph and rectCache[code] == nil then
            rectCache[code] = buildRectangles(glyph)
            foundDiff = true
        end
    end
end

if foundDiff then
    local rectCacheFile = fs.open("bios:rectcache.lua", "w")
    rectCacheFile.write(serpent.dump(rectCache))
    rectCacheFile.close()
end

local function sleep(time)
    local t = chip.getTime()
    while true do
        coroutine.yield()
        if t + (time * 1000) <= chip.getTime() then
            break
        end
    end
end

local cursor_x, cursor_y = 0,0
local scr_x, _ = screen.getSize()

screen.setColor(255, 255, 255)

local function drawChar(start_x, baseline_y, encoding)
    start_x = start_x + 1
    baseline_y = baseline_y + 8
    local glyph = glyphs[encoding]
    if not glyph then return end

    local gw = glyph.width or glyph.dwidth or 8
    local gh = glyph.height or #glyph.bitmap or 8
    local xoff = glyph.xoffset or 0
    local yoff = glyph.yoffset or 0

    if useRectangles then
        if not rectCache[encoding] then
            rectCache[encoding] = buildRectangles(glyph)
        end
        for _, rect in ipairs(rectCache[encoding]) do
            screen.fill(
                start_x + rect.x1,
                baseline_y - glyph.height + rect.y1,
                start_x + rect.x2,
                baseline_y - glyph.height + rect.y2
            )
        end
    else
        for row = 1, gh do
            local rowinfo = glyph.bitmap[row] or { val = 0, bits = gw }
            local val = rowinfo.val
            local rowBits = rowinfo.bits
            for col = 0, gw - 1 do
                local mask = bit32.lshift(1, rowBits - 1 - col)
                if bit32.band(val, mask) ~= 0 then
                    local sx = start_x + col + xoff
                    local sy = baseline_y - glyph.height + yoff + (row - 1)
                    screen.fill(sx, sy, sx, sy)
                end
            end
        end
    end
end

_G.NexB = {}

function _G.NexB.writeScr(str)
    for i = 1, #str do
        local c_char = str:sub(i, i)
        if c_char == "\n" then
            cursor_x = 0
            cursor_y = cursor_y + 8
        else
            drawChar(cursor_x, cursor_y, string.byte(c_char))
            cursor_x = cursor_x + 8
            if cursor_x >= scr_x then
                cursor_x = 0
                cursor_y = cursor_y + 8
            end
        end
    end
    screen.draw()
end

function _G.NexB.setCursorPos(x, y)
    cursor_x, cursor_y = x, y
end

function _G.NexB.getCursorPos()
    return cursor_x, cursor_y
end

NexB.writeScr("NexBoot v0.1.0+0\n")

local bootOptions = {}

if fs.exists("system:boot/meta.lua") then
    local metaFile = fs.open("system:boot/meta.lua", "r")
    local metaData = metaFile.read("a")
    metaFile.close()
    local metaFunc, err = load("return "..metaData, "meta", "t", {})
    local meta = metaFunc()
    table.insert(bootOptions, {meta.name, meta.version, meta.entrypoint})
end

if fs.exists("boot:meta.lua") then
    local metaFile = fs.open("boot:meta.lua", "r")
    local metaData = metaFile.read("a")
    metaFile.close()
    local meta = load("return "..metaData, "meta", "t", {})()
    table.insert(bootOptions, {meta.name, meta.version, meta.entrypoint})
end

for i, bootOption in ipairs(bootOptions) do
    NexB.writeScr(tostring(i)..") "..bootOption[1]..": "..bootOption[2].."\n")
end

local eventBuffer = {}

event.registerEvent(function(a, b, c)
    table.insert(eventBuffer, {a, b, c})
end)

local function asciiShift(ascii_val, shift)
    local char = string.char(ascii_val)

    if ascii_val >= 97 and ascii_val <= 122 then
        if shift then
            return string.char(ascii_val - 32)
        else
            return char
        end
    elseif ascii_val >= 65 and ascii_val <= 90 then
        if shift then
            return char
        else
            return string.char(ascii_val + 32)
        end
    end

    local number_shift_map = {
        [48] = ")", -- 0
        [49] = "!", -- 1
        [50] = "@", -- 2
        [51] = "#", -- 3
        [52] = "$", -- 4
        [53] = "%", -- 5
        [54] = "^", -- 6
        [55] = "&", -- 7
        [56] = "*", -- 8
        [57] = "("  -- 9
    }

    if ascii_val >= 48 and ascii_val <= 57 then
        if shift then
            return number_shift_map[ascii_val]
        else
            return char
        end
    end

    local special_shift_map = {
        ["-"] = "_",
        ["="] = "+",
        ["["] = "{",
        ["]"] = "}",
        ["\\"] = "|",
        [";"] = ":",
        ["'"] = "\"",
        [","] = "<",
        ["."] = ">",
        ["/"] = "?"
    }

    if shift and special_shift_map[char] then
        return special_shift_map[char]
    end

    return char
end

function _G.NexB.getInput()
    local inputBuffer = {}

    local shifting = false
    while true do
        local tobreak = false
        local events = eventBuffer
        eventBuffer = {}
        for _,v in ipairs(events) do
            if v[1] == "keyPressed" then
                local success, result = pcall(string.byte, v[3])
                result = tonumber(result)
                if v[2] and v[2] < 127 and v[2] > 31 then NexB.writeScr(asciiShift(result or v[2], shifting)); table.insert(inputBuffer, asciiShift(result or v[2], shifting))
                elseif v[2] == 14 then shifting = true
                elseif v[2] == 13 then tobreak = true
                elseif v[2] == 8 then
                    if #inputBuffer > 0 then
                        table.remove(inputBuffer)
                        screen.setColor(0,0,0)
                        cursor_x = cursor_x - 8

                        local scr_w, _ = screen.getSize()
                        if cursor_x < 0 then
                            cursor_y = cursor_y - 8
                            cursor_x = scr_w - 8
                        end

                        screen.fill(cursor_x,cursor_y,cursor_x+8,cursor_y+8)
                        screen.setColor(255,255,255)
                    end
                end
            elseif v[1] == "keyReleased" then
                if v[2] == 14 then shifting = false end
            end
        end
        if tobreak == true then break end
    end
    return table.concat(inputBuffer)
end

if #bootOptions == 0 then
	NexB.writeScr("Could not find an operating system!\nShutting down in 3 seconds.")
    sleep(1)
    NexB.writeScr(".")
    sleep(1)
    NexB.writeScr(".")
    sleep(1)
    chip.shutdown()
else -- chip.shutdown misbehaves sometimes, can't trust it to shut down before this gets executed
    local bootSelected = nil
    while true do
        NexB.writeScr(">")
        local user_input = NexB.getInput()
        local success, result = pcall(tonumber, user_input)
        if success and result ~= nil and result <= #bootOptions then
            bootSelected = result
            break
        end
        NexB.writeScr("\n")
    end

    local entrypoint = fs.open(bootOptions[bootSelected][3], "r")
    local entrypointData = entrypoint.read("a")
    entrypoint.close()
    local metaFunc, err = load(entrypointData, bootOptions[bootSelected][3], "bt", _ENV)
    if err then print(err) end
    metaFunc()
end
