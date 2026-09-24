-- Tests for the async_delivery option: non-blocking dispatch and
-- idle-gated FIFO delivery of subagent results.
local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      -- Shared builder, sent into the child once and stored on _G
      child.lua([[
        -- Build a mock parent chat that satisfies request_delivery / chat_is_idle
        _G.make_async_parent = function()
          local api = vim.api
          local bufnr = api.nvim_create_buf(false, true)
          return {
            id = "async_parent_" .. bufnr,
            bufnr = bufnr,
            current_request = nil,
            _compacting = false,
            tool_orchestrator = nil,
            adapter = { name = "test_adapter", type = "http", schema = { model = { default = "test-model" } } },
            ui = { hide = function() end, open = function() end },
            buf_messages = {},
            messages = {},
            submitted = 0,
            add_buf_message = function(self, data) table.insert(self.buf_messages, data) end,
            add_message = function(self, data) table.insert(self.messages, data) end,
            submit = function(self, opts) self.submitted = self.submitted + 1 end,
          }
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["async_delivery"] = new_set()

T["async_delivery"]["dispatch"] = new_set()

T["async_delivery"]["dispatch"]["async tool returns immediately with a marker and no blocking wait"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")

    local parent = _G.make_async_parent()

    local t = tool.create_subagent_tool("bg_agent", {
      description = "bg agent",
      system_prompt = "You are a bg agent",
      tools = {},
    }, { async_delivery = true })

    local captured = nil
    t.cmds[1]({ chat = parent }, { task = "do it" }, {
      output_cb = function(result) captured = result end,
    })

    -- The tool must have released immediately
    _G.captured_status = captured and captured.status
    _G.data_is_string = type(captured and captured.data) == "string"
    _G.data_mentions_subagent_result = captured and captured.data
      and captured.data:find("[subagent_result id=", 1, true) ~= nil
    local id, st = next(parent._subagents)
    _G.state_config_async = st and st.config and st.config.async
    _G.subagent_id = id
  ]])
  h.eq("success", child.lua_get([[_G.captured_status]]), "output_cb must have fired with success")
  h.eq(true, child.lua_get([[_G.data_is_string]]), "dispatch marker must be a string")
  h.eq(
    true,
    child.lua_get([[_G.data_mentions_subagent_result]]),
    "marker must mention the result tag"
  )
  h.eq(true, child.lua_get([[_G.state_config_async]]), "subagent state must be flagged async")
end

T["async_delivery"]["dispatch"]["blocking tool does NOT call output_cb immediately"] = function()
  child.lua([[
    local tool = require("codecompanion._extensions.subagents.tool")

    local parent = _G.make_async_parent()

    local t = tool.create_subagent_tool("blk_agent", {
      description = "blocking agent",
      system_prompt = "You are a blocking agent",
      tools = {},
    }, { async_delivery = false })

    local captured = nil
    t.cmds[1]({ chat = parent }, { task = "do it" }, {
      output_cb = function(result) captured = result end,
    })

    -- In blocking mode output_cb is stored as completion_callback, not called now
    _G.called_now = captured ~= nil
  ]])
  h.eq(false, child.lua_get([[_G.called_now]]), "blocking mode must not fire output_cb on dispatch")
end

T["async_delivery"]["dispatch"]["async dispatch does not hide the parent chat UI"] = function()
  child.lua([[
    local api = vim.api
    local bufnr = api.nvim_create_buf(false, true)
    local parent = _G.make_async_parent()
    local hides, opens = 0, 0
    parent.ui = {
      hide = function() hides = hides + 1 end,
      open = function() opens = opens + 1 end,
    }
    parent.bufnr = bufnr

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("ui_agent", {
      description = "ui", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })

    _G.hides = hides
    _G.opens = opens
  ]])
  h.eq(0, child.lua_get([[_G.hides]]), "async dispatch must not hide the parent chat UI")
  h.eq(0, child.lua_get([[_G.opens]]), "async dispatch must not open the parent chat UI either")
end

T["async_delivery"]["dispatch"]["blocking dispatch hides the parent chat UI"] = function()
  child.lua([[
    local parent = _G.make_async_parent()
    local hides = 0
    parent.ui = { hide = function() hides = hides + 1 end, open = function() end }

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("ui_blk_agent", {
      description = "ui blk", system_prompt = "p", tools = {},
    }, { async_delivery = false })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })

    _G.hides = hides
  ]])
  h.eq(1, child.lua_get([[_G.hides]]), "blocking dispatch must hide the parent chat UI")
