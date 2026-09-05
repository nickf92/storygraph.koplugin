-- Real StoryGraph parsing/mutation code, with transport and credentials isolated.
return function(overrides)
  local noop = function() end
  local modules = {
    storygraph_config = {},
    logger = { info = noop, warn = noop, err = noop },
    ["socket.http"] = {}, ltn12 = {}, json = {}, socketutil = {},
    ["ffi/util"] = { template = function(s) return s end },
    ["ui/trapper"] = {}, ["ui/network/manager"] = {},
    storygraph_version = { 0, 2, 9 },
  }
  for name, value in pairs(overrides or {}) do modules[name] = value end
  local env = setmetatable({ require = function(name)
    if modules[name] ~= nil then return modules[name] end
    return require(name)
  end }, { __index = _G })
  local api = setfenv(assert(loadfile("storygraph/lib/hardcover_api.lua")), env)()
  api.settings = { readSetting = function() return "" end }
  return api
end
