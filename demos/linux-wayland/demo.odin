package linux_wayland

import sb "../../"
import "core:log"
import "core:time"
import gl "vendor:OpenGL"

main :: proc() {
	context.logger = log.create_console_logger()
	platform, err := sb.linux_wayland_init()
	if err != nil {
		log.fatalf("failed to initialize platform, err=%v", err)
	}

	start_time := time.now()
	for platform.status(platform.data) == .Running {
		time.sleep(1 / 60)
		platform.input(platform.data)

		gl.ClearColor(1, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		platform.render(platform.data)
	}
}
