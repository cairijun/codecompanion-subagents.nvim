---@class CodeCompanion.SubAgents.Extension
---@field setup fun(opts: table): nil
---@field exports table

local M = {}

-- Store subagent configurations
M._subagents = {}
M._opts = {}

---Validate powers configuration
---@param opts table
---@return nil
local function validate_powers_config(opts)
  local powers = opts.powers
  if powers == nil then
    return
  end
  if type(powers) ~= "table" then
    error("powers must be a table")
  end
  -- Empty table means "no powers defined", not an error
  if vim.tbl_count(powers) == 0 then
    return
  end
  for level, value in pairs(powers) do
    if type(level) ~= "string" or level == "" then
      error("powers.<level>: empty power level name")
    end
    if type(value) ~= "table" or value.adapter == nil then
      error("powers.<level>: missing or invalid adapter")
    end
    if type(value.adapter) ~= "string" and type(value.adapter) ~= "table" then
      error("powers.<level>: missing or invalid adapter")
    end
  end
  -- Validate default_power references in subagents (only when powers is non-empty)
  local subagents = opts.subagents or {}
  for name, subagent_config in pairs(subagents) do
    if subagent_config.default_power ~= nil then
      if powers[subagent_config.default_power] == nil then
        error("subagents." .. name .. ".default_power references unknown power: " .. subagent_config.default_power)
      end
      if subagent_config.adapter ~= nil then
        error("subagents." .. name .. " cannot set both adapter and default_power")
      end
      if subagent_config.context_mode == "inherit" then
        error("subagents." .. name .. " with context_mode=\"inherit\" cannot use default_power")
      end
    end
  end
end

---Setup the extension
---@param opts table
---@return nil
function M.setup(opts)
  opts = opts or {}
  M._opts = opts

  -- Validate powers configuration before proceeding
  validate_powers_config(opts)

  local subagents = opts.subagents or {}
  M._subagents = subagents

  -- Get codecompanion config
  local config = require("codecompanion.config")
  local tool_module = require("codecompanion._extensions.subagents.tool")
  local manager = require("codecompanion._extensions.subagents.manager")

  -- Set subagent names for tool filtering
  local subagent_names = {}
  for name, _ in pairs(subagents) do
    table.insert(subagent_names, name)
  end
  manager:set_subagent_names(subagent_names)
  manager:set_powers(opts.powers or {})

  -- Register each subagent as a tool
  for name, subagent_config in pairs(subagents) do
    -- Create tool definition for this subagent using tool module
    local tool = tool_module.create_subagent_tool(name, subagent_config, opts)

    -- Register the tool directly in codecompanion's config
    -- Use the prefixed name from the tool
    config.interactions.chat.tools[tool.name] = tool
  end

  -- Register the complete_subagent tool
  local complete_tool = require("codecompanion._extensions.subagents.complete_tool")
  config.interactions.chat.tools["complete_subagent"] = complete_tool
end

---List all subagent names
---@return string[]
function M.list_subagents()
  local names = {}
  for name, _ in pairs(M._subagents) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

---Get a specific subagent configuration
---@param name string
---@return table|nil
function M.get_subagent(name)
  return M._subagents[name]
end

---Get the extension options
---@return table
function M.get_opts()
  return M._opts
end

M.exports = {
  list_subagents = M.list_subagents,
  get_subagent = M.get_subagent,
  get_opts = M.get_opts,
}

return M
