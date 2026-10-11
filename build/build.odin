package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

main :: proc() {
    logger_allocator := context.allocator
    context.logger = log.create_console_logger(allocator = logger_allocator)
    defer log.destroy_console_logger(context.logger, logger_allocator)

    compiled_shaders := compile_shaders()
    if !compiled_shaders {
        os.exit(1)
    }

    odin_exit_code := run_odin()
    if odin_exit_code != 0 {
        os.exit(odin_exit_code)
    }
}

@(private = "file")
compile_shaders :: proc() -> (ok: bool) {
    log.info("Compiling shaders...")
    shader_files, shader_files_error := os.read_all_directory_by_path(
        SHADERS_DIRECTORY,
        context.temp_allocator,
    )

    if shader_files_error != nil {
        log.errorf("Failed to collect shader files: %v", shader_files_error)
        return
    }

    slang_files, slang_filter_error := slice.filter(
        shader_files,
        proc(shader_file: os.File_Info) -> bool {
            return(
                shader_file.type == .Regular &&
                strings.has_suffix(shader_file.name, SLANG_SUFFIX) \
            )
        },
    )

    if slang_filter_error != nil {
        log.errorf("Failed to filter %s files: %v", SLANG_SUFFIX, slang_filter_error)
        return
    }

    ok = true
    for slang_file in slang_files {
        ok = run_compile_slang_to_spv(slang_file) && ok
        if !ok {
            return
        }
    }

    log.info("Finished compiling shaders")
    return
}

@(require_results)
@(private = "file")
run_compile_slang_to_spv :: proc(slang_file: os.File_Info) -> (ok: bool) {
    log.infof("Compiling %s into SPIR-V", slang_file.name)

    run_error_message: string
    defer {
        if run_error_message != "" {
            log.errorf("Failed to compile file %s --- %s", slang_file.fullpath, run_error_message)
        }
    }

    spv_path, _ := strings.concatenate(
        {strings.trim_suffix(slang_file.fullpath, SLANG_SUFFIX), SPV_SUFFIX},
        context.temp_allocator,
    )

    // First param is executable, subsequent are arguments in order
    compile_spv_command := []string {
        "slangc",
        slang_file.fullpath,
        "-target",
        "spirv",
        "-o",
        spv_path,
    }
    compile_spv_descriptor := os.Process_Desc {
        command     = compile_spv_command,
        stderr      = os.stderr,
        stdout      = os.stdout,
        // Empty to use current directory as working directory
        working_dir = "",
    }

    compile_spv_process, compile_spv_error := os.process_start(compile_spv_descriptor)

    if compile_spv_error != nil {
        run_error_message = fmt.tprintf("Failed to start slangc: %v", compile_spv_error)
        return
    }

    compile_spv_state, compile_spv_wait_error := os.process_wait(compile_spv_process)

    if compile_spv_wait_error != nil {
        run_error_message = fmt.tprintf(
            "Command slangc could not complete: %v",
            compile_spv_wait_error,
        )
        return
    }

    if !compile_spv_state.success || compile_spv_state.exit_code != 0 {
        run_error_message = fmt.tprintf(
            "Command slangc failed with exit code %d",
            compile_spv_state.exit_code,
        )
        return
    }

    log.infof("Successfully compiled %s -> %s", slang_file.fullpath, spv_path)
    return true
}

@(private = "file")
run_odin :: proc() -> (exit_code: int) {
    // The first argument picks the Odin command; default to "run".
    command := "run"
    if len(os.args) > 1 {
        command = os.args[1]
    }

    // Everything after it (e.g. -debug) is passed through to Odin.
    flags: []string
    if len(os.args) > 2 {
        flags = os.args[2:]
    }

    odin_command := make([dynamic]string, context.temp_allocator)
    append(&odin_command, "odin", command, ".", "-collection:libs=libs")
    append(&odin_command, ..flags)

    log.infof("Running: %s", strings.join(odin_command[:], " ", context.temp_allocator))

    odin_descriptor := os.Process_Desc {
        command     = odin_command[:],
        // With `run`, the game itself is this child process, so give it the terminal's streams.
        stdin       = os.stdin,
        stdout      = os.stdout,
        stderr      = os.stderr,
        // Empty to use current directory as working directory
        working_dir = "",
    }

    odin_process, odin_start_error := os.process_start(odin_descriptor)
    if odin_start_error != nil {
        log.errorf("Failed to start odin: %v", odin_start_error)
        return 1
    }

    odin_state, odin_wait_error := os.process_wait(odin_process)
    if odin_wait_error != nil {
        log.errorf("Failed to wait for odin: %v", odin_wait_error)
        return 1
    }

    return odin_state.exit_code
}

@(private = "file")
SHADERS_DIRECTORY :: "shaders"
@(private = "file")
SLANG_SUFFIX :: ".slang"
@(private = "file")
SPV_SUFFIX :: ".spv"
