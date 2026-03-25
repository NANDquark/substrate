package substrate

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"

socket_input_init :: proc(p: ^Platform) {
	state := &p.socket_input
	state.listen_fd = INVALID_TEST_INPUT_FD
	state.client_fd = INVALID_TEST_INPUT_FD

	socket_path, source_env, found := socket_input_lookup_socket_path(context.allocator)
	if !found || socket_path == "" {
		if found {
			delete(socket_path)
		}
		return
	}
	if len(socket_path) > TEST_INPUT_SOCKET_PATH_MAX {
		log.errorf(
			"substrate test input socket path too long, len=%v max=%v path=%v",
			len(socket_path),
			TEST_INPUT_SOCKET_PATH_MAX,
			socket_path,
		)
		delete(socket_path)
		return
	}

	state.verbose = socket_input_env_truthy(SUBSTRATE_INPUT_VERBOSE_ENV)
	state.socket_path = socket_path

	listen_fd, sock_err := linux.socket(
		linux.Address_Family.UNIX,
		linux.Socket_Type.STREAM,
		linux.Socket_FD_Flags{.NONBLOCK, .CLOEXEC},
		linux.Protocol(0),
	)
	if sock_err != .NONE {
		log.errorf("substrate test input socket create failed, err=%v", sock_err)
		socket_input_destroy(p)
		return
	}
	state.listen_fd = int(listen_fd)

	socket_path_cstr, path_err := strings.clone_to_cstring(socket_path, allocator = context.allocator)
	if path_err != nil {
		log.errorf("substrate test input socket path clone failed, err=%v", path_err)
		socket_input_destroy(p)
		return
	}
	defer delete(socket_path_cstr)

	unlink_err := linux.unlink(socket_path_cstr)
	if unlink_err != .NONE && unlink_err != .ENOENT {
		log.errorf("substrate test input socket unlink failed, err=%v path=%v", unlink_err, socket_path)
		socket_input_destroy(p)
		return
	}

	addr := linux.Sock_Addr_Un {
		sun_family = linux.Address_Family.UNIX,
	}
	copy(addr.sun_path[:], socket_path)

	if bind_err := linux.bind(linux.Fd(state.listen_fd), &addr); bind_err != .NONE {
		log.errorf("substrate test input socket bind failed, err=%v path=%v", bind_err, socket_path)
		socket_input_destroy(p)
		return
	}
	if listen_err := linux.listen(linux.Fd(state.listen_fd), 1); listen_err != .NONE {
		log.errorf("substrate test input socket listen failed, err=%v path=%v", listen_err, socket_path)
		socket_input_destroy(p)
		return
	}

	state.enabled = true
	log.infof("substrate test input socket ready, path=%v env=%v", socket_path, source_env)
}

socket_input_destroy :: proc(p: ^Platform) {
	state := &p.socket_input
	socket_input_close_client(state)
	socket_input_close_listener(state)

	if state.socket_path != "" {
		socket_path_cstr, path_err := strings.clone_to_cstring(state.socket_path, allocator = context.allocator)
		if path_err == nil {
			defer delete(socket_path_cstr)
			unlink_err := linux.unlink(socket_path_cstr)
			if unlink_err != .NONE && unlink_err != .ENOENT {
				log.errorf(
					"substrate test input socket unlink failed during destroy, err=%v path=%v",
					unlink_err,
					state.socket_path,
				)
			}
		}
		delete(state.socket_path)
	}

	clear(&state.recv_buffer)
	clear(&state.send_buffer)
	state.enabled = false
	state.verbose = false
	state.socket_path = ""
	state.close_after_send = false
}

socket_input_poll :: proc(p: ^Platform) {
	state := &p.socket_input
	if !state.enabled do return

	socket_input_flush_pending(p, state)
	socket_input_accept_clients(state)
	if state.client_fd == INVALID_TEST_INPUT_FD do return
	socket_input_flush_send_buffer(state)
	if state.client_fd == INVALID_TEST_INPUT_FD do return
	if state.close_after_send && len(state.send_buffer) == 0 {
		socket_input_close_client(state)
		return
	}
	if len(state.recv_buffer) > 0 {
		socket_input_process_buffer(p, state)
		if state.client_fd == INVALID_TEST_INPUT_FD do return
	}
	socket_input_flush_send_buffer(state)
	if state.client_fd == INVALID_TEST_INPUT_FD do return
	if state.close_after_send && len(state.send_buffer) == 0 {
		socket_input_close_client(state)
		return
	}
	socket_input_read_client(p, state)
	if state.client_fd == INVALID_TEST_INPUT_FD do return
	socket_input_flush_send_buffer(state)
	if state.client_fd == INVALID_TEST_INPUT_FD do return
	if state.close_after_send && len(state.send_buffer) == 0 {
		socket_input_close_client(state)
	}
}

