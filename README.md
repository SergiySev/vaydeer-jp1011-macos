# Vaydeer JP-1011 for macOS

A small Swift tool that reads and changes the keys of the Vaydeer JP-1011 keypad
(9 keys, shown by the system as `9-key Smart Keypad`) without the official app.
The layout is stored in the keypad itself, so you do not need this tool after writing.

This is an unofficial project. It was tested on one keypad: firmware 1.1.1,
bootloader 0.2.1, on a Mac with Apple silicon. Use it at your own risk.

## Quick start

You only need Xcode or the Command Line Tools. There are no other dependencies.

```bash
git clone https://github.com/SergiySev/vaydeer-jp1011-macos.git
```

```bash
cd vaydeer-jp1011-macos
```

```bash
swiftc -O vaydeer.swift -o vaydeer
```

```bash
./vaydeer dump
```

## Current layout

This is the layout on layer 1. It does not clash with normal keyboards,
and it works with any input language.

| | | |
|---|---|---|
| Ctrl+Opt+Shift+F1 | Ctrl+Opt+Shift+F2 | Ctrl+Opt+Shift+F3 |
| Ctrl+Opt+Shift+F4 | Ctrl+Opt+Shift+F5 | Ctrl+Opt+Shift+F6 |
| Ctrl+Opt+Shift+F7 | Ctrl+Opt+Shift+F8 | Ctrl+Opt+Shift+F9 |

To write it again (for example, after a reset):

```bash
M=ctrl+opt+shift; ./vaydeer set layer=0 0=$M+f1 1=$M+f2 2=$M+f3 3=$M+f4 4=$M+f5 5=$M+f6 6=$M+f7 7=$M+f8 8=$M+f9
```

## Commands

| Command | What it does |
|---|---|
| `./vaydeer info` | Shows the firmware and layers |
| `./vaydeer dump` | Shows all keys |
| `./vaydeer backup file.json` | Saves all keys to a file |
| `./vaydeer set 0=f1 1=ctrl+f2` | Changes keys on the active layer |
| `./vaydeer set layer=1 0=f1` | Changes keys on the chosen layer |
| `./vaydeer restore file.json` | Restores all layers from a file |
| `./vaydeer restore file.json 1` | Restores one layer from a file |

Keys are numbered row by row, from top to bottom:

```text
0 1 2
3 4 5
6 7 8
```

Layers count from zero: `layer=0` is the first layer, `layer=1` is the second.

Key names: `f1`–`f12`, `num0`–`num9`, `ctrl`, `shift`, `opt`, `cmd`.
Join them with `+`.

Before writing, `set` saves a file named `vaydeer-backup-<time>.json`.
After writing, the tool reads the keys back and compares them.

## Restore the original keys

`backups/original.json` holds the settings from before any changes:
Num1–Num9 on layer 1, and arrows, Home, End, Page Up, Page Down and Space on layer 2.

```bash
./vaydeer restore backups/original.json
```

## Test the keys on a Mac

This window shows what macOS really receives. It closes when it has seen all
9 combinations of the current layout, or after 3 minutes.

```bash
swiftc keytest.swift -o keytest
```

```bash
./keytest keytest.log 180
```

## Good to know

- **F13–F24 do not work** on firmware 1.1.1. The keypad accepts the code but
  stores `0x00`. This is why the layout uses combinations with F1–F9.
- **A layer can only be written as a whole.** If you write one key, the other
  keys on that layer are erased. The tool always sends all 9 keys.
- **Long labels are not stored.** An 18-character label came back empty, and a
  12-character label was stored correctly. The tool cuts labels to 12 characters.
- **Firmware.** Writing is allowed only for 1.0.2 and 1.1.1 with bootloader 0.2.1.
  Writing was tested on 1.1.1, and the Vaydeer Studio authors tested 1.0.2.
  For any other version, test on an inactive layer first.
- **The firmware command `0xFC` is blocked.** The tool only sends commands from
  the short list at the top of `vaydeer.swift`.
- Device: VID `0x0483`, PID `0x5752`, configuration interface with usage page
  `0xFF00` and usage `1`.

## Credits

The protocol description comes from the
[Vaydeer Studio](https://github.com/callum-baillie/vaydeer-studio-linux)
project (MIT license). Its code is not used here.

## License

MIT
