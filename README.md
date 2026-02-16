# nvim-iterview

Snapshot-based iteration review plugin for Neovim. Take filesystem checkpoints before an AI (or anyone) modifies your code, then review exactly what changed per iteration, independent of git state.

<video src="https://github.com/user-attachments/assets/06961bd6-305d-48a4-9bb8-97ef64d2257c" autoplay loop muted playsinline></video>

## Requirements

- Neovim >= 0.9
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- git
- [fd](https://github.com/sharkdp/fd)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "msegoviadev/nvim-iterview",
  lazy = false,
  dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
  config = function()
    require("iterview").setup()
  end,
}
```

## Keybindings

| Keybind | Command | Description |
|---|---|---|
| `<Space>ic` | `:IterviewCheckpoint` | Create a checkpoint |
| `<Space>id` | `:IterviewDiff` | Review changes since last checkpoint |
| `<Space>ih` | `:IterviewHistory` | Browse checkpoint history |
| `<Space>ix` | `:IterviewClear` | Clear all checkpoints |

Inside the diff picker:

| Key | Action |
|---|---|
| `Enter` | Open side-by-side diff (press `q` or `Esc` to return to picker) |
| `Ctrl+o` | Open the file directly |

## Configuration

Default configuration (all optional):

```lua
require("iterview").setup({
  max_checkpoints = 20,
  storage_dir = ".iterview",
  auto_gitignore = true,
  git_search_depth = 2,
  exclude_dirs = {
    "node_modules", ".venv", "target", "dist", "build", "__pycache__",
  },
  telescope = {
    layout_strategy = "vertical",
    layout_config = {
      height = 0.95,
      width = 0.8,
      preview_height = 0.6,
    },
  },
  keymaps = {
    checkpoint = "<leader>ic",
    diff = "<leader>id",
    history = "<leader>ih",
    clear = "<leader>ix",
  },
})
```

## How it works

Checkpoints store file content in git's object store via `git hash-object`, making them fast and storage-efficient. Diffs are computed against checkpoints rather than git state, so `git add .` never hides your changes. Supports multiple git repos under a single working directory.
