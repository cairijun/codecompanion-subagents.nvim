-- Tests for lua/codecompanion-subagents/manager.lua
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

T["manager"] = new_set()

T["manager"]["state stored in chat object"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Reset state
    manager._subagent_names = {}
    
    -- Create a mock parent chat
    local mock_chat = { id = "parent_chat" }
    
    manager:start_subagent(mock_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Do something", {})
    
    -- State should be in chat object, not module level
    _G.state_in_chat = mock_chat._subagents ~= nil and mock_chat._subagents.subagent_chat ~= nil
    _G.module_state_nil = manager.subagent_chat == nil
  ]])

  h.eq(true, child.lua_get([[_G.state_in_chat]]))
  h.eq(true, child.lua_get([[_G.module_state_nil]]))
end

T["manager"]["start_subagent sets active state"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_chat = { id = "parent_chat" }
    
    manager:start_subagent(mock_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Do something", {})
    
    -- Check state in chat object
    _G.has_active = mock_chat._subagents ~= nil and mock_chat._subagents.subagent_chat ~= nil
    _G.parent_in_subagent = mock_chat._subagents.subagent_chat._parent_chat == mock_chat
  ]])

  h.eq(true, child.lua_get([[_G.has_active]]))
  h.eq(true, child.lua_get([[_G.parent_in_subagent]]))
end

T["manager"]["complete_subagent clears state"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_chat = { id = "parent_chat" }
    
    manager:start_subagent(mock_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Do something", {})
    
    manager:complete_subagent(mock_chat, "Task completed")
    
    _G.active_cleared = mock_chat._subagents.subagent_chat == nil
    _G.result_set = mock_chat._subagents.pending_result == "Task completed"
  ]])

  h.eq(true, child.lua_get([[_G.active_cleared]]))
  h.eq(true, child.lua_get([[_G.result_set]]))
end

T["manager"]["is_active returns correct state"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_chat = { id = "parent_chat" }
    
    _G.initially_active = manager:is_active(mock_chat)
    
    manager:start_subagent(mock_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Task", {})
    
    _G.after_start_active = manager:is_active(mock_chat)
  ]])

  h.eq(false, child.lua_get([[_G.initially_active]]))
  h.eq(true, child.lua_get([[_G.after_start_active]]))
end

T["manager"]["tool filtering"] = new_set()

T["manager"]["tool filtering"]["excludes subagent tools"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Mock subagent names
    manager._subagent_names = { "agent_a", "agent_b" }
    
    local filtered = manager:get_subagent_tools({ "read_file", "subagent_agent_a", "subagent_agent_b" })
    
    _G.has_read_file = vim.tbl_contains(filtered, "read_file")
    _G.has_agent_a = vim.tbl_contains(filtered, "subagent_agent_a")
    _G.has_agent_b = vim.tbl_contains(filtered, "subagent_agent_b")
  ]])

  h.eq(true, child.lua_get([[_G.has_read_file]]))
  h.eq(false, child.lua_get([[_G.has_agent_a]]))
  h.eq(false, child.lua_get([[_G.has_agent_b]]))
end

T["manager"]["tool filtering"]["includes complete_subagent"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Mock subagent names
    manager._subagent_names = { "test_agent" }
    
    local filtered = manager:get_subagent_tools({ "read_file" })
    
    _G.has_complete = vim.tbl_contains(filtered, "complete_subagent")
  ]])

  h.eq(true, child.lua_get([[_G.has_complete]]))
end

T["manager"]["UI management"] = new_set()

T["manager"]["UI management"]["hides parent shows subagent"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat with UI mock
    local parent_hidden = false
    local mock_parent_chat = {
      id = "parent_chat",
      ui = {
        hide = function(self)
          parent_hidden = true
        end,
        open = function(self)
          parent_hidden = false
        end,
        is_visible = function(self)
          return not parent_hidden
        end,
      },
    }
    
    -- Start subagent with mock parent
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Task", {})
    
    _G.parent_hidden = parent_hidden
    _G.has_subagent = mock_parent_chat._subagents ~= nil and mock_parent_chat._subagents.subagent_chat ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.parent_hidden]]))
  h.eq(true, child.lua_get([[_G.has_subagent]]))
end

