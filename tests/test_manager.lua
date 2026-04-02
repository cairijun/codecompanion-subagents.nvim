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

T["manager"]["inherit tools"] = new_set()

T["manager"]["inherit tools"]["get_inherited_tools returns tools from parent"] = function()
  -- Test that get_inherited_tools correctly extracts and filters tools from parent chat
  -- Intent: Verify tools are inherited from parent's tool_registry.in_use, excluding subagent tools
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- 创建带有 tool_registry 的 mock parent chat
    local mock_parent_chat = {
      tool_registry = {
        in_use = {
          ["read_file"] = true,
          ["grep_search"] = true,
          ["subagent_code_reviewer"] = true,  -- 应该被过滤
        },
        groups = {},
      },
    }
    
    local tools = manager:get_inherited_tools(mock_parent_chat)
    
    _G.tools_count = #tools
    _G.has_read_file = vim.tbl_contains(tools, "read_file")
    _G.has_grep_search = vim.tbl_contains(tools, "grep_search")
    _G.has_subagent = vim.tbl_contains(tools, "subagent_code_reviewer")
  ]])

  h.eq(2, child.lua_get([[_G.tools_count]]))
  h.eq(true, child.lua_get([[_G.has_read_file]]))
  h.eq(true, child.lua_get([[_G.has_grep_search]]))
  h.eq(false, child.lua_get([[_G.has_subagent]]))
end

T["manager"]["inherit tools"]["get_inherited_tools handles nil parent"] = function()
  -- Test that get_inherited_tools handles nil parent gracefully
  -- Intent: Verify empty list is returned when parent is nil
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local tools = manager:get_inherited_tools(nil)
    
    _G.tools_empty = #tools == 0
  ]])

  h.eq(true, child.lua_get([[_G.tools_empty]]))
end

T["manager"]["inherit tools"]["get_inherited_tools handles missing tool_registry"] = function()
  -- Test that get_inherited_tools handles missing tool_registry
  -- Intent: Verify empty list is returned when parent has no tool_registry
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {}
    
    local tools = manager:get_inherited_tools(mock_parent_chat)
    
    _G.tools_empty = #tools == 0
  ]])

  h.eq(true, child.lua_get([[_G.tools_empty]]))
end

T["manager"]["inherit tools"]["get_inherited_tools handles empty tools"] = function()
  -- Test that get_inherited_tools handles empty in_use table
  -- Intent: Verify empty list is returned when parent has no tools in use
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      tool_registry = {
        in_use = {},
        groups = {},
      },
    }
    
    local tools = manager:get_inherited_tools(mock_parent_chat)
    
    _G.tools_empty = #tools == 0
  ]])

  h.eq(true, child.lua_get([[_G.tools_empty]]))
end

T["manager"]["inherit tools"]["get_inherited_tools filters all subagent tools"] = function()
  -- Test that get_inherited_tools filters all subagent tools
  -- Intent: Verify empty list is returned when parent only has subagent tools
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      tool_registry = {
        in_use = {
          ["subagent_code_reviewer"] = true,
          ["subagent_test_writer"] = true,
        },
        groups = {},
      },
    }
    
    local tools = manager:get_inherited_tools(mock_parent_chat)
    
    _G.tools_empty = #tools == 0
  ]])

  h.eq(true, child.lua_get([[_G.tools_empty]]))
end

T["manager"]["inherit mcp_servers"] = new_set()

