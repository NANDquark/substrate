#+private
package substrate

import "base:runtime"
import "core:container/bit_array"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import wl "lib/odin-wayland"
import "lib/odin-wayland/ext/libdecor"
import xkb "lib/xkb"
import gl "vendor:OpenGL"
import "vendor:egl"

Linux_Wayland_Data :: struct {
	status: Platform_Status,
	input:  Linux_Wayland_Input,
	window: struct {
		display:        ^wl.display,
		surface:        ^wl.surface,
		registry:       ^wl.registry,
		egl_display:    egl.Display,
		egl_window:     ^wl.egl_window,
		egl_surface:    egl.Surface,
		egl_context:    egl.Context,
		compositor:     ^wl.compositor,
		region:         ^wl.region,
		instance:       ^libdecor.instance,
		window_state:   libdecor.window_state,
		maximized:      bool,
		frame:          ^libdecor.frame,
		size, geometry: Size,
	},
}

Linux_Wayland_Input :: struct {
	seat:          ^wl.seat,
	seat_name:     cstring,
	pointer:       ^wl.pointer,
	xkb_context:   ^xkb.ctx,
	xkb_keymap:    ^xkb.keymap,
	xkb_state:     ^xkb.state,
	keyboard:      ^wl.keyboard,
	key_down_prev: ^bit_array.Bit_Array,
	key_down_curr: ^bit_array.Bit_Array,
}

Size :: [2]int

Linux_Wayland_Error :: union {
	enum {
		Display_Connect_Failed,
		EGL_Display_Failed,
		Compositor_Not_Found,
		XKB_Init_Failed,
	},
}

linux_wayland_data_init :: proc(p: ^Platform) -> Linux_Wayland_Error {
	context.allocator = p.allocator
	context.logger = p.logger

	init_success := false

	platform_data := new(Linux_Wayland_Data)
	_temp_global_platform = p // temp hack, see interface_error below
	platform_data.status = .Running
	init_input(&platform_data.input)
	p.data = Platform_Data_Ptr(platform_data)
	defer if !init_success do linux_wayland_data_destroy(p)

	p.vtable = Platform_VTable {
		status  = linux_wayland_status,
		update  = linux_wayland_update,
		present = linux_wayland_present,
	}

	window := &platform_data.window
	window.geometry = {1280, 720}
	window.size = {1280, 720}
	window.display = wl.display_connect(nil)
	if window.display == nil {
		return .Display_Connect_Failed
	}
	window.registry = wl.display_get_registry(window.display)
	wl.registry_add_listener(window.registry, &registry_listener, p)
	wl.display_roundtrip(window.display)
	window.surface = wl.compositor_create_surface(window.compositor)
	if window.compositor == nil {
		return .Compositor_Not_Found
	}

	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)
	config_attribs := []i32{egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.NONE}

	window.egl_display = egl.GetDisplay(cast(egl.NativeDisplayType)window.display)
	if window.egl_display == nil {
		return .EGL_Display_Failed
	}
	egl.Initialize(window.egl_display, &major, &minor)
	log.infof("EGL version: %v.%v", major, minor)

	config: egl.Config
	num_config: i32
	egl.ChooseConfig(window.egl_display, raw_data(config_attribs), &config, 1, &num_config)
	window.egl_context = egl.CreateContext(window.egl_display, config, nil, nil)
	window.egl_window = wl.egl_window_create(window.surface, window.size.x, window.size.y)
	window.egl_surface = egl.CreateWindowSurface(
		window.egl_display,
		config,
		cast(egl.NativeWindowType)window.egl_window,
		nil,
	)
	wl.surface_commit(window.surface)
	egl.MakeCurrent(window.egl_display, window.egl_surface, window.egl_surface, window.egl_context)
	gl.load_up_to(4, 6, egl.gl_set_proc_address)
	window.instance = libdecor.new(window.display, &decor)
	window.frame = libdecor.decorate(window.instance, window.surface, &frame_decor, p)
	libdecor.frame_set_app_id(window.frame, "odin-wayland-egl")
	libdecor.frame_set_title(window.frame, "Hellope from Wayland, EGL & libdecor!")
	libdecor.frame_map(window.frame)

	// Requires calling dispatch twice to get a configure event
	wl.display_dispatch(window.display)
	wl.display_dispatch(window.display)

	init_success = true
	return nil
}

