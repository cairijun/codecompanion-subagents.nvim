---@class CodeCompanion.SubAgents.Manager
---@field _subagent_names string[]
---@field _powers table

local M = {}

-- Global config (kept at module level)
M._subagent_names = {}
M._powers = {}

local api = vim.api

---Results awaiting delivery in async_delivery mode.
-- [parent_chat] = { { subagent_id = string, name = string, result = string, is_error = boolean|nil }, ... }
-- Keyed by the chat object itself: core chat ids are random small integers
-- (collision-prone) and the chat table is unique for the life of the buffer.
local pending_results = {}

local Approvals = require("codecompanion.interactions.chat.tools.approvals")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

---SubAgent base prompt - always injected to clarify execution context
---@type string
local SUBAGENT_BASE_PROMPT =
  [[You are running as a SubAgent. You should execute the task assigned to you by the main agent, but not the other tasks.
You have access to the `complete_subagent` tool. When you have completed your task, you MUST call the `complete_subagent` tool to return your results to the main agent.
DO NOT output your results directly in the response. ALL results MUST be passed as a parameter to the `complete_subagent` tool.]]

---Whether a parent chat is free to be woken up for a delivery
---@param chat CodeCompanion.Chat
---@return boolean
local function chat_is_idle(chat)
  if not chat or not chat.bufnr or not api.nvim_buf_is_valid(chat.bufnr) then
    return false
  end
  if chat.current_request ~= nil then
    return false
  end
  if chat._compacting then
    return false
  end
  -- A live tool orchestrator (even with an empty queue) will auto-submit the
  -- chat right after the current batch ends, so delivering now would race it
  if chat.tool_orchestrator ~= nil then
    return false
  end
  return true
end

---Deliver the next pending result to an idle parent chat
---@param chat CodeCompanion.Chat
---@return nil
local function deliver_next(chat)
  if not chat_is_idle(chat) then
    return
  end
  local queue = pending_results[chat]
  local item = queue and queue[1] or nil
  if not item then
    return
  end
  table.remove(queue, 1)
  if not next(queue) then
    pending_results[chat] = nil
  end

  local tag = string.format("[subagent_result id=%s]", item.subagent_id)
  if item.is_error then
    tag = tag .. " [ERROR]"
  end
  chat:add_buf_message({
    role = config.constants.USER_ROLE,
    content = tag,
  })
  chat:add_message({
    role = config.constants.USER_ROLE,
    content = string.format("%s\n%s", tag, item.result),
  })
  chat:submit({ auto_submit = true })

  log:info("Delivered subagent result for %s to parent chat", item.subagent_id)
end

---Enqueue a completed subagent result and deliver it on the parent chat's next idle point
---@param chat CodeCompanion.Chat
---@param subagent_id string
---@param name string
---@param result string
---@param is_error boolean|nil
local function request_delivery(chat, subagent_id, name, result, is_error)
  if not chat or not chat.bufnr or not api.nvim_buf_is_valid(chat.bufnr) then
    log:warn("Parent chat buffer is gone, dropping subagent result for %s", subagent_id)
    return
  end

  local queue = pending_results[chat]
  if not queue then
    queue = {}
    pending_results[chat] = queue
  end
  table.insert(queue, {
    subagent_id = subagent_id,
    name = name,
    result = result,
    is_error = is_error,
  })

  -- Deliver on the parent chat's next idle point. The event fires when a chat
  -- turn finishes and the buffer is ready for input, which is the only safe
  -- moment to inject a message and (re)submit the chat. The listener lives in
  -- a per-chat augroup that deletes itself when the buffer dies, so no
  -- global autocmd leaks for closed chats.
  -- Note: nvim_buf_delete fires BufWipeout (not BufDelete, which only
  -- :bdelete raises), so the self-cleanup listens for BufWipeout.
  local aug =
    api.nvim_create_augroup("CodeCompanionSubAgentsDelivery:" .. chat.bufnr, { clear = true })
  api.nvim_create_autocmd("BufWipeout", {
    group = aug,
    buffer = chat.bufnr,
    callback = function()
      -- Parent chat is gone: drop queued results and the delivery listener
      pending_results[chat] = nil
      vim.schedule(function()
        pcall(api.nvim_del_augroup_by_id, aug)
      end)
    end,
  })
  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatDone",
    callback = function(ev)
      if not ev.data or ev.data.bufnr ~= chat.bufnr then
        return
      end
      vim.schedule(function()
        if not api.nvim_buf_is_valid(chat.bufnr) then
          return
        end
        -- Make sure the chat object is still the registered one for this buffer
        local Chat = require("codecompanion.interactions.chat")
        local current = Chat.buf_get_chat(chat.bufnr)
        if current ~= chat then
          return
        end
        deliver_next(current)
      end)
    end,
  })

  if chat_is_idle(chat) then
    -- No LLM turn and no pending tool batch: deliver right away
    deliver_next(chat)
  else
    log:info("Queued subagent result for %s (parent chat busy)", subagent_id)
  end