T["manager"]["inherit mcp_servers"]["get_inherited_mcp_servers returns servers from parent"] = function()
  -- Test that get_inherited_mcp_servers correctly extracts MCP server names from parent chat
  -- Intent: Verify MCP servers are extracted from tool_registry.groups with mcp: prefix
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- 创建带有 MCP groups 的 mock parent chat
    local mock_parent_chat = {
      tool_registry = {
        in_use = {},
        groups = {
          ["mcp:tavily"] = { "tavily_search" },
          ["mcp:sequential-thinking"] = { "sequential_thinking" },
          ["other_group"] = { "other_tool" },  -- 非 MCP 组，应该被忽略
        },
      },
    }
    
    local servers = manager:get_inherited_mcp_servers(mock_parent_chat)
    
    _G.servers_count = #servers
    _G.has_tavily = vim.tbl_contains(servers, "tavily")
    _G.has_sequential = vim.tbl_contains(servers, "sequential-thinking")
    _G.has_other = vim.tbl_contains(servers, "other_group")
  ]])

  h.eq(2, child.lua_get([[_G.servers_count]]))
  h.eq(true, child.lua_get([[_G.has_tavily]]))
  h.eq(true, child.lua_get([[_G.has_sequential]]))
  h.eq(false, child.lua_get([[_G.has_other]]))
end

T["manager"]["inherit mcp_servers"]["get_inherited_mcp_servers handles nil parent"] = function()
  -- Test that get_inherited_mcp_servers handles nil parent gracefully
  -- Intent: Verify empty list is returned when parent is nil
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local servers = manager:get_inherited_mcp_servers(nil)
    
    _G.servers_empty = #servers == 0
  ]])

  h.eq(true, child.lua_get([[_G.servers_empty]]))
end

T["manager"]["inherit mcp_servers"]["get_inherited_mcp_servers handles missing tool_registry"] = function()
  -- Test that get_inherited_mcp_servers handles missing tool_registry
  -- Intent: Verify empty list is returned when parent has no tool_registry
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {}
    
    local servers = manager:get_inherited_mcp_servers(mock_parent_chat)
    
    _G.servers_empty = #servers == 0
  ]])

  h.eq(true, child.lua_get([[_G.servers_empty]]))
end

T["manager"]["inherit mcp_servers"]["get_inherited_mcp_servers handles empty groups"] = function()
  -- Test that get_inherited_mcp_servers handles empty groups table
  -- Intent: Verify empty list is returned when parent has no groups
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      tool_registry = {
        in_use = {},
        groups = {},
      },
    }
    
    local servers = manager:get_inherited_mcp_servers(mock_parent_chat)
    
    _G.servers_empty = #servers == 0
  ]])

  h.eq(true, child.lua_get([[_G.servers_empty]]))
end

T["manager"]["inherit mcp_servers"]["get_inherited_mcp_servers filters non-mcp groups"] = function()
  -- Test that get_inherited_mcp_servers filters non-MCP groups
  -- Intent: Verify only groups with mcp: prefix are extracted
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      tool_registry = {
        in_use = {},
        groups = {
          ["other_group"] = { "some_tool" },
          ["another_group"] = { "another_tool" },
        },
      },
    }
    
    local servers = manager:get_inherited_mcp_servers(mock_parent_chat)
    
    _G.servers_empty = #servers == 0
  ]])

  h.eq(true, child.lua_get([[_G.servers_empty]]))
end

T["manager"]["inherit integration"] = new_set()

T["manager"]["inherit integration"]["inherits tools when set to inherit"] = function()
  -- Test that start_subagent correctly inherits tools when set to "inherit"
  -- Intent: Verify tools are inherited from parent chat and passed to Chat.new
  -- Ref: Plan Task 5, Step 1
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
    
    -- 创建带有工具的 mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = {
        in_use = {
          ["read_file"] = true,
          ["grep_search"] = true,
        },
        groups = {},
      },
    }
    
    -- 使用 "inherit" 启动 subagent
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = "inherit",
    }, "Task", {})
    
    Chat.new = original_new
    
    -- 验证继承的工具被传递给 Chat.new
    _G.has_read_file = vim.tbl_contains(captured_opts.tools, "read_file")
    _G.has_grep_search = vim.tbl_contains(captured_opts.tools, "grep_search")
    _G.has_complete = vim.tbl_contains(captured_opts.tools, "complete_subagent")
  ]])

  h.eq(true, child.lua_get([[_G.has_read_file]]))
  h.eq(true, child.lua_get([[_G.has_grep_search]]))
  h.eq(true, child.lua_get([[_G.has_complete]]))
