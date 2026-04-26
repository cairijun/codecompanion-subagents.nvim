-- Integration test to verify concurrent subagents work correctly
-- Bug was: When main agent calls two subagents simultaneously, the second subagent's result was lost
-- Fix: chat._subagents is now a dictionary keyed by unique subagent_id
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

T["concurrent subagents"] = new_set()

T["concurrent subagents"]["two subagents running simultaneously both receive correct results"] = function()
  -- This test verifies that calling two subagents simultaneously
  -- both receive their correct results.
  --
  -- EXPECTED BEHAVIOR:
  --   - Agent 1's callback should receive Agent 1's result
  --   - Agent 2's callback should receive Agent 2's result
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
      ui = {
        hide = function() end,
        open = function() end,
      },
    }

    -- Create two subagent tool instances
    local tool1 = tool.create_subagent_tool("agent_one", {
      description = "First agent",
      system_prompt = "You are agent one",
      tools = {},
    })

    local tool2 = tool.create_subagent_tool("agent_two", {
      description = "Second agent",
      system_prompt = "You are agent two",
      tools = {},
    })

    -- Track output_cb calls for both agents
    local agent1_output_cb_called = false
    local agent1_output_cb_result = nil
    local agent2_output_cb_called = false
    local agent2_output_cb_result = nil

    -- Create mock opts with output_cb for each agent
    local mock_opts1 = {
      output_cb = function(result)
        agent1_output_cb_called = true
        agent1_output_cb_result = result
      end,
    }

    local mock_opts2 = {
      output_cb = function(result)
        agent2_output_cb_called = true
        agent2_output_cb_result = result
      end,
    }

    -- Create mock self with chat
    local mock_self = { chat = mock_chat }

    -- STEP 1: Start first subagent, capture its subagent_id
    tool1.cmds[1](mock_self, { task = "Task 1" }, mock_opts1)
    -- Find the subagent_id for agent_one
    local agent1_id = nil
    for id, state in pairs(mock_chat._subagents) do
      if state.config and state.config.name == "agent_one" then
        agent1_id = id
        -- Simulate subagent chat creation
        state.subagent_chat = { bufnr = 1001, ui = { hide = function() end } }
        break
      end
    end

    -- STEP 2: Start second subagent WITHOUT waiting for first to complete
    tool2.cmds[1](mock_self, { task = "Task 2" }, mock_opts2)
    -- Find the subagent_id for agent_two
    local agent2_id = nil
    for id, state in pairs(mock_chat._subagents) do
      if state.config and state.config.name == "agent_two" then
        agent2_id = id
        -- Simulate subagent chat creation
        state.subagent_chat = { bufnr = 1002, ui = { hide = function() end } }
        break
      end
    end

    -- STEP 3: First subagent completes (using its specific subagent_id)
    manager:complete_subagent(mock_chat, agent1_id, "Result from agent one", false)

    -- STEP 4: Second subagent completes (using its specific subagent_id)
    manager:complete_subagent(mock_chat, agent2_id, "Result from agent two", false)

    -- Capture final results
    _G.agent1_cb_called = agent1_output_cb_called
    _G.agent1_result = agent1_output_cb_result
    _G.agent2_cb_called = agent2_output_cb_called
    _G.agent2_result = agent2_output_cb_result
    _G.agent1_id = agent1_id
    _G.agent2_id = agent2_id
  ]])

  -- Verify both subagent_ids were created
  h.eq(true, child.lua_get([[_G.agent1_id ~= nil]]), "Agent 1 should have a subagent_id")
  h.eq(true, child.lua_get([[_G.agent2_id ~= nil]]), "Agent 2 should have a subagent_id")
  h.eq(true, child.lua_get([[_G.agent1_id ~= _G.agent2_id]]), "Agent 1 and Agent 2 should have different subagent_ids")

  -- Agent 1's callback SHOULD be called with Agent 1's result
  h.eq(true, child.lua_get([[_G.agent1_cb_called]]), "Agent 1's callback should be called")
  local agent1_result = child.lua_get([[_G.agent1_result]])
  h.eq("success", agent1_result and agent1_result.status, "Agent 1 result should have success status")
  h.eq("Result from agent one", agent1_result and agent1_result.data, "Agent 1 should receive its own result")

  -- Agent 2's callback SHOULD be called with Agent 2's result
  h.eq(true, child.lua_get([[_G.agent2_cb_called]]), "Agent 2's callback should be called")
  local agent2_result = child.lua_get([[_G.agent2_result]])
  h.eq("success", agent2_result and agent2_result.status, "Agent 2 result should have success status")
  h.eq("Result from agent two", agent2_result and agent2_result.data, "Agent 2 should receive its own result")
end

T["concurrent subagents"]["sequential subagents work correctly"] = function()
  -- Control test: sequential subagents (one completes before next starts) work fine
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
      ui = {
        hide = function() end,
        open = function() end,
      },
    }

    local tool1 = tool.create_subagent_tool("agent_one", {
      description = "First agent",
      system_prompt = "You are agent one",
      tools = {},
    })

    local tool2 = tool.create_subagent_tool("agent_two", {
      description = "Second agent",
      system_prompt = "You are agent two",
      tools = {},
    })

    local agent1_result = nil
    local agent2_result = nil

    local mock_self = { chat = mock_chat }

    -- Start first subagent
    tool1.cmds[1](mock_self, { task = "Task 1" }, {
      output_cb = function(result)
        agent1_result = result
      end,
    })

    -- Find agent1_id and simulate subagent chat
    local agent1_id = nil
    for id, state in pairs(mock_chat._subagents) do
      if state.config and state.config.name == "agent_one" then
        agent1_id = id
        state.subagent_chat = { bufnr = 1001, ui = { hide = function() end } }
        break
      end
    end

    -- Complete first subagent BEFORE starting second
    manager:complete_subagent(mock_chat, agent1_id, "Result from agent one", false)

    -- Now start second subagent
    tool2.cmds[1](mock_self, { task = "Task 2" }, {
      output_cb = function(result)
        agent2_result = result
      end,
    })

    -- Find agent2_id and simulate subagent chat
    local agent2_id = nil
    for id, state in pairs(mock_chat._subagents) do
      if state.config and state.config.name == "agent_two" then
        agent2_id = id
        state.subagent_chat = { bufnr = 1002, ui = { hide = function() end } }
        break
      end
    end

    -- Complete second subagent
    manager:complete_subagent(mock_chat, agent2_id, "Result from agent two", false)

    _G.agent1_result = agent1_result
    _G.agent2_result = agent2_result
  ]])

  -- Both results should be received correctly
  local agent1_result = child.lua_get([[_G.agent1_result]])
  local agent2_result = child.lua_get([[_G.agent2_result]])

  h.eq("success", agent1_result.status)
  h.eq("Result from agent one", agent1_result.data)
  h.eq("success", agent2_result.status)
  h.eq("Result from agent two", agent2_result.data)
end

return T