linux_wayland_data_destroy :: proc(p: ^Platform) {
	context = runtime.default_context()
	context.allocator = p.allocator

	data := cast(^Linux_Wayland_Data)p.data
	if data == nil do return

	input := &data.input
	if input.xkb_state != nil {
		xkb.state_unref(input.xkb_state)
	}
	if input.xkb_keymap != nil {
		xkb.keymap_unref(input.xkb_keymap)
	}
	if input.xkb_context != nil {
		xkb.context_unref(input.xkb_context)
	}
	bit_array.destroy(input.key_down_prev)
	bit_array.destroy(input.key_down_curr)

	window := &data.window
	if window.frame != nil {
		libdecor.frame_unref(window.frame)
	}
	if window.instance != nil {
		libdecor.unref(window.instance)
	}
	if window.egl_display != nil {
		egl.MakeCurrent(window.egl_display, nil, nil, nil)
		if window.egl_surface != nil {
			egl.DestroySurface(window.egl_display, window.egl_surface)
		}
		if window.egl_context != nil {
			egl.DestroyContext(window.egl_display, window.egl_context)
		}
		egl.Terminate(window.egl_display)
	}
	if window.egl_window != nil {
		wl.egl_window_destroy(window.egl_window)
	}
	if window.surface != nil {
		wl.surface_destroy(window.surface)
	}
	if window.compositor != nil {
		wl.compositor_destroy(window.compositor)
	}
	if window.registry != nil {
		wl.registry_destroy(window.registry)
	}
	if window.display != nil {
		wl.display_disconnect(window.display)
	}

	free(data)
	data = nil
}

// Note this does NOT initialize the key_down_prev and key_down_curr yet so that
// it can be based on the keymap after the wl seat & keyboard init
init_input :: proc(input: ^Linux_Wayland_Input) -> Linux_Wayland_Error {
	input.xkb_context = xkb.context_new(.No_Flags)
	if input.xkb_context == nil {
		return .XKB_Init_Failed
	}
	return nil
}

linux_wayland_status :: proc(p: ^Platform) -> Platform_Status {
	data := cast(^Linux_Wayland_Data)p.data
	return data.status
}

linux_wayland_update :: proc(p: ^Platform) {
	context.allocator = p.allocator
	context.logger = p.logger
	data := cast(^Linux_Wayland_Data)p.data
	display := data.window.display

	wl.display_flush(display)
	if wl.display_dispatch_pending(display) == -1 {
		data.status = .Fatal_Error
		log.errorf("Wayland dispatch error, err=%v", wl.display_get_error(display))
	}
}

linux_wayland_present :: proc(p: ^Platform) {
	data := cast(^Linux_Wayland_Data)p.data
	egl.SwapBuffers(data.window.egl_display, data.window.egl_surface)
	wl.display_flush(data.window.display)
}

registry_listener := wl.registry_listener {
	global        = registry_global,
	global_remove = registry_global_remove,
}

decor := libdecor.interface {
	error = interface_error,
}

frame_decor := libdecor.frame_interface {
	commit    = frame_commit,
	close     = frame_close,
	configure = frame_configure,
}

frame_close :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {
	p := cast(^Platform)user_data
	data := cast(^Linux_Wayland_Data)p.data
	data.status = .User_Quit
}

frame_commit :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {}

frame_configure :: proc "c" (
	frame: ^libdecor.frame,
	configuration: ^libdecor.configuration,
	user_data: rawptr,
) {
	p := cast(^Platform)user_data
	data := cast(^Linux_Wayland_Data)p.data
	window := &data.window
	width, height: int
	state: ^libdecor.state

	if !libdecor.configuration_get_content_size(configuration, frame, &width, &height) {
		width = window.geometry.x
		height = window.geometry.y
	}
	if width > 0 && height > 0 {
		if !window.maximized {
			window.size = {width, height}
		}
		window.geometry = {width, height}
	} else if !window.maximized {
		window.geometry = window.size
	}

	wl.egl_window_resize(window.egl_window, width, height, 0, 0)

	state = libdecor.state_new(width, height)
	libdecor.frame_commit(frame, state, configuration)
	libdecor.state_free(state)
	window_state: libdecor.window_state
	if !libdecor.configuration_get_window_state(configuration, &window_state) do window_state = {}

	window.maximized = window_state & {.MAXIMIZED, .FULLSCREEN} != {}
}

@(private = "file")
_temp_global_platform: ^Platform

interface_error :: proc "c" (
	instance: ^libdecor.instance,
	error: libdecor.error,
	message: cstring,
) {
	// get_user_data fails to link for some reason
	// data := cast(^Linux_Wayland_Data)libdecor.get_user_data(instance)
	p := _temp_global_platform
	if p.data == nil do return
	pdata := cast(^Linux_Wayland_Data)p.data
	pdata.status = .Fatal_Error
}

