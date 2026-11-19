package eloqc

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

Output :: ^strings.Builder

emit_program :: proc(program: ^Program, header_name: string) -> (header: string, source: string) {
	state_type := strings.to_ada_case(program.state_name)
	abend_type := strings.concatenate({state_type, "_Abend"})
	upper_name := strings.to_upper(program.state_name)

	header_builder := strings.builder_make()
	out := &header_builder
	guard := strings.to_upper(strings.concatenate({header_name, "_H"}))
	fmt.sbprintf(out, "#ifndef %s\n#define %s\n\n#include <stdbool.h>\n#include <stdint.h>\n#include <stddef.h>\n\n", guard, guard)
	emitted: map[^Type]bool
	for type in program.types do emit_type(out, type, &emitted)
	for field in program.fields do emit_type(out, field.type, &emitted)
	fmt.sbprintf(out, "typedef struct {{\n")
	for field in program.fields do fmt.sbprintf(out, "\t%s %s;\n", c_type_name(field.type), field.name)
	fmt.sbprintf(out, "}} %s;\n\n", state_type)
	fmt.sbprintf(out, "typedef enum {{\n\t%s_OK,\n", upper_name)
	for abend in ABENDS do fmt.sbprintf(out, "\t%s_ABEND_%s,\n", upper_name, abend)
	fmt.sbprintf(out, "}} %s;\n\n", abend_type)
	fmt.sbprintf(out, "void %s_init(%s *state);\n", program.state_name, state_type)
	fmt.sbprintf(out, "%s %s(%s *state);\n\n#endif\n", abend_type, program.state_name, state_type)

	source_builder := strings.builder_make()
	out = &source_builder
	fmt.sbprintf(out, "#include <math.h>\n#include \"%s.h\"\n\n", header_name)
	values := on_demand_values(program)
	value_matches: [dynamic]^Match
	for match in program.matches {
		if !match.has_pipes do append(&value_matches, match)
	}
	for definition in values do fmt.sbprintf(out, "%s;\n", value_signature(definition.name, definition.type, definition.row_table, state_type))
	for match in value_matches do fmt.sbprintf(out, "%s;\n", value_signature(match.name, match.type, match.row_table, state_type))
	for procedure in program.procedures {
		signature := foreign_signature(procedure) if procedure.foreign_name != "" else procedure_signature(program, procedure, state_type)
		fmt.sbprintf(out, "%s;\n", signature)
	}
	for definition in values {
		scope := Scope{parsed = &definition.parsed, row_table = definition.row_table}
		fmt.sbprintf(out, "\n%s {{\n\treturn ", value_signature(definition.name, definition.type, definition.row_table, state_type))
		emit_expression(program, &scope, out, definition.expression, definition.type)
		fmt.sbprintf(out, ";\n}}\n")
	}
	for match in value_matches do emit_value_match(program, out, match, state_type)
	for procedure in program.procedures {
		if procedure.foreign_name == "" do emit_procedure(program, out, procedure, state_type)
	}

	fmt.sbprintf(out, "\nvoid %s_init(%s *state) {{\n\t*state = (%s){{0}};\n", program.state_name, state_type, state_type)
	for field in program.fields {
		if field.initial == nil do continue
		scope := Scope{parsed = &field.parsed}
		fmt.sbprintf(out, "\tstate->%s = ", field.name)
		emit_expression(program, &scope, out, field.initial, field.type)
		fmt.sbprintf(out, ";\n")
	}
	fmt.sbprintf(out, "}}\n\n%s %s(%s *state) {{\n", abend_type, program.state_name, state_type)
	for field in program.fields {
		emit_state_checks(out, field.type, fmt.aprintf("state->%s", field.name), upper_name, 1)
	}
	tables := state_tables(program)
	for table in tables {
		if table.appends do fmt.sbprintf(out, "\tint %s_added = 0;\n", table.name)
	}
	emit_lines(program, out, upper_name)
	for table in tables do emit_row_changes(out, table)
	fmt.sbprintf(out, "\treturn %s_OK;\n}}\n", upper_name)

	return strings.to_string(header_builder), strings.to_string(source_builder)
}