end

---Get or create subagent state for a chat
---@param chat CodeCompanion.Chat
---@return table
local function get_or_create_state(chat, subagent_id)
  if not chat._subagents then
    chat._subagents = {}
  end
  if not chat._subagents[subagent_id] then
    chat._subagents[subagent_id] = {
      subagent_chat = nil,
      pending_result = nil,
      completion_callback = nil,
      config = nil,
    }
  end
  return chat._subagents[subagent_id]
end

---Get subagent state for a chat
---@param chat CodeCompanion.Chat
---@return table|nil
local function get_state(chat, subagent_id)
  if not chat._subagents then
    return nil
  end
  return chat._subagents[subagent_id]
end

---Set the list of subagent names for filtering
---@param names string[]
---@return nil
function M:set_subagent_names(names)
  M._subagent_names = names or {}
end

---Set the powers configuration
---@param powers table
---@return nil
function M:set_powers(powers)
  M._powers = powers or {}
end

---Get filtered tools for a sub-agent
---Excludes other subagent tools and includes complete_subagent
---@param tools string[] List of tool names requested
---@return string[] Filtered list of tool names
function M:get_subagent_tools(tools)
  local filtered = {}
  local subagent_names = M._subagent_names or {}

  for _, tool_name in ipairs(tools or {}) do
    -- Exclude if it's a subagent tool (check against prefixed names)
    local is_subagent = false
    for _, name in ipairs(subagent_names) do
      if tool_name == "subagent_" .. name then
        is_subagent = true
        break
      end
    end

    if not is_subagent then
      table.insert(filtered, tool_name)
    end
  end

  -- Always include complete_subagent
  if not vim.tbl_contains(filtered, "complete_subagent") then
    table.insert(filtered, "complete_subagent")
  end

  return filtered
end

---Get inherited tools from parent chat
---Excludes subagent tools to prevent recursion
---@param parent_chat CodeCompanion.Chat
---@return string[]
function M:get_inherited_tools(parent_chat)
  if not parent_chat or not parent_chat.tool_registry then
    log:warn("Parent chat or tool registry not found, cannot inherit tools")
    return {}
  end

  local in_use = parent_chat.tool_registry.in_use or {}
  local tools = {}

  for tool_name, _ in pairs(in_use) do
    -- Exclude subagent tools to prevent recursion
    if not tool_name:match("^subagent_") then
      table.insert(tools, tool_name)
    end
  end

  log:info("Inherited tools from parent chat: %s", tools)
  return tools
end

