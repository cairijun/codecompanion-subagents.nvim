---@class CodeCompanion.Tool.CompleteSubAgent
local M = {}

M.name = "complete_subagent"

M.cmds = {
  ---Complete the sub-agent task
  ---@param self CodeCompanion.Tools.Tool
  ---@param args table The arguments from the LLM's tool call
  ---@param opts? {input: any, output_cb: fun(result: {status: string, data: any})}
  ---@return {status: "success"|"error", data: string}?
  function(self, args, opts)
    local manager = require("codecompanion._extensions.subagents.manager")
    local result = args.result

    -- Get parent chat from subagent chat
    local parent_chat = self.chat._parent_chat

    if not parent_chat then
      -- Error: no parent chat reference
      if opts and opts.output_cb then
        opts.output_cb({ status = "error", data = "No parent chat reference" })
      end
      return
    end

    -- Get subagent_id from subagent chat
    local subagent_id = self.chat._subagent_id

    if not result then
      manager:complete_subagent(parent_chat, subagent_id, "Error: No result provided", true)
      if opts and opts.output_cb then
        opts.output_cb({ status = "error", data = "No result provided" })
      end
      return
    end

    manager:complete_subagent(parent_chat, subagent_id, result, false)

    -- Intentionally do not call output_cb on success to prevent Chat auto-submit
    -- The subagent result is already passed to parent chat via manager:complete_subagent
  end,
}

M.schema = {
  type = "function",
  ["function"] = {
    name = "complete_subagent",
    description = "Complete the sub-agent task and return results to the parent chat",
    parameters = {
      type = "object",
      properties = {
        result = {
          type = "string",
          description = "The result or output from the sub-agent task",
        },
      },
      required = { "result" },
    },
    strict = true,
  },
}

M.handlers = {
  on_exit = function(self, meta)
    -- Cleanup if needed
  end,
}

M.output = {
  error = function(self, stderr, meta)
    local chat = meta.tools.chat
    local errors = vim.iter(stderr):flatten():join("\n")
    chat:add_tool_output(self, errors)
  end,
}

return M
