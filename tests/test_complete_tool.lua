-- Tests for lua/codecompanion-subagents/complete_tool.lua
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

T["complete_tool"] = new_set()

T["complete_tool"]["has correct schema"] = function()
  child.lua([[
_G.tool = require("codecompanion._extensions.subagents.complete_tool")
    
    _G.tool_name = _G.tool.name
    _G.schema_type = _G.tool.schema.type
    _G.has_result_param = _G.tool.schema["function"].parameters.properties.result ~= nil
    _G.has_strict = _G.tool.schema["function"].strict ~= nil
    _G.strict_value = _G.tool.schema["function"].strict
  ]])

  h.eq("complete_subagent", child.lua_get([[_G.tool_name]]))
  h.eq("function", child.lua_get([[_G.schema_type]]))
  h.eq(true, child.lua_get([[_G.has_result_param]]))
  h.eq(true, child.lua_get([[_G.has_strict]]))
  h.eq(true, child.lua_get([[_G.strict_value]]))
end

T["complete_tool"]["cmds function calls manager"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local tool = require("codecompanion._extensions.subagents.complete_tool")
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      _subagents = {
        subagent_chat = { name = "test" },
      },
    }
    
    -- Create a mock subagent chat with parent reference
    local mock_subagent_chat = {
      id = "subagent_chat",
      _parent_chat = mock_parent_chat,
    }
    
    _G.result_captured = nil
    _G.output_msg = nil
    
    -- Use opts parameter with output_cb
    local mock_opts = {
      output_cb = function(msg) _G.output_msg = msg end
    }
    
    -- Create mock self with subagent chat
    local mock_self = {
      chat = mock_subagent_chat,
    }
    
    tool.cmds[1](mock_self, { result = "Test result" }, mock_opts)
    
    _G.result_captured = mock_parent_chat._subagents.pending_result
    _G.output_status = _G.output_msg and _G.output_msg.status
  ]])

  h.eq("Test result", child.lua_get([[_G.result_captured]]))
  h.eq("success", child.lua_get([[_G.output_status]]))
end

T["complete_tool"]["handles missing result"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local tool = require("codecompanion._extensions.subagents.complete_tool")
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      _subagents = {
        subagent_chat = { name = "test" },
        pending_result = nil,
      },
    }
    
    -- Create a mock subagent chat with parent reference
    local mock_subagent_chat = {
      id = "subagent_chat",
      _parent_chat = mock_parent_chat,
    }
    
    _G.output_msg = nil
    
    -- Use opts parameter with output_cb
    local mock_opts = {
      output_cb = function(msg) _G.output_msg = msg end
    }
    
    -- Create mock self with subagent chat
    local mock_self = {
      chat = mock_subagent_chat,
    }
    
    tool.cmds[1](mock_self, {}, mock_opts)
    
    _G.has_error = _G.output_msg and _G.output_msg.status == "error"
  ]])

  h.eq(true, child.lua_get([[_G.has_error]]))
end

return T
