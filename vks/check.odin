package vks

import "core:fmt"
import "core:log"
import vkb "libs:odin-vk-bootstrap"
import vk "vendor:vulkan"

// Returns false (after logging) unless `result` is exactly SUCCESS, so callers can write:
//   check_success(vk.CreateFence(...), "Failed to create fence") or_return
// Only use it for calls where any other result is a failure. Calls with non-error status codes,
// like SUBOPTIMAL_KHR from acquire/present, need explicit handling.
@(private)
@(require_results)
check_success_vk :: proc(
    result: vk.Result,
    format: string,
    args: ..any,
    loc := #caller_location,
) -> (
    ok: bool,
) {
    if result != .SUCCESS {
        log.errorf("%s: %v", fmt.tprintf(format, ..args), result, location = loc)
        return false
    }
    return true
}

// Returns false (after logging) unless `err` is nil, which is how vk-bootstrap reports success,
// so callers can write:
//   check_success(vkb.instance_builder_build(...), "Failed to build Vulkan instance") or_return
@(private)
@(require_results)
check_success_vkb :: proc(
    err: vkb.Error,
    format: string,
    args: ..any,
    loc := #caller_location,
) -> (
    ok: bool,
) {
    if err != nil {
        log.errorf("%s: %v", fmt.tprintf(format, ..args), err, location = loc)
        return false
    }
    return true
}

// Like `check_success_vkb`, for vk-bootstrap calls that return a value along with the error.
// The value is passed through, so callers can write:
//   images := check_success(vkb.swapchain_get_images(...), "Failed to get swapchain images") or_return
@(private)
@(require_results)
check_success_vkb_value :: proc(
    value: $T,
    err: vkb.Error,
    format: string,
    args: ..any,
    loc := #caller_location,
) -> (
    result: T,
    ok: bool,
) {
    if err != nil {
        log.errorf("%s: %v", fmt.tprintf(format, ..args), err, location = loc)
        return value, false
    }
    return value, true
}

@(private)
check_success :: proc {
    check_success_vk,
    check_success_vkb,
    check_success_vkb_value,
}