// Types go out after the types they hold.
emit_type :: proc(out: Output, type: ^Type, emitted: ^map[^Type]bool) {
	if type.builtin || type.untyped || emitted[type] do return
	emitted[type] = true
	switch type.kind {
	case .Integer, .Float, .Boolean:
	case .Enum:
		fmt.sbprintf(out, "typedef int32_t %s;\nenum {{", type.name)
		for name, index in type.cases {
			fmt.sbprintf(out, "%s %s", index == 0 ? "" : ",", enum_constant(type, name))
		}
		fmt.sbprintf(out, " }};\n\n")
	case .Array:
		emit_type(out, type.element, emitted)
		element_type := c_type_name(type.element)
		if type.count > len(ELEMENT_NAMES[0]) {
			fmt.sbprintf(out, "typedef struct {{ %s elements[%d]; }} %s;\n\n", element_type, type.count, c_type_name(type))
			break
		}
		letters := ELEMENT_NAMES[0]
		names: [dynamic]string
		for index in 0 ..< type.count do append(&names, letters[index:][:1])
		fmt.sbprintf(out, "typedef union {{\n\t%s elements[%d];\n\tstruct {{ %s %s; }};\n}} %s;\n\n",
			element_type, type.count, element_type, strings.join(names[:], ", "), c_type_name(type))
	case .Struct:
		for field in type.fields do emit_type(out, field.type, emitted)
		fmt.sbprintf(out, "typedef struct {{\n")
		for field in type.fields do fmt.sbprintf(out, "\t%s %s;\n", c_type_name(field.type), field.name)
		fmt.sbprintf(out, "}} %s;\n\n", type.name)
	case .Table:
		emit_type(out, type.row, emitted)
		fmt.sbprintf(out, "typedef struct {{\n")
		for field in type.fields do fmt.sbprintf(out, "\t%s %s[%d];\n", c_type_name(field.type), field.name, type.count)
		fmt.sbprintf(out, "\tint count;\n\tuint8_t removed[%d];\n}} %s;\n\n", type.count, c_type_name(type))
	}
}

// (hole abend-detail :tags abends :needs abcont) no Abend_Detail in the state: line, row, value, abcont_count.
ABENDS :: [?]string{"BAD_CASE", "BAD_COUNT", "TABLE_FULL"}

state_tables :: proc(program: ^Program) -> [dynamic]^Type {
	tables: [dynamic]^Type
	for field in program.fields {
		if field.type.kind == .Table do append(&tables, field.type)
	}
	return tables
}

// Rows added or removed during the step land here: new rows count, then removed
// rows are swapped out for the last row.
emit_row_changes :: proc(out: Output, table: ^Type) {
	if table.appends do fmt.sbprintf(out, "\tstate->%s.count += %s_added;\n", table.name, table.name)
	if !table.removes do return
	fmt.sbprintf(out, "\tfor (int row = 0; row < state->%s.count;) {{\n", table.name)
	fmt.sbprintf(out, "\t\tif (!state->%s.removed[row]) {{\n\t\t\trow += 1;\n\t\t\tcontinue;\n\t\t}}\n", table.name)
	fmt.sbprintf(out, "\t\tint last = --state->%s.count;\n", table.name)
	for column in table.fields {
		fmt.sbprintf(out, "\t\tstate->%s.%s[row] = state->%s.%s[last];\n", table.name, column.name, table.name, column.name)
	}
	fmt.sbprintf(out, "\t\tstate->%s.removed[row] = state->%s.removed[last];\n", table.name, table.name)
	fmt.sbprintf(out, "\t\tstate->%s.removed[last] = 0;\n\t}}\n", table.name)
}

// One row read out of the columns, as a struct.
row_literal :: proc(table: ^Type, index: string) -> string {
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "(%s){{", table.row.name)
	for column, position in table.fields {
		fmt.sbprintf(&builder, "%s.%s = state->%s.%s[%s]", position == 0 ? " " : ", ", column.name, table.name, column.name, index)
	}
	fmt.sbprintf(&builder, " }}")
	return strings.to_string(builder)
}

emit_row_store :: proc(out: Output, indent: string, table: ^Type, index: string, flow_variable: string) {
	for column in table.fields {
		fmt.sbprintf(out, "%sstate->%s.%s[%s] = %s.%s;\n", indent, table.name, column.name, index, flow_variable, column.name)
	}
}