end

T["manager"]["inherit integration"]["inherits mcp_servers when set to inherit"] = function()
  -- Test that start_subagent correctly inherits mcp_servers when set to "inherit"
  -- Intent: Verify MCP servers are inherited from parent chat and passed to Chat.new
  -- Ref: Plan Task 5, Step 1
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
    
    -- 创建带有 MCP 服务器的 mock parent chat
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = {
        in_use = {},
        groups = {
          ["mcp:tavily"] = { "tavily_search" },
        },
      },
    }
    
    -- 使用 "inherit" 启动 subagent
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      mcp_servers = "inherit",
    }, "Task", {})
    
    Chat.new = original_new
    
    -- 验证继承的 MCP 服务器被传递给 Chat.new
    _G.mcp_servers = captured_opts.mcp_servers
  ]])

  local mcp_servers = child.lua_get([[_G.mcp_servers]])
  h.eq({ "tavily" }, mcp_servers)
end

T["manager"]["inherit integration"]["inherits both tools and mcp_servers"] = function()
  -- Test that start_subagent correctly inherits both tools and mcp_servers
  -- Intent: Verify both tools and MCP servers can be inherited simultaneously
  -- Ref: Plan Task 5, Step 1
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
      tool_registry = {
        in_use = {
          ["read_file"] = true,
        },
        groups = {
          ["mcp:tavily"] = { "tavily_search" },
        },
      },
    }
    
    -- 同时继承 tools 和 mcp_servers
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = "inherit",
      mcp_servers = "inherit",
    }, "Task", {})
    
    Chat.new = original_new
    
    _G.has_read_file = vim.tbl_contains(captured_opts.tools, "read_file")
    _G.mcp_servers = captured_opts.mcp_servers
  ]])

  h.eq(true, child.lua_get([[_G.has_read_file]]))
  h.eq({ "tavily" }, child.lua_get([[_G.mcp_servers]]))
end

T["manager"]["inherit integration"]["handles inherit with empty parent tools"] = function()
  -- Test that start_subagent handles inherit with empty parent tools
  -- Intent: Verify complete_subagent is still included when inheriting empty tools
  -- Ref: Plan Task 5, Step 1
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
      tool_registry = {
        in_use = {},
        groups = {},
      },
    }
    
    -- 继承空工具列表
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = "inherit",
    }, "Task", {})
    
    Chat.new = original_new
    
    -- 即使继承空列表，也应该有 complete_subagent
    _G.has_complete = vim.tbl_contains(captured_opts.tools, "complete_subagent")
    _G.tools_count = #captured_opts.tools
  ]])

  h.eq(true, child.lua_get([[_G.has_complete]]))
  h.eq(1, child.lua_get([[_G.tools_count]]))
end

T["manager"]["system prompt handling"] = new_set()

T["manager"]["system prompt handling"]["replace mode clears default and sets custom"] = function()
  -- Test that replace mode clears default system prompt and sets custom one
  -- Intent: Verify when replace_main_system_prompt = true, only custom system_prompt is used
  -- Ref: Plan Task 3, Step 1
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local set_system_prompt_calls = {}
    local mock_chat_instance = {
      bufnr = 9999,
      _parent_chat = nil,
      messages = {},
      set_system_prompt = function(self, prompt, opts)
        opts = opts or {}
        table.insert(set_system_prompt_calls, {
          prompt = prompt,
          tag = opts._meta and opts._meta.tag,
        })
      end,
      submit = function() end,
    }
    
    local original_new = Chat.new
    Chat.new = function(opts)
      return mock_chat_instance
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = { in_use = {}, groups = {} },
    }
    
    -- Start subagent with replace_main_system_prompt = true
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Custom system prompt",
      tools = {},
      replace_main_system_prompt = true,
    }, "Task", {})
    
    Chat.new = original_new
    
    _G.calls_count = #set_system_prompt_calls
    _G.calls = set_system_prompt_calls
  ]])

  -- Should have 2 calls: clear default + set custom + context prompt
  local calls_count = child.lua_get([[_G.calls_count]])
  h.eq(3, calls_count)

  local calls = child.lua_get([[_G.calls]])
  -- First call: clear default (empty string)
  h.eq("", calls[1].prompt)
  -- Second call: custom system prompt
  h.eq("Custom system prompt", calls[2].prompt)
  h.eq("subagent_system_prompt", calls[2].tag)
  -- Third call: context prompt
  h.eq("subagent_base_prompt", calls[3].tag)