socket_input_flush_pending :: proc(p: ^Platform, state: ^Socket_Input_State) {
	for button in Mouse_Button {
		if !state.pending_mouse_up[button] do continue
		inject_mouse_up_checked(p, button)
		state.pending_mouse_up[button] = false
	}
}

socket_input_accept_clients :: proc(state: ^Socket_Input_State) {
	for {
		client_addr: linux.Sock_Addr_Un
		client_fd, accept_err := linux.accept(
			linux.Fd(state.listen_fd),
			&client_addr,
			linux.Socket_FD_Flags{.NONBLOCK, .CLOEXEC},
		)
		#partial switch accept_err {
		case .NONE:
				if state.client_fd != INVALID_TEST_INPUT_FD {
					_ = linux.close(client_fd)
					socket_input_verbosef(state, "rejected extra socket input client")
					continue
				}
				state.client_fd = int(client_fd)
				clear(&state.recv_buffer)
				clear(&state.send_buffer)
				state.close_after_send = false
				socket_input_verbosef(state, "accepted socket input client")
		case .EAGAIN:
			return
		case .EINTR:
			continue
		case:
			log.errorf("substrate test input accept failed, err=%v", accept_err)
			return
		}
	}
}

socket_input_read_client :: proc(p: ^Platform, state: ^Socket_Input_State) {
	buffer: [TEST_INPUT_RECV_CHUNK_SIZE]u8
	for state.client_fd != INVALID_TEST_INPUT_FD {
		n, recv_err := linux.recv(
			linux.Fd(state.client_fd),
			buffer[:],
			linux.Socket_Msg{},
		)
		#partial switch recv_err {
			case .NONE:
				if n == 0 {
					socket_input_verbosef(state, "socket input client disconnected")
					socket_input_close_client(state)
					return
				}
			append(&state.recv_buffer, ..buffer[:n])
			if len(state.recv_buffer) > TEST_INPUT_RECV_BUFFER_MAX {
				socket_input_send_error(state, "", "input line exceeds buffer limit")
				log.errorf("substrate test input buffer exceeded limit, path=%v", state.socket_path)
				socket_input_close_client(state)
				return
			}
				socket_input_process_buffer(p, state)
		case .EAGAIN:
			return
		case .EINTR:
			continue
		case:
			log.errorf("substrate test input recv failed, err=%v", recv_err)
			socket_input_close_client(state)
			return
		}
	}
}

socket_input_process_buffer :: proc(p: ^Platform, state: ^Socket_Input_State) {
	consumed := 0
	for i in 0 ..< len(state.recv_buffer) {
		if state.recv_buffer[i] != '\n' do continue

		line_bytes := state.recv_buffer[consumed:i]
		consumed = i + 1
		if len(strings.trim_space(string(line_bytes))) == 0 do continue

		req: Socket_Input_Request
		unmarshal_err := json.unmarshal(line_bytes, &req, allocator = context.allocator)
		if unmarshal_err != nil {
			socket_input_send_error(state, "", "invalid json")
			log.errorf("substrate test input json parse failed, err=%v line=%v", unmarshal_err, string(line_bytes))
			continue
		}

		close_after, yield_after, req_err := socket_input_handle_request(p, &req)
		if req_err != "" {
			socket_input_send_error(state, req.id, req_err)
		} else {
			socket_input_send_ok(state, req.id)
		}

		delete(req.id)
		delete(req.cmd)
		delete(req.text)
		delete(req.button)

		if close_after {
			state.close_after_send = true
			return
		}
		if yield_after {
			break
		}
	}

	if consumed == 0 do return

	remaining := len(state.recv_buffer) - consumed
	if remaining > 0 {
		copy(state.recv_buffer[:remaining], state.recv_buffer[consumed:])
		resize(&state.recv_buffer, remaining)
	} else {
		clear(&state.recv_buffer)
	}
}

