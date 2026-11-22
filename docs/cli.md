# CLI

The CLI drives apps the same way the MCP tools do, for you, a script or a skill-based agent.
Commands after the first apply to the last window used; pass `-w <id|app>` to switch. From the repo,
run it as `uv run puter-use …`; from elsewhere, `uv run --project /path/to/puter-use puter-use …`
(it keeps your working directory, so relative paths like `exec loop.py` still work).
`puter-use --help` and `puter-use <command> --help` list every option.
Ctrl-C (SIGINT) stops a command, a running `exec` script too: the helper stops what it was doing for it
(a wait, a batch, typing) and lets go of any held key or button, and the CLI prints `stopped: interrupted`
and exits with status 130.

Each command is a call, and each image it prints is another look, so batch the steps you can predict
into one `act` (one image at the end), and run loops as a script with `exec` (`-c` for a short one).
Don't chain commands with `&&`: images printed but not looked at count as seen, so the guard that stops
a click on a stale screenshot can't help.

```bash
puter-use act '[{"type":"click","target":"Name"},{"type":"type","text":"Ada"},{"type":"keypress","keys":"Tab"},{"type":"type","text":"ada@example.com","submit":true}]'
puter-use exec -c 'for name in ["Ada", "Bo", "Cy"]: pu.fill({"Name": name}, submit="Add")' -w Probe   # a loop, no call per step
puter-use windows Firefox
puter-use shot Firefox                  # prints status + image path
puter-use shot Firefox --region 0,0,300,120   # zoom in to read small text
puter-use shot -w Firefox --region 80,148,620,170 --no-image   # just the text in that box
puter-use shot Firefox --no-image       # accessibility outline only (opt-in)
puter-use shot -w TextEdit --read       # the whole text of the focused text area, 10000 characters at a time
puter-use shot -w Probe --read Notes --offset 10000   # by what it shows (or its number): the next part
puter-use shot -w Probe --read Notes --offset -2000   # the last 2000 characters
puter-use shot -w Probe --read Notes --query invoice  # where "invoice" is in it: @offset lines to read on from
puter-use shot -w Firefox --read        # the whole page as Markdown, its links and controls numbered for -e
puter-use click 640 88                  # → new screenshot path if anything changed
puter-use click -e 12                   # press accessibility element 12
puter-use click -e Save                 # the element showing "Save" (fails, listing them, if several do)
puter-use find "Export" --role button   # numbered matches with their positions
puter-use find Email Password "Sign in" # several texts in one call (up to 10), a part for each
puter-use find --role field             # every field (the first 20, then how many more)
puter-use shot Firefox --marks          # numbers drawn on the controls
puter-use shot Firefox --no-image --interactive   # outline of just the controls
puter-use type "hello" --submit        # type, then Return
puter-use scroll --dy 600               # pixels, positive = down (--dx: right); one of them, or --until
puter-use scroll --until "Load more"    # a screenful at a time until it's in view (--max-scrolls, up to 15)
puter-use act '[{"type":"keypress","keys":"cmd+l"},{"type":"type","text":"example.com\n"}]'
puter-use perform 7 expand              # an accessibility action on element 7
puter-use key Return --screenshot never # just the status line (exit status 1 if an action failed)
puter-use type "Ada" -e 3 --crop-changes --detail low   # an image of only what changed, at low detail
puter-use key "Tab Tab Return"          # a key sequence; --repeat 5 presses it five times
puter-use menus export -w Probe         # menu items matching "export", with their shortcuts
puter-use menu "File > Export as PDF…"  # run a menu command
puter-use menu "Export as PDF…"         # the same by its name alone, if no other command has it
puter-use type "Ada" -e 3 --clear --submit   # click field 3, empty it, type, Return
puter-use select Color Blue             # pick "Blue" in the pop-up showing "Color" (or by number: select 4 Blue)
puter-use fill Email=ada@example.com Size=L "I agree=true" --submit   # a form by its labels, then Return
puter-use navigate example.com          # in the agent's own browser window
puter-use open ~/Desktop/report.pdf     # in its default app, in the background
puter-use wait-for "Done" --timeout-ms 8000
puter-use wait-for --change             # until the window looks different from when it began, then settles
puter-use act '[…]' --save-as "export pdf" --var file=q3.pdf   # run it, saved if every action succeeds
puter-use macro "export pdf" file=q4.pdf    # replay it
puter-use macros --all                  # what's saved
puter-use exec fill_contacts.py         # a script with `pu` ready (see Code mode)
puter-use release                       # hide the agent cursor
puter-use quit                          # stop the helper; returns once it has exited (the next call starts it)
```
