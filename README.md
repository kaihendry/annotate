# annotate

Minimal macOS screenshot annotation tool. One Swift file, AppKit only, no
dependencies — compile it yourself and there is nothing to trust but Apple's
toolchain. Born out of [flameshot#4125](https://github.com/flameshot-org/flameshot/issues/4125).

![test-terminal.png annotated by Claude via the headless CLI](test-annotated.png)

## Build

```sh
swiftc -O Annotate.swift -o annotate
```

## Use (GUI)

```sh
./annotate             # screenshot to clipboard (⌃⇧⌘4), annotate, ⌘Q → clipboard
./annotate shot.png    # annotate an existing file
```

Annotate never calls `screencapture` itself — on MDM-managed machines the
Screen Recording permission this needs is often blocked. Instead it rides on
the system screenshot tool: launch annotate, press ⌃⇧⌘4 and grab a region
(⌃ sends it to the clipboard), and the image loads automatically. If the
clipboard already holds an image at launch, it loads straight away.

On macOS 15.4+ the first auto-load triggers a one-time system alert asking
to allow annotate to paste from other apps — approve it (or set annotate to
Always Allow under System Settings → Privacy & Security). ⌘V always works
without any prompt.

| Key | Action |
|-----|--------|
| `B` / `A` / `T` | box / arrow / text tool (current tool shown in titlebar) |
| drag | draw box or arrow |
| click, type, `⏎` | place text (`⎋` cancels) |
| `⌘Z` | undo last shape |
| `⌘C` | copy annotated image |
| `⌘S` | save as PNG |
| `⌘Q` | quit — annotated image is copied to the clipboard automatically |

Shapes are red with a white halo, text is 28pt JetBrains Mono Bold (falls back
to system monospaced). Exports at full retina resolution.

`make install-app` puts Annotate.app in /Applications, so after ⌃⇧⌘4 just
launch it from Spotlight (or any launcher) — the screenshot loads itself.

## Use (headless, for scripts and agents)

Coordinates are image pixels, origin top-left — the same way vision models
report positions. Shape flags are repeatable.

```sh
./annotate in.png \
  --box   x,y,w,h \
  --arrow x1,y1,x2,y2 \
  --text  "x,y,label text" \
  --out   out.png
```

Text that would overflow the image is clamped inside it.

## Example: let Claude do the pointing

```sh
screencapture -i shot.png   # or any existing screenshot

claude -p 'Read shot.png and find every mention of "Flameshot".
Annotate them by running:
  ./annotate shot.png --box x,y,w,h --arrow x1,y1,x2,y2 --text "x,y,label" --out annotated.png
(flags repeatable; coordinates are pixels, origin top-left).
Box each mention, add one arrow + short label for the most important one.
Then read annotated.png back and re-run with corrected coordinates if
anything is misplaced.'
```

The read-back step is what makes this reliable: the model verifies its own
box placement visually and corrects itself. `test-terminal.png` /
`test-annotated.png` in this repo are the output of exactly this workflow.
