package spice

import "core:image/jpeg"
import "core:log"
import "core:mem"
import "window"

main :: proc() {
	logger_allocator := context.allocator
	context.logger = log.create_console_logger(allocator = logger_allocator)
	defer log.destroy_console_logger(context.logger, logger_allocator)

	when ODIN_DEBUG {
		log.info("Overriding context.allocator with mem.Tracking_Allocator")
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer report_and_destroy_tracking_allocator(&track)
	}

	title := "Spice"
	log.infof("Creating Vulkan window: %s", title)
	main_window, created_window := window.create(title = title, width = 800, height = 600)
	if !created_window {
		log.errorf("Failed to Create Vulkan window: %s", title)
		return
	}
	defer window.destroy(&main_window)
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

report_and_destroy_tracking_allocator :: proc(track: ^mem.Tracking_Allocator) {
	context.allocator = track.backing
	if len(track.allocation_map) > 0 {
		log.errorf("%v allocations not freed:", len(track.allocation_map))
		for _, entry in track.allocation_map {
			log.errorf("- %v bytes @ %v", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		log.errorf("%v incorrect frees:", len(track.bad_free_array))
		for entry in track.bad_free_array {
			log.errorf("- %p @ %v", entry.memory, entry.location)
		}
	}
	mem.tracking_allocator_destroy(track)
}