end

T["manager"]["system prompt handling"]["insert mode keeps default and adds custom"] = function()
  -- Test that insert mode keeps default system prompt and adds custom one
  -- Intent: Verify when replace_main_system_prompt = false, both default and custom prompts exist
  -- Ref: Plan Task 3, Step 2
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local set_system_prompt_calls = {}
    local mock_chat_instance = {
      bufnr = 9999,
      _parent_chat = nil,
      messages = {},
      set_system_prompt = function(self, prompt, opts)
        opts = opts or {}
        table.insert(set_system_prompt_calls, {
          prompt = prompt,
          tag = opts._meta and opts._meta.tag,
        })
      end,
      submit = function() end,
    }
    
    local original_new = Chat.new
    Chat.new = function(opts)
      return mock_chat_instance
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = { in_use = {}, groups = {} },
    }
    
    -- Start subagent with replace_main_system_prompt = false (default)
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Custom system prompt",
      tools = {},
      replace_main_system_prompt = false,
    }, "Task", {})
    
    Chat.new = original_new
    
    _G.calls_count = #set_system_prompt_calls
    _G.calls = set_system_prompt_calls
  ]])

  -- Should have 2 calls: custom system prompt + context prompt (no clear)
  local calls_count = child.lua_get([[_G.calls_count]])
  h.eq(2, calls_count)

  local calls = child.lua_get([[_G.calls]])
  -- First call: custom system prompt
  h.eq("Custom system prompt", calls[1].prompt)
  h.eq("subagent_system_prompt", calls[1].tag)
  -- Second call: context prompt
  h.eq("subagent_base_prompt", calls[2].tag)
end

T["manager"]["system prompt handling"]["context prompt always injected"] = function()
  -- Test that SubAgent context prompt is always injected
  -- Intent: Verify context prompt is injected regardless of replace/insert mode
  -- Ref: Plan Task 3, Step 3
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local set_system_prompt_calls = {}
    local mock_chat_instance = {
      bufnr = 9999,
      _parent_chat = nil,
      messages = {},
      set_system_prompt = function(self, prompt, opts)
        opts = opts or {}
        table.insert(set_system_prompt_calls, {
          prompt = prompt,
          tag = opts._meta and opts._meta.tag,
        })
      end,
      submit = function() end,
    }
    
    local original_new = Chat.new
    Chat.new = function(opts)
      return mock_chat_instance
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = { in_use = {}, groups = {} },
    }
    
    -- Start subagent without custom system_prompt
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = nil,
      tools = {},
    }, "Task", {})
    
    Chat.new = original_new
    
    _G.calls_count = #set_system_prompt_calls
    _G.calls = set_system_prompt_calls
  ]])

  -- Should have 1 call: context prompt only
  local calls_count = child.lua_get([[_G.calls_count]])
  h.eq(1, calls_count)

  local calls = child.lua_get([[_G.calls]])
  -- Context prompt should be injected
  h.eq("subagent_base_prompt", calls[1].tag)
end

T["manager"]["system prompt integration"] = new_set()

