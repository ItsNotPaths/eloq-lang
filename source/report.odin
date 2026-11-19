package eloqc

import "core:fmt"
import "core:slice"
import "core:strings"

// Reports are plain lines on stdout. `--report` turns on every one.
Reports :: struct {
	coercions:         bool,
	access:            bool,
	index_order:       bool,
	log_intermediates: bool,
}

reports: Reports
coercion_lines: map[string]bool // checks can run more than once, so lines are kept unique

// accepts, and notes the number conversion for `--coercions`.
fits :: proc(target, source: ^Type, location: Location) -> bool {
	if !accepts(target, source) do return false
	if target != source && is_number(target) && is_number(source) && !source.untyped {
		kind := "widening" if widens(target, source) else "narrowing"
		coercion_lines[fmt.aprintf("%s:%d: %s %s to %s", location.path, location.line, kind, source.name, target.name)] = true
	}
	return true
}

// Whether `target` holds every value of `source`, by the common sizes.
widens :: proc(target, source: ^Type) -> bool {
	switch {
	case target.kind == .Float && source.kind == .Integer:
		return true
	case target.kind != source.kind:
		return false
	case target.kind == .Float:
		return target.size >= source.size
	case is_unsigned(target) && !is_unsigned(source):
		return false
	case is_unsigned(source) && !is_unsigned(target):
		return target.size > source.size
	}
	return target.size >= source.size
}

print_reports :: proc(program: ^Program) {
	if reports.coercions {
		lines: [dynamic]string
		for line in coercion_lines do append(&lines, line)
		slice.sort(lines[:])
		for line in lines do fmt.println(line)
	}
	for line in program.lines {
		location := line.location
		if reports.access {
			fmt.printfln("%s:%d: reads %s; writes %s", location.path, location.line, name_list(line.access.reads), name_list(line.access.writes))
		}
		if reports.index_order && line.row_table != nil && len(line.access.index_writes) > 0 {
			fmt.printfln("%s:%d: writes %s by index in a loop over %s; the result can depend on row order", location.path, location.line, name_list(line.access.index_writes), line.row_table.name)
		}
	}
}

name_list :: proc(names: map[string]bool) -> string {
	if len(names) == 0 do return "nothing"
	return strings.join(sorted_names(names)[:], ", ")
}