T["manager"]["UI management"]["restores parent on complete"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Track state
    local parent_visible = true
    local subagent_closed = false
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      ui = {
        hide = function(self)
          parent_visible = false
        end,
        open = function(self)
          parent_visible = true
        end,
        is_visible = function(self)
          return parent_visible
        end,
      },
    }
    
    -- Start subagent
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Task", {})
    
    -- Mock the subagent's close method
    if mock_parent_chat._subagents.subagent_chat and mock_parent_chat._subagents.subagent_chat.ui then
      mock_parent_chat._subagents.subagent_chat.ui.close = function()
        subagent_closed = true
      end
    end
    
    -- Complete subagent
    manager:complete_subagent(mock_parent_chat, "Done")
    
    _G.parent_visible = parent_visible
    _G.subagent_closed = subagent_closed
    _G.subagent_cleared = mock_parent_chat._subagents.subagent_chat == nil
  ]])

  h.eq(true, child.lua_get([[_G.parent_visible]]))
  h.eq(true, child.lua_get([[_G.subagent_cleared]]))
end

T["manager"]["mcp_servers"] = new_set()

T["manager"]["mcp_servers"]["passes mcp_servers to Chat.new"] = function()
  -- Test that mcp_servers is passed to Chat.new when creating subagent chat
  -- Intent: Verify Chat creation includes mcp_servers parameter
  -- Ref: Plan Task 2, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    -- Capture Chat.new arguments
    local captured_opts = nil
    local original_new = Chat.new
    Chat.new = function(opts)
      captured_opts = opts
      -- Return a mock chat object
      return {
        bufnr = 9999,
        _parent_chat = nil,
        set_system_prompt = function() end,
        submit = function() end,
      }
    end
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Start subagent with mcp_servers
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      mcp_servers = { "sequential-thinking", "tavily" },
    }, "Task", {})
    
    -- Restore original
    Chat.new = original_new
    
    -- Verify mcp_servers was passed to Chat.new
    _G.has_mcp_servers = captured_opts.mcp_servers ~= nil
    _G.mcp_servers = captured_opts.mcp_servers
  ]])

  h.eq(true, child.lua_get([[_G.has_mcp_servers]]))
  local mcp_servers = child.lua_get([[_G.mcp_servers]])
  h.eq({ "sequential-thinking", "tavily" }, mcp_servers)
end

T["manager"]["mcp_servers"]["handles nil mcp_servers"] = function()
  -- Test that nil mcp_servers is handled in Chat creation
  -- Intent: Verify Chat creation works without mcp_servers
  -- Ref: Plan Task 2, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local captured_opts = nil
    local original_new = Chat.new
    Chat.new = function(opts)
      captured_opts = opts
      return {
        bufnr = 9999,
        _parent_chat = nil,
        set_system_prompt = function() end,
        submit = function() end,
      }
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Start subagent WITHOUT mcp_servers
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      -- mcp_servers not specified
    }, "Task", {})
    
    Chat.new = original_new
    
    -- vim.NIL is Neovim's representation of nil across Lua states
    _G.mcp_servers_is_nil = captured_opts.mcp_servers == nil or captured_opts.mcp_servers == vim.NIL
  ]])

  h.eq(true, child.lua_get([[_G.mcp_servers_is_nil]]))
end

T["manager"]["mcp_servers"]["handles empty mcp_servers"] = function()
  -- Test that empty mcp_servers table is passed correctly
  -- Intent: Verify empty mcp_servers table is handled
  -- Ref: Plan Task 2, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local captured_opts = nil
    local original_new = Chat.new
    Chat.new = function(opts)
      captured_opts = opts
      return {
        bufnr = 9999,
        _parent_chat = nil,
        set_system_prompt = function() end,
        submit = function() end,
      }
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Start subagent with empty mcp_servers
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      mcp_servers = {},
    }, "Task", {})
    
    Chat.new = original_new
    
    _G.mcp_servers = captured_opts.mcp_servers
  ]])

  h.eq({}, child.lua_get([[_G.mcp_servers]]))
end

T["manager"]["integration"] = new_set()

