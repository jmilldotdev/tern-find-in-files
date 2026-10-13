# tern-find-in-files

A Tern plugin: VS Code-style search across the files under a folder,
powered by [ripgrep](https://github.com/BurntSushi/ripgrep).

Open it from the palette ("Find in files") in the focused pane's directory. Results update
as you type.

| Key | Action |
| --- | --- |
| up / down | move the selection |
| enter / click | open the match at its line, in place of the search block |
| ctrl+r | toggle regex |
| ctrl+i | toggle case-sensitive (default: smart case) |
| ctrl+u | clear the query |
| esc | close the block |

Opening a result parks the search; closing that editor, or starting a new search inside
the same folder, brings it back with its query and results.

## Install

```sh
brew install ripgrep
tern plugin install https://github.com/jmilldotdev/tern-find-in-files
```

Tern's preset owns `shift+cmd+f`, so bind it in `settings.json`:

```json
"keybinds": { "shift+cmd+f": "plugin.find-in-files.open" }
```
