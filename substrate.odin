package substrate

import "core:container/bit_array"
import "core:log"
import "core:mem"
import vk "vendor:vulkan"

Platform_Type :: enum {
	Unknown       = 0,
	Linux_Wayland = 1,
	Windows       = 2,
}

// Configurable via -define:Current_Platform_Type=<platform enum value>.
// Default follows the target OS so native demo commands do not need -define.
when ODIN_OS == .Windows {
	Default_Current_Platform_Type :: int(Platform_Type.Windows)
} else when ODIN_OS == .Linux {
	Default_Current_Platform_Type :: int(Platform_Type.Linux_Wayland)
} else {
	Default_Current_Platform_Type :: int(Platform_Type.Unknown)
}

Current_Platform_Type: Platform_Type : Platform_Type(
	#config(Current_Platform_Type, Default_Current_Platform_Type),
)

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
	Windows_Error,
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

	p.allocator = allocator
	p.logger = logger
	p.app_id = app_id
	p.app_title = app_title
	p.window_size = window_size
	p.input.events.allocator = allocator
	bit_array.init(&p.input.key_down, MAX_KEY)
	bit_array.init(&p.input.mouse_down, MAX_MOUSE)

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

	delete(p.input.events)
	p.input.events = {}
	bit_array.destroy(&p.input.key_down)
	p.input.key_down = {}
	bit_array.destroy(&p.input.mouse_down)
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

vulkan_required_extensions :: proc() -> [2]cstring {
	when Current_Platform_Type == .Linux_Wayland {
		return [2]cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME}
	}
	when Current_Platform_Type == .Windows {
		return [2]cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WIN32_SURFACE_EXTENSION_NAME}
	}
	return {}
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

	return {}, false
}

