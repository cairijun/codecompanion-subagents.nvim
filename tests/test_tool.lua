-- Tests for lua/codecompanion-subagents/tool.lua
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

T["tool"] = new_set()

T["tool"]["create_subagent_tool returns valid tool"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    _G.subagent_tool = tool.create_subagent_tool("test_agent", {
      description = "Test agent description",
      system_prompt = "You are a test agent",
      tools = { "read_file", "grep_search" },
    })
    
    _G.tool_name = _G.subagent_tool.name
    _G.has_schema = _G.subagent_tool.schema ~= nil
    _G.has_cmds = _G.subagent_tool.cmds ~= nil
    _G.cmds_is_function = type(_G.subagent_tool.cmds[1]) == "function"
  ]])

  h.eq("subagent_test_agent", child.lua_get([[_G.tool_name]]))
  h.eq(true, child.lua_get([[_G.has_schema]]))
  h.eq(true, child.lua_get([[_G.has_cmds]]))
  h.eq(true, child.lua_get([[_G.cmds_is_function]]))
end

T["tool"]["schema has correct structure"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local t = tool.create_subagent_tool("reviewer", {
      description = "Code reviewer",
      system_prompt = "Review code",
    })
    
    _G.schema_type = t.schema.type
    _G.func_name = t.schema["function"].name
    _G.has_task_param = t.schema["function"].parameters.properties.task ~= nil
  ]])

  h.eq("function", child.lua_get([[_G.schema_type]]))
  h.eq("subagent_reviewer", child.lua_get([[_G.func_name]]))
  h.eq(true, child.lua_get([[_G.has_task_param]]))
end

T["tool"]["uses custom context_spec"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local t = tool.create_subagent_tool("agent", {
      description = "Agent",
      system_prompt = "Be helpful",
      context_spec = "Custom context info",
    })
    
    _G.context_desc = t.schema["function"].parameters.properties.context.description
  ]])

  h.eq("Custom context info", child.lua_get([[_G.context_desc]]))
end

T["tool"]["cmds signature"] = function()
  -- Test that cmds function receives opts parameter with input and output_cb fields
  -- Intent: Verify the cmds function signature matches CodeCompanion's tool interface
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat with adapter
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = {
          model = { default = "test-model" }
        },
      },
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Create tool instance
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = {},
    })
    
    -- Track what was passed to the cmds function
    local captured_opts = nil
    local captured_self = nil
    local captured_args = nil
    
    -- Mock output_cb to capture opts
    local mock_output_cb_called = false
    local mock_output_cb_result = nil
    local function mock_output_cb(result)
      mock_output_cb_called = true
      mock_output_cb_result = result
    end
    
    -- Create mock self with chat (CodeCompanion.Tools has chat property)
    local mock_self = {
      chat = mock_chat,
    }
    
    -- Create mock opts with input and output_cb
    local mock_opts = {
      input = { previous_output = "test" },
      output_cb = mock_output_cb,
    }
    
    -- Execute the tool command with proper opts signature
    tool_instance.cmds[1](mock_self, { task = "Test task" }, mock_opts)
    
    -- Find the subagent_id and manually set subagent_chat to simulate successful creation
    local subagent_id = next(mock_chat._subagents)
    mock_chat._subagents[subagent_id].subagent_chat = { bufnr = 9999, ui = { hide = function() end } }
    
    -- Simulate completion to trigger output_cb
    manager:complete_subagent(mock_chat, subagent_id, "Task completed")
    
    -- Verify output_cb was called
    _G.output_cb_called = mock_output_cb_called
    _G.output_cb_result = mock_output_cb_result
  ]])

  h.eq(true, child.lua_get([[_G.output_cb_called]]))
  local result = child.lua_get([[_G.output_cb_result]])
  h.eq("success", result.status)
  h.eq("Task completed", result.data)
end

T["tool"]["mcp_servers config"] = new_set()

T["tool"]["mcp_servers config"]["passes mcp_servers to manager"] = function()
  -- Test that mcp_servers config is passed to manager:start_subagent
  -- Intent: Verify SubAgent config's mcp_servers field is correctly passed to manager
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Capture what was passed to start_subagent
    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
      -- Don't actually start, just capture
    end
    
    -- Create tool instance with mcp_servers
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = { "read_file" },
      mcp_servers = { "sequential-thinking", "tavily" },
    })
    
    -- Execute the tool command
    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    -- Restore original
    manager.start_subagent = original_start
    
    -- Verify mcp_servers was passed
    _G.has_mcp_servers = captured_config.mcp_servers ~= nil
    _G.mcp_servers = captured_config.mcp_servers
  ]])

  h.eq(true, child.lua_get([[_G.has_mcp_servers]]))
  local mcp_servers = child.lua_get([[_G.mcp_servers]])
  h.eq({ "sequential-thinking", "tavily" }, mcp_servers)
