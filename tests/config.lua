-- Minimal test configuration for codecompanion
-- Based on deps/codecompanion.nvim/tests/config.lua

return {
  adapters = {
    http = {
      test_adapter = {
        name = "test_adapter",
        url = "https://example.com/v1/chat/completions",
        roles = {
          llm = "assistant",
          user = "user",
        },
        opts = {
          stream = true,
        },
        headers = {
          content_type = "application/json",
        },
        parameters = {
          stream = true,
        },
        handlers = {
          form_parameters = function()
            return {}
          end,
          form_messages = function()
            return {}
          end,
          is_complete = function()
            return false
          end,
          tools = {
            format_tool_calls = function(self, tools)
              return tools
            end,
            output_response = function(self, tool_call, output)
              return {
                role = "tool",
                tools = {
                  call_id = tool_call.id,
                },
                content = output,
                _meta = { tag = tool_call.id },
                opts = { visible = false },
              }
            end,
          },
        },
        schema = {
          model = {
            default = "skynet",
          },
        },
      },
    },
  },
}
