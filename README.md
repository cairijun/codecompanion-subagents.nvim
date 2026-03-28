# codecompanion-subagents.nvim

A CodeCompanion.nvim extension that adds SubAgent support, allowing the main agent to delegate tasks to specialized sub-agents through tool calls.

## Features

- **Dynamic Tool Generation**: Each configured subagent becomes a tool the main agent can call
- **Tool Filtering**: Subagents cannot call other subagent tools, preventing infinite recursion
- **UI Management**: Parent chat is hidden while subagent runs, restored on completion
- **Explicit Completion**: Subagents must call `complete_subagent` to return results

## Installation

### Using lazy.nvim

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "your-username/codecompanion-subagents.nvim",
  },
  config = function()
    require("codecompanion").setup({
      extensions = {
        subagents = {
          enabled = true,
          opts = {
            subagents = {
              -- Define your subagents here
            },
          },
        },
      },
    })
  end,
}
```

## Configuration

### Subagent Options

Each subagent requires the following fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | Yes | Description shown to the main agent |
| `system_prompt` | string | Yes | System prompt for the subagent |
| `tools` | string[] | No | List of tools available to the subagent |
| `mcp_servers` | string[] | No | List of MCP server names to use |
| `context_description` | string | No | Custom description for the context parameter |

### Example Configuration

```lua
require("codecompanion").setup({
  extensions = {
    subagents = {
      enabled = true,
      opts = {
        subagents = {
          ["code_reviewer"] = {
            description = "Reviews code for bugs, style issues, and improvements",
            system_prompt = "You are an expert code reviewer. Analyze code for potential issues, suggest improvements, and provide constructive feedback.",
            tools = { "read_file", "grep_search" },
            context_description = "The code files or buffers to review",
          },
          ["test_writer"] = {
            description = "Writes unit tests for the provided code",
            system_prompt = "You are a test engineer. Write comprehensive unit tests for the provided code using the appropriate testing framework.",
            tools = { "read_file", "create_file", "edit_file" },
          },
          ["doc_writer"] = {
            description = "Writes documentation for code",
            system_prompt = "You are a technical writer. Create clear, comprehensive documentation for the provided code.",
            tools = { "read_file", "create_file", "edit_file" },
          },
        },
      },
    },
  },
})
```

## MCP Server Support

SubAgents can specify which MCP (Model Context Protocol) servers to use. MCP servers provide additional tools and capabilities to the subagent.

### Configuration

MCP servers must be configured globally in CodeCompanion's `mcp.servers` section. SubAgents reference these servers by name:

```lua
require("codecompanion").setup({
  mcp = {
    servers = {
      ["sequential-thinking"] = {
        cmd = { "npx", "-y", "@modelcontextprotocol/server-sequential-thinking" },
      },
      ["tavily"] = {
        cmd = { "npx", "-y", "tavily-mcp@latest" },
        env = { TAVILY_API_KEY = "your-key" },
      },
    },
  },
  extensions = {
    subagents = {
      enabled = true,
      opts = {
        subagents = {
          ["researcher"] = {
            description = "Research assistant with web search",
            system_prompt = "You are a research assistant. Use the available tools to research topics.",
            tools = { "read_file" },
            mcp_servers = { "tavily", "sequential-thinking" },
          },
        },
      },
    },
  },
})
```

### How It Works

1. MCP servers are configured globally in CodeCompanion's `mcp.servers` section
2. SubAgents reference these servers by name in the `mcp_servers` field
3. When a SubAgent starts, CodeCompanion automatically starts the specified MCP servers
4. MCP tools become available to the SubAgent through the tool registry

## Usage

Once configured, the main CodeCompanion agent will have access to tools named after each subagent. All subagent tools are automatically prefixed with `subagent_`. For example, with the configuration above, the agent can:

1. **Call `subagent_code_reviewer`**: Ask the agent to "Review this code using the subagent_code_reviewer tool"
2. **Call `subagent_test_writer`**: Ask the agent to "Write tests using the subagent_test_writer tool"
3. **Call `subagent_doc_writer`**: Ask the agent to "Document this function using the subagent_doc_writer tool"

The main agent will delegate the task to the appropriate subagent, which will execute with its specialized system prompt and tool set, then return results back to the main conversation.

## API

The extension exports the following functions:

### `list_subagents()`

Returns a list of all configured subagent names.

```lua
local names = require("codecompanion").extensions.subagents.list_subagents()
-- Returns: { "code_reviewer", "test_writer", "doc_writer" }
```

### `get_subagent(name)`

Returns the configuration for a specific subagent.

```lua
local config = require("codecompanion").extensions.subagents.get_subagent("code_reviewer")
-- Returns: { description = "...", system_prompt = "...", tools = {...} }
```

## How It Works

1. **Setup Phase**: When CodeCompanion initializes, the extension registers a tool for each configured subagent with a `subagent_` prefix
2. **Tool Call**: The main agent decides to delegate a task and calls a subagent tool
3. **SubAgent Execution**: 
   - Manager hides the parent chat UI
   - Creates a new subagent chat with filtered tools
   - Subagent executes with its specialized system prompt
4. **Completion**: 
   - Subagent calls `complete_subagent` with its result
   - Manager restores the parent chat UI
   - Result is returned to the main conversation

## Tool Naming Convention

All subagent tools are automatically prefixed with `subagent_`. For example:

- A subagent configured as `code_reviewer` becomes tool `subagent_code_reviewer`
- A subagent configured as `test_writer` becomes tool `subagent_test_writer`

This prefix helps distinguish subagent tools from built-in tools and prevents naming conflicts.

## License

Apache License 2.0
