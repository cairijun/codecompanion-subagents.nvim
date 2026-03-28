-- Tests for lua/codecompanion/_extensions/subagents/init.lua
local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
    end,
    post_once = child.stop,
  },
})

T["init"] = new_set()

T["init"]["setup registers subagent tools"] = function()
  child.lua([[
    local subagents = require("codecompanion._extensions.subagents")
    
    require("codecompanion").setup({
      extensions = {
        subagents = {
          enabled = true,
          opts = {
            subagents = {
              ["test_reviewer"] = {
                description = "A test code reviewer",
                system_prompt = "You are a code reviewer",
              },
            },
          },
        },
      },
    })
    
    local tools_config = require("codecompanion.config").interactions.chat.tools
    _G.has_test_reviewer = tools_config["subagent_test_reviewer"] ~= nil
    
    -- Verify tool can be resolved by CodeCompanion's Tools.resolve
    local Tools = require("codecompanion.interactions.chat.tools.init")
    local resolved = Tools.resolve(tools_config["subagent_test_reviewer"])
    _G.can_resolve = resolved ~= nil
    _G.resolved_has_name = resolved and resolved.name == "subagent_test_reviewer"
    _G.resolved_has_cmds = resolved and resolved.cmds ~= nil
    _G.resolved_has_schema = resolved and resolved.schema ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.has_test_reviewer]]))
  h.eq(true, child.lua_get([[_G.can_resolve]]))
  h.eq(true, child.lua_get([[_G.resolved_has_name]]))
  h.eq(true, child.lua_get([[_G.resolved_has_cmds]]))
  h.eq(true, child.lua_get([[_G.resolved_has_schema]]))
end

T["init"]["setup handles empty subagents"] = function()
  child.lua([[
    local subagents = require("codecompanion._extensions.subagents")
    
    require("codecompanion").setup({
      extensions = {
        subagents = {
          enabled = true,
          opts = {
            subagents = {},
          },
        },
      },
    })
    
    _G.has_error = false
  ]])

  h.eq(false, child.lua_get([[_G.has_error]]))
end

T["init"]["exports list_subagents function"] = function()
  child.lua([[
    require("codecompanion").setup({
      extensions = {
        subagents = {
          enabled = true,
          opts = {
            subagents = {
              ["agent1"] = { description = "Agent 1", system_prompt = "..." },
              ["agent2"] = { description = "Agent 2", system_prompt = "..." },
            },
          },
        },
      },
    })
    
    _G.list = require("codecompanion").extensions.subagents.list_subagents()
  ]])

  local list = child.lua_get([[_G.list]])
  h.eq(2, #list)
end

return T
