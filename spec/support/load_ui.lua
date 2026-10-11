-- Load UI modules with explicit headless widget boundaries.
return function(path, dependencies)
  local modules = {
    gettext = function(text) return text end,
    ["ffi/util"] = { template = function(text, ...)
      local args = {...}
      return (text:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)]) end))
    end },
  }
  for name, module in pairs(dependencies or {}) do modules[name] = module end
  local environment = setmetatable({require = function(name)
    if modules[name] ~= nil then return modules[name] end
    if name == "math" or name == "os" or name:match("^storygraph/lib/constants/") or name == "storygraph/lib/table_util" then return require(name) end
    return {}
  end}, {__index = _G})
  return setfenv(assert(loadfile(path)), environment)()
end
