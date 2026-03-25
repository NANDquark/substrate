# Substrate - Platform Layer in Odin

This package provides a minimal native platform layer in Odin.

Supported platforms:
- `Linux_Wayland`
- `Windows`
- `SDL`

`Current_Platform_Type` values:
- `Linux_Wayland = 1`
- `Windows = 2`
- `SDL = 3`

## Dependencies

Initialize submodules first:

`git submodule update --init --recursive`

### Linux (Wayland)

- libdecor-devel
- libwayland-egl
- libwayland-client
- libxkbcommon-devel

### Windows

- MSVC toolchain (Visual Studio Build Tools or Visual Studio with C++ tools)
- Windows SDK

## Type-check Commands

This package is a library, so use `-no-entry-point`.
`Current_Platform_Type` defaults to `SDL` for stable, cross-platform behavior.

Windows backend:

`odin check . -no-entry-point -target:windows_amd64`

Linux backend:

`odin check . -no-entry-point -target:linux_amd64`

## Demo Commands

Windows demo:

`odin run demos/windows`

Linux Wayland demo:

`odin run demos/linux-wayland`

To force a platform selection explicitly, override with:

`-define:Current_Platform_Type=<numeric value>`

## Inputs

- Key identifiers are backend-native:
  - Linux/Wayland uses XKB keysyms.
  - Windows uses Win32 virtual-key values.

## Test Input Socket

Linux builds can expose an opt-in Unix socket for low-level test input injection.

Environment variables:

- `SUBSTRATE_INPUT_SOCKET=/absolute/path/to/substrate-input.sock`
- `APP_CONTROL_SOCKET=/absolute/path/to/substrate-input.sock` as a temporary compatibility alias when `SUBSTRATE_INPUT_SOCKET` is unset
- `SUBSTRATE_INPUT_VERBOSE=1` to log client connect/disconnect and rejection events

Protocol:

- Unix domain socket
- one JSON object per line (`jsonl`)
- one JSON response per request
- single active client at a time

Supported commands:

- `{"id":"1","cmd":"ping"}`
- `{"id":"2","cmd":"key_down","key":65}`
- `{"id":"3","cmd":"key_up","key":65}`
- `{"id":"4","cmd":"key_tap","key":65307}`
- `{"id":"5","cmd":"text","text":"hello"}`
- `{"id":"6","cmd":"mouse_move","x":320,"y":240}`
- `{"id":"7","cmd":"mouse_down","button":"left"}`
- `{"id":"8","cmd":"mouse_up","button":"left"}`
- `{"id":"9","cmd":"mouse_click","button":"left"}`
- `{"id":"10","cmd":"scroll","dx":0,"dy":-1}`
- `{"id":"11","cmd":"set_focus","focused":true}`
- `{"id":"12","cmd":"reset_inputs"}`
- `{"id":"13","cmd":"close"}`

Response examples:

- `{"id":"1","ok":true}`
- `{"id":"2","ok":false,"error":"unknown command"}`

Notes:

- This injects low-level substrate input only. It is not an application-owned control API.
- `key` uses the same backend-specific integer values substrate already uses internally.
- `text` generates `Char_Event`s; it does not synthesize physical key chords.
- `mouse_move` uses window-local coordinates, with the application top-left at `0,0`.
- `mouse_click` presses immediately and releases on the next platform update so UI code sees a real click across two frames.

Manual smoke example:

```bash
export SUBSTRATE_INPUT_SOCKET="$PWD/.gui/substrate-input.sock"
mkdir -p .gui
printf '%s\n' '{"id":"1","cmd":"ping"}' | socat - UNIX-CONNECT:"$SUBSTRATE_INPUT_SOCKET"
printf '%s\n' '{"id":"2","cmd":"mouse_move","x":100,"y":120}' | socat - UNIX-CONNECT:"$SUBSTRATE_INPUT_SOCKET"
printf '%s\n' '{"id":"3","cmd":"mouse_click","button":"left"}' | socat - UNIX-CONNECT:"$SUBSTRATE_INPUT_SOCKET"
```
