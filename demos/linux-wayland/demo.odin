package linux_wayland

import sb "../../"
import "core:log"
import "core:time"
import gl "vendor:OpenGL"

main :: proc() {
	platform, err := sb.linux_wayland_init()
	if err != nil {
		log.fatalf("failed to initialize platform, err=%v", err)
	}

	for platform.status(platform.data) == .Running {
		time.sleep(16 * time.Millisecond)
		platform.input(platform.data)
		gl.ClearColor(1.0, 0.0, 0.0, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		platform.render(platform.data)
	}

	log.infof("quit status: %v", platform.status)
}
