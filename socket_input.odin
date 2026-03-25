package substrate

import "core:log"
import "core:os"
import "core:strings"

SUBSTRATE_INPUT_SOCKET_ENV :: "SUBSTRATE_INPUT_SOCKET"
APP_CONTROL_SOCKET_ENV :: "APP_CONTROL_SOCKET"
SUBSTRATE_INPUT_VERBOSE_ENV :: "SUBSTRATE_INPUT_VERBOSE"
TEST_INPUT_SOCKET_PATH_MAX :: 107
TEST_INPUT_RECV_CHUNK_SIZE :: 4096
TEST_INPUT_RECV_BUFFER_MAX :: 64 * 1024
INVALID_TEST_INPUT_FD :: -1

Socket_Input_State :: struct {
	enabled:            bool,
	verbose:            bool,
	socket_path:        string,
	listen_fd:          int,
	client_fd:          int,
	recv_buffer:        [dynamic]u8,
	send_buffer:        [dynamic]u8,
	close_after_send:   bool,
	pending_mouse_up:   [Mouse_Button]bool,
}

Socket_Input_Request :: struct {
	id:      string,
	cmd:     string,
	text:    string,
	button:  string,
	key:     int,
	x:       f32,
	y:       f32,
	dx:      f32,
	dy:      f32,
	focused: bool,
}

Socket_Input_Response :: struct {
	id:    string `json:"id"`,
	ok:    bool `json:"ok"`,
	error: string `json:"error,omitempty"`,
}

socket_input_lookup_socket_path :: proc(allocator := context.allocator) -> (socket_path: string, source_env: string, found: bool) {
	socket_path, found = os.lookup_env_alloc(SUBSTRATE_INPUT_SOCKET_ENV, allocator)
	if found {
		return socket_path, SUBSTRATE_INPUT_SOCKET_ENV, true
	}

	socket_path, found = os.lookup_env_alloc(APP_CONTROL_SOCKET_ENV, allocator)
	if found {
		return socket_path, APP_CONTROL_SOCKET_ENV, true
	}

	return "", "", false
}

socket_input_env_truthy :: proc(name: string) -> bool {
	value, found := os.lookup_env_alloc(name, context.allocator)
	if found {
		defer delete(value)
	}
	if !found || value == "" {
		return false
	}
	if value == "0" || strings.equal_fold(value, "false") || strings.equal_fold(value, "no") {
		return false
	}
	return true
}

socket_input_verbosef :: proc(state: ^Socket_Input_State, format: string, args: ..any) {
	if !state.verbose do return
	log.infof(format, ..args)
}

when ODIN_OS != .Linux {
	socket_input_init :: proc(p: ^Platform) {
		socket_path, source_env, found := socket_input_lookup_socket_path(context.allocator)
		if found {
			defer delete(socket_path)
		}
		if found && socket_path != "" {
			log.errorf(
				"substrate test input socket requested via %v, but this build target does not support Unix sockets",
				source_env,
			)
		}
	}

	socket_input_destroy :: proc(p: ^Platform) {
		if p.socket_input.socket_path != "" {
			delete(p.socket_input.socket_path)
		}
		clear(&p.socket_input.recv_buffer)
		clear(&p.socket_input.send_buffer)
		p.socket_input.enabled = false
		p.socket_input.verbose = false
		p.socket_input.socket_path = ""
		p.socket_input.listen_fd = INVALID_TEST_INPUT_FD
		p.socket_input.client_fd = INVALID_TEST_INPUT_FD
		p.socket_input.close_after_send = false
	}

	socket_input_poll :: proc(p: ^Platform) {}
}