---Get inherited MCP servers from parent chat
---@param parent_chat CodeCompanion.Chat
---@return string[]
function M:get_inherited_mcp_servers(parent_chat)
  if not parent_chat or not parent_chat.tool_registry then
    log:warn("Parent chat or tool registry not found, cannot inherit MCP servers")
    return {}
  end

  local groups = parent_chat.tool_registry.groups or {}
  local mcp_servers = {}
  local mcp_prefix = "mcp:"

  for group_name, _ in pairs(groups) do
    if group_name:sub(1, #mcp_prefix) == mcp_prefix then
      local server_name = group_name:sub(#mcp_prefix + 1)
      table.insert(mcp_servers, server_name)
    end
  end

  log:info("Inherited MCP servers from parent chat: %s", mcp_servers)
  return mcp_servers
end

---Get inherited messages from parent chat
---Replaces the tool call message with a context message
---@param parent_chat CodeCompanion.Chat
---@param subagent_name string
---@param task string
---@return CodeCompanion.Chat.Messages
function M:get_inherited_messages(parent_chat, subagent_name, task)
  if not parent_chat or not parent_chat.messages then
    log:warn("Parent chat or messages not found, cannot inherit messages")
    return {}
  end

  local messages = parent_chat.messages
  if #messages == 0 then
    log:warn("Parent chat has no messages to inherit")
    return {}
  end

  local fork_msg_idx
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call["function"] and call["function"].name == ("subagent_" .. subagent_name) then
          fork_msg_idx = i
          break
        end
      end
      if fork_msg_idx then
        break
      end
    end
  end
  if fork_msg_idx == nil then
    log:error("No branching message found for subagent_%s", subagent_name)
    error("Precondition violated: tool call message not found in parent chat")
  end

  local filtered_messages = vim
    .iter(messages)
    :take(fork_msg_idx - 1)
    :filter(function(msg)
      return msg.role ~= "system"
    end)
    :map(function(msg)
      return vim.deepcopy(msg)
    end)
    :totable()

  if #filtered_messages == 0 then
    log:warn("No non-system messages to inherit")
  end

  local context_content = string.format(
    [[--- CONTEXT FORKED AT THIS POINT ---
YOU ARE NOW EXECUTING AS A FORKING SUBAGENT. ALL THE PREVIOUS MESSAGES ARE INTERACTIONS BETWEEN THE USER AND THE MAIN AGENT (NOT YOU). YOU SHOULD USE THIS CONTEXT TO COMPLETE YOUR TASK DESCRIBED BELOW.

<your_task>
%s
</your_task>]],
    task
  )
  table.insert(filtered_messages, {
    role = config.constants.USER_ROLE,
    content = context_content,
  })

  log:info("Inherited %d messages from parent chat", #filtered_messages)
  return filtered_messages
end

---Start a sub-agent
---@param parent_chat CodeCompanion.Chat
---@param subagent_config table
---@param task string
---@param context table|nil
---@return string subagent_id
function M:start_subagent(parent_chat, subagent_config, task, context)
  -- Check if parent_chat is already a subagent chat (prevent nesting)
  if parent_chat and parent_chat._subagent_id then
    log:error("Cannot start a subagent from another subagent chat")
    error("YOU ARE THE SUB-AGENT. YOU ARE NOT ALLOWED TO START ANOTHER SUB-AGENT.")
  end

  -- Generate unique subagent_id for concurrent subagent support
  if not parent_chat._subagent_counter then
    parent_chat._subagent_counter = 0
  end
  parent_chat._subagent_counter = parent_chat._subagent_counter + 1
  local subagent_id = subagent_config.name .. "_" .. parent_chat._subagent_counter

  log:info("Starting subagent: %s", subagent_id)

  -- Get or create state for this specific subagent
  local state = get_or_create_state(parent_chat, subagent_id)

  -- Store config in chat state
  state.config = subagent_config

  -- Tools
  local tools = subagent_config.tools
  if tools == "inherit" then
    tools = self:get_inherited_tools(parent_chat)
  end

  -- MCP servers
  local mcp_servers = subagent_config.mcp_servers
  if mcp_servers == "inherit" then
    mcp_servers = self:get_inherited_mcp_servers(parent_chat)
  end

  -- Power resolution: call arg power > default_power > parent chat adapter
  local power = subagent_config.power
  local default_power = subagent_config.default_power
  local supports_power = subagent_config.adapter == nil
    and subagent_config.context_mode ~= "inherit"

  if power ~= nil then
    if not supports_power then
      error("subagent_" .. subagent_config.name .. " does not support power override")
    end
    if M._powers[power] == nil then
      error("unknown power level: " .. power)
    end
  end

  if power and M._powers[power] then
    subagent_config.adapter = M._powers[power].adapter
  elseif default_power and M._powers[default_power] then
    subagent_config.adapter = M._powers[default_power].adapter
  end

  -- Adapter: nil or "inherit" falls back to parent chat's adapter
  local adapter = subagent_config.adapter
  if adapter == nil or adapter == "inherit" then
    adapter = parent_chat.adapter
  end

  -- Hide parent chat UI (blocking mode only: the parent chat sits idle while
  -- the subagent works. In async mode the main agent keeps working, so the
  -- parent chat must stay as it is). The core UI can hold a stale winnr once
  -- the window is closed, so only hide a visible window and pcall as defense
  -- in depth.
  if
    parent_chat
    and parent_chat.ui
    and not subagent_config.async
    and (not parent_chat.ui.is_visible or parent_chat.ui:is_visible())
  then
    pcall(parent_chat.ui.hide, parent_chat.ui)
  end

  -- Get filtered tools
  local filtered_tools = self:get_subagent_tools(tools)

  -- Determine context mode
  local context_mode = subagent_config.context_mode or "explicit"

  -- Build messages based on context_mode
  local messages
  if context_mode == "inherit" then
    -- Inherit mode: get messages from parent chat
    messages = self:get_inherited_messages(parent_chat, subagent_config.name, task)
    if #messages == 0 then
      -- Fallback to explicit mode if no messages to inherit
      log:warn("No messages to inherit, falling back to explicit mode")
      messages = {
        {
          role = config.constants.USER_ROLE,
          content = task,
        },
      }
    end
  else
    -- Explicit mode: build task message with context
    local task_content = task
    if context and type(context) == "table" and not vim.tbl_isempty(context) then
      task_content = string.format("%s\n\n<context>\n%s</context>", task, vim.inspect(context))
    end
    messages = {
      {
        role = config.constants.USER_ROLE,
        content = task_content,
      },
    }
  end

  -- Inject result_spec into the last user message
  local result_spec = subagent_config.result_spec
  if result_spec then
    -- Find the last user message and append result_spec
    for i = #messages, 1, -1 do
      if messages[i].role == config.constants.USER_ROLE then
        messages[i].content = string.format(
          "%s\n\nUse @{complete_subagent} to response you result:\n<expected-result>\n%s\n</expected-result>",
          messages[i].content,
          result_spec
        )
        break
      end
    end
  end

  -- Create the subagent chat with messages
  -- This ensures ui:render creates proper buffer structure before tool_registry:add
  local Chat = require("codecompanion.interactions.chat")

  log:info(
    "Creating chat for subagent %s with tools: %s and MCP servers: %s",
    subagent_config.name,
    filtered_tools,
    mcp_servers
  )
  local ok, subagent_chat = pcall(Chat.new, {
    adapter = adapter,
    title = string.format("SubAgent: %s", subagent_config.name),
    tools = filtered_tools,
    mcp_servers = mcp_servers,
    messages = messages,
    auto_submit = false,
  })

  if not ok then
    log:error("Failed to create subagent chat: %s", subagent_chat)
    -- Restore parent chat UI on error (blocking mode hid it; async mode only
    -- if the chat is idle, otherwise we would interrupt the main agent).
    if parent_chat and parent_chat.ui then
      if not subagent_config.async or chat_is_idle(parent_chat) then
        pcall(parent_chat.ui.open, parent_chat.ui)
      end
    end
    if state.completion_callback then
      state.completion_callback("Error: Failed to create subagent chat", true)
      state.completion_callback = nil
    end
    error("Failed to create subagent chat: " .. tostring(subagent_chat))
  end

  -- Store subagent chat in parent chat state
  state.subagent_chat = subagent_chat

  -- Store parent chat reference in subagent chat for complete_tool
  subagent_chat._parent_chat = parent_chat

  -- Store subagent_id on subagent chat for complete_tool identification
  subagent_chat._subagent_id = subagent_id

  -- Register the completion callback: in async delivery mode the result is
  -- queued and delivered on the parent chat's next idle point. In blocking
  -- mode tool.lua installs its own output_cb-based callback after start.
  if subagent_config.async then
    state.completion_callback = function(result, is_error)
      request_delivery(parent_chat, subagent_id, subagent_config.name, result, is_error)
    end
  else
    state.completion_callback = nil
  end

  -- Apply approval mode
  local approval_mode = subagent_config.approval_mode or "isolated"
  if approval_mode ~= "isolated" then
    local parent_bufnr = parent_chat.bufnr
    local sub_bufnr = subagent_chat.bufnr

    if approval_mode == "inherit" then
      local parent_approvals = Approvals.list()[parent_bufnr]
      if parent_approvals then
        Approvals.list()[sub_bufnr] = vim.deepcopy(parent_approvals)
        log:info("Inherited approval state from parent chat (bufnr=%d)", parent_bufnr)
      else
        log:debug("No parent approval state to inherit (bufnr=%d)", parent_bufnr)
      end
    elseif approval_mode == "shared" then
      Approvals.list()[parent_bufnr] = Approvals.list()[parent_bufnr] or {}
      Approvals.list()[sub_bufnr] = Approvals.list()[parent_bufnr]
      log:info("Shared approval state with parent chat (bufnr=%d)", parent_bufnr)
    end
  end

  -- Handle system prompt based on replace_main_system_prompt flag
  local replace_main = subagent_config.replace_main_system_prompt or false

  if replace_main then
    -- Replace mode: clear default system prompt first
    subagent_chat:set_system_prompt("", { _meta = { tag = "system_prompt_from_config" } })
  end

  -- Set custom system prompt if provided (with unique tag)
  if subagent_config.system_prompt then
    subagent_chat:set_system_prompt(subagent_config.system_prompt, {
      visible = false,
      _meta = { tag = "subagent_system_prompt" },
    })
  end

  -- Always inject SubAgent base prompt
  subagent_chat:set_system_prompt(SUBAGENT_BASE_PROMPT, {
    visible = false,
    _meta = { tag = "subagent_base_prompt" },
  })

  -- Submit the chat to start the LLM interaction
  vim.schedule(function()
    subagent_chat:submit()
  end)

  log:debug("Subagent started: %s", subagent_config.name)

  return subagent_id
end

---Complete the sub-agent
---@param parent_chat CodeCompanion.Chat
---@param result string
---@param is_error boolean|nil
---@return nil
function M:complete_subagent(parent_chat, subagent_id, result, is_error)
  log:info("Completing subagent %s", subagent_id)

  -- Get state from parent chat
  local state = get_state(parent_chat, subagent_id)
  if not state or not state.subagent_chat then
    log:error("No active subagent found for id: %s", subagent_id)
    if state and state.completion_callback then
      state.completion_callback("Error: No active subagent found to complete", true)
      state.completion_callback = nil
    end
    return
  end

  -- Store result
  state.pending_result = result

  -- Save bufnr and clean up approval cache before clearing state.
  -- The core UI keeps the winnr after the window is closed (it has no
  -- WinClosed autocmd), so hide() can raise "Invalid window id" for a
  -- subagent chat whose window the user closed. Only hide a visible window;
  -- the call is pcall-guarded as defense in depth.
  local sub_bufnr = state.subagent_chat.bufnr
  local sub_ui = state.subagent_chat.ui
  if sub_ui and sub_ui.is_visible and sub_ui:is_visible() then
    pcall(sub_ui.hide, sub_ui)
  end
  if sub_bufnr then
    Approvals:reset(sub_bufnr)
  end
  state.subagent_chat = nil

  -- Restore parent chat UI (blocking mode hid it; async mode only when the
  -- chat is idle and no other subagents are still running). open() is safe
  -- on an invisible window (it creates a new one); pcall guards the
  -- edge case of a stale winnr.
  if parent_chat and parent_chat.ui then
    local async = state.config and state.config.async == true
    if not async or (chat_is_idle(parent_chat) and not self:is_active(parent_chat)) then
      pcall(parent_chat.ui.open, parent_chat.ui)
    end
  end

  -- Call completion callback if set
  if state.completion_callback then
    state.completion_callback(result, is_error)
    state.completion_callback = nil
  end

  -- Clear config
  state.config = nil
end

---Check if a sub-agent is active
---@param chat CodeCompanion.Chat|nil
---@return boolean
function M:is_active(chat)
  if not chat or not chat._subagents then
    return false
  end
  for _, state in pairs(chat._subagents) do
    if state.subagent_chat ~= nil then
      return true
    end
  end
  return false
end

return M
