package vks

import "core:log"
import "core:slice"
import vk "vendor:vulkan"

Pipeline :: struct {
    layout:                vk.PipelineLayout,
    pipeline:              vk.Pipeline,
    descriptor_set_layout: vk.DescriptorSetLayout,
}

@(private)
@(require_results)
create_pipeline :: proc(gpu_context: Gpu_Context) -> (pipeline: Pipeline, ok: bool) {
    defer if !ok {
        destroy_pipeline(&pipeline, gpu_context)
    }

    vk_device := gpu_context.device.vk_device

    // Create descriptor set layout
    descriptor_set_layout_binding := vk.DescriptorSetLayoutBinding {
        binding         = 0,
        descriptorType  = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = MAX_TEXTURES,
        stageFlags      = {.FRAGMENT},
    }
    descriptor_binding_flags := vk.DescriptorBindingFlags{.VARIABLE_DESCRIPTOR_COUNT}
    descriptor_binding_flags_create_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
        sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        bindingCount  = 1,
        pBindingFlags = &descriptor_binding_flags,
    }
    descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        pNext        = &descriptor_binding_flags_create_info,
        bindingCount = 1,
        pBindings    = &descriptor_set_layout_binding,
    }
    check_success(
        vk.CreateDescriptorSetLayout(
            vk_device,
            &descriptor_set_layout_create_info,
            nil,
            &pipeline.descriptor_set_layout,
        ),
        "Failed to create descriptor set layout",
    ) or_return

    fullscreen_shader_module, fullscreen_shader_created := create_shader_module(
        #load(FULLSCREEN_SPIRV_PATH),
        vk_device,
    )
    defer vk.DestroyShaderModule(vk_device, fullscreen_shader_module, nil)

    if !fullscreen_shader_created {
        log.errorf("Failed to create shader module for %s", FULLSCREEN_SPIRV_PATH)
        return
    }

    return pipeline, true
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
        codeSize = slice.size(spirv),
        pCode    = raw_data(spirv),
    }

    check_success(
        vk.CreateShaderModule(vk_device, &shader_create_info, nil, &shader_module),
        "Failed to create shader module",
    ) or_return

    return shader_module, true
}

@(private)
destroy_pipeline :: proc(pipeline: ^Pipeline, gpu_context: Gpu_Context) {
    if pipeline.descriptor_set_layout != 0 {
        vk.DestroyDescriptorSetLayout(
            gpu_context.device.vk_device,
            pipeline.descriptor_set_layout,
            nil,
        )
    }
}

@(private = "file")
FULLSCREEN_SPIRV_PATH :: "../shaders/fullscreen.spv"

// Only have a single background texture for now
@(private)
MAX_TEXTURES :: 1
