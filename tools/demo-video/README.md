# Quick Prompt demo video

Tools for recording and cutting `site/assets/quick-prompt-demo.mp4` and its poster. They use AVFoundation and ScreenCaptureKit, so no ffmpeg is needed.

## Build

```bash
mkdir -p tools/demo-video/bin && for f in tools/demo-video/*.swift; do swiftc -O "$f" -o "tools/demo-video/bin/$(basename "$f" .swift)"; done
```

The `bin/` folder is git-ignored. Deprecation warnings are expected.

| Tool | Use |
| --- | --- |
| `backdrop` | Full-screen navy (`#15213e`) window behind everything. Run in the background, `pkill -x backdrop` when done. |
| `record out.mov seconds x y w h` | Records a screen region at 2x with the cursor hidden and Claude's windows left out. Points, top-left origin. |
| `frames in out-dir step [start end] [maxWidth]` | JPEG frames plus a per-step change score, for finding event times. |
| `sheet out.jpg cols cellWidth files...` | Contact sheet of frames. |
| `edit in.mov out.mp4 spec.json` | The cut. Prints the output duration and the cue times for the page's step labels. |
| `rawframe in.mp4 t out.png` | A frame with its values as browsers show them. Use it for the poster so the poster and the video match. |

## Record a take

1. Run `./build.sh` if `Sources/` changed. Size the Duet workspace to 1189×702 at (140, 112), then minimize it.
2. Start `backdrop`. Run `osascript tools/demo-video/mail-draft.applescript` to open the Mail draft. Then run `open -a Mail`, because Mail doesn't draw the draft body until it's frontmost.
3. Clear any leftover text in Quick Prompt (Tools → Quick Prompt, empty the field, close the panel).
4. Start the recorder in the background: `nohup tools/demo-video/bin/record take.mov 130 96 71 1277 784 &`.
5. Click at the end of the draft body and press ⌃⌥Space for real (the global shortcut ignores synthetic input). Type "Give me one icebreaker for Monday's team demo. One sentence." and click Both with a real click. An accessibility press sends the prompt but leaves Duet behind Mail.
6. Let both answers finish. About 60 seconds of footage covers the whole take.

Each take starts a new conversation in both accounts. When you're done, close the Mail draft without sending, delete the autosaved copy from Drafts, and stop `backdrop`.

## Cut it

`quick-prompt-demo.json` is the spec for the current video. Its source times belong to that take, so after a new recording, find the new event times with `frames` and `sheet` and update `segments`, `chip`, `lift`, `camera`, `cursor`, `clicks` and `xfade` to match. Paths in the spec are relative to the repository root, so run from there:

```bash
tools/demo-video/bin/edit take.mov site/assets/quick-prompt-demo.mp4 tools/demo-video/quick-prompt-demo.json
```

- **Spec fields:** see the header comment in `edit.swift`. Camera and overlay positions are in output pixels (1600×982, top-left origin), measured before any zoom.
- **Step labels:** copy the printed `cues` into the `data-start` attributes of `.demo-steps` in `site/index.html`. Press starts at 0.
- **Poster:** pick a frame that tells the story on its own, since reduced-motion viewers only see the poster. Then run `tools/demo-video/bin/rawframe site/assets/quick-prompt-demo.mp4 7.2 poster.png` and `cwebp -q 80 -m 6 -metadata none poster.png -o site/assets/quick-prompt-demo-poster.webp`.
- **Check before shipping:** extract frames and look for anything private (the Mail From row shows the sender's address until Quick Prompt covers it), the prompt drawer, and warning toasts. Confirm both answers finish before the outro.