end

T["async_delivery"]["dispatch"]["async completion does not open the parent chat UI while it is busy"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()
    parent.current_request = {} -- busy: open must be suppressed
    local opens = 0
    parent.ui = { hide = function() end, open = function() opens = opens + 1 end }

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("ui_done_agent", {
      description = "ui done", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    manager:complete_subagent(parent, id, "DONE", false)

    _G.opens = opens
  ]])
  h.eq(
    0,
    child.lua_get([[_G.opens]]),
    "async completion must not open the parent chat UI while it is busy"
  )
end

T["async_delivery"]["delivery"] = new_set()

T["async_delivery"]["delivery"]["result delivered immediately when parent is idle"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("imm_agent", {
      description = "imm", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    -- Parent is idle -> completion should deliver immediately (no ChatDone needed)
    manager:complete_subagent(parent, id, "IMMEDIATE-RESULT", false)

    _G.submitted = parent.submitted
    _G.buf_count = #parent.buf_messages
    _G.msg_count = #parent.messages
    _G.msg0 = parent.messages[1] and parent.messages[1].content
    _G.buf0 = parent.buf_messages[1] and parent.buf_messages[1].content
  ]])
  h.eq(1, child.lua_get([[_G.submitted]]), "idle parent should be re-submitted once")
  h.eq(1, child.lua_get([[_G.buf_count]]), "one buffer message added")
  h.eq(1, child.lua_get([[_G.msg_count]]), "one chat message added")
  h.eq(true, child.lua_get([[_G.msg0 and _G.msg0:find("[subagent_result id=", 1, true) ~= nil]]))
  h.eq(true, child.lua_get([[_G.msg0 and _G.msg0:find("IMMEDIATE-RESULT", 1, true) ~= nil]]))
end

T["async_delivery"]["delivery"]["result queued (not delivered) when parent is busy"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()
    parent.current_request = {} -- busy

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("busy_agent", {
      description = "busy", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    manager:complete_subagent(parent, id, "QUEUED-RESULT", false)

    _G.submitted = parent.submitted -- must be 0 while busy
    _G.msg_count = #parent.messages
  ]])
  h.eq(0, child.lua_get([[_G.submitted]]), "busy parent must not be submitted immediately")
  h.eq(0, child.lua_get([[_G.msg_count]]), "result must be queued, not delivered yet")
end

T["async_delivery"]["delivery"]["error result is delivered with an ERROR marker"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("err_agent", {
      description = "err", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    manager:complete_subagent(parent, id, "SOMETHING WENT WRONG", true)

    _G.msg0 = parent.messages[1] and parent.messages[1].content
    _G.buf0 = parent.buf_messages[1] and parent.buf_messages[1].content
  ]])
  h.eq(
    true,
    child.lua_get([[_G.msg0 and _G.msg0:find("[subagent_result id=", 1, true) ~= nil]]),
    "error delivery must carry the result tag"
  )
  h.eq(
    true,
    child.lua_get([[_G.msg0 and _G.msg0:find("[ERROR]", 1, true) ~= nil]]),
    "error delivery must be marked [ERROR]"
  )
  h.eq(
    true,
    child.lua_get([[_G.msg0 and _G.msg0:find("SOMETHING WENT WRONG", 1, true) ~= nil]]),
    "error delivery must contain the error text"
  )
  h.eq(
    true,
    child.lua_get([[_G.buf0 and _G.buf0:find("[ERROR]", 1, true) ~= nil]]),
    "buffer line must be marked [ERROR] too"
  )
