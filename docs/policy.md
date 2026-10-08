# Policy

What agents may do in each app, and what needs your OK, is set by `~/Library/Application
Support/puter-use/policy.json`. puter-use only reads it; nothing in its tools writes it. With no file, the
defaults are:

| | |
|---|---|
| **off limits** (`deny`) | password managers: 1Password, Bitwarden, Keychain Access, Passwords, LastPass, KeePassXC, Dashlane, Enpass, Proton Pass. They aren't listed by `windows` or captured, even in a whole-screen screenshot |
| **clicks only** (`click`) | terminals: Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty, WezTerm. The pointer works, but typing, keys, menu commands and pasting (a context menu's Paste included) don't, since one typed line can run anything |
| **asks first** (`confirm`) | a press on a control (a click, a drag on it, `perform`), a menu item or option chosen (`menu`, `item`, `select`), or a key that does the same (a menu command's shortcut, Return on a default button, Space on a focused button, however it's sent), whose label has one of: delete, remove, erase, discard, don't save, revert, move to trash, send, pay, buy, purchase, place order, checkout, check out, transfer, publish, post, empty trash, uninstall, deactivate |
| **won't type** (`secure_fields`) | into password fields (typing, pasting, `set_value`, or a `cmd+v`), including one a Tab moves into partway through the text |

```json
{
  "apps": {"com.apple.Terminal": "full", "Slack": "view", "com.example.Bank": "deny"},
  "confirm": ["delete", "send", "pay"],
  "secure_fields": "block"
}
```

- `apps` takes bundle ids or app names. The levels are `deny`, `view` (screenshots, `find` and `menus`,
  plus scrolling and hovering to read; no clicks, typing or commands), `click` or `full`. `windows`
  marks each window that's `view` or `click`, and names the `deny` apps it leaves out.
- `confirm` replaces the word list; `[]` turns confirmation off. Words match whole words of a label,
  ignoring case and punctuation ("don't save" matches "Don't Save…").
- `"secure_fields": "allow"` lets the agent type into password fields.

The file is re-read whenever it changes. A batch with an action the level doesn't allow is refused
before any of it runs. An entry that can't be understood is reported by `windows` and read the safe
way (an unknown level is `deny`); a file that isn't JSON at all leaves the defaults in force.

**Confirmation.** A press that needs your OK stops the batch before anything happens:

```
stopped before action 3 (click): "Delete" looks like it can't be undone (delete); actions 3-4 were not run. Ask the user; if they agree, repeat it with "confirm": true
```

If the MCP client can ask you (MCP elicitation), puter-use asks you directly and, if you agree,
carries on from that press (a `save_as` still saves the whole batch). If you say no, the result is an
error and the agent is told not to try another way. Otherwise the agent is told to ask you, and to
repeat the press with `confirm: true` (`--confirm` in the CLI). A macro never saves `confirm`, so a
replay asks again; `confirm: true` on the macro action (`macro NAME --confirm`) OKs the presses that
replay makes. A `fill` checks its fields and submit button before filling anything in, and its
`confirm` covers its own clicks.

This is a safety net, not a guarantee. It looks at labels, so an unlabelled icon, or a key an app
handles without a menu command or button (the Delete key in a list, say), isn't caught.
