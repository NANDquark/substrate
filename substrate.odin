package substrate

import "core:container/bit_array"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

Platform_Type :: enum {
	Unknown       = 0,
	Linux_Wayland = 1,
	Windows       = 2,
	SDL           = 3,
}

Platform_Hint :: enum {
	Vulkan_Compatible,
}

// Configurable via -define:Current_Platform_Type=<platform enum value>.
// Default for now is SDL for stability and Linux/Windows for experimental
// recreational purposes.
Default_Current_Platform_Type :: int(Platform_Type.SDL)

Current_Platform_Type: Platform_Type : Platform_Type(
	#config(Current_Platform_Type, Default_Current_Platform_Type),
)

Platform :: struct {
	allocator:   mem.Allocator,
	logger:      log.Logger,
	app_id:      string,
	app_title:   string,
	window_size: [2]int,
	hints:       bit_set[Platform_Hint],
	data:        Platform_Data_Ptr, // Internal platform-specific data
	vtable:      Platform_VTable,
	input:       Platform_Input,
}

// Internal platform specific data
Platform_Data_Ptr :: distinct rawptr

Platform_VTable :: struct {
	status:  proc(p: ^Platform) -> Platform_Status,
	update:  proc(p: ^Platform),
	present: proc(p: ^Platform),
}

Platform_Input :: struct {
	events:         [dynamic]Event,
	key_down:       bit_array.Bit_Array,
	mouse_down:     [Mouse_Button]bool,
	mouse_pos:      [2]f32,
	mouse_delta:    [2]f32,
	scroll_steps:   [2]f32,
	window_focused: bool,
}

Event :: union {
	Key_Event,
	Mouse_Event,
	Char_Event,
	Focus_Event,
}

MAX_KEY :: 512
Key_Event :: struct {
	key:    int,
	action: Button_Action,
}

Mouse_Event :: struct {
	button: Mouse_Button,
	action: Button_Action,
}

Button_Action :: enum {
	Pressed,
	Released,
}

Char_Event :: struct {
	c: rune,
}

Focus_Action :: enum {
	Gained,
	Lost,
}

Focus_Event :: struct {
	action: Focus_Action,
}

Mouse_Button :: enum int {
	Left   = 0,
	Right  = 1,
	Middle = 2,
}

Platform_Status :: enum {
	User_Quit,
	Running,
	Fatal_Error,
}

Platform_Error :: union #shared_nil {
	enum {
		Unsupported_Platform_Type,
	},
	Linux_Wayland_Error,
	Windows_Error,
	SDL_Error,
}

Linux_Wayland_Error :: union {
	enum {
		Display_Connect_Failed,
		Compositor_Not_Found,
		XKB_Init_Failed,
	},
}

Windows_Error :: union {
	enum {
		Register_Class_Failed,
		Create_Window_Failed,
	},
}

SDL_Error :: union {
	enum {
		Init_Failed,
		Create_Window_Failed,
		Show_Window_Failed,
	},
}

init :: proc(
	p: ^Platform,
	app_id: string,
	app_title: string,
	window_size: [2]int,
	hints := bit_set[Platform_Hint]{},
	logger := context.logger,
	allocator := context.allocator,
) -> Platform_Error {
	context.logger = logger
	context.allocator = allocator

	p.allocator = allocator
	p.logger = logger
	p.app_id = app_id
	p.app_title = app_title
	p.window_size = window_size
	p.hints = hints
	p.input.window_focused = true
	p.input.events.allocator = allocator
	bit_array.init(&p.input.key_down, MAX_KEY)

	when Current_Platform_Type == .Linux_Wayland {
		err := linux_wayland_data_init(p)
		if err != nil {
			log.errorf("failed to create platform, type=%v, err=%v", Current_Platform_Type, err)
		}
		return err
	}

	when Current_Platform_Type == .Windows {
		err := windows_data_init(p)
		if err != nil {
			log.errorf("failed to create platform, type=%v, err=%v", Current_Platform_Type, err)
		}
		return err
	}

	when Current_Platform_Type == .SDL {
		err := sdl_data_init(p)
		if err != nil {
			log.errorf("failed to create platform, type=%v, err=%v", Current_Platform_Type, err)
		}
		return err
	}

	return .Unsupported_Platform_Type
}

