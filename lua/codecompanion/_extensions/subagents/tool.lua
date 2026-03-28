---@class CodeCompanion.SubAgents.Tool
---@field create_subagent_tool fun(name: string, config: table): table

local M = {}

---Create a tool definition for a subagent
---@param name string The name of the subagent
---@param config table Subagent configuration with description, system_prompt, tools, etc.
---@return table tool Tool definition compatible with codecompanion
function M.create_subagent_tool(name, config)
  local prefixed_name = "subagent_" .. name
  local description = config.description or ("Sub-agent: " .. name)
  local system_prompt = config.system_prompt or ("You are a sub-agent named " .. name)
  local tools = config.tools or {}
  local mcp_servers = config.mcp_servers
  local context_description = config.context_description or "Additional context for the task"

  return {
    name = prefixed_name,
    cmds = {
      function(self, args, opts)
        local manager = require("codecompanion._extensions.subagents.manager")

        -- Start the sub-agent with parent_chat
        manager:start_subagent(self.chat, {
          name = name,
          system_prompt = system_prompt,
          tools = tools,
          mcp_servers = mcp_servers,
        }, args.task, args.context)

        -- Store completion callback in chat object
        if self.chat._subagents then
          self.chat._subagents.completion_callback = function(result, is_error)
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
          properties = {
            task = {
              type = "string",
              description = "The task description for the sub-agent",
            },
            context = {
              type = "object",
              description = context_description,
            },
          },
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
