-- Logging + string helpers. Mirrors the kcd-cheat util pattern.

function st:isBlank(value)
  return value == nil or value == ""
end

function st:toUpper(value)
  if not st:isBlank(value) then
    return string.upper(value)
  end
  return value
end

function st:toLower(value)
  if not st:isBlank(value) then
    return string.lower(value)
  end
  return value
end

function st:log(value)
  System.LogAlways(value)
end

function st:logDebug(message, ...)
  st:log(string.format("$3[ST DEBUG] " .. message, ...))
end

function st:logInfo(message, ...)
  st:log(string.format("$5[ST] " .. message, ...))
end

function st:logWarn(message, ...)
  st:log(string.format("$6[ST WARN] " .. message, ...))
end

function st:logError(message, ...)
  st:log(string.format("$4[ST ERROR] " .. message, ...))
end

-- Shallow-copy keys to a sorted array for deterministic iteration.
function st:sortedKeys(tbl)
  local keys = {}
  for k, _ in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

st:logDebug("st_util.lua loaded")