socket_input_handle_request :: proc(p: ^Platform, req: ^Socket_Input_Request) -> (close_after, yield_after: bool, err: string) {
	switch req.cmd {
	case "ping":
		return false, false, ""
	case "close":
		return true, false, ""
	case "key_down":
		if !inject_key_down_checked(p, req.key) {
			return false, false, "key out of range"
		}
		return false, false, ""
	case "key_up":
		if !inject_key_up_checked(p, req.key) {
			return false, false, "key out of range"
		}
		return false, false, ""
	case "key_tap":
		if !inject_key_down_checked(p, req.key) {
			return false, false, "key out of range"
		}
		if !inject_key_up_checked(p, req.key) {
			return false, false, "key out of range"
		}
		return false, false, ""
	case "char", "text":
		for r in req.text {
			set_char(p, r)
		}
		return false, false, ""
	case "mouse_move":
		set_mouse_pos(p, req.x, req.y)
		return false, false, ""
		case "mouse_down":
			button, ok := socket_input_parse_mouse_button(req.button)
			if !ok {
				return false, false, "unknown mouse button"
			}
			inject_mouse_down_checked(p, button)
			return false, false, ""
		case "mouse_up":
			button, ok := socket_input_parse_mouse_button(req.button)
			if !ok {
				return false, false, "unknown mouse button"
			}
			inject_mouse_up_checked(p, button)
			return false, false, ""
		case "mouse_click":
			button, ok := socket_input_parse_mouse_button(req.button)
			if !ok {
				return false, false, "unknown mouse button"
			}
			inject_mouse_down_checked(p, button)
			p.socket_input.pending_mouse_up[button] = true
			return false, true, ""
	case "scroll":
		set_scroll_steps(p, req.dx, req.dy)
		return false, false, ""
	case "set_focus":
		set_window_focus(p, req.focused)
		return false, false, ""
		case "reset_inputs":
			inject_reset_inputs(p)
			p.socket_input.pending_mouse_up = {}
			return false, false, ""
	case:
		return false, false, "unknown command"
	}
}

socket_input_parse_mouse_button :: proc(name: string) -> (Mouse_Button, bool) {
	switch {
	case strings.equal_fold(name, "left"):
		return .Left, true
	case strings.equal_fold(name, "right"):
		return .Right, true
	case strings.equal_fold(name, "middle"):
		return .Middle, true
	case:
		return Mouse_Button(0), false
	}
}

socket_input_send_ok :: proc(state: ^Socket_Input_State, id: string) {
	resp := Socket_Input_Response {
		id = id,
		ok = true,
	}
	socket_input_send_response(state, resp)
}

socket_input_send_error :: proc(state: ^Socket_Input_State, id, msg: string) {
	resp := Socket_Input_Response {
		id    = id,
		ok    = false,
		error = msg,
	}
	socket_input_send_response(state, resp)
}

socket_input_send_response :: proc(state: ^Socket_Input_State, resp: Socket_Input_Response) {
	data, marshal_err := json.marshal(resp, allocator = context.allocator)
	if marshal_err != nil {
		log.errorf("substrate test input response marshal failed, err=%v", marshal_err)
		socket_input_close_client(state)
		return
	}
	defer delete(data)

	append(&state.send_buffer, ..data[:])
	append(&state.send_buffer, '\n')
	socket_input_flush_send_buffer(state)
}

socket_input_flush_send_buffer :: proc(state: ^Socket_Input_State) {
	if state.client_fd == INVALID_TEST_INPUT_FD do return

	sent := 0
	for sent < len(state.send_buffer) {
		n, send_err := linux.send(
			linux.Fd(state.client_fd),
			state.send_buffer[sent:],
			linux.Socket_Msg{.NOSIGNAL},
		)
		#partial switch send_err {
		case .NONE:
			if n <= 0 {
				socket_input_close_client(state)
				return
			}
			sent += n
		case .EINTR:
			continue
		case .EAGAIN:
			break
		case:
			log.errorf("substrate test input send failed, err=%v", send_err)
			socket_input_close_client(state)
			return
		}
	}
	if sent == 0 do return
	remaining := len(state.send_buffer) - sent
	if remaining > 0 {
		copy(state.send_buffer[:remaining], state.send_buffer[sent:])
		resize(&state.send_buffer, remaining)
	} else {
		clear(&state.send_buffer)
	}
}

socket_input_close_client :: proc(state: ^Socket_Input_State) {
	if state.client_fd != INVALID_TEST_INPUT_FD {
		_ = linux.close(linux.Fd(state.client_fd))
		state.client_fd = INVALID_TEST_INPUT_FD
	}
	clear(&state.recv_buffer)
	clear(&state.send_buffer)
	state.close_after_send = false
}

socket_input_close_listener :: proc(state: ^Socket_Input_State) {
	if state.listen_fd != INVALID_TEST_INPUT_FD {
		_ = linux.close(linux.Fd(state.listen_fd))
		state.listen_fd = INVALID_TEST_INPUT_FD
	}
}