end

T["tool"]["mcp_servers config"]["handles nil mcp_servers"] = function()
  -- Test that nil mcp_servers is handled gracefully
  -- Intent: Verify SubAgent works without mcp_servers config
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end
    
    -- Create tool instance WITHOUT mcp_servers
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = { "read_file" },
      -- mcp_servers is not specified
    })
    
    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    manager.start_subagent = original_start
    
    -- vim.NIL is Neovim's representation of nil across Lua states
    _G.mcp_servers_is_nil = captured_config.mcp_servers == nil or captured_config.mcp_servers == vim.NIL
  ]])

  h.eq(true, child.lua_get([[_G.mcp_servers_is_nil]]))
end

T["tool"]["mcp_servers config"]["handles empty mcp_servers"] = function()
  -- Test that empty mcp_servers table is passed correctly
  -- Intent: Verify empty mcp_servers table is handled
  -- Ref: Plan Task 1, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end
    
    -- Create tool instance with empty mcp_servers
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = { "read_file" },
      mcp_servers = {},
    })
    
    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    manager.start_subagent = original_start
    
    _G.mcp_servers = captured_config.mcp_servers
  ]])

  h.eq({}, child.lua_get([[_G.mcp_servers]]))
end

T["tool"]["schema has strict field"] = function()
  -- Test that schema has strict = true field
  -- Intent: Verify schema structure matches CodeCompanion's requirements
  -- Ref: Plan Task 1, Step 5
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    
    local t = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
    })
    
    _G.has_strict = t.schema["function"].strict ~= nil
    _G.strict_value = t.schema["function"].strict
  ]])

  h.eq(true, child.lua_get([[_G.has_strict]]))
  h.eq(true, child.lua_get([[_G.strict_value]]))
end

T["tool"]["result flow"] = new_set()

T["tool"]["result flow"]["returns result to main chat"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat with adapter
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = {
          model = { default = "test-model" }
        },
      },
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Create tool instance
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = {},
    })
    
    -- Simulate tool execution with mock input
    local captured_output = nil
    local mock_input = {
      output_cb = function(msg)
        captured_output = msg
      end,
    }
    
    -- Create mock self with chat (CodeCompanion.Tools has chat property)
    local mock_self = {
      chat = mock_chat,
    }
    
    -- Execute the tool command - this sets up the completion callback
    tool_instance.cmds[1](mock_self, { task = "Test task" }, mock_input)
    
    -- Find the subagent_id and manually set subagent_chat to simulate successful creation
    -- (since we can't create a real Chat without full setup)
    local subagent_id = next(mock_chat._subagents)
    mock_chat._subagents[subagent_id].subagent_chat = { bufnr = 9999, ui = { hide = function() end } }
    
    -- Verify subagent is active
    _G.subagent_active_before = manager:is_active(mock_chat)
    
    -- Simulate complete_subagent being called
    manager:complete_subagent(mock_chat, subagent_id, "Task completed successfully")
    
    -- Verify subagent is no longer active
    _G.subagent_active_after = manager:is_active(mock_chat)
    
    -- Get the captured output from completion callback
    _G.captured = captured_output
  ]])

  h.eq(true, child.lua_get([[_G.subagent_active_before]]))
  h.eq(false, child.lua_get([[_G.subagent_active_after]]))

  local captured = child.lua_get([[_G.captured]])
  h.eq("success", captured.status)
  h.eq("Task completed successfully", captured.data)
end

T["tool"]["result flow"]["handles error result"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat with adapter
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = {
          model = { default = "test-model" }
        },
      },
      ui = {
        hide = function() end,
        open = function() end,
      },
    }
    
    -- Create tool instance
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = {},
    })
    
    -- Simulate tool execution with mock input
    local captured_output = nil
    local mock_input = {
      output_cb = function(msg)
        captured_output = msg
      end,
    }
    
    -- Create mock self with chat (CodeCompanion.Tools has chat property)
    local mock_self = {
      chat = mock_chat,
    }
    
    -- Execute the tool command
    tool_instance.cmds[1](mock_self, { task = "Test task" }, mock_input)
    
    -- Find the subagent_id and manually set subagent_chat to simulate successful creation
    local subagent_id = next(mock_chat._subagents)
    mock_chat._subagents[subagent_id].subagent_chat = { bufnr = 9999, ui = { hide = function() end } }
    
    -- Simulate error completion
    manager:complete_subagent(mock_chat, subagent_id, "Error: Something went wrong", true)
    
    -- Get the captured output
    _G.captured = captured_output
  ]])

  local captured = child.lua_get([[_G.captured]])
  h.eq("error", captured.status)
  h.eq("Error: Something went wrong", captured.data)
