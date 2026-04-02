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
| `adapter` | string, table, or "inherit" | No | Adapter for the subagent. Use a string name (e.g., `"anthropic"`), a table with name and model (e.g., `{ name = "openai", model = "gpt-4o" }`), or `"inherit"` to use the parent chat's adapter (default when omitted). |

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

## Usage

A subagent will available as a tool named `subagent_{subagent_name}`. You can ask the main agent to call this tool delegate a task to the subagent. For example, with the above configuration, you can:

- `Draft a design document for the feature X, and use @{subagent_web_researcher} to explore existing solutions and gather information on best practices`
- `Based on what we discussed, use @{subagent_generic} to implement the feature`
- `Use @{subagent_reviewer} to review current code changes`

The main agent will delegate the task to the appropriate subagent, which will execute with its specialized system prompt and tool set, then return results back to the main conversation.

## How It Works

1. **Setup Phase**: When CodeCompanion initializes, the extension registers a tool for each configured subagent with a `subagent_` prefix
2. **Tool Call**: The main agent decides to delegate a task and calls a subagent tool
3. **SubAgent Execution**:
   - Hides the parent chat UI
   - Creates a new subagent chat
   - Subagent executes with its specialized system prompt
4. **Completion**:
   - Subagent calls `complete_subagent` with its result
   - Restores the parent chat UI
   - Result is returned to the main conversation

## License

Apache License 2.0