T["manager"]["integration"]["complete mcp workflow"] = function()
  -- Test complete SubAgent + MCP workflow
  -- Intent: Verify end-to-end flow from tool creation to Chat creation with mcp_servers
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    -- Capture Chat.new arguments
    local chat_opts_captured = nil
    local original_new = Chat.new
    Chat.new = function(opts)
      chat_opts_captured = opts
      return {
        bufnr = 9999,
        _parent_chat = nil,
        set_system_prompt = function() end,
        submit = function() end,
      }
    end
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Create tool instance with both tools and mcp_servers
    local tool_instance = tool.create_subagent_tool("researcher", {
      description = "Research assistant",
      system_prompt = "You are a research assistant",
      tools = { "read_file", "grep_search" },
      mcp_servers = { "tavily", "sequential-thinking" },
    })
    
    -- Execute the tool command
    local mock_self = { chat = mock_parent_chat }
    tool_instance.cmds[1](mock_self, { task = "Research topic X" }, {})
    
    -- Restore original
    Chat.new = original_new
    
    -- Verify complete workflow
    _G.has_tools = chat_opts_captured.tools ~= nil
    _G.has_mcp_servers = chat_opts_captured.mcp_servers ~= nil
    _G.tools = chat_opts_captured.tools
    _G.mcp_servers = chat_opts_captured.mcp_servers
    _G.has_complete_subagent = vim.tbl_contains(chat_opts_captured.tools, "complete_subagent")
  ]])

  h.eq(true, child.lua_get([[_G.has_tools]]))
  h.eq(true, child.lua_get([[_G.has_mcp_servers]]))
  h.eq(true, child.lua_get([[_G.has_complete_subagent]]))

  local tools = child.lua_get([[_G.tools]])
  local mcp_servers = child.lua_get([[_G.mcp_servers]])

  -- Verify tools include complete_subagent
  h.eq(true, vim.tbl_contains(tools, "complete_subagent"))
  -- Verify mcp_servers passed correctly
  h.eq({ "tavily", "sequential-thinking" }, mcp_servers)
end

T["manager"]["integration"]["handles nonexistent mcp server gracefully"] = function()
  -- Test that nonexistent MCP server names don't crash the system
  -- Intent: Verify graceful handling when MCP server name doesn't exist
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local chat_created = false
    local original_new = Chat.new
    Chat.new = function(opts)
      chat_created = true
      return {
        bufnr = 9999,
        _parent_chat = nil,
        set_system_prompt = function() end,
        submit = function() end,
      }
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Start subagent with nonexistent MCP server name
    -- CodeCompanion handles MCP server lifecycle, not SubAgents
    local ok, err = pcall(function()
      manager:start_subagent(mock_parent_chat, {
        name = "test_agent",
        system_prompt = "Test",
        tools = {},
        mcp_servers = { "nonexistent-server" },
      }, "Task", {})
    end)
    
    Chat.new = original_new
    
    -- Should not crash, Chat creation should succeed
    _G.no_crash = ok
    _G.chat_created = chat_created
  ]])

  h.eq(true, child.lua_get([[_G.no_crash]]))
  h.eq(true, child.lua_get([[_G.chat_created]]))
end

T["manager"]["error handling"] = new_set()

T["manager"]["error handling"]["handles creation failure gracefully"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Try to start subagent with invalid config (should not crash)
    local ok, err = pcall(function()
      manager:start_subagent(mock_parent_chat, {
        name = "test_agent",
        system_prompt = "Test",
        tools = { "nonexistent_tool" },
      }, "Task", {})
    end)
    
    _G.no_crash = ok
    _G.state_clean = mock_parent_chat._subagents == nil or mock_parent_chat._subagents.subagent_chat == nil
  ]])

  -- Should not crash
  h.eq(true, child.lua_get([[_G.no_crash]]))
end

T["manager"]["error handling"]["cleans up on error completion"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Start subagent
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Task", {})
    
    -- Simulate error completion
    manager:complete_subagent(mock_parent_chat, "Error: Something went wrong", true)
    
    _G.state_clean = mock_parent_chat._subagents.subagent_chat == nil
    _G.result_stored = mock_parent_chat._subagents.pending_result
  ]])

  h.eq(true, child.lua_get([[_G.state_clean]]))
  h.eq("Error: Something went wrong", child.lua_get([[_G.result_stored]]))
end

T["manager"]["error handling"]["calls callback with error flag"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Track callback args
    _G.callback_result = nil
    _G.callback_is_error = nil
    
    -- Start subagent with callback
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
    }, "Task", {})
    
    -- Set callback in chat state
    mock_parent_chat._subagents.completion_callback = function(result, is_error)
      _G.callback_result = result
      _G.callback_is_error = is_error
    end
    
    -- Complete with error
    manager:complete_subagent(mock_parent_chat, "Error occurred", true)
  ]])

  h.eq("Error occurred", child.lua_get([[_G.callback_result]]))
  h.eq(true, child.lua_get([[_G.callback_is_error]]))
end

return T
