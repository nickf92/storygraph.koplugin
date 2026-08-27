describe("Github", function()
  local Github
  local requested_url
  local original_modules = {}
  local module_names = {
    "socket.http",
    "json",
    "ltn12",
    "storygraph_version",
    "storygraph/lib/github",
  }

  before_each(function()
    for _, module_name in ipairs(module_names) do
      original_modules[module_name] = package.loaded[module_name]
    end

    package.loaded["socket.http"] = {
      request = function(options)
        requested_url = options.url
        options.sink('{"plugin_version":"1.2.3"}')
        options.sink(nil)
        return 1, 200, {}
      end,
    }
    local json_decode = setmetatable({ simple = {} }, {
      __call = function()
        return { plugin_version = "1.2.3" }
      end,
    })
    package.loaded["json"] = { decode = json_decode }
    package.loaded["ltn12"] = {
      sink = {
        table = function(target)
          return function(chunk)
            if chunk then
              target[#target + 1] = chunk
            end
            return 1
          end
        end,
      },
    }
    package.loaded["storygraph_version"] = { 1, 0, 0 }
    package.loaded["storygraph/lib/github"] = nil

    Github = require("storygraph/lib/github")
  end)

  after_each(function()
    for _, module_name in ipairs(module_names) do
      package.loaded[module_name] = original_modules[module_name]
    end
    requested_url = nil
  end)

  it("fetches version information from the current fork", function()
    local version_info = Github:fetchVersionInfo()

    assert.are.equal(
      "https://raw.githubusercontent.com/nickf92/storygraph.koplugin/main/version.json",
      requested_url
    )
    assert.are.equal("1.2.3", version_info.plugin_version)
  end)
end)