c_type_name :: proc(type: ^Type) -> string {
	type := default_type(type)
	if type.kind == .Array && strings.has_prefix(type.name, "[") {
		return fmt.aprintf("Array_%d_%s", type.count, c_type_name(type.element))
	}
	if type.kind == .Table do return strings.concatenate({strings.to_ada_case(type.name), "_Table"})
	return type.name
}

enum_constant :: proc(type: ^Type, name: string) -> string {
	return strings.to_upper(strings.concatenate({type.name, "_", name}))
}

on_demand_values :: proc(program: ^Program) -> [dynamic]^Definition {
	values: [dynamic]^Definition
	for definition in program.definitions {
		if !definition.constant do append(&values, definition)
	}
	return values
}

value_signature :: proc(name: string, type: ^Type, row_table: ^Type, state_type: string) -> string {
	row := ", int row" if row_table != nil else ""
	return fmt.aprintf("static inline %s value_%s(const %s *state%s)", c_type_name(type), name, state_type, row)
}

// A struct or array input is spread into one argument per field.
foreign_signature :: proc(procedure: ^Procedure) -> string {
	parameters: [dynamic]string
	for argument in foreign_arguments(procedure.input.type, "") do append(&parameters, c_type_name(argument.type))
	return_type := c_type_name(procedure.output.type) if procedure.output != nil else "void"
	return fmt.aprintf("%s %s(%s)", return_type, procedure.foreign_name, strings.join(parameters[:], ", "))
}

Foreign_Argument :: struct {
	type: ^Type,
	path: string, // after the flow variable: ".x"
}

foreign_arguments :: proc(type: ^Type, path: string) -> [dynamic]Foreign_Argument {
	arguments: [dynamic]Foreign_Argument
	#partial switch type.kind {
	case .Struct:
		for field in type.fields do append(&arguments, Foreign_Argument{field.type, fmt.aprintf("%s.%s", path, field.name)})
	case .Array:
		for index in 0 ..< type.count do append(&arguments, Foreign_Argument{type.element, fmt.aprintf("%s%s", path, element_access(type, index))})
	case:
		append(&arguments, Foreign_Argument{type, path})
	}
	return arguments
}

// Parameters: the read-only slot, the written slot, then the cached values it reads.
// Returns the written slot.
// (hole restrict-pointers :tags codegen) no restrict on pointers whose arrays the write sets prove apart.
procedure_signature :: proc(program: ^Program, procedure: ^Procedure, state_type: string) -> string {
	builder := strings.builder_make()
	return_type := procedure.output != nil ? c_type_name(procedure.output.type) : "void"
	fmt.sbprintf(&builder, "static inline %s proc_%s(%s *state", return_type, procedure.name, state_type)
	for slot in ([]^Slot{procedure.input, procedure.output}) {
		if slot != nil do fmt.sbprintf(&builder, ", %s slot_%s", c_type_name(slot.type), slot.name)
	}
	for name in sorted_names(cached_values(program, procedure.access)) {
		_, type, _ := step_value(program, name)
		fmt.sbprintf(&builder, ", %s cached_%s", c_type_name(type), name)
	}
	fmt.sbprintf(&builder, ")")
	return strings.to_string(builder)
}

recompute_every_read: bool

// An on-demand value that can live in a step local: not constant, not per row.
step_value :: proc(program: ^Program, name: string) -> (access: ^Access, type: ^Type, ok: bool) {
	#partial switch found in program.names[name] {
	case ^Definition:
		if !found.constant && found.row_table == nil do return &found.access, found.type, true
	case ^Match:
		if !found.has_pipes && found.row_table == nil do return &found.access, found.type, true
	}
	return nil, nil, false
}

overlaps :: proc(reads, writes: map[string]bool) -> bool {
	for name in reads {
		if writes[name] do return true
	}
	return false
}

// The values a line or proc reads from step locals: those it does not change itself.
// A value whose inputs it writes is recomputed on each read there.
cached_values :: proc(program: ^Program, access: Access) -> map[string]bool {
	cached: map[string]bool
	if recompute_every_read do return cached
	for name in access.value_reads {
		value, _, ok := step_value(program, name)
		if ok && !overlaps(value.reads, access.writes) do cached[name] = true
	}
	return cached
}

sorted_names :: proc(set: map[string]bool) -> []string {
	names: [dynamic]string
	for name in set do append(&names, name)
	slice.sort(names[:])
	return names[:]
}

