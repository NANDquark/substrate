package substrate

import "core:c"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

SDL_MAX_VK_EXTENSIONS :: 16

SDL_Data :: struct {
	status: Platform_Status,
	window: ^sdl.Window,
}

@(private)
_sdl_vulkan_extensions_buffer: [SDL_MAX_VK_EXTENSIONS]cstring

sdl_data_init :: proc(p: ^Platform) -> SDL_Error {
	init_success := false
	data := new(SDL_Data)
	data.status = .Running
	p.data = Platform_Data_Ptr(data)
	defer if !init_success do sdl_data_destroy(p)

	p.vtable = Platform_VTable {
		status  = sdl_status,
		update  = sdl_update,
		present = sdl_present,
	}

	if !sdl.Init(sdl.INIT_VIDEO | sdl.INIT_EVENTS) {
		log.errorf("SDL_Init failed: %s", string(sdl.GetError()))
		return .Init_Failed
	}

	title, title_err := strings.clone_to_cstring(p.app_title, context.temp_allocator)
	if title_err != nil {
		log.errorf("failed to allocate app title cstring: %v", title_err)
		return .Create_Window_Failed
	}
	app_id_cstr, app_id_err := strings.clone_to_cstring(p.app_id, context.temp_allocator)
	if app_id_err != nil {
		log.errorf("failed to allocate app id cstring: %v", app_id_err)
		return .Create_Window_Failed
	}
	_ = sdl.SetAppMetadata(title, "0.1.0", app_id_cstr)

	flags := sdl.WINDOW_RESIZABLE | sdl.WINDOW_HIGH_PIXEL_DENSITY
	if has_hint(p, .Vulkan_Compatible) {
		flags |= sdl.WINDOW_VULKAN
	}

	data.window = sdl.CreateWindow(title, c.int(p.window_size[0]), c.int(p.window_size[1]), flags)
	if data.window == nil {
		log.errorf("SDL_CreateWindow failed: %s", string(sdl.GetError()))
		return .Create_Window_Failed
	}
	if !sdl.ShowWindow(data.window) {
		log.errorf("SDL_ShowWindow failed: %s", string(sdl.GetError()))
		return .Show_Window_Failed
	}
	// Give focus to the created window in case the WM starts it obscured.
	sdl.RaiseWindow(data.window)

	init_success = true
	return nil
}

sdl_data_destroy :: proc(p: ^Platform) {
	data := cast(^SDL_Data)p.data
	if data == nil {
		return
	}

	if data.window != nil {
		sdl.DestroyWindow(data.window)
		data.window = nil
	}
	sdl.Quit()

	free(data)
	p.data = Platform_Data_Ptr(nil)
}

sdl_status :: proc(p: ^Platform) -> Platform_Status {
	data := cast(^SDL_Data)p.data
	if data == nil {
		return .Fatal_Error
	}
	return data.status
}

sdl_present :: proc(p: ^Platform) {}

