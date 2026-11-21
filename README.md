# Tooltip Reclaimer

Tooltip Reclaimer names the addon that added each line of a tooltip on **WoW Forever**.

Install as `Interface/AddOns/TooltipReclaimer`. Hover an item, spell, unit, or link. Labels sit beside the tooltip. The tooltip text itself is left alone.

Lines drawn by the game client stay unlabeled until you ask for them.

## Commands

`/tooltipreclaimer` works the same as `/ttr`:

```
/ttr             toggle the labels
/ttr game        also name lines that come from the game client
/ttr file        add the file and line that wrote each one
/ttr list        print sources for the tooltip under the cursor
```

The CurseForge project logo is `logo.jpg` (1024×1024). Upload that file as the project logo. It is left out of the addon zip.

## Releases

Version tags use the same form as TyGear. Pushing one builds the zip and publishes a GitHub release.

```
git tag 1-0-1-release
git push origin 1-0-1-release
```