// Everything is stale at step start, since the host may have written state. A value
// is recomputed before the first line that reads it after a write to its inputs.
emit_lines :: proc(program: ^Program, out: Output, upper_name: string) {
	body := strings.builder_make()
	current: map[string]bool
	locals: map[string]bool
	for line, index in program.lines {
		cached := cached_values(program, line.access)
		for name in sorted_names(cached) {
			if current[name] do continue
			current[name] = true
			locals[name] = true
			fmt.sbprintf(&body, "\tcached_%s = value_%s(state);\n", name, name)
		}
		emit_line(program, &body, line, index + 1, upper_name, &cached)
		for name in sorted_names(current) {
			value, _, _ := step_value(program, name)
			if overlaps(value.reads, line.access.writes) do delete_key(&current, name)
		}
	}
	for name in sorted_names(locals) {
		_, type, _ := step_value(program, name)
		fmt.sbprintf(out, "\t%s cached_%s;\n", c_type_name(type), name)
	}
	strings.write_string(out, strings.to_string(body))
}

emit_procedure :: proc(program: ^Program, output: Output, procedure: ^Procedure, state_type: string) {
	cached := cached_values(program, procedure.access)
	scope := Scope{parsed = &procedure.parsed, procedure = procedure, cached = &cached}
	body_builder := strings.builder_make()
	out := &body_builder
	for statement in procedure.parsed.statements {
		assignment := statement.derived.(^ast.Assign_Stmt)
		target := assignment.lhs[0]
		target_type := type_of(program, &scope, target)
		if target_type.kind == .Array && assignment.op.text != "=" {
			for element in 0 ..< target_type.count {
				fmt.sbprintf(out, "\t")
				emit_expression(program, &scope, out, target, nil, element)
				fmt.sbprintf(out, " %s ", assignment.op.text)
				emit_expression(program, &scope, out, assignment.rhs[0], target_type, element)
				fmt.sbprintf(out, ";\n")
			}
			continue
		}
		fmt.sbprintf(out, "\t")
		emit_expression(program, &scope, out, target, nil)
		fmt.sbprintf(out, " %s ", assignment.op.text)
		emit_expression(program, &scope, out, assignment.rhs[0], target_type)
		fmt.sbprintf(out, ";\n")
	}
	if procedure.output != nil do fmt.sbprintf(out, "\treturn slot_%s;\n", procedure.output.name)
	body := strings.to_string(body_builder)

	// Cached values can leave a proc with no use of state at all.
	uses_state := strings.contains(body, "state->") || strings.contains(body, "(state")
	fmt.sbprintf(output, "\n%s {{\n%s%s}}\n", procedure_signature(program, procedure, state_type), "" if uses_state else "\t(void)state;\n", body)
}

Line_Emitter :: struct {
	program:    ^Program,
	out:        Output,
	number:     int,
	indent:     string,
	flow_count: int,
	has_gate:   bool,
	row_table:  ^Type,
	upper_name: string,
	cached:     ^map[string]bool,
}

// A line over a table is a loop over its rows. A gate skips to the next row.
// (hole intermediate-logging :tags tooling :sev polish) no way to log every named intermediate of a line.
// (hole parallel-lines :tags codegen) lines with disjoint write sets still run one after another.
emit_line :: proc(program: ^Program, out: Output, line: Line, number: int, upper_name: string, cached: ^map[string]bool) {
	parts := line.parts[:]
	emitter := Line_Emitter{program = program, out = out, number = number, indent = "\t\t", flow_count = 1, row_table = line.row_table, upper_name = upper_name, cached = cached}

	fmt.sbprintf(out, "\t{{ // %s:%d\n", line.location.path, line.location.line)
	outer_indent := emitter.indent
	if line.row_table != nil {
		fmt.sbprintf(out, "%sfor (int row = 0; row < state->%s.count; row += 1) {{\n", emitter.indent, line.row_table.name)
		emitter.indent = strings.concatenate({emitter.indent, "\t"})
	}
	loop_indent := emitter.indent
	if line.repeat_count > 0 {
		fmt.sbprintf(out, "%sfor (int pass = 0; pass < %d; pass += 1) {{\n", emitter.indent, line.repeat_count)
		emitter.indent = strings.concatenate({emitter.indent, "\t"})
	}
	scope := Scope{parsed = &parts[0].parsed, row_table = line.row_table, cached = cached}
	flow := default_type(type_of(program, &scope, parts[0].expression))
	fmt.sbprintf(out, "%s%s flow_1 = ", emitter.indent, c_type_name(flow))
	emit_expression(program, &scope, out, parts[0].expression, flow)
	fmt.sbprintf(out, ";\n")
	emit_parts(&emitter, parts[1:], flow, "flow_1", nil)

	if line.repeat_count > 0 do fmt.sbprintf(out, "%s}}\n", loop_indent)
	if emitter.has_gate do fmt.sbprintf(out, "%sline_%d_end:;\n", loop_indent, number)
	if line.row_table != nil do fmt.sbprintf(out, "%s}}\n", outer_indent)
	fmt.sbprintf(out, "\t}}\n")
}

