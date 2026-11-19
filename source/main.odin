package eloqc

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	input_path, output_path: string
	// (hole report-flag :tags tooling) no report flags (--coercions, --access, --index-order); --report turns on all.
	// (hole formatter :tags tooling) no --format: tabs, one opener (the more used of ? and ¿), --upside-down for ¿.
	for argument in os.args[1:] {
		switch {
		case strings.has_prefix(argument, "-out:"):
			output_path = argument[len("-out:"):]
		case argument == "--recompute-every-read":
			recompute_every_read = true
		case:
			input_path = argument
		}
	}
	if input_path == "" {
		fmt.eprintln("usage: eloqc <program.eloq> [-out:<output path without extension>]")
		os.exit(2)
	}
	if output_path == "" {
		output_path = strip_extension(input_path)
	}

	lines := read_source(input_path)
	items := group_items(lines[:])
	program := build_program(items[:])
	check_program(&program)
	header, source := emit_program(&program, base_name(output_path))
	write_file(strings.concatenate({output_path, ".h"}), header)
	write_file(strings.concatenate({output_path, ".c"}), source)
}

Location :: struct {
	path: string,
	line: int,
}

fail :: proc(location: Location, message: string, args: ..any) -> ! {
	fmt.eprintf("%s:%d: ", location.path, location.line)
	fmt.eprintfln(message, ..args)
	os.exit(1)
}

write_file :: proc(path: string, text: string) {
	if error := os.write_entire_file(path, transmute([]u8)text); error != nil {
		fmt.eprintfln("cannot write %s: %v", path, error)
		os.exit(1)
	}
}

base_name :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

strip_extension :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	return dot > strings.last_index_byte(path, '/') ? path[:dot] : path
}
