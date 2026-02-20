package linux_wayland

import pf "../"
import "core:log"
import "core:os"
import "core:time"

p: pf.Platform

main :: proc() {
	context.logger = log.create_console_logger()
	err := pf.init(&p, "com.nandquark.substrate", "Substrate Demo", {800, 600})
	if err != nil {
		log.errorf("failed to create platform, err=%v", err)
		os.exit(1)
	}

	for pf.status(&p) == .Running {
		time.sleep(1 / 60)
		pf.update(&p)

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

		pf.present(&p)
	}

	pf.destroy(&p)
}