destroy :: proc(p: ^Platform) {
	if p == nil do return
	if p.data == Platform_Data_Ptr(nil) && p.vtable.status == nil do return

	when Current_Platform_Type == .Linux_Wayland {
		if p.data != Platform_Data_Ptr(nil) {
			linux_wayland_data_destroy(p)
		}
	}

	when Current_Platform_Type == .Windows {
		if p.data != Platform_Data_Ptr(nil) {
			windows_data_destroy(p)
		}
	}

	when Current_Platform_Type == .SDL {
		if p.data != Platform_Data_Ptr(nil) {
			sdl_data_destroy(p)
		}
	}

	delete(p.input.events)
	p.input.events = {}
	bit_array.destroy(&p.input.key_down)
	p.input.key_down = {}
	p.input.mouse_down = {}
	p.vtable = {}
	p.data = Platform_Data_Ptr(nil)
}

// Check the status, and if not .Running the caller must clean up and exit
status :: proc(p: ^Platform) -> Platform_Status {
	return p.vtable.status(p)
}

// Process all inputs for this frame and update platform state
update :: proc(p: ^Platform) {
	p.input.scroll_steps = {}
	p.vtable.update(p)
}

// Swap graphical buffers to present the current frame's graphics to the window
present :: proc(p: ^Platform) {
	p.vtable.present(p)
	clear(&p.input.events)
}

// Is key currently down, regardless of which frame it started down
is_key_down :: proc(p: ^Platform, #any_int key: int) -> bool {
	return bit_array.get(&p.input.key_down, key)
}

// Was key up last frame and now down this frame
is_key_pressed :: proc(p: ^Platform, #any_int key: int) -> bool {
	for e in p.input.events {
		#partial switch ke in e {
		case Key_Event:
			if ke.key == key && ke.action == .Pressed do return true
		}
	}
	return false
}

// Was key down last frame and now up this frame
is_key_released :: proc(p: ^Platform, #any_int key: int) -> bool {
	for e in p.input.events {
		#partial switch ke in e {
		case Key_Event:
			if ke.key == key && ke.action == .Released do return true
		}
	}
	return false
}

// Is mouse button currently down, regardless of which frame it started down.
is_mouse_down :: proc(p: ^Platform, button: Mouse_Button) -> bool {
	return p.input.mouse_down[button]
}

// Was mouse button up last frame and now down this frame.
is_mouse_pressed :: proc(p: ^Platform, button: Mouse_Button) -> bool {
	for e in p.input.events {
		#partial switch me in e {
		case Mouse_Event:
			if me.button == button && me.action == .Pressed do return true
		}
	}
	return false
}

// Was mouse button down last frame and now up this frame.
is_mouse_released :: proc(p: ^Platform, button: Mouse_Button) -> bool {
	for e in p.input.events {
		#partial switch me in e {
		case Mouse_Event:
			if me.button == button && me.action == .Released do return true
		}
	}
	return false
}

// The mouse position in window coordinates: [x, y].
get_mouse_pos :: proc(p: ^Platform) -> [2]f32 {
	return p.input.mouse_pos
}

// Mouse movement delta from the last pointer update: [dx, dy].
get_mouse_delta :: proc(p: ^Platform) -> [2]f32 {
	return p.input.mouse_delta
}

// The mouse scroll amount in logical steps this frame: [x, y].
get_scroll_steps :: proc(p: ^Platform) -> [2]f32 {
	return p.input.scroll_steps
}

is_window_focused :: proc(p: ^Platform) -> bool {
	return p.input.window_focused
}

@(private)
set_key_down :: proc(p: ^Platform, #any_int key: int) {
	bit_array.set(&p.input.key_down, key)
	// If somehow key_down is sent multiple times a frame generate multiple pressed events
	append(&p.input.events, Key_Event{key = key, action = .Pressed})
}

