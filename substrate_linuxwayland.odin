package substrate

import "core:log"
import "core:mem"

import "base:runtime"
import "core:fmt"
import "core:os"
import wl "lib/odin-wayland"
import "lib/odin-wayland/ext/libdecor"
import gl "vendor:OpenGL"
import "vendor:egl"

Linux_Wayland_Data :: struct {
	allocator: mem.Allocator,
	status:    Platform_Status,
	window:    struct {
		display:        ^wl.display,
		surface:        ^wl.surface,
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
	},
}

linux_wayland_init :: proc(allocator := context.allocator) -> (Platform, Linux_Wayland_Error) {
	platform_data := new(Linux_Wayland_Data)
	_temp_global_platform_data = platform_data // temp hack, see interface_error below
	platform_data.allocator = allocator
	platform_data.status = .Running

	window := &platform_data.window
	window.geometry = {1280, 720}
	window.size = {1280, 720}
	window.display = wl.display_connect(nil)
	if window.display == nil {
		return Platform{}, .Display_Connect_Failed
	}
	registry := wl.display_get_registry(window.display)
	wl.registry_add_listener(registry, &registry_listener, platform_data)
	wl.display_roundtrip(window.display)
	window.surface = wl.compositor_create_surface(window.compositor)

	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)
	config_attribs := []i32{egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.NONE}

	window.egl_display = egl.GetDisplay(cast(egl.NativeDisplayType)window.display)
	if window.egl_display == nil {
		return Platform{}, .EGL_Display_Failed
	}
	egl.Initialize(window.egl_display, &major, &minor)
	fmt.printfln("EGL version: %v.%v", major, minor)

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

	return Platform {
			data = Platform_Data(platform_data),
			status = status,
			input = input,
			render = render,
		},
		nil
}

status :: proc(pdata: Platform_Data) -> Platform_Status {
	data := cast(^Linux_Wayland_Data)pdata
	return data.status
}

input :: proc(pdata: Platform_Data) {
	data := cast(^Linux_Wayland_Data)pdata
	for {
		res := wl.display_dispatch_pending(data.window.display)
		if res == 0 {
			return
		} else if res < 0 {
			err := wl.display_get_error(data.window.display)
			log.errorf("Wayland dispatch error, err=%v", err)
		}
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
	context = runtime.default_context()
	context.allocator = data.allocator
	data.status = .User_Quit
}

frame_commit :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {}

frame_configure :: proc "c" (
	frame: ^libdecor.frame,
	configuration: ^libdecor.configuration,
	user_data: rawptr,
) {
	context = runtime.default_context()
	data := cast(^Linux_Wayland_Data)user_data
	context.allocator = data.allocator

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
	context = runtime.default_context()
	context.allocator = data.allocator
	data.status = .Fatal_Error
}

registry_global :: proc "c" (
	user_data: rawptr,
	registry: ^wl.registry,
	name: uint,
	interface_name: cstring,
	version: uint,
) {
	context = runtime.default_context()
	data := cast(^Linux_Wayland_Data)user_data
	context.allocator = data.allocator

	switch interface_name {
	case wl.compositor_interface.name:
		data.window.compositor = cast(^wl.compositor)wl.registry_bind(
			registry,
			name,
			&wl.compositor_interface,
			4,
		)
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}