T["manager"]["system prompt integration"]["full flow with replace mode"] = function()
  -- Test complete system prompt flow from tool creation to Chat creation
  -- Intent: Verify full integration with replace mode
  -- Ref: Plan Task 5, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local set_system_prompt_calls = {}
    local captured_opts = nil
    
    local mock_chat_instance = {
      bufnr = 9999,
      _parent_chat = nil,
      messages = {},
      set_system_prompt = function(self, prompt, opts)
        opts = opts or {}
        table.insert(set_system_prompt_calls, {
          prompt = prompt,
          tag = opts._meta and opts._meta.tag,
        })
      end,
      submit = function() end,
    }
    
    local original_new = Chat.new
    Chat.new = function(opts)
      captured_opts = opts
      return mock_chat_instance
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = { in_use = {}, groups = {} },
    }
    
    -- Create tool with replace mode
    local tool_instance = tool.create_subagent_tool("custom_agent", {
      description = "Custom agent",
      system_prompt = "You are a specialized agent.",
      tools = { "read_file" },
      replace_main_system_prompt = true,
    })
    
    -- Execute the tool
    local mock_self = { chat = mock_parent_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    Chat.new = original_new
    
    _G.calls_count = #set_system_prompt_calls
    _G.calls = set_system_prompt_calls
    _G.has_complete = vim.tbl_contains(captured_opts.tools, "complete_subagent")
  ]])

  local calls_count = child.lua_get([[_G.calls_count]])
  h.eq(3, calls_count) -- clear + custom + context

  local calls = child.lua_get([[_G.calls]])
  h.eq("", calls[1].prompt) -- clear default
  h.eq("You are a specialized agent.", calls[2].prompt)
  h.eq("subagent_system_prompt", calls[2].tag)
  h.eq("subagent_base_prompt", calls[3].tag)

  h.eq(true, child.lua_get([[_G.has_complete]]))
end

T["manager"]["system prompt integration"]["full flow with insert mode"] = function()
  -- Test complete system prompt flow with insert mode
  -- Intent: Verify full integration with insert mode (default)
  -- Ref: Plan Task 5, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    local Chat = require("codecompanion.interactions.chat")
    
    local set_system_prompt_calls = {}
    local captured_opts = nil
    
    local mock_chat_instance = {
      bufnr = 9999,
      _parent_chat = nil,
      messages = {},
      set_system_prompt = function(self, prompt, opts)
        opts = opts or {}
        table.insert(set_system_prompt_calls, {
          prompt = prompt,
          tag = opts._meta and opts._meta.tag,
        })
      end,
      submit = function() end,
    }
    
    local original_new = Chat.new
    Chat.new = function(opts)
      captured_opts = opts
      return mock_chat_instance
    end
    
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
      tool_registry = { in_use = {}, groups = {} },
    }
    
    -- Create tool with insert mode (default)
    local tool_instance = tool.create_subagent_tool("custom_agent", {
      description = "Custom agent",
      system_prompt = "You are a specialized agent.",
      tools = { "read_file" },
      -- replace_main_system_prompt defaults to false
    })
    
    -- Execute the tool
    local mock_self = { chat = mock_parent_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    Chat.new = original_new
    
    _G.calls_count = #set_system_prompt_calls
    _G.calls = set_system_prompt_calls
  ]])

  local calls_count = child.lua_get([[_G.calls_count]])
  h.eq(2, calls_count) -- custom + context (no clear)

  local calls = child.lua_get([[_G.calls]])
  h.eq("You are a specialized agent.", calls[1].prompt)
  h.eq("subagent_system_prompt", calls[1].tag)
  h.eq("subagent_base_prompt", calls[2].tag)
end

-- ============================================================================
-- Context Mode Tests
-- ============================================================================

T["manager"]["get_inherited_messages"] = new_set()

