---@class CodeCompanion.SubAgents.Manager
---@field _subagent_names string[]

local M = {}

-- Global config (kept at module level)
M._subagent_names = {}

local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

---SubAgent base prompt - always injected to clarify execution context
---@type string
local SUBAGENT_BASE_PROMPT =
  [[You are running as a SubAgent. You have access to the `complete_subagent` tool.
When you have completed your task, call the `complete_subagent` tool to return your results to the main agent.
DO NOT output your results directly in the response. ALL results MUST be passed as a parameter to the `complete_subagent` tool.]]

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
    -- 排除 subagent 工具（避免递归）
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

---Deep copy a message table
---@param msg CodeCompanion.Chat.Message
---@return CodeCompanion.Chat.Message
local function deep_copy_message(msg)
  local copy = {}
  for k, v in pairs(msg) do
    if type(v) == "table" then
      copy[k] = vim.deepcopy(v)
    else
      copy[k] = v
    end
  end
  return copy
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

  -- 1. Deep copy parent messages
  local copied_messages = {}
  for _, msg in ipairs(messages) do
    table.insert(copied_messages, deep_copy_message(msg))
  end

  -- 2. Remove all system messages
  local filtered_messages = {}
  for _, msg in ipairs(copied_messages) do
    if msg.role ~= "system" then
      table.insert(filtered_messages, msg)
    end
  end

  if #filtered_messages == 0 then
    log:warn("No non-system messages to inherit")
    return {}
  end

  -- 3. Find the last message containing the subagent_xxx tool call
  local tool_call_prefix = "subagent_" .. subagent_name
  local tool_call_idx = nil

  for i = #filtered_messages, 1, -1 do
    local msg = filtered_messages[i]
    if msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call["function"] and call["function"].name == tool_call_prefix then
          tool_call_idx = i
          break
        end
      end
      if tool_call_idx then
        break
      end
    end
  end

  -- 4. Replace the tool call message with context message
  if tool_call_idx then
    local context_content = string.format(
      [[You are now executing as a SubAgent.

Task: %s

Continue from the conversation context above.]],
      task
    )
    filtered_messages[tool_call_idx] = {
      role = config.constants.USER_ROLE,
      content = context_content,
    }
  else
    log:warn(
      "Could not find tool call message for subagent_%s, using original messages",
      subagent_name
    )
  end

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
  log:debug("Starting subagent: %s", subagent_config.name)

  -- Generate unique subagent_id for concurrent subagent support
  if not parent_chat._subagent_counter then
    parent_chat._subagent_counter = 0
  end
  parent_chat._subagent_counter = parent_chat._subagent_counter + 1
  local subagent_id = subagent_config.name .. "_" .. parent_chat._subagent_counter

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

  -- Adapter: nil or "inherit" falls back to parent chat's adapter
  local adapter = subagent_config.adapter
  if adapter == nil or adapter == "inherit" then
    adapter = parent_chat.adapter
  end

  -- Hide parent chat UI
  if parent_chat and parent_chat.ui then
    parent_chat.ui:hide()
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
      task_content = string.format("%s\n\nContext:\n%s", task, vim.inspect(context))
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
        messages[i].content =
          string.format("%s\n\n[Expected Result]\n%s", messages[i].content, result_spec)
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
    -- Restore parent chat UI on error
    if parent_chat and parent_chat.ui then
      parent_chat.ui:open()
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
  log:debug("Completing subagent %s with result: %s", subagent_id, result)

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
  -- Reset state
  state.subagent_chat.ui:hide()
  state.subagent_chat = nil

  -- Restore parent chat UI
  if parent_chat and parent_chat.ui then
    parent_chat.ui:open()
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
