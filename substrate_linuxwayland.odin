package substrate

import "base:runtime"
import "core:log"
import "core:mem"
import wl "lib/odin-wayland"
import "lib/odin-wayland/ext/libdecor"
import gl "vendor:OpenGL"
import "vendor:egl"

Linux_Wayland_Data :: struct {
	allocator: mem.Allocator,
	logger:    log.Logger,
	status:    Platform_Status,
	input:     struct {
		seat:      ^wl.seat,
		seat_name: cstring,
		pointer:   ^wl.pointer,
		keyboard:  ^wl.keyboard,
	},
	window:    struct {
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

Size :: [2]int

Linux_Wayland_Error :: union {
	enum {
		Display_Connect_Failed,
		EGL_Display_Failed,
		Compositor_Not_Found,
	},
}

linux_wayland_init :: proc(
	logger := context.logger,
	allocator := context.allocator,
) -> (
	Platform,
	Linux_Wayland_Error,
) {
	platform := Platform {
		status = status,
		input  = input,
		render = render,
	}
	init_success := false
	defer if !init_success do linux_wayland_destroy(&platform)

	platform_data := new(Linux_Wayland_Data, allocator)
	_temp_global_platform_data = platform_data // temp hack, see interface_error below
	platform_data.allocator = allocator
	platform_data.logger = logger
	platform_data.status = .Running
	platform.data = Platform_Data(platform_data)

	window := &platform_data.window
	window.geometry = {1280, 720}
	window.size = {1280, 720}
	window.display = wl.display_connect(nil)
	if window.display == nil {
		return Platform{}, .Display_Connect_Failed
	}
	window.registry = wl.display_get_registry(window.display)
	wl.registry_add_listener(window.registry, &registry_listener, platform_data)
	wl.display_roundtrip(window.display)
	window.surface = wl.compositor_create_surface(window.compositor)
	if window.compositor == nil {
		return Platform{}, .Compositor_Not_Found
	}

	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)
	config_attribs := []i32{egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.NONE}

	window.egl_display = egl.GetDisplay(cast(egl.NativeDisplayType)window.display)
	if window.egl_display == nil {
		return Platform{}, .EGL_Display_Failed
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
	window.frame = libdecor.decorate(window.instance, window.surface, &frame_decor, platform_data)
	libdecor.frame_set_app_id(window.frame, "odin-wayland-egl")
	libdecor.frame_set_title(window.frame, "Hellope from Wayland, EGL & libdecor!")
	libdecor.frame_map(window.frame)

	// Requires calling dispatch twice to get a configure event
	wl.display_dispatch(window.display)
	wl.display_dispatch(window.display)

	init_success = true
	return platform, nil
}

linux_wayland_destroy :: proc(platform: ^Platform) {
	data := cast(^Linux_Wayland_Data)platform.data
	if data == nil do return

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


	free(data, data.allocator)
	platform.data = nil
}

status :: proc(pdata: Platform_Data) -> Platform_Status {
	data := cast(^Linux_Wayland_Data)pdata
	return data.status
}

input :: proc(pdata: Platform_Data) {
	data := cast(^Linux_Wayland_Data)pdata
	display := data.window.display
	context.logger = data.logger

	wl.display_flush(display)
	for wl.display_dispatch_pending(display) > 0 {}
	if wl.display_dispatch_pending(display) == -1 {
		data.status = .Fatal_Error
		log.errorf("Wayland dispatch error, err=%v", wl.display_get_error(display))
	}
}

render :: proc(pdata: Platform_Data) {
	data := cast(^Linux_Wayland_Data)pdata
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
	data := cast(^Linux_Wayland_Data)user_data
	data.status = .User_Quit
}

frame_commit :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {}

frame_configure :: proc "c" (
	frame: ^libdecor.frame,
	configuration: ^libdecor.configuration,
	user_data: rawptr,
) {
	data := cast(^Linux_Wayland_Data)user_data
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
_temp_global_platform_data: ^Linux_Wayland_Data

interface_error :: proc "c" (
	instance: ^libdecor.instance,
	error: libdecor.error,
	message: cstring,
) {
	// get_user_data fails to link for some reason
	// data := cast(^Linux_Wayland_Data)libdecor.get_user_data(instance)
	data := _temp_global_platform_data
	if data == nil do return
	data.status = .Fatal_Error
}

registry_global :: proc "c" (
	user_data: rawptr,
	registry: ^wl.registry,
	name: uint,
	interface_name: cstring,
	version: uint,
) {
	data := cast(^Linux_Wayland_Data)user_data

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
		wl.seat_add_listener(data.input.seat, seat_listener, data)
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

seat_listener := &wl.seat_listener {
	capabilities = proc "c" (user_data: rawptr, seat: ^wl.seat, capabilities: wl.seat_capability) {
		data := cast(^Linux_Wayland_Data)user_data
		if capabilities == .pointer && data.input.pointer == nil {
			data.input.pointer = wl.seat_get_pointer(data.input.seat)
			wl.pointer_add_listener(data.input.pointer, pointer_listener, data)
		} else if capabilities == .keyboard && data.input.keyboard == nil {
			data.input.keyboard = wl.seat_get_keyboard(data.input.seat)
			wl.keyboard_add_listener(data.input.keyboard, keyboard_listener, data)
		}
	},
	name = proc "c" (user_data: rawptr, seat: ^wl.seat, name: cstring) {
		data := cast(^Linux_Wayland_Data)user_data
		data.input.seat_name = name
	},
}

pointer_listener := &wl.pointer_listener {
	enter = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		serial_: uint,
		surface_: ^wl.surface,
		surface_x_: wl.fixed_t,
		surface_y_: wl.fixed_t,
	) {},
	motion = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		time_: uint,
		surface_x_: wl.fixed_t,
		surface_y_: wl.fixed_t,
	) {},
	button = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		serial_: uint,
		time_: uint,
		button_: uint,
		state_: wl.pointer_button_state,
	) {},
	axis = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		time_: uint,
		axis_: wl.pointer_axis,
		value_: wl.fixed_t,
	) {},
	frame = proc "c" (data: rawptr, pointer: ^wl.pointer) {},
	axis_source = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis_source_: wl.pointer_axis_source,
	) {},
	axis_stop = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		time_: uint,
		axis_: wl.pointer_axis,
	) {},
	axis_discrete = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis_: wl.pointer_axis,
		discrete_: int,
	) {},
	axis_value120 = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis_: wl.pointer_axis,
		value120_: int,
	) {},
	axis_relative_direction = proc "c" (
		data: rawptr,
		pointer: ^wl.pointer,
		axis_: wl.pointer_axis,
		direction_: wl.pointer_axis_relative_direction,
	) {},
}

keyboard_listener := &wl.keyboard_listener {
	keymap = proc "c" (
		data: rawptr,
		keyboard: ^wl.keyboard,
		format_: wl.keyboard_keymap_format,
		fd_: int,
		size_: uint,
	) {},
	enter = proc "c" (
		data: rawptr,
		keyboard: ^wl.keyboard,
		serial_: uint,
		surface_: ^wl.surface,
		keys_: wl.array,
	) {},
	leave = proc "c" (
		data: rawptr,
		keyboard: ^wl.keyboard,
		serial_: uint,
		surface_: ^wl.surface,
	) {},
	key = proc "c" (
		data: rawptr,
		keyboard: ^wl.keyboard,
		serial_: uint,
		time_: uint,
		key_: uint,
		state_: wl.keyboard_key_state,
	) {},
	modifiers = proc "c" (
		data: rawptr,
		keyboard: ^wl.keyboard,
		serial_: uint,
		mods_depressed_: uint,
		mods_latched_: uint,
		mods_locked_: uint,
		group_: uint,
	) {},
	repeat_info = proc "c" (data: rawptr, keyboard: ^wl.keyboard, rate_: int, delay_: int) {},
}