// Mirrors check_parts. Returns the flow variable after the parts.
emit_parts :: proc(emitter: ^Line_Emitter, parts: []Part, flow: ^Type, flow_variable: string, outer: ^Part) -> string {
	program, out, indent := emitter.program, emitter.out, emitter.indent
	flow, flow_variable := flow, flow_variable
	for &part, index in parts {
		scope := Scope{parsed = &part.parsed, flow_type = flow, flow_variable = flow_variable, row_table = emitter.row_table, cached = emitter.cached}
		switch part.kind {
		case .Gate:
			fmt.sbprintf(out, "%sif (!(", indent)
			emit_expression(program, &scope, out, part.expression, nil)
			fmt.sbprintf(out, ")) goto line_%d_end;\n", emitter.number)
			emitter.has_gate = true
		case .Data:
			table := table_named(program, part.expression)
			switch {
			case part.appends:
				// (hole abcont :tags (tables abends)) TABLE_FULL is an abend; should be an abcont that drops the add and finishes the step.
				fmt.sbprintf(out, "%sif (state->%s.count + %s_added >= %d) return %s_ABEND_TABLE_FULL;\n", indent, table.name, table.name, table.count, emitter.upper_name)
				emit_row_store(out, indent, table, fmt.aprintf("state->%s.count + %s_added", table.name, table.name), flow_variable)
				fmt.sbprintf(out, "%s%s_added += 1;\n", indent, table.name)
			// (hole remove-write-back :tags tables :sev polish) |remove| shells still stores the unchanged row back.
			case table != nil:
				emit_row_store(out, indent, table, "row", flow_variable)
			case:
				fmt.sbprintf(out, "%s", indent)
				emit_expression(program, &scope, out, part.expression, nil)
				fmt.sbprintf(out, " = %s;\n", flow_variable)
			}
		case .Procedure:
			destination := destination_of(parts[index + 1:], outer)
			if part.name == "remove" {
				fmt.sbprintf(out, "%sstate->%s.removed[row] = 1;\n", indent, emitter.row_table.name)
				continue
			}
			#partial switch found in program.names[part.name] {
			case ^Procedure:
				call := procedure_call(program, found, flow_variable, destination, emitter.row_table, emitter.cached)
				if found.output == nil {
					fmt.sbprintf(out, "%s%s;\n", indent, call)
					continue
				}
				flow = found.output.type
				flow_variable = next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s = %s;\n", indent, c_type_name(flow), flow_variable, call)
				// (hole abend-removed-flags :tags (tables abends)) an abend mid-step leaves removed flags set; it should clear them before it returns.
				if found.foreign_name != "" && flow.kind == .Enum {
					fmt.sbprintf(out, "%sif ((uint32_t)%s >= %d) return %s_ABEND_BAD_CASE;\n", indent, flow_variable, len(flow.cases), emitter.upper_name)
				}
			case ^Match:
				output := check_parts(program, found.arms[0].parts[:], flow, destination, emitter.row_table, nil, found.location)
				result := next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s;\n", indent, c_type_name(output), result)
				emit_switch_open(emitter.program, out, found, indent, emitter.cached)
				emitter.indent = strings.concatenate({indent, "\t"})
				for &arm, arm_index in found.arms {
					fmt.sbprintf(out, "%s%s {{\n", indent, case_labels(found, arm_index))
					arm_result := emit_parts(emitter, arm.parts[:], flow, flow_variable, destination)
					fmt.sbprintf(out, "%s%s = %s;\n%sbreak;\n%s}}\n", emitter.indent, result, arm_result, emitter.indent, indent)
				}
				emitter.indent = indent
				fmt.sbprintf(out, "%s}}\n", indent)
				flow, flow_variable = output, result
			}
		}
	}
	return flow_variable
}

