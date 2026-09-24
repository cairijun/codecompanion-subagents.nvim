# codecompanion-subagents.nvim

A CodeCompanion.nvim extension that adds SubAgent support, allowing the main agent to delegate tasks to specialized sub-agents through tool calls.

> [!ATTENTION] This is just a POC to demonstrate how subagents could be implemented in CodeCompanion. It is definitely not (and may never be) production-ready. Use with caution!

## Installation

### Using lazy.nvim

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "cairijun/codecompanion-subagents.nvim",
  },
  config = function()
    require("codecompanion").setup({
      extensions = {
        subagents = {
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
| `result_spec` | string | Yes | Description of expected result |
| `system_prompt` | string | No | System prompt for the subagent |
| `replace_main_system_prompt` | boolean | No | When `true`, replaces the default system prompt entirely. When `false` (default), appends to the default system prompt. |
| `tools` | string[] or "inherit" | No | List of tools available to the subagent. Use "inherit" to inherit from parent agent. |
| `mcp_servers` | string[] or "inherit" | No | List of MCP server names to use. Use "inherit" to inherit from parent agent. |
| `context_mode` | "explicit" or "inherit" | No | Context mode: "explicit" (default) passes context as parameter; "inherit" inherits message history from parent chat. |
| `context_spec` | string | No | Description of what context is needed (used in `context_mode="explicit"`) |
| `adapter` | string, table, or "inherit" | No | Adapter for the subagent. Use a string name (e.g., `"anthropic"`), a table with name and model (e.g., `{ name = "openai", model = "gpt-4o" }`), or `"inherit"` to use the parent chat's adapter (default when omitted). **Mutually exclusive with `default_power`.** |
| `default_power` | string | No | Default power level for this subagent. Requires `powers` to be defined. Cannot be used with `adapter` or `context_mode = "inherit"`. |
| `approval_mode` | `"isolated"`, `"inherit"`, or `"shared"` | No | How tool approval state is managed. `"isolated"` (default): SubAgent starts with no pre-approved tools. `"inherit"`: deep-copies parent's approval state at startup, then operates independently. `"shared"`: shares the same approval table with parent bidirectionally. |
| `async_delivery` | boolean | No | Run this subagent non-blocking: the tool call returns immediately and the result is delivered later as a separate message. A per-subagent override for the global `opts.async_delivery` option. |

### Example Configuration

```lua
require("codecompanion").setup({
  extensions = {
    subagents = {
      enabled = true,
      opts = {
        subagents = {
          generic = {
            description = "A general-purpose subagent that you can delegate a task to. It sees all your previous messages so you don't need to repeat the whole context.",
            tools = "inherit",
            mcp_servers = "inherit",
            context_mode = "inherit",
            result_spec = "A brief summary of what you have done, or errors/exceptions encountered that prevented you from completing the task.",
          },
          code_reviewer = {
            description = "Reviews code for bugs, style issues, and improvements",
            system_prompt = "You are an expert code reviewer. Analyze code for potential issues, suggest improvements, and provide constructive feedback.",
            tools = { "file_search", "get_changed_files", "grep_search", "read_file" },
            context_spec = "1) Background information of the changes or repo. 2) The code files to review.",
            result_spec = "A structured review with: issues found, severity, and suggestions",
          },
          web_researcher = {
            description = [[Searches the web to answer specific questions.
Use this subagent when you need to research topics, find current information, or investigate technical issues online.
Returns a comprehensive report with citations.]],
            system_prompt = [[You are a research specialist focused on web search and information synthesis.

Your workflow:
1. **Understand**: Peform a basic search to understand the question and gather background information.
2. **Plan**: Create a research plan outlining the key topics to investigate.
3. **Gather**: For each topic, perform targeted web searches to find relevant information, data, and sources.
4. **Synthesize**: Compile the research findings into a comprehensive report that directly answers the original question, including citations for all sources used.
]]
            mcp_servers = { "brave-search" },
            tools = { "fetch_webpage" },
            context_spec = "The question or topic to research",
            result_spec = [[A comprehensive research report that includes:
- A clear and concise answer to the research question
- Citations with links to sources (or file references for codebase research)
- Confidence levels for key claims (high/medium/low)
- Suggestions for further investigation if applicable]],
          },
          -- Use a cheaper/faster model for simple summarization tasks
          summarizer = {
            description = "Summarizes text or documents concisely",
            system_prompt = "You are a concise summarizer. Extract the key points and present them clearly.",
            adapter = { name = "anthropic", model = "claude-haiku-4-5-20251001" },
            context_spec = "The text or document to summarize",
            result_spec = "A concise bullet-point summary of the key points",
          },
        },
      },
    },
  },
})
```

### Example with Power Configuration

```lua
require("codecompanion").setup({
  extensions = {
    subagents = {
      enabled = true,
      opts = {
        powers = {
          high = {
            adapter = { name = "copilot", model = "gpt-5.4" },
          },
          medium = {
            adapter = { name = "deepseek", model = "deepseek-v4-pro" },
          },
          low = {
            adapter = { name = "deepseek", model = "deepseek-v4-flash" },
          },
        },
        subagents = {
          code_reviewer = {
            description = "Reviews code for bugs, style issues, and improvements",
            system_prompt = "You are an expert code reviewer.",
            tools = { "file_search", "grep_search", "read_file" },
            context_spec = "The code files to review.",
            result_spec = "A structured review with findings and suggestions",
            default_power = "medium",
          },
          test_writer = {
            description = "Writes unit tests for the given code",
            system_prompt = "You are a test engineer.",
            tools = { "file_search", "read_file" },
            context_spec = "The code to test.",
            result_spec = "The test file content",
            -- No default_power: falls back to parent chat adapter unless overridden at call time
          },
        },
      },
    },
  },
})
```

## Usage

A subagent will available as a tool named `subagent_{subagent_name}`. You can ask the main agent to call this tool delegate a task to the subagent. For example, with the above configuration, you can:

- `Draft a design document for the feature X, and use @{subagent_web_researcher} to explore existing solutions and gather information on best practices`
- `Based on what we discussed, use @{subagent_generic} to implement the feature`
- `Use @{subagent_reviewer} to review current code changes`

The main agent will delegate the task to the appropriate subagent, which will execute with its specialized system prompt and tool set, then return results back to the main conversation.

### Power Configuration

Power levels let you define named adapter presets at the project level and reference them from subagents, enabling a three-layer resolution model:

1. **Project-level** — `opts.powers` defines named power levels and their adapter mappings.
2. **Subagent default** — `default_power` sets a default level for a specific subagent.
3. **Call-time override** — the `power` parameter in the tool call overrides the default for a single invocation.

Resolution order: `call arg power` > `subagent default_power` > `parent chat adapter`.

#### `opts.powers`

A table mapping power level names to adapter configurations:

```lua
opts = {
  powers = {
    high = {
      adapter = { name = "copilot", model = "gpt-5.4" },
    },
    medium = {
      adapter = { name = "deepseek", model = "deepseek-v4-pro" },
    },
    low = {
      adapter = { name = "deepseek", model = "deepseek-v4-flash" },
    },
  },
  subagents = {
    -- ...
  },
}
```

Each `powers.<level>.adapter` follows the same semantics as the subagent `adapter` field — it can be a string name or a table with `name` and `model`.

#### Unsupported Power scenarios

The following subagent configurations do **not** support Power:

- `context_mode = "inherit"` — inherits the parent chat's execution context, so Power is not applicable.
- Explicit `adapter` — a subagent with a hardcoded adapter cannot also use Power; use `default_power` instead.

#### Tool call `power` parameter

When `opts.powers` is defined and a subagent supports Power, the tool schema exposes an optional `power` parameter with an enum matching the defined level names. The main agent can pass this parameter at call time to override the subagent's default power level.

### Approval Modes

SubAgents support three approval modes to control whether tool approvals are shared with the parent agent:

| Mode | Behavior |
|------|----------|
| `isolated` (default) | SubAgent starts with no pre-approved tools, operates independently |
| `inherit` | SubAgent deep-copies parent's approval state at startup, then operates independently |
| `shared` | SubAgent shares the same approval table with the parent (bidirectional) |

### Async Delivery

By default a subagent call blocks the main agent's tool queue until the subagent finishes.
With `async_delivery` enabled, the tool call returns immediately and the subagent keeps
working in the background. Its result is delivered to the chat as a separate message
tagged `[subagent_result id=<subagent_id>]` on the next turn where the chat is idle.
This lets the main agent dispatch several subagents and continue working while they
run in parallel.

```lua
require("codecompanion").setup({
  extensions = {
    subagents = {
      enabled = true,
      opts = {
        -- All subagents run non-blocking
        async_delivery = true,
        subagents = {
          web_researcher = {
            description = "Searches the web to answer specific questions.",
            async_delivery = false, -- per-subagent override: keep this one blocking
            -- ...
          },
        },
      },
    },
  },
})
```

Both `async_delivery` (global) and `subagents.<name>.async_delivery` (override) must be
booleans. When both are set, the per-subagent value wins.

**Trade-offs:**

- The result arrives as a separate message, not as the tool result of the original call.
- Failed subagents are delivered with an extra `[ERROR]` marker in the `[subagent_result id=...]` tag.
- Every delivered result starts one extra LLM turn.
- Several pending results are delivered one per idle turn, in FIFO order.

## How It Works

1. **Setup Phase**: When CodeCompanion initializes, the extension registers a tool for each configured subagent with a `subagent_` prefix
2. **Tool Call**: The main agent decides to delegate a task and calls a subagent tool
3. **SubAgent Execution**:
   - In blocking mode, hides the parent chat UI
   - Creates a new subagent chat
   - Subagent executes with its specialized system prompt
4. **Completion**:
   - Subagent calls `complete_subagent` with its result
   - In blocking mode: restores the parent chat UI and returns the result to the main conversation
   - In async delivery mode: queues the result and delivers it as a separate `[subagent_result id=...]` message when the parent chat is idle (see [Async Delivery](#async-delivery))

## License

Apache License 2.0
