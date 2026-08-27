# Omablur

A bar panel (`"kind": "bar-widget"`) to tune window corner rounding and blur
intensity for [Omarchy](https://omarchy.org), without opening a config file.
Click the bar chip, drag a slider — the change applies to the running
Hyprland session immediately.

## Install

```bash
omarchy plugin add https://github.com/Charlieras262/omarchy-omablur.git --enable
```

`omarchy plugin update` later pulls new versions the same way any
git-managed plugin does.

## Use

Click the chip in the bar to open the panel:

- **Corner rounding** — a 0-20px slider, mapped 1:1 to Hyprland's
  `decoration:rounding`.
- **Blur** — an on/off switch (`decoration:blur:enabled`).
- **Intensity** — a 0-100% slider, shown while blur is on, converted to
  Hyprland's `decoration:blur:size` (1-20, linear) and `decoration:blur:passes`
  (1-3, stepped: each extra pass roughly doubles the GPU cost for a
  much smaller visual gain past 2-3, so a straight linear mapping would make
  the top half of the slider barely distinguishable but noticeably heavier).

Dragging a slider previews the change live via `hyprctl keyword` — nothing
is written to disk until you release it. On release, the setting is
persisted as a marked block in your own `~/.config/hypr/looknfeel.lua`, so
it survives a Hyprland restart:

```lua
-- BEGIN charlieras262.omablur
hl.config({
  decoration = {
    rounding = 8,
    blur = {
      enabled = true,
      size = 8,
      passes = 2,
      new_optimizations = true,
      ignore_opacity = true,
    },
  },
})
-- END charlieras262.omablur
```

Only the lines between those two markers are ever touched — anything else
you already have in `looknfeel.lua` is left exactly as it was.

### Rounding also applies to the shell itself

Corner rounding isn't only a window thing: Omarchy's own `Style.cornerRadius`
(used by every popup panel — Display, network, bluetooth, audio, etc.) already
mirrors `decoration:rounding` live, and
[omarchy-floating-bar](https://github.com/Charlieras262/omarchy-floating-bar)
1.4.0+ defaults its own corners to that same value when you haven't set an
explicit `cornerRadius` in its own config. Dragging Omablur's rounding slider
calls Omarchy's own `Style.refresh()` after each change, so both follow the
slider live, with no direct coupling between the three plugins — they all
just read the one shared value.

## Remove

```bash
omarchy plugin remove charlieras262.omablur
```

This removes the plugin's files, but leaves the marked block above in
`looknfeel.lua` (Hyprland keeps using that rounding/blur setting after
removal, same as it would if you'd typed it in by hand). To drop it too:

```bash
python3 ~/.config/omarchy/plugins/charlieras262.omablur/compat/uninstall-looknfeel.py charlieras262.omablur
```

Run that *before* `omarchy plugin remove` (once removed, the script above
is gone too — in that case just delete the marked block from
`~/.config/hypr/looknfeel.lua` by hand).

## Dependencies

`hyprctl` (ships with Hyprland/Omarchy) for reading and applying live
values, and `python3` for the config-file writer. Everything else is plain
QML on Omarchy's own `qs.Commons`/`qs.Ui` modules — no external packages or
services.

## License

MIT — see [LICENSE](LICENSE).
