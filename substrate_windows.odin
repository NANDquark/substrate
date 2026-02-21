#+private
#+build windows
package substrate

import "base:runtime"
import "core:log"
import "core:sys/windows"

Windows_Data :: struct {
	status:                 Platform_Status,
	hinstance:              windows.HINSTANCE,
	hwnd:                   windows.HWND,
	class_name:             []u16,
	minimized:              bool,
	vulkan_active:          bool,
	pending_high_surrogate: u16,
}

windows_data_init :: proc(p: ^Platform) -> Windows_Error {
	context.allocator = p.allocator
	context.logger = p.logger

	init_success := false
	data := new(Windows_Data)
	data.status = .Running
	p.data = Platform_Data_Ptr(data)
	defer if !init_success do windows_data_destroy(p)

	p.vtable = Platform_VTable {
		status  = windows_status,
		update  = windows_update,
		present = windows_present,
	}

	data.hinstance = cast(windows.HINSTANCE)windows.GetModuleHandleW(nil)
	data.class_name = windows.utf8_to_utf16("substrate_window_class", p.allocator)
	if len(data.class_name) == 0 {
		return .Register_Class_Failed
	}

	wc: windows.WNDCLASSEXW
	wc.cbSize = size_of(windows.WNDCLASSEXW)
	wc.style = windows.CS_HREDRAW | windows.CS_VREDRAW
	wc.lpfnWndProc = windows_wnd_proc
	wc.hInstance = data.hinstance
	wc.hCursor = windows.LoadCursorW(nil, cstring16(windows._IDC_ARROW))
	wc.lpszClassName = cstring16(raw_data(data.class_name))
	if windows.RegisterClassExW(&wc) == 0 {
		return .Register_Class_Failed
	}

	title := windows.utf8_to_utf16(p.app_title, p.allocator)
	defer delete(title)
	data.hwnd = windows.CreateWindowExW(
		0,
		cstring16(raw_data(data.class_name)),
		cstring16(raw_data(title)),
		windows.WS_OVERLAPPEDWINDOW,
		windows.CW_USEDEFAULT,
		windows.CW_USEDEFAULT,
		i32(p.window_size[0]),
		i32(p.window_size[1]),
		nil,
		nil,
		data.hinstance,
		nil,
	)
	if data.hwnd == nil {
		return .Create_Window_Failed
	}

	windows.SetWindowLongPtrW(data.hwnd, windows.GWLP_USERDATA, windows.LONG_PTR(uintptr(p)))
	windows.ShowWindow(data.hwnd, windows.SW_SHOW)
	windows.UpdateWindow(data.hwnd)

	init_success = true
	return nil
}

windows_data_destroy :: proc(p: ^Platform) {
	context = runtime.default_context()
	context.allocator = p.allocator
	context.logger = p.logger

	data := cast(^Windows_Data)p.data
	if data == nil do return

	if data.hwnd != nil {
		windows.DestroyWindow(data.hwnd)
		data.hwnd = nil
	}
	if len(data.class_name) > 0 {
		windows.UnregisterClassW(cstring16(raw_data(data.class_name)), data.hinstance)
		delete(data.class_name)
	}

	free(data)
	p.data = Platform_Data_Ptr(nil)
}

windows_status :: proc(p: ^Platform) -> Platform_Status {
	data := cast(^Windows_Data)p.data
	return data.status
}

windows_update :: proc(p: ^Platform) {
	context.allocator = p.allocator
	context.logger = p.logger

	msg: windows.MSG
	for {
		has_message := windows.PeekMessageW(&msg, nil, 0, 0, windows.PM_REMOVE)
		if has_message == windows.FALSE {
			break
		}
		windows.TranslateMessage(&msg)
		windows.DispatchMessageW(&msg)
	}
}

windows_present :: proc(p: ^Platform) {}

