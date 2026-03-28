---@class CodeCompanion.SubAgents.Manager
---@field _subagent_names string[]

local M = {}

-- Global config (kept at module level)
M._subagent_names = {}

local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

---Get or create subagent state for a chat
---@param chat CodeCompanion.Chat
---@return table
local function get_state(chat)
  if not chat._subagents then
    chat._subagents = {
      subagent_chat = nil,
      pending_result = nil,
      completion_callback = nil,
      config = nil,
    }
  end
  return chat._subagents
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

---Start a sub-agent
---@param parent_chat CodeCompanion.Chat
---@param subagent_config table
---@param task string
---@param context table|nil
---@return nil
function M:start_subagent(parent_chat, subagent_config, task, context)
  log:debug("Starting subagent: %s", subagent_config.name)

  -- Get or create state for this chat
  local state = get_state(parent_chat)

  -- Store config in chat state
  state.config = subagent_config

  -- Hide parent chat UI
  if parent_chat and parent_chat.ui then
    parent_chat.ui:hide()
  end

  -- Get filtered tools
  local filtered_tools = self:get_subagent_tools(subagent_config.tools)

  -- Build the task message with context if provided
  local task_content = task
  if context and type(context) == "table" and not vim.tbl_isempty(context) then
    task_content = string.format("%s\n\nContext:\n%s", task, vim.inspect(context))
  end

  -- Create the subagent chat with task message
  -- This ensures ui:render creates proper buffer structure before tool_registry:add
  local Chat = require("codecompanion.interactions.chat")

  local ok, subagent_chat = pcall(function()
    return Chat.new({
      adapter = parent_chat.adapter,
      title = string.format("SubAgent: %s", subagent_config.name),
      tools = filtered_tools,
      mcp_servers = subagent_config.mcp_servers,
      callbacks = {},
      messages = {
        {
          role = config.constants.USER_ROLE,
          content = task_content,
        },
      },
      auto_submit = false,
    })
  end)

  if not ok or not subagent_chat then
    log:error("Failed to create subagent chat: %s", subagent_chat)
    -- Restore parent chat UI on error
    if parent_chat and parent_chat.ui then
      parent_chat.ui:open()
    end
    if state.completion_callback then
      state.completion_callback("Error: Failed to create subagent chat", true)
      state.completion_callback = nil
    end
    return
  end

  -- Store subagent chat in parent chat state
  state.subagent_chat = subagent_chat

  -- Store parent chat reference in subagent chat for complete_tool
  subagent_chat._parent_chat = parent_chat

  -- Set custom system prompt (will replace the default one automatically)
  if subagent_config.system_prompt then
    subagent_chat:set_system_prompt(subagent_config.system_prompt, { visible = false })
  end

  -- Submit the chat to start the LLM interaction
  vim.schedule(function()
    subagent_chat:submit()
  end)

  log:debug("Subagent started: %s", subagent_config.name)
end

---Complete the sub-agent
---@param parent_chat CodeCompanion.Chat
---@param result string
---@param is_error boolean|nil
---@return nil
function M:complete_subagent(parent_chat, result, is_error)
  log:debug("Completing subagent with result: %s", result)

  -- Get state from parent chat
  local state = get_state(parent_chat)

  -- Store result
  state.pending_result = result
  -- Reset state
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
  return chat._subagents.subagent_chat ~= nil
end

return M