next_flow :: proc(emitter: ^Line_Emitter) -> string {
	emitter.flow_count += 1
	return fmt.aprintf("flow_%d", emitter.flow_count)
}

procedure_call :: proc(program: ^Program, procedure: ^Procedure, flow_variable: string, destination: ^Part, row_table: ^Type, line_cached: ^map[string]bool) -> string {
	if procedure.foreign_name != "" {
		values: [dynamic]string
		for argument in foreign_arguments(procedure.input.type, "") {
			append(&values, strings.concatenate({flow_variable, argument.path}))
		}
		return fmt.aprintf("%s(%s)", procedure.foreign_name, strings.join(values[:], ", "))
	}
	arguments := strings.builder_make()
	fmt.sbprintf(&arguments, "state, %s", flow_variable)
	if procedure.input != nil && procedure.output != nil {
		fmt.sbprintf(&arguments, ", ")
		if destination != nil && !destination.appends {
			scope := Scope{parsed = &destination.parsed, row_table = row_table}
			emit_expression(program, &scope, &arguments, destination.expression, nil)
		} else {
			fmt.sbprintf(&arguments, "(%s){{0}}", c_type_name(procedure.output.type))
		}
	}
	for name in sorted_names(cached_values(program, procedure.access)) {
		if line_cached[name] do fmt.sbprintf(&arguments, ", cached_%s", name)
		else do fmt.sbprintf(&arguments, ", value_%s(state)", name)
	}
	return fmt.aprintf("proc_%s(%s)", procedure.name, strings.to_string(arguments))
}

emit_switch_open :: proc(program: ^Program, out: Output, match: ^Match, indent: string, cached: ^map[string]bool = nil) {
	scope := Scope{parsed = &match.parsed, row_table = match.row_table, cached = cached}
	fmt.sbprintf(out, "%sswitch ((int)(", indent)
	emit_expression(program, &scope, out, match.subject, nil)
	fmt.sbprintf(out, ")) {{\n")
}

// Cases are checked at step start, so the last arm also takes `default`.
case_labels :: proc(match: ^Match, arm_index: int) -> string {
	arm := match.arms[arm_index]
	last := arm_index == len(match.arms) - 1
	if arm.label == "else" do return "default:"
	label: string
	switch arm.label {
	case "true":
		label = "case 1:"
	case "false":
		label = "case 0:"
	case:
		label = fmt.aprintf("case %s:", enum_constant(match.subject_type, arm.label))
	}
	return strings.concatenate({label, " default:"}) if last else label
}

emit_value_match :: proc(program: ^Program, out: Output, match: ^Match, state_type: string) {
	fmt.sbprintf(out, "\n%s {{\n", value_signature(match.name, match.type, match.row_table, state_type))
	if !match.touches_state do fmt.sbprintf(out, "\t(void)state;\n")
	emit_switch_open(program, out, match, "\t")
	for &arm, index in match.arms {
		scope := Scope{parsed = &arm.parsed, row_table = match.row_table}
		fmt.sbprintf(out, "\t%s return ", case_labels(match, index))
		emit_expression(program, &scope, out, arm.value, match.type)
		fmt.sbprintf(out, ";\n")
	}
	fmt.sbprintf(out, "\t}}\n}}\n")
}

