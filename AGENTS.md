# codecompanion-subagents

CodeCompanion.nvim extension that adds SubAgent support, allowing the main agent to delegate tasks to specialized sub-agents through tool calls.

## Architecture

### Key Components

| File | Description |
|------|-------------|
| `lua/codecompanion/_extensions/subagents/init.lua` | Extension entry point, setup and exports |
| `lua/codecompanion/_extensions/subagents/tool.lua` | SubAgent tool generator |
| `lua/codecompanion/_extensions/subagents/manager.lua` | SubAgent lifecycle management |
| `lua/codecompanion/_extensions/subagents/complete_tool.lua` | `complete_subagent` tool for returning results |

### Key Design Decisions

- **Tool-based delegation**: Subagents are exposed as tools, enabling the main agent to delegate tasks naturally through its existing tool-calling mechanism
    * Tool naming: All subagent tools are prefixed with `subagent_` (e.g., `subagent_code_reviewer`).
- **Isolation**: Each subagent runs with its own system prompt and filtered tool set, allowing specialization without cross-contamination
- **Explicit completion**: Subagents must call `complete_subagent` to return results, ensuring clear task boundaries and result flow
* **Configuration**: Subagents are configured in `extensions.subagents.opts.subagents`

## Coding Conventions
Use English for all code comments, string literals, and documentation.

## Development

```bash
# Run all tests
make test
# Run specific test file
make test_file FILE=tests/test_manager.lua
# Format code
make format
```
