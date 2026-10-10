# spice

A small Vulkan renderer written in [Odin](https://odin-lang.org), built as a learning project.

Resources followed:

1. [How to Vulkan](https://howtovulkan.com) by Sascha Willems
   - Using modern Vulkan (1.3/1.4): dynamic rendering, synchronization2, buffer device address
     and descriptor indexing.
   - Deferring to [odin-vk-bootstrap](https://github.com/Capati/odin-vk-bootstrap) for setup and
     [VMA](https://github.com/Capati/odin-vma) for memory allocation, wherever possible.

## Project layout

| Path | Contents |
|---|---|
| `main.odin` | Entry point |
| `window/` | GLFW window and frame loop |
| `vks/` | Vulkan code: GPU context, swapchain, renderer, pipeline, textures |
| `shaders/` | Slang shaders |
| `build/` | Build program: compiles shaders, then runs `odin` |
| `libs/` | External libraries used -- See [External dependencies][external-dependencies] |

## Requirements

- [Odin](https://odin-lang.org/docs/install/) (developed with `dev-2026-09`)
- [Slang](https://github.com/shader-slang/slang/releases) (`slangc` on your `PATH`)
- A Vulkan 1.4 driver supporting these features:
  - Vulkan 1.0: `samplerAnisotropy`
  - Vulkan 1.2: `descriptorIndexing`, `shaderSampledImageArrayNonUniformIndexing`,
    `descriptorBindingVariableDescriptorCount`, `runtimeDescriptorArray`, `bufferDeviceAddress`
  - Vulkan 1.3: `synchronization2`, `dynamicRendering`
- On Linux, GLFW 3 installed system-wide (developed with 3.4, e.g. `libglfw3-dev` on Debian/Ubuntu)
- In debug builds, the Vulkan validation layers (`VK_LAYER_KHRONOS_validation`)

Developed on Linux (WSL2). Other platforms are untested.

## External dependencies

| Dependency | Used for | How it's included | License |
|---|---|---|---|
| [odin-vk-bootstrap](https://github.com/Capati/odin-vk-bootstrap) | Vulkan instance, device and swapchain setup | Git submodule in `libs/odin-vk-bootstrap` | MIT |
| [odin-vma](https://github.com/Capati/odin-vma) | Odin bindings for [Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator) | Git submodule in `libs/odin-vma`, static library built locally | MIT |

Also uses packages from Odin's [vendor collection](https://pkg.odin-lang.org/vendor/), which ship
with the compiler. Some link system libraries; those are listed under [Requirements](#requirements).

## Building

Clone with the submodules:

```bash
git clone --recurse-submodules https://github.com/SpicyCactuar/spice.git
```

Build the VMA static library once, following the
[odin-vma instructions](https://github.com/Capati/odin-vma#building-vma). On Linux it must end up
as `libs/odin-vma/libvma_linux_x86_64.a`.

### Background image

No image is included in the repository. Place any image at:

```
assets/textures/background.jpg
```

### Run

The build program compiles the shaders, then passes everything after `--` to `odin`:

```bash
odin run build -out=bin/build -- run -debug -out=bin/spice
```

## License

The code is licensed under the [zlib license](LICENSE). Dependencies in `libs/` keep their own
licenses.

[external-dependencies]: #external-dependencies
