-- Load the application without KOReader; each test owns its dependency stubs.
return function(dependencies)
  local modules = {
    gettext = function(text) return text end,
    datastorage = { getDataDir = function() return "/nonexistent/storygraph-spec" end },
    ["ui/widget/container/widgetcontainer"] = {
      extend = function(_, app) return app end,
    },
  }
  for name, module in pairs(dependencies or {}) do modules[name] = module end
  local environment = setmetatable({
    require = function(name)
      if modules[name] ~= nil then return modules[name] end
      if name == "math" or name == "storygraph/lib/table_util"
          or name:match("^storygraph/lib/constants/") then
        return require(name)
      end
      return {}
    end,
  }, { __index = _G })
  return setfenv(assert(loadfile("main.lua")), environment)()
end