registry_global :: proc "c" (
	user_data: rawptr,
	registry: ^wl.registry,
	name: uint,
	interface_name: cstring,
	version: uint,
) {
	p := cast(^Platform)user_data
	data := cast(^Linux_Wayland_Data)p.data

	switch interface_name {
	case wl.compositor_interface.name:
		data.window.compositor = cast(^wl.compositor)wl.registry_bind(
			registry,
			name,
			&wl.compositor_interface,
			version,
		)
	case wl.seat_interface.name:
		data.input.seat = cast(^wl.seat)wl.registry_bind(
			registry,
			name,
			&wl.seat_interface,
			version,
		)
		wl.seat_add_listener(data.input.seat, seat_listener, p)
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

seat_listener := &wl.seat_listener {
	capabilities = proc "c" (user_data: rawptr, seat: ^wl.seat, capabilities: wl.seat_capability) {
		p := cast(^Platform)user_data
		data := cast(^Linux_Wayland_Data)p.data
		if uint(capabilities & .pointer) != 0 && data.input.pointer == nil {
			data.input.pointer = wl.seat_get_pointer(data.input.seat)
			wl.pointer_add_listener(data.input.pointer, pointer_listener, p)
		}
		if uint(capabilities & .keyboard) != 0 && data.input.keyboard == nil {
			data.input.keyboard = wl.seat_get_keyboard(data.input.seat)
			wl.keyboard_add_listener(data.input.keyboard, keyboard_listener, p)
		}
	},
	name = proc "c" (user_data: rawptr, seat: ^wl.seat, name: cstring) {
		p := cast(^Platform)user_data
		data := cast(^Linux_Wayland_Data)p.data
		data.input.seat_name = name
	},
}

pointer_listener := &wl.pointer_listener {
	enter = proc "c" (
		user_data: rawptr,
		pointer: ^wl.pointer,
		serial: uint,
		surface: ^wl.surface,
		surface_x: wl.fixed_t,
		surface_y: wl.fixed_t,
	) {},
	leave = proc "c" (
		user_data: rawptr,
		pointer: ^wl.pointer,
		serial_: uint,
		surface_: ^wl.surface,
	) {},
	motion = proc "c" (
		user_data: rawptr,
		pointer: ^wl.pointer,
		time: uint,
		surface_x: wl.fixed_t,
		surface_y: wl.fixed_t,
	) {},
	button = proc "c" (
		user_data: rawptr,
		pointer: ^wl.pointer,
		serial: uint,
		time: uint,
		button: uint,
		state: wl.pointer_button_state,
	) {
		context = runtime.default_context()
		p := cast(^Platform)user_data
		context.allocator = p.allocator
		context.logger = p.logger

		switch state {
		case .pressed:
			set_mouse_down(p, button)
		case .released:
			set_mouse_up(p, button)
		}
	},
	axis = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		time: uint,
		axis: wl.pointer_axis,
		value: wl.fixed_t,
	) {},
	frame = proc "c" (data: rawptr, pointer: ^wl.pointer) {},
	axis_source = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis_source: wl.pointer_axis_source,
	) {},
	axis_stop = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		time: uint,
		axis: wl.pointer_axis,
	) {},
	axis_discrete = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis: wl.pointer_axis,
		discrete: int,
	) {},
	axis_value120 = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis: wl.pointer_axis,
		value120: int,
	) {},
	axis_relative_direction = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis: wl.pointer_axis,
		direction: wl.pointer_axis_relative_direction,
	) {},
}

// evdev modifier scancodes
Linux_Wayland_Modifier :: enum {
	L_Shift     = 42,
	R_Shift     = 54,
	L_Control   = 29,
	R_Control   = 97,
	L_Alt       = 56,
	R_Alt       = 100, // Often AltGr
	L_Super     = 125, // Windows/Command Key
	R_Super     = 126,
	Caps_Lock   = 58,
	Num_Lock    = 69,
	Scroll_Lock = 70,
	Menu        = 127, // The "right-click" keyboard key
}