// A host can write any number into an enum or a table count. Catch it before anything reads it.
emit_state_checks :: proc(out: Output, type: ^Type, path: string, upper_name: string, depth: int) {
	indent := strings.repeat("\t", depth)
	if type.kind == .Table {
		fmt.sbprintf(out, "%sif ((unsigned)%s.count > %d) return %s_ABEND_BAD_COUNT;\n", indent, path, type.count, upper_name)
	}
	if !holds_enum(type) do return
	#partial switch type.kind {
	case .Enum:
		fmt.sbprintf(out, "%sif ((uint32_t)%s >= %d) return %s_ABEND_BAD_CASE;\n", indent, path, len(type.cases), upper_name)
	case .Struct:
		for field in type.fields {
			emit_state_checks(out, field.type, fmt.aprintf("%s.%s", path, field.name), upper_name, depth)
		}
	case .Array, .Table:
		index := fmt.aprintf("index_%d", depth)
		limit := fmt.aprintf("%s.count", path) if type.kind == .Table else fmt.aprintf("%d", type.count)
		fmt.sbprintf(out, "%sfor (int %s = 0; %s < %s; %s += 1) {{\n", indent, index, index, limit, index)
		if type.kind == .Table {
			for column in type.fields {
				emit_state_checks(out, column.type, fmt.aprintf("%s.%s[%s]", path, column.name, index), upper_name, depth + 1)
			}
		} else {
			emit_state_checks(out, type.element, fmt.aprintf("%s.elements[%s]", path, index), upper_name, depth + 1)
		}
		fmt.sbprintf(out, "%s}}\n", indent)
	}
}

holds_enum :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Enum:
		return true
	case .Struct:
		for field in type.fields {
			if holds_enum(field.type) do return true
		}
	case .Array:
		return holds_enum(type.element)
	case .Table:
		return holds_enum(type.row)
	}
	return false
}

// Array math is written out per element. `element` picks one element, -1 is the whole value.
emit_expression :: proc(program: ^Program, scope: ^Scope, out: Output, expression: ^ast.Expr, want: ^Type, element := -1) {
	type := type_of(program, scope, expression)
	want := want
	if want != nil && want.kind == .Array && type.kind != .Array do want = want.element
	if type.untyped && want != nil do type = want
	type = default_type(type)

	if type.kind == .Array && element < 0 && distributes(expression) {
		fmt.sbprintf(out, "(%s){{{{", c_type_name(type))
		for index in 0 ..< type.count {
			if index > 0 do fmt.sbprintf(out, ", ")
			emit_expression(program, scope, out, expression, type, index)
		}
		fmt.sbprintf(out, "}}}}")
		return
	}

	#partial switch node in expression.derived {
	case ^ast.Basic_Lit:
		fmt.sbprintf(out, "%s", format_literal(node.tok.text, type))
	case ^ast.Ident:
		if definition, ok := program.names[node.name].(^Definition); ok && definition.constant && find_slot(scope.procedure, node.name) == nil {
			definition_scope := Scope{parsed = &definition.parsed}
			fmt.sbprintf(out, "(")
			emit_expression(program, &definition_scope, out, definition.expression, type, element)
			fmt.sbprintf(out, ")")
			return
		}
		fmt.sbprintf(out, "%s", c_name(program, scope, node.name))
		emit_element(out, type, element)
	case ^ast.Paren_Expr:
		fmt.sbprintf(out, "(")
		emit_expression(program, scope, out, node.expr, type, element)
		fmt.sbprintf(out, ")")
	case ^ast.Selector_Expr:
		if enum_type := enum_named(program, node.expr); enum_type != nil {
			fmt.sbprintf(out, "%s", enum_constant(enum_type, node.field.name))
			return
		}
		if table := table_named(program, node.expr); table != nil && find_slot(scope.procedure, table.name) == nil {
			fmt.sbprintf(out, "state->%s.%s[row]", table.name, node.field.name)
			emit_element(out, type, element)
			return
		}
		emit_expression(program, scope, out, node.expr, nil)
		base := type_of(program, scope, node.expr)
		if base.kind == .Array {
			fmt.sbprintf(out, "%s", element_access(base, element_index(base, node.field.name)))
		} else {
			fmt.sbprintf(out, ".%s", node.field.name)
		}
		emit_element(out, type, element)
	case ^ast.Unary_Expr:
		fmt.sbprintf(out, "%s", node.op.text)
		emit_expression(program, scope, out, node.expr, type, element)
	case ^ast.Binary_Expr:
		left := type_of(program, scope, node.left)
		right := type_of(program, scope, node.right)
		operand_type := type
		if type.kind == .Boolean && left.kind != .Boolean {
			operand_type = default_type(unify(left, right, node_location(scope, expression)))
		}
		if operand_type.kind == .Array && type.kind == .Boolean {
			emit_array_comparison(program, scope, out, node, operand_type)
			return
		}
		fmt.sbprintf(out, "(")
		emit_expression(program, scope, out, node.left, operand_type, element)
		fmt.sbprintf(out, " %s ", node.op.text)
		emit_expression(program, scope, out, node.right, operand_type, element)
		fmt.sbprintf(out, ")")
	case ^ast.Comp_Lit:
		if type.kind == .Array {
			emit_expression(program, scope, out, node.elems[element], type.element)
			return
		}
		fmt.sbprintf(out, "(%s){{", c_type_name(type))
		for item, index in node.elems {
			field_value := item.derived.(^ast.Field_Value)
			field := struct_field(type, field_value.field.derived.(^ast.Ident).name, {})
			fmt.sbprintf(out, "%s.%s = ", index == 0 ? " " : ", ", field.name)
			emit_expression(program, scope, out, field_value.value, field.type)
		}
		fmt.sbprintf(out, " }}")
	case ^ast.Call_Expr:
		name := node.expr.derived.(^ast.Ident).name
		if is_table_call(node) {
			table := table_named(program, node.args[0])
			// (hole pending-count :tags tables) count() and capacity() are calls; should be shells.count and shells.added fields, capacity a plain constant.
			if name == "count" do fmt.sbprintf(out, "state->%s.count", table.name)
			else do fmt.sbprintf(out, "%d", table.count)
			return
		}
		scalar := type.element if type.kind == .Array else type
		fmt.sbprintf(out, "%s%s(", name, "f" if scalar.name == "float" else "")
		for argument, index in node.args {
			if index > 0 do fmt.sbprintf(out, ", ")
			emit_expression(program, scope, out, argument, type, element)
		}
		fmt.sbprintf(out, ")")
	}
}

