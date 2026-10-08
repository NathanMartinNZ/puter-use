# CLI

The CLI drives apps the same way the MCP tools do, for you, a script or a skill-based agent.
Commands after the first apply to the last window used; pass `-w <id|app>` to switch. From the repo,
run it as `uv run puter-use …`; from elsewhere, `uv run --directory /path/to/puter-use puter-use …`.
`puter-use --help` and `puter-use <command> --help` list every option.

```bash
puter-use windows Firefox
puter-use shot Firefox                  # prints status + image path
puter-use shot Firefox --region 0,0,300,120   # zoom in to read small text
puter-use shot -w Firefox --region 80,148,620,170 --no-image   # just the text in that box
puter-use shot Firefox --no-image       # accessibility outline only (opt-in)
puter-use click 640 88                  # → new screenshot path if anything changed
puter-use click -e 12                   # press accessibility element 12
puter-use click -e Save                 # the element showing "Save" (fails, listing them, if several do)
puter-use find "Export" --role button   # numbered matches with their positions
puter-use shot Firefox --marks          # numbers drawn on the controls
puter-use shot Firefox --no-image --interactive   # outline of just the controls
puter-use type "hello" && puter-use key Return
puter-use scroll --dy 600
puter-use act '[{"type":"keypress","keys":"cmd+l"},{"type":"type","text":"example.com\n"}]'
puter-use perform 7 expand              # an accessibility action on element 7
puter-use key Return --screenshot never # just the status line (exit status 1 if an action failed)
puter-use key "Tab Tab Return"          # a key sequence; --repeat 5 presses it five times
puter-use menus export -w Probe         # menu items matching "export", with their shortcuts
puter-use menu "File > Export as PDF…"  # run a menu command
puter-use type "Ada" -e 3 --clear --submit   # click field 3, empty it, type, Return
puter-use select 4 Blue                 # pick "Blue" in pop-up 4
puter-use navigate example.com          # in the agent's own browser window
puter-use open ~/Desktop/report.pdf     # in its default app, in the background
puter-use wait-for "Done" --timeout-ms 8000
puter-use act '[…]' --save-as "export pdf" --var file=q3.pdf   # save a batch that worked
puter-use macro "export pdf" file=q4.pdf    # replay it
puter-use macros --all                  # what's saved
puter-use exec fill_contacts.py         # a script with `pu` ready (see Code mode)
puter-use release                       # hide the agent cursor
```