sdl_update :: proc(p: ^Platform) {
	data := cast(^SDL_Data)p.data
	if data == nil || data.window == nil {
		return
	}

	window_id := sdl.GetWindowID(data.window)
	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			data.status = .User_Quit
		case .WINDOW_CLOSE_REQUESTED:
			if event.window.windowID == window_id {
				data.status = .User_Quit
			}
		case .WINDOW_FOCUS_LOST:
			if event.window.windowID == window_id {
				set_window_focus(p, false)
			}
		case .WINDOW_FOCUS_GAINED:
			if event.window.windowID == window_id {
				set_window_focus(p, true)
			}
		case .MOUSE_MOTION:
			if event.motion.windowID == window_id {
				set_mouse_pos(p, event.motion.x, event.motion.y)
			}
		case .MOUSE_BUTTON_DOWN:
			if event.button.windowID == window_id {
				button, ok := sdl_mouse_button_to_enum(event.button.button)
				if ok {
					set_mouse_down_checked(p, button)
				}
			}
		case .MOUSE_BUTTON_UP:
			if event.button.windowID == window_id {
				button, ok := sdl_mouse_button_to_enum(event.button.button)
				if ok {
					set_mouse_up_checked(p, button)
				}
			}
		case .MOUSE_WHEEL:
			if event.wheel.windowID == window_id {
				scroll_step := [2]f32{event.wheel.x, event.wheel.y}
				if event.wheel.integer_x != 0 || event.wheel.integer_y != 0 {
					scroll_step = {f32(event.wheel.integer_x), f32(event.wheel.integer_y)}
				}
				if event.wheel.direction == .FLIPPED {
					scroll_step.x = -scroll_step.x
					scroll_step.y = -scroll_step.y
				}
				// Match existing substrate scroll convention for zoom direction.
				scroll_step.y = -scroll_step.y
				set_scroll_steps(p, scroll_step.x, scroll_step.y)
			}
		case .KEY_DOWN:
			if event.key.windowID == window_id {
				key, ok := sdl_scancode_to_key(event.key.scancode)
				if ok {
					set_key_down_checked(p, key)
				}
			}
		case .KEY_UP:
			if event.key.windowID == window_id {
				key, ok := sdl_scancode_to_key(event.key.scancode)
				if ok {
					set_key_up_checked(p, key)
				}
			}
		}
	}
}

sdl_mouse_button_to_enum :: proc(button: sdl.Uint8) -> (Mouse_Button, bool) {
	switch button {
	case sdl.BUTTON_LEFT:
		return .Left, true
	case sdl.BUTTON_RIGHT:
		return .Right, true
	case sdl.BUTTON_MIDDLE:
		return .Middle, true
	}
	return .Left, false
}

sdl_scancode_to_key :: proc(scancode: sdl.Scancode) -> (int, bool) {
	#partial switch scancode {
	case .A:
		return int(Key.A), true
	case .D:
		return int(Key.D), true
	case .W:
		return int(Key.W), true
	case .S:
		return int(Key.S), true
	}
	return 0, false
}

set_key_down_checked :: proc(p: ^Platform, key: int) {
	if key < 0 || key >= MAX_KEY do return
	set_key_down(p, key)
}

set_key_up_checked :: proc(p: ^Platform, key: int) {
	if key < 0 || key >= MAX_KEY do return
	set_key_up(p, key)
}

set_mouse_down_checked :: proc(p: ^Platform, button: Mouse_Button) {
	set_mouse_down(p, button)
}

set_mouse_up_checked :: proc(p: ^Platform, button: Mouse_Button) {
	set_mouse_up(p, button)
}

sdl_vulkan_required_extensions :: proc() -> []cstring {
	when Current_Platform_Type != .SDL {
		return nil
	}

	count: sdl.Uint32
	extensions := sdl.Vulkan_GetInstanceExtensions(&count)
	if extensions == nil {
		return nil
	}

	n := int(count)
	if n > len(_sdl_vulkan_extensions_buffer) {
		n = len(_sdl_vulkan_extensions_buffer)
	}
	for i in 0 ..< n {
		_sdl_vulkan_extensions_buffer[i] = extensions[i]
	}
	return _sdl_vulkan_extensions_buffer[:n]
}

sdl_vulkan_create_surface :: proc(p: ^Platform, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	when Current_Platform_Type != .SDL {
		return {}, false
	}

	data := cast(^SDL_Data)p.data
	if data == nil || data.window == nil {
		return {}, false
	}

	surface: vk.SurfaceKHR
	if !sdl.Vulkan_CreateSurface(data.window, instance, nil, &surface) {
		log.errorf("SDL_Vulkan_CreateSurface failed: %s", string(sdl.GetError()))
		return {}, false
	}
	return surface, true
}

get_sdl_window :: proc(p: ^Platform) -> (^sdl.Window, bool) {
	when Current_Platform_Type != .SDL {
		return nil, false
	}
	data := cast(^SDL_Data)p.data
	if data == nil || data.window == nil {
		return nil, false
	}
	return data.window, true
}
