-- A JSON encoder and decoder standing in for HttpService in the test bundles.
--
-- Only what the managers actually produce and consume: objects, arrays,
-- strings, numbers, booleans and null. Arrays and objects are distinguished the
-- way the real service does, by whether the table has a contiguous integer
-- keyspace starting at 1, and object keys are emitted in sorted order so that
-- encoding the same table twice produces the same bytes.

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeValue(value)
    local kind = type(value)
    if value == nil then
        return "null"
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "cannot encode " .. tostring(value))
        if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    elseif kind == "string" then
        return '"'
            .. (string.gsub(value, '[%c"\\]', function(character)
                return ESCAPES[character] or string.format("\\u%04x", string.byte(character))
            end))
            .. '"'
    elseif kind ~= "table" then
        error("cannot encode " .. kind)
    end

    local count = 0
    for _ in value do
        count += 1
    end
    local parts = {}
    if count == #value then
        for _, entry in value do
            table.insert(parts, encodeValue(entry))
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in value do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    for _, key in keys do
        table.insert(parts, encodeValue(key) .. ":" .. encodeValue(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function skipSpace(text, at)
    local _, stop = string.find(text, "^[ \t\r\n]*", at)
    return stop + 1
end

local decodeValue

local function decodeString(text, index)
    local buffer = {}
    local at = index + 1
    while true do
        local byte = string.sub(text, at, at)
        assert(byte ~= "", "unterminated string")
        if byte == '"' then
            return table.concat(buffer), at + 1
        elseif byte == "\\" then
            local escape = string.sub(text, at + 1, at + 1)
            local mapped = ({ n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" })[escape]
            if mapped then
                table.insert(buffer, mapped)
                at += 2
            elseif escape == "u" then
                table.insert(buffer, string.char(tonumber(string.sub(text, at + 2, at + 5), 16) % 256))
                at += 6
            else
                table.insert(buffer, escape)
                at += 2
            end
        else
            table.insert(buffer, byte)
            at += 1
        end
    end
end

function decodeValue(text, index)
    index = skipSpace(text, index)
    local character = string.sub(text, index, index)
    assert(character ~= "", "unexpected end of input")

    if character == "{" then
        local object = {}
        index = skipSpace(text, index + 1)
        if string.sub(text, index, index) == "}" then
            return object, index + 1
        end
        while true do
            local key, value
            key, index = decodeValue(text, index)
            assert(type(key) == "string", "object keys must be strings")
            index = skipSpace(text, index)
            assert(string.sub(text, index, index) == ":", "expected a colon")
            value, index = decodeValue(text, index + 1)
            object[key] = value
            index = skipSpace(text, index)
            local delimiter = string.sub(text, index, index)
            if delimiter == "," then
                index += 1
            elseif delimiter == "}" then
                return object, index + 1
            else
                error("expected a comma or a closing brace")
            end
        end
    elseif character == "[" then
        local array = {}
        index = skipSpace(text, index + 1)
        if string.sub(text, index, index) == "]" then
            return array, index + 1
        end
        while true do
            local value
            value, index = decodeValue(text, index)
            table.insert(array, value)
            index = skipSpace(text, index)
            local delimiter = string.sub(text, index, index)
            if delimiter == "," then
                index += 1
            elseif delimiter == "]" then
                return array, index + 1
            else
                error("expected a comma or a closing bracket")
            end
        end
    elseif character == '"' then
        return decodeString(text, index)
    end

    for _, literal in { "true", "false", "null" } do
        if string.sub(text, index, index + #literal - 1) == literal then
            local decoded = if literal == "true" then true elseif literal == "false" then false else nil
            return decoded, index + #literal
        end
    end

    local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", index)
    assert(number and number ~= "", "unexpected character " .. character)
    return tonumber(number), index + #number
end

local jsonService = {}

function jsonService:JSONEncode(value)
    return encodeValue(value)
end

function jsonService:JSONDecode(text)
    assert(type(text) == "string", "JSONDecode expects a string")
    local value, index = decodeValue(text, 1)
    local _, stop = string.find(text, "^[ \t\r\n]*", index)
    assert(stop == #text, "trailing characters after the JSON value")
    return value
end

local JSONService = jsonService
