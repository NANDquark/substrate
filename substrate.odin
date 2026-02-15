package substrate

import "core:container/bit_array"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

// Configurable via -define:Current_Platform_Type=1
Current_Platform_Type: Platform_Type : #config(Current_Platform_Type, Platform_Type.Linux_Wayland)

Platform_Type :: enum {
	Unknown       = 0,
	Linux_Wayland = 1,
}

Platform :: struct {
	allocator:   mem.Allocator,
	logger:      log.Logger,
	app_id:      string,
	app_title:   string,
	window_size: [2]int,
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
	events:      [dynamic]Event,
	key_down:    bit_array.Bit_Array,
	mouse_down:  bit_array.Bit_Array,
	mouse_pos:   [2]f32,
	mouse_delta: [2]f32,
}

Event :: union {
	Key_Event,
	Mouse_Event,
	Char_Event,
}

MAX_KEY :: 512
MAX_MOUSE :: 48

Key_Event :: struct {
	key:    int,
	action: Button_Action,
}

Mouse_Event :: struct {
	button: int,
	action: Button_Action,
}

Button_Action :: enum {
	Pressed,
	Released,
}

Char_Event :: struct {
	c: rune,
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
}

init :: proc(
	p: ^Platform,
	app_id: string,
	app_title: string,
	window_size: [2]int,
	logger := context.logger,
	allocator := context.allocator,
) -> Platform_Error {
	context.logger = logger
	context.allocator = allocator

	when Current_Platform_Type == .Linux_Wayland {
		p.allocator = allocator
		p.logger = logger
		p.app_id = app_id
		p.app_title = app_title
		p.window_size = window_size
		p.input.events.allocator = allocator
		bit_array.init(&p.input.key_down, MAX_KEY)
		bit_array.init(&p.input.mouse_down, MAX_MOUSE)
		err := linux_wayland_data_init(p)
		if err != nil {
			log.errorf("failed to create platform, type=%v, err=%v", Current_Platform_Type, err)
		}
		return err
	}

	return .Unsupported_Platform_Type
}

destroy :: proc(p: ^Platform) {
	when Current_Platform_Type == .Linux_Wayland {
		linux_wayland_data_destroy(p)
		delete(p.input.events)
		bit_array.destroy(&p.input.key_down)
		bit_array.destroy(&p.input.mouse_down)
	}
}

// Check the status, and if not .Running the caller must clean up and exit
status :: proc(p: ^Platform) -> Platform_Status {
	return p.vtable.status(p)
}

// Process all inputs for this frame and update platform state
update :: proc(p: ^Platform) {
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
	was_key_up := !bit_array.get(&p.input.key_down, key)
	if !was_key_up do return false
	for e in p.input.events {
		#partial switch ke in e {
		case Key_Event:
			if ke.action == .Pressed do return true
		}
	}
	return false
}

// Was key down last frame and now up this frame
is_key_released :: proc(p: ^Platform, #any_int key: int) -> bool {
	was_key_down := bit_array.get(&p.input.key_down, key)
	if !was_key_down do return false
	for e in p.input.events {
		#partial switch ke in e {
		case Key_Event:
			if ke.action == .Released do return true
		}
	}
	return false
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
	p.input.mouse_delta = prev_pos - p.input.mouse_pos
}

@(private)
set_mouse_down :: proc(p: ^Platform, #any_int button: int) {
	bit_array.set(&p.input.mouse_down, button)
	append(&p.input.events, Mouse_Event{button = button, action = .Pressed})
}

@(private)
set_mouse_up :: proc(p: ^Platform, #any_int button: int) {
	was_down := bit_array.get(&p.input.mouse_down, button)
	if was_down {
		bit_array.unset(&p.input.mouse_down, button)
		append(&p.input.events, Mouse_Event{button = button, action = .Released})
	}
}

@(private)
set_char :: proc(p: ^Platform, c: rune) {
	append(&p.input.events, Char_Event{c = c})
}

required_vulkan_extensions :: proc() -> [2]cstring {
	return [2]cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME}
}

create_vulkan_surface :: proc(p: ^Platform, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
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
