---@class CodeCompanion.SubAgents.Tool
---@field create_subagent_tool fun(name: string, config: table): table

local M = {}

local log = require("codecompanion.utils.log")

-- Valid approval modes for subagent tool approval state management
local valid_approval_modes = { isolated = true, inherit = true, shared = true }

---Create a tool definition for a subagent
---@param name string The name of the subagent
---@param config table Subagent configuration with description, system_prompt, tools, etc.
---@return table tool Tool definition compatible with codecompanion
function M.create_subagent_tool(name, config, opts)
  local prefixed_name = "subagent_" .. name
  local description = config.description or ("Sub-agent: " .. name)
  local system_prompt = config.system_prompt
  local tools = config.tools or {}
  local mcp_servers = config.mcp_servers
  -- Context mode: "explicit" (default) or "inherit"
  -- - explicit: context is passed as a parameter
  -- - inherit: inherits message history from parent chat
  local context_mode = config.context_mode or "explicit"
  -- context_spec: describes what context is needed
  local context_spec = config.context_spec or "Additional context for the task"
  -- result_spec: describes what result format is expected
  local result_spec = config.result_spec
  local replace_main_system_prompt = config.replace_main_system_prompt or false
  local adapter = config.adapter
  local default_power = config.default_power

  -- Approval mode determines how tool approval state is managed:
  local approval_mode = config.approval_mode or "isolated"
  if not valid_approval_modes[approval_mode] then
    log:warn("Invalid approval_mode '%s', falling back to 'isolated'", approval_mode)
    approval_mode = "isolated"
  end

  -- Build schema properties based on context_mode
  local schema_properties = {
    task = {
      type = "string",
      description = "The task description for the sub-agent",
    },
  }

  -- Only add context parameter in explicit mode
  if context_mode == "explicit" then
    schema_properties.context = {
      type = "object",
      description = context_spec,
    }
  end

  -- Add power parameter when powers is defined and SubAgent supports it
  opts = opts or {}
  local powers = opts.powers or {}
  local supports_power = vim.tbl_count(powers) > 0 and adapter == nil and context_mode ~= "inherit"
  if supports_power then
    local power_keys = vim.tbl_keys(powers)
    table.sort(power_keys)
    schema_properties.power = {
      type = "string",
      description = "Power level override for this invocation. Set this only when there are strong reasons to deviate from the default choice.",
      enum = power_keys,
    }
  end

  -- Async delivery resolution: per-subagent override wins over the global
  -- async_delivery option. Captured here because the opts parameter of the
  -- cmds function below is the runner opts, not the extension opts.
  local global_async_delivery = opts.async_delivery == true
  local function resolve_async_delivery()
    if config.async_delivery ~= nil then
      return config.async_delivery == true
    end
    return global_async_delivery
  end

  return {
    name = prefixed_name,
    cmds = {
      function(self, args, opts)
        local manager = require("codecompanion._extensions.subagents.manager")

        -- Extract power from call args
        local power = args.power

        local async_delivery = resolve_async_delivery()

        -- Start the sub-agent with parent_chat, capture the unique subagent_id
        local subagent_id = manager:start_subagent(self.chat, {
          name = name,
          system_prompt = system_prompt,
          tools = tools,
          mcp_servers = mcp_servers,
          replace_main_system_prompt = replace_main_system_prompt,
          context_mode = context_mode,
          result_spec = result_spec,
          adapter = adapter,
          approval_mode = approval_mode,
          power = power,
          default_power = default_power,
          async = async_delivery,
        }, args.task, args.context)

        if async_delivery then
          -- Non-blocking dispatch: release the orchestrator immediately. The
          -- real result is delivered later as a separate message on the
          -- parent chat's next idle point (see manager:async delivery).
          if opts and opts.output_cb then
            opts.output_cb({
              status = "success",
              data = string.format(
                [[SubAgent %s started in the background (id=%s). The task was dispatched and you do not need to wait for it. Its result will be delivered to you as a separate message starting with [subagent_result id=%s] when the subagent finishes. Continue with other work.]],
                name,
                subagent_id,
                subagent_id
              ),
            })
          end
          return
        end

        -- Store completion callback in chat object keyed by subagent_id
        if self.chat._subagents and self.chat._subagents[subagent_id] then
          self.chat._subagents[subagent_id].completion_callback = function(result, is_error)
            if opts and opts.output_cb then
              if is_error then
                opts.output_cb({ status = "error", data = result })
              else
                opts.output_cb({ status = "success", data = result })
              end
            end
          end
        end
      end,
    },
    schema = {
      type = "function",
      ["function"] = {
        name = prefixed_name,
        description = description,
        parameters = {
          type = "object",
          properties = schema_properties,
          required = { "task" },
        },
        strict = true,
      },
    },
    handlers = {
      on_exit = function(self, meta)
        -- Cleanup if needed
      end,
    },
    output = {
      prompt = function(self, meta)
        return string.format("Delegate task to %s?", name)
      end,
      success = function(self, stdout, meta)
        local chat = meta.tools.chat
        local output = vim.iter(stdout):flatten():join("\n")
        chat:add_tool_output(self, output, "Sub-agent completed")
      end,
      error = function(self, stderr, meta)
        local chat = meta.tools.chat
        local errors = vim.iter(stderr):flatten():join("\n")
        chat:add_tool_output(self, errors)
      end,
    },
  }
end

return M