// Expressions that are built per element, rather than read whole.
distributes :: proc(expression: ^ast.Expr) -> bool {
	#partial switch node in expression.derived {
	case ^ast.Binary_Expr, ^ast.Unary_Expr, ^ast.Comp_Lit, ^ast.Basic_Lit:
		return true
	case ^ast.Paren_Expr:
		return distributes(node.expr)
	case ^ast.Call_Expr:
		return !is_table_call(node)
	}
	return false
}

emit_element :: proc(out: Output, type: ^Type, element: int) {
	if type.kind == .Array && element >= 0 do fmt.sbprintf(out, "%s", element_access(type, element))
}

// `.y` where the array has element names, `.elements[5]` past them.
element_access :: proc(type: ^Type, index: int) -> string {
	letters := ELEMENT_NAMES[0]
	if type.count <= len(letters) do return fmt.aprintf(".%c", letters[index])
	return fmt.aprintf(".elements[%d]", index)
}

emit_array_comparison :: proc(program: ^Program, scope: ^Scope, out: Output, node: ^ast.Binary_Expr, type: ^Type) {
	fmt.sbprintf(out, node.op.text == "!=" ? "!(" : "(")
	for index in 0 ..< type.count {
		if index > 0 do fmt.sbprintf(out, " && ")
		emit_expression(program, scope, out, node.left, type, index)
		fmt.sbprintf(out, " == ")
		emit_expression(program, scope, out, node.right, type, index)
	}
	fmt.sbprintf(out, ")")
}

c_name :: proc(program: ^Program, scope: ^Scope, name: string) -> string {
	switch {
	case name == FLOW_NAME && scope.flow_type != nil:
		return scope.flow_variable
	case name == "true" || name == "false":
		return name
	case find_slot(scope.procedure, name) != nil:
		return strings.concatenate({"slot_", name})
	}
	if scope.cached != nil && scope.cached[name] do return strings.concatenate({"cached_", name})
	#partial switch found in program.names[name] {
	case ^Definition:
		return fmt.aprintf("value_%s(state%s)", name, ", row" if found.row_table != nil else "")
	case ^Match:
		return fmt.aprintf("value_%s(state%s)", name, ", row" if found.row_table != nil else "")
	case ^Field:
		if found.type.kind == .Table do return row_literal(found.type, "row")
	}
	return strings.concatenate({"state->", name})
}

format_literal :: proc(text: string, type: ^Type) -> string {
	text, _ := strings.remove_all(text, "_")
	if type.kind != .Float do return text
	if !strings.contains_any(text, ".eE") do text = strings.concatenate({text, ".0"})
	if type.name == "float" do text = strings.concatenate({text, "f"})
	return text
}