windows_wnd_proc :: proc "system" (
	hwnd: windows.HWND,
	message: windows.UINT,
	wparam: windows.WPARAM,
	lparam: windows.LPARAM,
) -> windows.LRESULT {
	context = runtime.default_context()
	p := get_platform_from_hwnd(hwnd)
	if p == nil || p.data == nil {
		return windows.DefWindowProcW(hwnd, message, wparam, lparam)
	}
	context.allocator = p.allocator
	context.logger = p.logger
	data := cast(^Windows_Data)p.data

	switch message {
	case windows.WM_CLOSE:
		windows.DestroyWindow(hwnd)
		return 0
	case windows.WM_DESTROY:
		data.status = .User_Quit
		return 0
	case windows.WM_SIZE:
		width := int(u16(cast(uintptr)lparam & 0xFFFF))
		height := int(u16((cast(uintptr)lparam >> 16) & 0xFFFF))
		p.window_size = {width, height}
		data.minimized = cast(uintptr)wparam == windows.SIZE_MINIMIZED
		return 0
	case windows.WM_MOUSEMOVE:
		x := f32(windows.GET_X_LPARAM(lparam))
		y := f32(windows.GET_Y_LPARAM(lparam))
		set_mouse_pos(p, x, y)
		return 0
	case windows.WM_LBUTTONDOWN:
		set_mouse_down_checked(p, 0)
		return 0
	case windows.WM_LBUTTONUP:
		set_mouse_up_checked(p, 0)
		return 0
	case windows.WM_RBUTTONDOWN:
		set_mouse_down_checked(p, 1)
		return 0
	case windows.WM_RBUTTONUP:
		set_mouse_up_checked(p, 1)
		return 0
	case windows.WM_MBUTTONDOWN:
		set_mouse_down_checked(p, 2)
		return 0
	case windows.WM_MBUTTONUP:
		set_mouse_up_checked(p, 2)
		return 0
	case windows.WM_XBUTTONDOWN:
		xbutton := int(u16((cast(uintptr)wparam >> 16) & 0xFFFF))
		if xbutton == windows.XBUTTON1 {
			set_mouse_down_checked(p, 3)
		} else if xbutton == windows.XBUTTON2 {
			set_mouse_down_checked(p, 4)
		}
		return 0
	case windows.WM_XBUTTONUP:
		xbutton := int(u16((cast(uintptr)wparam >> 16) & 0xFFFF))
		if xbutton == windows.XBUTTON1 {
			set_mouse_up_checked(p, 3)
		} else if xbutton == windows.XBUTTON2 {
			set_mouse_up_checked(p, 4)
		}
		return 0
	case windows.WM_KEYDOWN:
		set_key_down_checked(p, int(cast(uintptr)wparam))
		return 0
	case windows.WM_KEYUP:
		set_key_up_checked(p, int(cast(uintptr)wparam))
		return 0
	case windows.WM_SYSKEYDOWN:
		set_key_down_checked(p, int(cast(uintptr)wparam))
		alt_down := (cast(uintptr)lparam & (1 << 29)) != 0
		if cast(uintptr)wparam == windows.VK_F4 && alt_down {
			return windows.DefWindowProcW(hwnd, message, wparam, lparam)
		}
		return 0
	case windows.WM_SYSKEYUP:
		set_key_up_checked(p, int(cast(uintptr)wparam))
		return 0
	case windows.WM_CHAR:
		c := u16(cast(uintptr)wparam & 0xFFFF)
		handle_utf16_char(p, data, c)
		return 0
	}

	return windows.DefWindowProcW(hwnd, message, wparam, lparam)
}

set_key_down_checked :: proc(p: ^Platform, key: int) {
	if key < 0 || key >= MAX_KEY do return
	set_key_down(p, key)
}

set_key_up_checked :: proc(p: ^Platform, key: int) {
	if key < 0 || key >= MAX_KEY do return
	set_key_up(p, key)
}

set_mouse_down_checked :: proc(p: ^Platform, button: int) {
	if button < 0 || button >= MAX_MOUSE do return
	set_mouse_down(p, button)
}

set_mouse_up_checked :: proc(p: ^Platform, button: int) {
	if button < 0 || button >= MAX_MOUSE do return
	set_mouse_up(p, button)
}

handle_utf16_char :: proc(p: ^Platform, data: ^Windows_Data, c: u16) {
	if c >= 0xD800 && c <= 0xDBFF {
		data.pending_high_surrogate = c
		return
	}

	if c >= 0xDC00 && c <= 0xDFFF {
		if data.pending_high_surrogate != 0 {
			high := u32(data.pending_high_surrogate) - 0xD800
			low := u32(c) - 0xDC00
			codepoint := ((high << 10) | low) + 0x10000
			set_char(p, cast(rune)codepoint)
			data.pending_high_surrogate = 0
		}
		return
	}

	if data.pending_high_surrogate != 0 {
		set_char(p, cast(rune)data.pending_high_surrogate)
		data.pending_high_surrogate = 0
	}
	set_char(p, cast(rune)c)
}

get_platform_from_hwnd :: proc "contextless" (hwnd: windows.HWND) -> ^Platform {
	ud := windows.GetWindowLongPtrW(hwnd, windows.GWLP_USERDATA)
	if ud == 0 do return nil
	return cast(^Platform)(rawptr(uintptr(ud)))
}
