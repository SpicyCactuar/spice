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
create_pipeline :: proc(
    gpu_context: Gpu_Context,
    color_format: vk.Format,
) -> (
    pipeline: Pipeline,
    ok: bool,
) {
    log.info("Creating graphics pipeline")

    defer if !ok {
        destroy_pipeline(&pipeline, gpu_context)
    }

    vk_device := gpu_context.device.vk_device

    // Create descriptor set layout
    descriptor_set_layout_binding := vk.DescriptorSetLayoutBinding {
        // Corresponds to the binding, the first number in `[[vk::binding(0, 0)]]`
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
    // The set (second number in `[[vk::binding(0, 0)]]`) is this layout's index in the pipeline layout
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

    // Create pipeline layout
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType          = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        // Corresponds to the set, the second number in `[[vk::binding(0, 0)]]`: index 0 is set 0
        pSetLayouts    = &pipeline.descriptor_set_layout,
    }
    check_success(
        vk.CreatePipelineLayout(vk_device, &pipeline_layout_create_info, nil, &pipeline.layout),
        "Failed to create pipeline layout",
    ) or_return

    // Setup pipeline stages
    spirv := #load(FULLSCREEN_SPIRV_PATH, []u32)
    shader_module_create_info := vk.ShaderModuleCreateInfo {
        sType    = .SHADER_MODULE_CREATE_INFO,
        pNext    = nil,
        codeSize = slice.size(spirv),
        pCode    = raw_data(spirv),
    }

    shader_stages := [?]vk.PipelineShaderStageCreateInfo {
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &shader_module_create_info,
            stage = {.VERTEX},
            pName = SHADER_ENTRY_POINT,
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &shader_module_create_info,
            stage = {.FRAGMENT},
            pName = SHADER_ENTRY_POINT,
        },
    }

    // Fixed-function state
    // No vertex buffers: the vertex shader builds the triangle from the vertex index
    vertex_input_state := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }
    // Every 3 vertices form a triangle
    input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
        sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    // One viewport and scissor, set per frame (see dynamic_states) so resizing needs no new pipeline
    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }
    // Filled triangles, no culling: the fullscreen triangle must never be discarded by its winding
    rasterization_state := vk.PipelineRasterizationStateCreateInfo {
        sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode    = {},
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1,
    }
    // No multisampling: one sample per pixel
    multisample_state := vk.PipelineMultisampleStateCreateInfo {
        sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }
    // No blending: the background overwrites the color attachment, all four channels
    color_blend_attachment := vk.PipelineColorBlendAttachmentState {
        blendEnable    = false,
        colorWriteMask = {.R, .G, .B, .A},
    }
    color_blend_state := vk.PipelineColorBlendStateCreateInfo {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &color_blend_attachment,
    }
    // Viewport and scissor come from vk.CmdSetViewport / vk.CmdSetScissor when drawing
    dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = len(dynamic_states),
        pDynamicStates    = &dynamic_states[0],
    }

    // Dynamic rendering: the attachment formats this pipeline renders into
    color_format := color_format
    rendering_create_info := vk.PipelineRenderingCreateInfo {
        sType                   = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount    = 1,
        pColorAttachmentFormats = &color_format,
    }

    // Create graphics pipeline
    graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &rendering_create_info,
        stageCount          = len(shader_stages),
        pStages             = &shader_stages[0],
        pVertexInputState   = &vertex_input_state,
        pInputAssemblyState = &input_assembly_state,
        pViewportState      = &viewport_state,
        pRasterizationState = &rasterization_state,
        pMultisampleState   = &multisample_state,
        pColorBlendState    = &color_blend_state,
        pDynamicState       = &dynamic_state,
        layout              = pipeline.layout,
    }
    check_success(
        vk.CreateGraphicsPipelines(
            vk_device,
            0,
            1,
            &graphics_pipeline_create_info,
            nil,
            &pipeline.pipeline,
        ),
        "Failed to create graphics pipeline",
    ) or_return

    log.info("Created graphics pipeline")

    return pipeline, true
}

@(private)
destroy_pipeline :: proc(pipeline: ^Pipeline, gpu_context: Gpu_Context) {
    if pipeline.pipeline != 0 {
        vk.DestroyPipeline(gpu_context.device.vk_device, pipeline.pipeline, nil)
    }

    if pipeline.layout != 0 {
        vk.DestroyPipelineLayout(gpu_context.device.vk_device, pipeline.layout, nil)
    }

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

@(private = "file")
SHADER_ENTRY_POINT :: cast(cstring)"main"

// Only have a single background texture for now
@(private)
MAX_TEXTURES :: 1