keyboard_listener := &wl.keyboard_listener {
	keymap = proc "c" (
		user_data: rawptr,
		keyboard: ^wl.keyboard,
		format: wl.keyboard_keymap_format,
		fd: int,
		size: uint,
	) {
		p := cast(^Platform)user_data
		data := cast(^Linux_Wayland_Data)p.data
		context = runtime.default_context()
		context.allocator = p.allocator
		context.logger = p.logger

		success := false
		defer if !success {
			data.status = .Fatal_Error
		}

		defer linux.close(linux.Fd(fd))

		if format != .xkb_v1 {
			log.error("received unsupported XKB keymap, format=%v", format)
			return
		}

		// The keymap can change when a user changes keyboard layout/language.
		// If an existing keymap exists and clean it up before loading the new
		// one.
		if data.input.xkb_keymap != nil {
			xkb.keymap_unref(data.input.xkb_keymap)
			data.input.xkb_keymap = nil
			// state is directly tied to keymap so reset it too
			if data.input.xkb_state != nil {
				xkb.state_unref(data.input.xkb_state)
				data.input.xkb_state = nil
			}
		}

		keymap_ptr, mmap_errno := linux.mmap(0, size, {.READ}, {.PRIVATE}, linux.Fd(fd))
		if mmap_errno != .NONE {
			log.errorf("failed to process XKB keymap, err=%v", mmap_errno)
			return
		}
		defer {
			munmap_errno := linux.munmap(keymap_ptr, size)
			if munmap_errno != .NONE {
				log.errorf("XKB keymap munmap failed, potential memory leak, err=%v", munmap_errno)
			}
		}

		keymap_bytes := slice.bytes_from_ptr(keymap_ptr, int(size))
		keymap_cstr := strings.clone_to_cstring(string(keymap_bytes))
		defer delete(keymap_cstr)

		data.input.xkb_keymap = xkb.keymap_new_from_string(
			data.input.xkb_context,
			keymap_cstr,
			.Text_V1,
			.No_Flags,
		)
		if data.input.xkb_keymap == nil {
			log.error("failed to parse XKB keymap")
			return
		}
		data.input.xkb_state = xkb.state_new(data.input.xkb_keymap)
		if data.input.xkb_state == nil {
			log.error("failed to build XKB keymap state")
		}

		success = true
	},
	enter = proc "c" (
		user_data: rawptr,
		keyboard: ^wl.keyboard,
		serial: uint,
		surface: ^wl.surface,
		keys: wl.array,
	) {
		// TODO handle keyboard being activated on a surface (window takes focus)
	},
	leave = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial: uint, surface: ^wl.surface) {
		// TODO handle keyboard deactivating on a surface (window loses focus)
		// Should we just clear key state?
	},
	key = proc "c" (
		user_data: rawptr,
		keyboard: ^wl.keyboard,
		serial: uint,
		time: uint,
		scancode: uint,
		state: wl.keyboard_key_state,
	) {
		p := cast(^Platform)user_data
		data := cast(^Linux_Wayland_Data)p.data
		context = runtime.default_context()
		context.allocator = p.allocator
		context.logger = p.logger

		// TERMINOLOGY:
		// scancode - Exact physical location of a key on the keyboard
		// keycode - Kernel layer code for a key
		// keysym - Character mapped to a keycode

		keycode := xkb.keycode_t(scancode + 8) // xkb needs +8 to convert from evdev scancode
		dir: xkb.key_direction = .Up if state == wl.keyboard_key_state.released else .Down
		xkb.state_update_key(data.input.xkb_state, keycode, dir)
		keysym := xkb.state_key_get_one_sym(data.input.xkb_state, keycode)
		char_buf: [4]i8 // assumes utf8
		num_char_bytes := xkb.state_key_get_utf8(
			data.input.xkb_state,
			keycode,
			raw_data(char_buf[:]),
			4,
		)
		char: rune
		if num_char_bytes > 0 {
			r, w := utf8.decode_rune(slice.bytes_from_ptr(&char_buf, 4))
			if r != utf8.RUNE_ERROR {
				char = r
			}
		}

		// TODO should we have a separate "modifiers" bitset to make it more generic
		// Right now it's just put into key_down but the callers don't know the
		// platform scancode for

		switch state {
		case .pressed, .repeated:
			set_key_down(p, keysym)
			if char != {} {
				set_char(p, char)
			}
		case .released:
			set_key_up(p, keysym)
			if char != {} {
				set_char(p, char)
			}
		}
	},
	modifiers = proc "c" (
		user_data: rawptr,
		keyboard: ^wl.keyboard,
		serial: uint,
		mods_depressed: uint,
		mods_latched: uint,
		mods_locked: uint,
		group: uint,
	) {
		p := cast(^Platform)user_data
		data := cast(^Linux_Wayland_Data)p.data
		context = runtime.default_context()
		context.allocator = p.allocator
		context.logger = p.logger

		xkb.state_update_mask(
			data.input.xkb_state,
			xkb.mod_mask_t(mods_depressed),
			xkb.mod_mask_t(mods_latched),
			xkb.mod_mask_t(mods_locked),
			0,
			0,
			xkb.layout_index_t(group),
		)
	},
	repeat_info = proc "c" (user_data: rawptr, keyboard: ^wl.keyboard, rate: int, delay: int) {
		// TODO handle repeat config from compositor including how often to trigger repeats
		// This should be handled in the client here by running a timer to generate and emit the repeats
	},
}
