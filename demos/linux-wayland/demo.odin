package linux_wayland

import pf "../../"
import "core:log"
import "core:os"
import "core:time"
import gl "vendor:OpenGL"

main :: proc() {
	context.logger = log.create_console_logger()
	p, err := pf.create()
	if err != nil {
		os.exit(1)
	}

	for pf.status(p) == .Running {
		time.sleep(1 / 60)
		pf.update(p)

		for e in p.input.events {
			#partial switch ee in e {
			case pf.Char_Event:
				log.infof("char: %v", ee.c)
			case pf.Key_Event:
				log.infof("%v key, %v", rune(ee.key), ee.action)
			case pf.Mouse_Event:
				log.infof("mouse button %d, %v", ee.button, ee.action)
			}
		}

		gl.ClearColor(1, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		pf.present(p)
	}

	pf.destroy(p)
}
