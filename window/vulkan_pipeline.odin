package window

import "core:log"
import vk "vendor:vulkan"

Vulkan_Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

@(private)
@(require_results)
create_pipeline :: proc(vk_device: vk.Device) -> (pipeline: Vulkan_Pipeline, ok: bool) {
	fullscreen_shader_module, fullscreen_shader_created := create_shader_module(
		#load(FULLSCREEN_SPIRV_PATH),
		vk_device,
	)
	defer vk.DestroyShaderModule(vk_device, fullscreen_shader_module, nil)

	if !fullscreen_shader_created {
		log.errorf("Failed to create shader module for %s", FULLSCREEN_SPIRV_PATH)
		return
	}

	// TODO: Finish implementation
	return {}, true
}

@(private = "file")
@(require_results)
create_shader_module :: proc(
	spirv: []u32,
	vk_device: vk.Device,
) -> (
	shader_module: vk.ShaderModule,
	ok: bool,
) {
	shader_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		pNext    = nil,
		codeSize = len(spirv) * size_of(u32),
		pCode    = raw_data(spirv),
	}

	create_shader_module_result := vk.CreateShaderModule(
		vk_device,
		&shader_create_info,
		nil,
		&shader_module,
	)
	if create_shader_module_result != .SUCCESS {
		log.errorf("Failed to create shader module: %v", create_shader_module_result)
		return
	}
	ok = true
	return
}

@(private)
destroy_pipeline :: proc(pipeline: ^Vulkan_Pipeline, vk_device: vk.Device) {
	// TODO: Implement
}

@(private = "file")
FULLSCREEN_SPIRV_PATH :: "../shaders/fullscreen.spv"