T["manager"]["get_inherited_messages"]["returns empty for nil parent"] = function()
  -- Test that get_inherited_messages handles nil parent gracefully
  -- Intent: Verify empty list is returned when parent is nil
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local messages = manager:get_inherited_messages(nil, "test_agent", "Task")
    
    _G.messages_empty = #messages == 0
  ]])

  h.eq(true, child.lua_get([[_G.messages_empty]]))
end

T["manager"]["get_inherited_messages"]["returns empty for parent without messages"] = function()
  -- Test that get_inherited_messages handles parent without messages
  -- Intent: Verify empty list is returned when parent has no messages
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      id = "parent_chat",
      messages = {},
    }
    
    local messages = manager:get_inherited_messages(mock_parent_chat, "test_agent", "Task")
    
    _G.messages_empty = #messages == 0
  ]])

  h.eq(true, child.lua_get([[_G.messages_empty]]))
end

T["manager"]["get_inherited_messages"]["filters out system messages"] = function()
  -- Test that get_inherited_messages filters out system messages
  -- Intent: Verify system messages are removed from inherited messages
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      id = "parent_chat",
      messages = {
        { role = "system", content = "System prompt" },
        { role = "user", content = "User message" },
        { role = "llm", content = "LLM response" },
        { role = "system", content = "Another system" },
      },
    }
    
    local messages = manager:get_inherited_messages(mock_parent_chat, "test_agent", "Task")
    
    _G.messages_count = #messages
    _G.all_non_system = true
    for _, msg in ipairs(messages) do
      if msg.role == "system" then
        _G.all_non_system = false
        break
      end
    end
  ]])

  h.eq(2, child.lua_get([[_G.messages_count]]))
  h.eq(true, child.lua_get([[_G.all_non_system]]))
end

T["manager"]["get_inherited_messages"]["replaces tool call message"] = function()
  -- Test that get_inherited_messages replaces tool call message with context
  -- Intent: Verify tool call message is replaced with SubAgent context message
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      id = "parent_chat",
      messages = {
        { role = "user", content = "Previous message" },
        { role = "llm", content = "LLM response" },
        {
          role = "llm",
          content = "",
          tools = {
            calls = {
              {
                id = "call_123",
                ["function"] = {
                  name = "subagent_test_agent",
                  arguments = '{ "task": "Do something" }',
                },
              },
            },
          },
        },
      },
    }
    
    local messages = manager:get_inherited_messages(mock_parent_chat, "test_agent", "New task")
    
    _G.messages_count = #messages
    _G.last_message = messages[#messages].content
    _G.last_role = messages[#messages].role
    _G.has_task = messages[#messages].content:find("New task") ~= nil
  ]])

  h.eq(3, child.lua_get([[_G.messages_count]]))
  h.eq("user", child.lua_get([[_G.last_role]]))
  h.eq(true, child.lua_get([[_G.has_task]]))
end

T["manager"]["get_inherited_messages"]["handles missing tool call"] = function()
  -- Test that get_inherited_messages handles missing tool call gracefully
  -- Intent: Verify messages are still returned when tool call is not found
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_parent_chat = {
      id = "parent_chat",
      messages = {
        { role = "user", content = "User message" },
        { role = "llm", content = "LLM response" },
      },
    }
    
    local messages = manager:get_inherited_messages(mock_parent_chat, "test_agent", "Task")
    
    _G.messages_count = #messages
    _G.first_content = messages[1].content
  ]])

  h.eq(2, child.lua_get([[_G.messages_count]]))
  h.eq("User message", child.lua_get([[_G.first_content]]))
end

-- ============================================================================
-- Context Mode Integration Tests
-- ============================================================================

T["manager"]["context_mode"] = new_set()

