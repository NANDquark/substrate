package substrate

Platform :: struct {
	data:   Platform_Data,
	status: proc(data: Platform_Data) -> Platform_Status,
	input:  proc(data: Platform_Data),
	render: proc(data: Platform_Data),
}

Platform_Data :: distinct rawptr

Platform_Status :: enum {
	User_Quit,
	Running,
	Fatal_Error,
}
