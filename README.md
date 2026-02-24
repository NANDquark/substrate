# Substrate - Platform Layer in Odin

This package provides a minimal native platform layer in Odin.

Supported platforms:
- `Linux_Wayland`
- `Windows`

`Current_Platform_Type` values:
- `Linux_Wayland = 1`
- `Windows = 2`

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
`Current_Platform_Type` defaults from the target OS, so `-define` is usually unnecessary.

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