T["manager"]["context_mode"]["explicit mode includes context parameter"] = function()
  -- Test that explicit mode includes context parameter in schema
  -- Intent: Verify context parameter is present in tool schema for explicit mode
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test agent",
      system_prompt = "Test",
      context_mode = "explicit",
      context_spec = "Files to analyze",
      tools = {},
    })
    
    local props = tool_instance.schema["function"].parameters.properties
    _G.has_task = props.task ~= nil
    _G.has_context = props.context ~= nil
    _G.context_desc = props.context and props.context.description
  ]])

  h.eq(true, child.lua_get([[_G.has_task]]))
  h.eq(true, child.lua_get([[_G.has_context]]))
  h.eq("Files to analyze", child.lua_get([[_G.context_desc]]))
end

T["manager"]["context_mode"]["inherit mode excludes context parameter"] = function()
  -- Test that inherit mode excludes context parameter from schema
  -- Intent: Verify context parameter is not present in tool schema for inherit mode
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test agent",
      system_prompt = "Test",
      context_mode = "inherit",
      tools = {},
    })
    
    local props = tool_instance.schema["function"].parameters.properties
    _G.has_task = props.task ~= nil
    _G.has_context = props.context ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.has_task]]))
  h.eq(false, child.lua_get([[_G.has_context]]))
end

T["manager"]["context_mode"]["default mode is explicit"] = function()
  -- Test that default context_mode is explicit
  -- Intent: Verify context parameter is present when context_mode is not specified
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test agent",
      system_prompt = "Test",
      tools = {},
    })
    
    local props = tool_instance.schema["function"].parameters.properties
    _G.has_context = props.context ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.has_context]]))
end

T["manager"]["context_mode"]["inherit mode uses inherited messages"] = function()
  -- Test that inherit mode uses inherited messages
  -- Intent: Verify messages are inherited from parent chat in inherit mode
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
      tool_registry = { in_use = {}, groups = {} },
      messages = {
        { role = "user", content = "Previous message" },
        { role = "llm", content = "LLM response" },
      },
    }
    
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      context_mode = "inherit",
    }, "New task", nil)
    
    Chat.new = original_new
    
    _G.messages_count = #captured_opts.messages
    _G.has_previous = captured_opts.messages[1].content == "Previous message"
  ]])

  h.eq(2, child.lua_get([[_G.messages_count]]))
  h.eq(true, child.lua_get([[_G.has_previous]]))
end

-- ============================================================================
-- Result Spec Tests
-- ============================================================================

T["manager"]["result_spec"] = new_set()

T["manager"]["result_spec"]["injects result_spec into task"] = function()
  -- Test that result_spec is injected into task message
  -- Intent: Verify result_spec is appended to the last user message
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
      tool_registry = { in_use = {}, groups = {} },
    }
    
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      result_spec = "Return a JSON object with status and message",
    }, "Do something", nil)
    
    Chat.new = original_new
    
    local content = captured_opts.messages[1].content
    _G.has_task = content:find("Do something") ~= nil
    _G.has_result_spec = content:find("Expected Result") ~= nil
    _G.has_json = content:find("JSON object") ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.has_task]]))
  h.eq(true, child.lua_get([[_G.has_result_spec]]))
  h.eq(true, child.lua_get([[_G.has_json]]))
end

T["manager"]["result_spec"]["injects result_spec in inherit mode"] = function()
  -- Test that result_spec is injected in inherit mode
  -- Intent: Verify result_spec is appended to inherited messages
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
      tool_registry = { in_use = {}, groups = {} },
      messages = {
        { role = "user", content = "Previous message" },
        { role = "llm", content = "LLM response" },
      },
    }
    
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      context_mode = "inherit",
      result_spec = "Return a summary",
    }, "New task", nil)
    
    Chat.new = original_new
    
    -- Find the last user message
    local last_user_content = nil
    for i = #captured_opts.messages, 1, -1 do
      if captured_opts.messages[i].role == "user" then
        last_user_content = captured_opts.messages[i].content
        break
      end
    end
    
    _G.has_result_spec = last_user_content and last_user_content:find("Expected Result") ~= nil
    _G.has_summary = last_user_content and last_user_content:find("Return a summary") ~= nil
  ]])

  h.eq(true, child.lua_get([[_G.has_result_spec]]))
  h.eq(true, child.lua_get([[_G.has_summary]]))