@(private)
set_key_up :: proc(p: ^Platform, #any_int key: int) {
	was_down := bit_array.get(&p.input.key_down, key)
	if was_down {
		bit_array.unset(&p.input.key_down, key)
		append(&p.input.events, Key_Event{key = key, action = .Released})
	}
}

@(private)
set_mouse_pos :: proc(p: ^Platform, x, y: f32) {
	prev_pos := p.input.mouse_pos
	p.input.mouse_pos = [2]f32{x, y}
	// Convention: delta is previous - current, so positive means movement left/up.
	p.input.mouse_delta = prev_pos - p.input.mouse_pos
}

@(private)
set_mouse_down :: proc(p: ^Platform, button: Mouse_Button) {
	p.input.mouse_down[button] = true
	append(&p.input.events, Mouse_Event{button = button, action = .Pressed})
}

@(private)
set_mouse_up :: proc(p: ^Platform, button: Mouse_Button) {
	was_down := p.input.mouse_down[button]
	if was_down {
		p.input.mouse_down[button] = false
		append(&p.input.events, Mouse_Event{button = button, action = .Released})
	}
}

@(private)
set_scroll_steps :: proc(p: ^Platform, dx, dy: f32) {
	delta := [2]f32{dx, dy}
	p.input.scroll_steps += delta
}

@(private)
set_char :: proc(p: ^Platform, c: rune) {
	append(&p.input.events, Char_Event{c = c})
}

@(private)
release_all_down_inputs :: proc(p: ^Platform) {
	for key in 0 ..< MAX_KEY {
		set_key_up(p, key)
	}
	for button in Mouse_Button {
		set_mouse_up(p, button)
	}
}

@(private)
set_window_focus :: proc(p: ^Platform, focused: bool) {
	if p.input.window_focused == focused do return
	if !focused {
		release_all_down_inputs(p)
		append(&p.input.events, Focus_Event{action = .Lost})
	} else {
		append(&p.input.events, Focus_Event{action = .Gained})
	}
	p.input.window_focused = focused
}

set_hint :: proc(p: ^Platform, hint: Platform_Hint, enabled := true) {
	if p == nil do return
	if enabled {
		p.hints += {hint}
	} else {
		p.hints -= {hint}
	}
}

has_hint :: proc(p: ^Platform, hint: Platform_Hint) -> bool {
	if p == nil do return false
	return hint in p.hints
}

vulkan_required_extensions :: proc() -> []cstring {
	when Current_Platform_Type == .Linux_Wayland {
		return [2]cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME}[:]
	}
	when Current_Platform_Type == .Windows {
		return [2]cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WIN32_SURFACE_EXTENSION_NAME}[:]
	}
	when Current_Platform_Type == .SDL {
		return sdl_vulkan_required_extensions()
	}
	return nil
}

vulkan_create_surface :: proc(p: ^Platform, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	when Current_Platform_Type == .Linux_Wayland {
		data := (^Linux_Wayland_Data)(p.data)
		create_info := vk.WaylandSurfaceCreateInfoKHR {
			sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
			flags   = {},
			display = (^vk.wl_display)(data.window.display),
			surface = (^vk.wl_surface)(data.window.surface),
		}
		surface: vk.SurfaceKHR
		result := vk.CreateWaylandSurfaceKHR(instance, &create_info, nil, &surface)
		if result != .SUCCESS {
			return {}, false
		}
		data.window.vulkan_active = true
		return surface, true
	}

	when Current_Platform_Type == .Windows {
		data := (^Windows_Data)(p.data)
		create_info := vk.Win32SurfaceCreateInfoKHR {
			sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
			flags     = {},
			hinstance = data.hinstance,
			hwnd      = data.hwnd,
		}
		surface: vk.SurfaceKHR
		result := vk.CreateWin32SurfaceKHR(instance, &create_info, nil, &surface)
		if result != .SUCCESS {
			data.status = .Fatal_Error
			log.errorf("vkCreateWin32SurfaceKHR failed, result=%v", result)
			return {}, false
		}
		data.vulkan_active = true
		return surface, true
	}

	when Current_Platform_Type == .SDL {
		return sdl_vulkan_create_surface(p, instance)
	}

	return {}, false
}
