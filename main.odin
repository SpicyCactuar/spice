package ruten

import "core:image/jpeg"
import "core:log"
import "window"

main :: proc() {
	context.logger = log.create_console_logger()

	title := "Ruten"
	log.infof("Creating Vulkan window: %s", title)
	main_window, created_window := window.create_window(width = 800, height = 600, title = title)
	if !created_window {
		return
	}
	defer window.cleanup(&main_window)
	log.infof("Created Vulkan window: %s", title)

	image_path := "assets/textures/your_name.jpg"
	background_image, error := jpeg.load(filename = image_path)

	if error != nil {
		log.errorf("Failed to load %s", image_path)
		return
	}
	defer jpeg.destroy(background_image)

	window.loop_until_close(window = main_window)
}