end

T["manager"]["result_spec"]["no injection when result_spec is nil"] = function()
  -- Test that no result_spec is injected when not specified
  -- Intent: Verify task message is unchanged when result_spec is nil
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
      tool_registry = { in_use = {}, groups = {} },
    }
    
    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      -- result_spec not specified
    }, "Do something", nil)
    
    Chat.new = original_new
    
    local content = captured_opts.messages[1].content
    _G.no_result_spec = content:find("Expected Result") == nil
    _G.just_task = content == "Do something"
  ]])

  h.eq(true, child.lua_get([[_G.no_result_spec]]))
  h.eq(true, child.lua_get([[_G.just_task]]))
end

-- ============================================================================
-- context_spec Tests
-- ============================================================================

T["manager"]["context_spec"] = new_set()

T["manager"]["context_spec"]["uses context_spec in schema"] = function()
  -- Test that context_spec is used in schema description
  -- Intent: Verify context_spec is used as context parameter description
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local tool_instance = tool.create_subagent_tool("code_reviewer", {
      description = "Code reviewer",
      system_prompt = "You are a code reviewer.",
      context_spec = "The code files to review, including file paths",
      tools = {},
    })
    
    local desc = tool_instance.schema["function"].parameters.properties.context.description
    _G.has_spec = desc == "The code files to review, including file paths"
  ]])

  h.eq(true, child.lua_get([[_G.has_spec]]))
end

T["manager"]["context_spec"]["uses default when not specified"] = function()
  -- Test that default description is used when not specified
  -- Intent: Verify fallback to default description
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test agent",
      system_prompt = "Test",
      tools = {},
    })
    
    local desc = tool_instance.schema["function"].parameters.properties.context.description
    _G.has_default = desc == "Additional context for the task"
  ]])

  h.eq(true, child.lua_get([[_G.has_default]]))
end

T["manager"]["adapter"] = new_set()

T["manager"]["adapter"]["inherits parent adapter when nil"] = function()
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

    local parent_adapter = { name = "parent_adapter" }
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = parent_adapter,
      ui = { hide = function() end, open = function() end },
    }

    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      -- adapter not specified
    }, "Task", {})

    Chat.new = original_new

    _G.adapter_name = captured_opts.adapter.name
  ]])

  h.eq("parent_adapter", child.lua_get([[_G.adapter_name]]))
end

T["manager"]["adapter"]["inherits parent adapter when set to inherit"] = function()
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

    local parent_adapter = { name = "parent_adapter" }
    local mock_parent_chat = {
      id = "parent_chat",
      adapter = parent_adapter,
      ui = { hide = function() end, open = function() end },
    }

    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      adapter = "inherit",
    }, "Task", {})

    Chat.new = original_new

    _G.adapter_name = captured_opts.adapter.name
  ]])

  h.eq("parent_adapter", child.lua_get([[_G.adapter_name]]))
end

T["manager"]["adapter"]["uses custom adapter string"] = function()
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
      adapter = { name = "parent_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      adapter = "openai",
    }, "Task", {})

    Chat.new = original_new

    _G.adapter_value = captured_opts.adapter
  ]])

  h.eq("openai", child.lua_get([[_G.adapter_value]]))
end

T["manager"]["adapter"]["uses custom adapter table with model"] = function()
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
      adapter = { name = "parent_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    manager:start_subagent(mock_parent_chat, {
      name = "test_agent",
      system_prompt = "Test",
      tools = {},
      adapter = { name = "openai", model = "gpt-4o" },
    }, "Task", {})

    Chat.new = original_new

    _G.adapter_value = captured_opts.adapter
  ]])

  local adapter = child.lua_get([[_G.adapter_value]])
  h.eq("openai", adapter.name)
  h.eq("gpt-4o", adapter.model)
end

return T