end

T["tool"]["replace_main_system_prompt config"] = new_set()

T["tool"]["replace_main_system_prompt config"]["passes replace_main_system_prompt to manager"] = function()
  -- Test that replace_main_system_prompt config is passed to manager:start_subagent
  -- Intent: Verify SubAgent config's replace_main_system_prompt field is correctly passed to manager
  -- Ref: Plan Task 2, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    -- Create a mock parent chat
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    -- Capture what was passed to start_subagent
    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end
    
    -- Create tool instance with replace_main_system_prompt = true
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = { "read_file" },
      replace_main_system_prompt = true,
    })
    
    -- Execute the tool command
    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    -- Restore original
    manager.start_subagent = original_start
    
    -- Verify replace_main_system_prompt was passed
    _G.has_replace_flag = captured_config.replace_main_system_prompt ~= nil
    _G.replace_flag_value = captured_config.replace_main_system_prompt
  ]])

  h.eq(true, child.lua_get([[_G.has_replace_flag]]))
  h.eq(true, child.lua_get([[_G.replace_flag_value]]))
end

T["tool"]["adapter config"] = new_set()

T["tool"]["adapter config"]["passes adapter string to manager"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")

    local mock_chat = {
      id = "parent_chat",
      adapter = { name = "test_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end

    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      adapter = "openai",
    })

    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    manager.start_subagent = original_start

    _G.adapter_value = captured_config.adapter
  ]])

  h.eq("openai", child.lua_get([[_G.adapter_value]]))
end

T["tool"]["adapter config"]["passes adapter table to manager"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")

    local mock_chat = {
      id = "parent_chat",
      adapter = { name = "test_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end

    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      adapter = { name = "openai", model = "gpt-4o" },
    })

    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    manager.start_subagent = original_start

    _G.adapter_value = captured_config.adapter
  ]])

  local adapter = child.lua_get([[_G.adapter_value]])
  h.eq("openai", adapter.name)
  h.eq("gpt-4o", adapter.model)
end

T["tool"]["adapter config"]["passes nil adapter to manager when not specified"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")

    local mock_chat = {
      id = "parent_chat",
      adapter = { name = "test_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end

    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      -- adapter not specified
    })

    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    manager.start_subagent = original_start

    _G.adapter_is_nil = captured_config.adapter == nil or captured_config.adapter == vim.NIL
  ]])

  h.eq(true, child.lua_get([[_G.adapter_is_nil]]))
end

T["tool"]["adapter config"]["passes inherit string to manager"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")

    local mock_chat = {
      id = "parent_chat",
      adapter = { name = "test_adapter" },
      ui = { hide = function() end, open = function() end },
    }

    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end

    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      adapter = "inherit",
    })

    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    manager.start_subagent = original_start

    _G.adapter_value = captured_config.adapter
  ]])

  h.eq("inherit", child.lua_get([[_G.adapter_value]]))
end

T["tool"]["replace_main_system_prompt config"]["defaults to false when not specified"] = function()
  -- Test that replace_main_system_prompt defaults to false
  -- Intent: Verify default value is false when not specified in config
  -- Ref: Plan Task 2, Step 1
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")
    local manager = require("codecompanion._extensions.subagents.manager")
    
    local mock_chat = {
      id = "parent_chat",
      adapter = {
        name = "test_adapter",
        type = "http",
        schema = { model = { default = "test-model" } },
      },
      ui = { hide = function() end, open = function() end },
    }
    
    local captured_config = nil
    local original_start = manager.start_subagent
    manager.start_subagent = function(self, chat, config, task, context)
      captured_config = config
    end
    
    -- Create tool instance WITHOUT replace_main_system_prompt
    local tool_instance = tool.create_subagent_tool("test_agent", {
      description = "Test",
      system_prompt = "Test",
      tools = { "read_file" },
      -- replace_main_system_prompt is not specified
    })
    
    local mock_self = { chat = mock_chat }
    tool_instance.cmds[1](mock_self, { task = "Test task" }, {})
    
    manager.start_subagent = original_start
    
    -- Default should be false
    _G.replace_flag_value = captured_config.replace_main_system_prompt
  ]])

  h.eq(false, child.lua_get([[_G.replace_flag_value]]))
end

return T
