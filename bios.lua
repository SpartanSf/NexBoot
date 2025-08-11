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


local GLFW_KEY_SPACE           = 32
local GLFW_KEY_APOSTROPHE      = 39
local GLFW_KEY_COMMA           = 44
local GLFW_KEY_MINUS           = 45
local GLFW_KEY_PERIOD          = 46
local GLFW_KEY_SLASH           = 47
local GLFW_KEY_0               = 48
local GLFW_KEY_1               = 49
local GLFW_KEY_2               = 50
local GLFW_KEY_3               = 51
local GLFW_KEY_4               = 52
local GLFW_KEY_5               = 53
local GLFW_KEY_6               = 54
local GLFW_KEY_7               = 55
local GLFW_KEY_8               = 56
local GLFW_KEY_9               = 57
local GLFW_KEY_SEMICOLON       = 59
local GLFW_KEY_EQUAL           = 61
local GLFW_KEY_A               = 65
local GLFW_KEY_B               = 66
local GLFW_KEY_C               = 67
local GLFW_KEY_D               = 68
local GLFW_KEY_E               = 69
local GLFW_KEY_F               = 70
local GLFW_KEY_G               = 71
local GLFW_KEY_H               = 72
local GLFW_KEY_I               = 73
local GLFW_KEY_J               = 74
local GLFW_KEY_K               = 75
local GLFW_KEY_L               = 76
local GLFW_KEY_M               = 77
local GLFW_KEY_N               = 78
local GLFW_KEY_O               = 79
local GLFW_KEY_P               = 80
local GLFW_KEY_Q               = 81
local GLFW_KEY_R               = 82
local GLFW_KEY_S               = 83
local GLFW_KEY_T               = 84
local GLFW_KEY_U               = 85
local GLFW_KEY_V               = 86
local GLFW_KEY_W               = 87
local GLFW_KEY_X               = 88
local GLFW_KEY_Y               = 89
local GLFW_KEY_Z               = 90
local GLFW_KEY_LEFT_BRACKET    = 91
local GLFW_KEY_BACKSLASH       = 92
local GLFW_KEY_RIGHT_BRACKET   = 93
local GLFW_KEY_GRAVE_ACCENT    = 96
local GLFW_KEY_ENTER           = 257
local GLFW_KEY_TAB             = 258
local GLFW_KEY_BACKSPACE       = 259
local GLFW_KEY_ESCAPE          = 256

local glfw_punct = {
    [GLFW_KEY_APOSTROPHE]    = "'",
    [GLFW_KEY_COMMA]         = ",",
    [GLFW_KEY_MINUS]         = "-",
    [GLFW_KEY_PERIOD]        = ".",
    [GLFW_KEY_SLASH]         = "/",
    [GLFW_KEY_SEMICOLON]     = ";",
    [GLFW_KEY_EQUAL]         = "=",
    [GLFW_KEY_LEFT_BRACKET]  = "[",
    [GLFW_KEY_BACKSLASH]     = "\\",
    [GLFW_KEY_RIGHT_BRACKET] = "]",
    [GLFW_KEY_GRAVE_ACCENT]  = "`",
}

local shifted_numbers = {
    [GLFW_KEY_1] = "!",
    [GLFW_KEY_2] = "@",
    [GLFW_KEY_3] = "#",
    [GLFW_KEY_4] = "$",
    [GLFW_KEY_5] = "%",
    [GLFW_KEY_6] = "^",
    [GLFW_KEY_7] = "&",
    [GLFW_KEY_8] = "*",
    [GLFW_KEY_9] = "(",
    [GLFW_KEY_0] = ")",
}

local shifted_punct = {
    ["'"] = "\"",
    [","] = "<",
    ["-"] = "_",
    ["."] = ">",
    ["/"] = "?",
    [";"] = ":",
    ["="] = "+",
    ["["] = "{",
    ["\\"] = "|",
    ["]"] = "}",
    ["`"] = "~",
}

local function glfw2ascii(keycode, shift_pressed)
    if keycode >= GLFW_KEY_A and keycode <= GLFW_KEY_Z then
        local base = shift_pressed and 65 or 97
        return string.char(base + (keycode - GLFW_KEY_A))
    end

    if keycode >= GLFW_KEY_0 and keycode <= GLFW_KEY_9 then
        if shift_pressed then
            return shifted_numbers[keycode]
        else
            return string.char(keycode)
        end
    end

    if keycode == GLFW_KEY_SPACE then
        return ' '
    end

    if glfw_punct[keycode] then
        local ch = glfw_punct[keycode]
        if shift_pressed and shifted_punct[ch] then
            return shifted_punct[ch]
        else
            return ch
        end
    end

    if keycode == GLFW_KEY_ENTER then
        return '\n'
    elseif keycode == GLFW_KEY_TAB then
        return '\t'
    elseif keycode == GLFW_KEY_BACKSPACE then
        return '\b'
    elseif keycode == GLFW_KEY_ESCAPE then
        return '\27'
    end

    return nil
end

local function getInput()
    local inputBuffer = {}

    local shifting = false
    while true do
        local tobreak = false
        local events = event.getEventQueue()
        event.clearEventQueue()
        for _,v in ipairs(events) do
            if v[1] == "keyPressed" then
                if v[2] and v[2] < 256 then NexB.writeScr(glfw2ascii(v[2], shifting)); table.insert(inputBuffer, glfw2ascii(v[2], shifting))
                elseif v[2] == 340 then shifting = true
                elseif v[2] == GLFW_KEY_ENTER then tobreak = true
                elseif v[2] == GLFW_KEY_BACKSPACE then
                    if #inputBuffer > 0 then
                        table.remove(inputBuffer)
                        screen.setColor(1,1,1)
                        cursor_x = cursor_x - 8

                        local scr_w, _ = screen.getSize()
                        if cursor_x < 0 then
                            cursor_y = cursor_y - 8
                            cursor_x = scr_w - 8
                        end

                        screen.fill(cursor_x,cursor_y,cursor_x+8,cursor_y+8)
                        screen.setColor(256,256,256)
                    end
                end
            elseif v[1] == "keyReleased" then
                if v[2] == 340 then shifting = false end
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
        local user_input = getInput()
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
