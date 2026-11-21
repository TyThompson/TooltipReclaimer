# TooltipReclaimer

Tooltip Reclaimer names the addon that added each line of a tooltip on **WoW Forever**.

Install as `Interface/AddOns/TooltipReclaimer`. Hover an item, spell, unit, or link. Labels sit beside the tooltip. The tooltip text itself is left alone.

Lines drawn by the game client stay unlabeled until you ask for them.

## Options

Under **Esc > Options > AddOns > Tooltip Reclaimer**:

- Show source labels
- Show client lines
- Show file names
- Detected addon hooks: each addon that has written a tooltip line, with the source file. Uncheck one to remove that addon's lines from tooltips.

## Commands

`/tooltipreclaimer` works the same as `/ttr`:

```
/ttr             toggle the labels
/ttr options     open the options menu
/ttr game        also name lines that come from the game client
/ttr file        add the file and line that wrote each one
/ttr list        print sources for the tooltip under the cursor
```


## Releases

```
git tag 1-0-1-release
git push origin 1-0-1-release
```