end

T["async_delivery"]["delivery"]["success result is delivered without an ERROR marker"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("ok_agent", {
      description = "ok", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    manager:complete_subagent(parent, id, "FINE-RESULT", false)

    _G.msg0 = parent.messages[1] and parent.messages[1].content
  ]])
  h.eq(true, child.lua_get([[_G.msg0 and _G.msg0:find("FINE-RESULT", 1, true) ~= nil]]))
  h.eq(
    true,
    child.lua_get([[_G.msg0:find("[ERROR]", 1, true) == nil]]),
    "a successful delivery must not carry the ERROR marker"
  )
end

T["async_delivery"]["delivery"]["delivery autocmd is removed when the parent buffer is deleted"] = function()
  child.lua([[
    local api = vim.api
    local before = #api.nvim_get_autocmds({ event = "User", pattern = "CodeCompanionChatDone" })

    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()
    parent.current_request = {} -- busy: completion queues and the listener must be armed
    local bufnr = parent.bufnr

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("leak_agent", {
      description = "leak", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    manager:complete_subagent(parent, id, "LEAK-BODY", false)

    -- The listener must be registered now
    local after_start = #api.nvim_get_autocmds({ event = "User", pattern = "CodeCompanionChatDone" })
    _G.listener_armed = after_start > before

    -- Parent buffer dies -> listener must be cleaned up
    api.nvim_buf_delete(bufnr, { force = true })
    vim.wait(500) -- allow vim.schedule cleanup to run

    local after_delete = #api.nvim_get_autocmds({ event = "User", pattern = "CodeCompanionChatDone" })
    _G.listener_removed = after_delete == before
    _G.delta = after_delete - before
  ]])
  h.eq(
    true,
    child.lua_get([[_G.listener_armed]]),
    "the delivery listener must be registered on first async completion"
  )
  h.eq(
    true,
    child.lua_get([[_G.listener_removed]]),
    "the delivery listener must be removed when the parent buffer dies"
  )
end

T["async_delivery"]["delivery"]["parent buffer gone drops the result cleanly"] = function()
  child.lua([[
    local api = vim.api
    local manager = require("codecompanion._extensions.subagents.manager")

    -- Build a parent, capture its real bufnr, then delete the buffer
    local parent = _G.make_async_parent()
    local bufnr = parent.bufnr
    parent.current_request = {} -- force queue path (avoid immediate delivery before delete)

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("gone_agent", {
      description = "gone", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    st.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }

    api.nvim_buf_delete(bufnr, { force = true }) -- parent buffer dies

    -- complete must not error and must not deliver
    local ok = pcall(function()
      manager:complete_subagent(parent, id, "SHOULD-DROP", false)
    end)
    _G.no_error = ok
    _G.msg_count = #parent.messages
    _G.submitted = parent.submitted
  ]])
  h.eq(true, child.lua_get([[_G.no_error]]), "completion with a dead buffer must not error")
  h.eq(0, child.lua_get([[_G.msg_count]]), "nothing delivered to a dead buffer")
  h.eq(0, child.lua_get([[_G.submitted]]), "no submit against a dead buffer")
end

T["async_delivery"]["integration"] = new_set()

T["async_delivery"]["integration"]["ChatDone delivers queued results in FIFO order"] = function()
  child.lua([[
    require("codecompanion").setup(require("tests.config"))
    local Chat = require("codecompanion.interactions.chat")

    -- Real parent chat so ChatDone / Chat.buf_get_chat behave like production
    local chat = Chat.new({
      adapter = require("codecompanion.config").adapters.http.test_adapter,
      title = "Async Parent",
      tools = {},
      auto_submit = false,
    })
    _G.chat_holder = chat
    chat.current_request = {} -- busy: completions must queue, not deliver
    -- Replace the real submit with a recorder: the delivery pipeline is what
    -- is under test; a real HTTP submit against the fake adapter URL would add
    -- uncontrolled network timing and spurious ChatDone events.
    chat.submit = function(self, opts) self.submitted = (self.submitted or 0) + 1 end

    local manager = require("codecompanion._extensions.subagents.manager")
    local tool = require("codecompanion._extensions.subagents.tool")

    for _, name in ipairs({ "fifo_a", "fifo_b" }) do
      local t = tool.create_subagent_tool(name, {
        description = name, system_prompt = "p", tools = {},
      }, { async_delivery = true })
      t.cmds[1]({ chat = chat }, { task = "task" }, { output_cb = function() end })
      for _, state in pairs(chat._subagents) do
        if state.config and state.config.name == name then
          -- Inject a mock subagent chat so complete_subagent can run
          state.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }
        end
      end
    end

    -- Complete A then B: queue order must be A, B. complete_subagent is keyed
    -- by subagent_id (name .. "_" .. counter), so look each one up by name.
    for _, pair in ipairs({ { "fifo_a", "FIRST" }, { "fifo_b", "SECOND" } }) do
      for id, state in pairs(chat._subagents) do
        if state.config and state.config.name == pair[1] then
          manager:complete_subagent(chat, id, pair[2] .. "-BODY", false)
        end
      end
    end

    _G.msg_before = #chat.messages
    _G.parent_bufnr = chat.bufnr
  ]])

  local msg_before = child.lua_get([[_G.msg_before]])
  h.eq(
    true,
    child.lua_get([[_G.msg_before == #_G.chat_holder.messages]]),
    "nothing may be delivered while the chat is busy"
  )

  -- One "turn finished" for the real chat: the core clears current_request in
  -- Chat:done() before Chat:finish() fires ChatDone, so mirroring that order
  -- is the production-equivalent idle signal.
  local function fire_chat_done()
    child.lua([[
      _G.chat_holder.current_request = nil
      require("codecompanion.utils").fire("ChatDone", { bufnr = _G.chat_holder.bufnr })
    ]])
  end

  -- First ChatDone delivers exactly the first queued result
  fire_chat_done()
  h.eq(
    true,
    h.wait_for(function()
      return child.lua_get([[_G.msg_before + 1]]) == child.lua_get([[#_G.chat_holder.messages]])
    end, 3000),
    "one ChatDone must deliver exactly one queued result"
  )
  h.eq(
    true,
    child.lua_get(
      [[_G.chat_holder.messages[#_G.chat_holder.messages].content:find("FIRST-BODY", 1, true) ~= nil]]
    ),
    "first delivery must contain the first result"
  )

  -- Second ChatDone delivers the second queued result
  fire_chat_done()
  h.eq(
    true,
    h.wait_for(function()
      return child.lua_get([[_G.msg_before + 2]]) == child.lua_get([[#_G.chat_holder.messages]])
    end, 3000),
    "second ChatDone must deliver the second queued result"
  )
  h.eq(
    true,
    child.lua_get(
      [[_G.chat_holder.messages[#_G.chat_holder.messages].content:find("SECOND-BODY", 1, true) ~= nil]]
    ),
    "second delivery must contain the second result"
  )

  -- Third ChatDone with an empty queue must not deliver anything
  child.lua([[
    require("codecompanion.utils").fire("ChatDone", { bufnr = _G.chat_holder.bufnr })
    vim.wait(200)
  ]])
  h.eq(
    true,
    child.lua_get([[_G.msg_before + 2]]) == child.lua_get([[#_G.chat_holder.messages]]),
    "an empty queue must not produce a phantom delivery"
  )
end

T["async_delivery"]["integration"]["ChatDone from another chat does not deliver this chat's results"] = function()
  child.lua([[
    require("codecompanion").setup(require("tests.config"))
    local Chat = require("codecompanion.interactions.chat")

    local a = Chat.new({
      adapter = require("codecompanion.config").adapters.http.test_adapter,
      title = "Parent A", tools = {}, auto_submit = false,
    })
    local b = Chat.new({
      adapter = require("codecompanion.config").adapters.http.test_adapter,
      title = "Parent B", tools = {}, auto_submit = false,
    })
    _G.chat_a = a
    _G.chat_b = b
    a.current_request = {} -- busy: completion queues

    local manager = require("codecompanion._extensions.subagents.manager")
    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("xbuf_agent", {
      description = "x", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = a }, { task = "task" }, { output_cb = function() end })
    for _, state in pairs(a._subagents) do
      state.subagent_chat = { bufnr = 9000, ui = { hide = function() end } }
    end
    local id
    for k, state in pairs(a._subagents) do
      if state.config and state.config.name == "xbuf_agent" then
        id = k
      end
    end
    manager:complete_subagent(a, id, "XBUF-BODY", false)

    _G.a_before = #a.messages
    _G.b_before = #b.messages
  ]])

  -- Fire ChatDone with B's bufnr while A has a queued result
  child.lua([[
    require("codecompanion.utils").fire("ChatDone", { bufnr = _G.chat_b.bufnr })
    vim.wait(200)
  ]])
  h.eq(
    true,
    child.lua_get([[_G.a_before]]) == child.lua_get([[#_G.chat_a.messages]]),
    "a ChatDone from another chat must not deliver this chat's result"
  )
  h.eq(
    true,
    child.lua_get([[_G.b_before]]) == child.lua_get([[#_G.chat_b.messages]]),
    "the other chat must not receive this chat's result either"
  )
end

T["async_delivery"]["stale windows"] = new_set()

T["async_delivery"]["stale windows"]["completion does not error when the subagent window was closed"] = function()
  child.lua([[
    local manager = require("codecompanion._extensions.subagents.manager")
    local parent = _G.make_async_parent()

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("stale_agent", {
      description = "stale", system_prompt = "p", tools = {},
    }, { async_delivery = true })
    t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    local id, st = next(parent._subagents)
    -- The user closed the subagent chat window. The core UI keeps the stale
    -- winnr and hide() raises E472 on it.
    st.subagent_chat = {
      bufnr = 9000,
      ui = {
        is_visible = function(self) return false end,
        hide = function(self) error("Invalid window id: 1015", 0) end,
        open = function() end,
      },
    }

    local ok, err = pcall(function()
      manager:complete_subagent(parent, id, "STALE-RESULT", false)
    end)
    _G.no_error = ok
    _G.err = tostring(err)
    _G.msg0 = parent.messages[1] and parent.messages[1].content
  ]])
  h.eq(
    true,
    child.lua_get([[_G.no_error]]),
    "completion must not error on a closed subagent window (err: "
      .. tostring(child.lua_get([[_G.err]]))
      .. ")"
  )
  h.eq(
    true,
    child.lua_get([[_G.msg0 and _G.msg0:find("STALE-RESULT", 1, true) ~= nil]]),
    "the result must still be delivered"
  )
end

T["async_delivery"]["stale windows"]["blocking dispatch does not error when the parent window was closed"] = function()
  child.lua([[
    local parent = _G.make_async_parent()
    parent.ui = {
      is_visible = function(self) return false end,
      hide = function(self) error("Invalid window id: 1016", 0) end,
      open = function() end,
    }

    local tool = require("codecompanion._extensions.subagents.tool")
    local t = tool.create_subagent_tool("stale_blk_agent", {
      description = "stale blk", system_prompt = "p", tools = {},
    }, { async_delivery = false })

    local ok, err = pcall(function()
      t.cmds[1]({ chat = parent }, { task = "task" }, { output_cb = function() end })
    end)
    _G.no_error = ok
    _G.err = tostring(err)
    _G.started = parent._subagents and next(parent._subagents) ~= nil
  ]])
  h.eq(
    true,
    child.lua_get([[_G.no_error]]),
    "blocking dispatch must not error on a closed parent window (err: "
      .. tostring(child.lua_get([[_G.err]]))
      .. ")"
  )
  h.eq(true, child.lua_get([[_G.started]]), "the subagent must still start")
end

return T
