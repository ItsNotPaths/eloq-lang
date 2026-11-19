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
	fmt.sbprintf(out, "#ifndef ELOQ_STRING\n#define ELOQ_STRING\ntypedef struct {{ const char *data; int len; }} String;\n#endif\n\n")
	emitted: map[^Type]bool
	for type in program.types do emit_type(out, type, &emitted)
	for field in program.fields do emit_type(out, field.type, &emitted)
	fmt.sbprintf(out, "typedef enum {{\n")
	for code in CODES do fmt.sbprintf(out, "\t%s_%s,\n", upper_name, code)
	fmt.sbprintf(out, "}} %s;\n\n", abend_type)
	fmt.sbprintf(out, "typedef struct {{\n\t%s code;\n\tint line;\n\tint row;\n\tint value;\n}} %s_Entry;\n\n", abend_type, abend_type)
	fmt.sbprintf(out, "typedef struct {{\n\t%s_Entry entries[%d];\n\tint count;\n\tint dropped;\n\tbool stop_on_abcont;\n}} %ss;\n\n", abend_type, ABEND_CAPACITY, abend_type)
	fmt.sbprintf(out, "typedef struct {{\n")
	for field in program.fields do fmt.sbprintf(out, "\t%s %s;\n", c_type_name(field.type), field.name)
	fmt.sbprintf(out, "\t%ss abends;\n}} %s;\n\n", abend_type, state_type)
	fmt.sbprintf(out, "void %s_init(%s *state);\n", program.state_name, state_type)
	fmt.sbprintf(out, "int %s(%s *state);\n\n#endif\n", program.state_name, state_type)

	source_builder := strings.builder_make()
	out = &source_builder
	fmt.sbprintf(out, "#include <math.h>\n#include <string.h>\n#include \"%s.h\"\n\n", header_name)
	tables := state_tables(program)
	emit_abend_procs(out, tables, abend_type, state_type)
	values := on_demand_values(program)
	value_matches: [dynamic]^Match
	for match in program.matches {
		if !match.has_pipes do append(&value_matches, match)
	}
	for definition in values do fmt.sbprintf(out, "%s;\n", value_signature(definition.name, definition.type, definition.row_table, writes_state(definition), state_type))
	for match in value_matches do fmt.sbprintf(out, "%s;\n", value_signature(match.name, match.type, match.row_table, match.access.indexes, state_type))
	for procedure in program.procedures {
		signature := foreign_signature(procedure) if procedure.foreign_name != "" else procedure_signature(program, procedure, state_type)
		fmt.sbprintf(out, "%s;\n", signature)
	}
	for definition in values {
		scope := Scope{parsed = &definition.parsed, row_table = definition.row_table}
		fmt.sbprintf(out, "\n%s {{\n", value_signature(definition.name, definition.type, definition.row_table, writes_state(definition), state_type))
		emit_index_checks(program, &scope, out, "\t", {definition.expression}, table_row(definition.row_table), zero_return(definition.type))
		if len(definition.pipe) > 0 {
			emit_value_pipe(program, &scope, out, definition)
			continue
		}
		fmt.sbprintf(out, "\treturn ")
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
	fmt.sbprintf(out, "}}\n\n")
	fmt.sbprintf(out, "int %s(%s *state) {{\n\tstate->abends.count = 0;\n\tstate->abends.dropped = 0;\n", program.state_name, state_type)
	for field in program.fields {
		emit_state_checks(out, field.type, fmt.aprintf("state->%s", field.name), upper_name, field.location.line, "-1", 1)
	}
	for table in tables do fmt.sbprintf(out, "\tstate->%s.added = 0;\n", table.name)
	emit_lines(program, out, upper_name)
	for table in tables do emit_row_changes(out, table)
	fmt.sbprintf(out, "\treturn state->abends.count + state->abends.dropped;\n}}\n")

	return strings.to_string(header_builder), strings.to_string(source_builder)
}

// Types go out after the types they hold.
emit_type :: proc(out: Output, type: ^Type, emitted: ^map[^Type]bool) {
	if type.builtin || type.untyped || emitted[type] do return
	emitted[type] = true
	switch type.kind {
	case .Integer, .Float, .Boolean, .String:
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
		fmt.sbprintf(out, "\tint count;\n\tint added;\n\tuint8_t removed[%d];\n}} %s;\n\n", type.count, c_type_name(type))
	}
}

CODES :: [?]string{"ABEND_BAD_CASE", "ABEND_BAD_COUNT", "ABCONT_TABLE_FULL", "ABCONT_BAD_INDEX"}
ABEND_CAPACITY :: 16

// Codes land in state->abends in the order they happen. A stop drops pending removes.
emit_abend_procs :: proc(out: Output, tables: [dynamic]^Type, abend_type, state_type: string) {
	parameters := fmt.aprintf("%s *state, %s code, int line, int row, int value", state_type, abend_type)
	fmt.sbprintf(out, "static inline void record_abend(%s) {{\n", parameters)
	fmt.sbprintf(out, "\tif (state->abends.count == %d) {{\n\t\tstate->abends.dropped += 1;\n\t\treturn;\n\t}}\n", ABEND_CAPACITY)
	fmt.sbprintf(out, "\tstate->abends.entries[state->abends.count++] = (%s_Entry){{code, line, row, value}};\n}}\n\n", abend_type)
	fmt.sbprintf(out, "static inline int stop_step(%s *state) {{\n", state_type)
	for table in tables {
		if table.appends do fmt.sbprintf(out, "\tstate->%s.added = 0;\n", table.name)
		if table.removes do fmt.sbprintf(out, "\tmemset(state->%s.removed, 0, sizeof state->%s.removed);\n", table.name, table.name)
	}
	fmt.sbprintf(out, "\treturn state->abends.count + state->abends.dropped;\n}}\n\n")
	fmt.sbprintf(out, "static inline int abend_step(%s) {{\n\trecord_abend(state, code, line, row, value);\n\treturn stop_step(state);\n}}\n\n", parameters)
}

abend_call :: proc(procedure, upper_name, code: string, line: int, row, value: string) -> string {
	return fmt.aprintf("%s(state, %s_%s, %d, %s, %s)", procedure, upper_name, code, line, row, value)
}

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
	if table.appends do fmt.sbprintf(out, "\tstate->%s.count += state->%s.added;\n\tstate->%s.added = 0;\n", table.name, table.name, table.name)
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
	if type.kind == .String do return "String"
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

value_signature :: proc(name: string, type: ^Type, row_table: ^Type, writable: bool, state_type: string) -> string {
	row := ", int row" if row_table != nil else ""
	return fmt.aprintf("static inline %s value_%s(%s%s *state%s)", c_type_name(type), name, "" if writable else "const ", state_type, row)
}

// A value that indexes can record an abcont, and procs take state as writable.
writes_state :: proc(definition: ^Definition) -> bool {
	return definition.access.indexes || len(definition.pipe) > 0
}

emit_value_pipe :: proc(program: ^Program, scope: ^Scope, out: Output, definition: ^Definition) {
	flow := default_type(type_of(program, scope, definition.expression))
	fmt.sbprintf(out, "\t%s flow_1 = ", c_type_name(flow))
	emit_expression(program, scope, out, definition.expression, flow)
	fmt.sbprintf(out, ";\n")
	flow_variable := "flow_1"
	no_cache: map[string]bool
	for part, index in definition.pipe {
		procedure := resolve_procedure(program, program.names[part.name].(^Procedure), flow, definition.parsed.location)
		call := procedure_call(program, procedure, flow_variable, nil, definition.row_table, &no_cache)
		if procedure.output == nil {
			fmt.sbprintf(out, "\t%s;\n", call)
			continue
		}
		flow_variable = fmt.aprintf("flow_%d", index + 2)
		flow = procedure.output.type
		fmt.sbprintf(out, "\t%s %s = %s;\n", c_type_name(flow), flow_variable, call)
	}
	fmt.sbprintf(out, "\treturn %s;\n}}\n", flow_variable)
}

table_row :: proc(row_table: ^Type) -> string {
	return "row" if row_table != nil else "-1"
}

zero_return :: proc(type: ^Type) -> string {
	return fmt.aprintf("return (%s){{0}};", c_type_name(type))
}

Index_Check :: struct {
	index: string,
	bound: string,
	line:  int,
}

// One bounds check per index, before the statement that holds it, so a bad index
// records one abcont rather than one per element. Returns whether it wrote any.
emit_index_checks :: proc(program: ^Program, scope: ^Scope, out: Output, indent: string, expressions: []^ast.Expr, row, on_fail: string) -> bool {
	checks: [dynamic]Index_Check
	for expression in expressions do gather_index_checks(program, scope, expression, &checks)
	emitted: map[string]bool
	for check in checks {
		key := strings.concatenate({check.index, " < ", check.bound})
		if emitted[key] do continue
		emitted[key] = true
		call := abend_call("record_abend", strings.to_upper(program.state_name), "ABCONT_BAD_INDEX", check.line, row, fmt.aprintf("(int)(%s)", check.index))
		fmt.sbprintf(out, "%sif ((unsigned)(%s) >= (unsigned)(%s)) {{\n%s\t%s;\n%s\t%s\n%s}}\n", indent, check.index, check.bound, indent, call, indent, on_fail, indent)
	}
	return len(checks) > 0
}

// Inner indexes first: `a[b[i]]` checks `i` before `b[i]`.
gather_index_checks :: proc(program: ^Program, scope: ^Scope, expression: ^ast.Expr, checks: ^[dynamic]Index_Check) {
	if expression == nil do return
	#partial switch node in expression.derived {
	case ^ast.Index_Expr:
		gather_index_checks(program, scope, node.expr, checks)
		gather_index_checks(program, scope, node.index, checks)
		bound: string
		if is_table_index(program, scope, node) {
			bound = fmt.aprintf("state->%s.count", table_named(program, node.expr).name)
		} else if _, is_literal := node.index.derived.(^ast.Basic_Lit); is_literal {
			return
		} else {
			bound = fmt.aprintf("%d", type_of(program, scope, node.expr).count)
		}
		append(checks, Index_Check{index_text(program, scope, node.index), bound, node_location(scope, expression).line})
	case ^ast.Selector_Expr:
		gather_index_checks(program, scope, node.expr, checks)
	case ^ast.Paren_Expr:
		gather_index_checks(program, scope, node.expr, checks)
	case ^ast.Unary_Expr:
		gather_index_checks(program, scope, node.expr, checks)
	case ^ast.Binary_Expr:
		gather_index_checks(program, scope, node.left, checks)
		gather_index_checks(program, scope, node.right, checks)
	case ^ast.Comp_Lit:
		for element in node.elems do gather_index_checks(program, scope, element, checks)
	case ^ast.Field_Value:
		gather_index_checks(program, scope, node.value, checks)
	case ^ast.Call_Expr:
		for argument in node.args do gather_index_checks(program, scope, argument, checks)
	}
}

// A part whose proc or values can record an abcont inside the call, which the line
// then sees by the code count.
part_calls_index :: proc(program: ^Program, part: ^Part) -> bool {
	if part.kind == .Procedure {
		#partial switch found in program.names[part.name] {
		case ^Procedure:
			for overload := found; overload != nil; overload = overload.next_overload {
				if overload.access.indexes do return true
			}
		case ^Match:
			if reads_index_value(program, found.subject) do return true
			for &arm in found.arms {
				for &arm_part in arm.parts {
					if part_calls_index(program, &arm_part) do return true
				}
			}
		}
		return false
	}
	return reads_index_value(program, part.expression)
}

reads_index_value :: proc(program: ^Program, expression: ^ast.Expr) -> bool {
	for name in gather_names(expression) {
		#partial switch found in program.names[name.name] {
		case ^Definition:
			if found.access.indexes do return true
		case ^Match:
			if !found.has_pipes && found.access.indexes do return true
		}
	}
	return false
}

is_table_index :: proc(program: ^Program, scope: ^Scope, indexed: ^ast.Index_Expr) -> bool {
	table := table_named(program, indexed.expr)
	return table != nil && find_slot(scope.procedure, table.name) == nil
}

index_text :: proc(program: ^Program, scope: ^Scope, index: ^ast.Expr) -> string {
	builder := strings.builder_make()
	emit_expression(program, scope, &builder, index, builtin_type("int"))
	return strings.to_string(builder)
}

// A struct or array input is spread into one argument per field.
procedure_c_name :: proc(procedure: ^Procedure) -> string {
	if !procedure.overloaded do return strings.concatenate({"proc_", procedure.name})
	return fmt.aprintf("proc_%s_%s", procedure.name, c_type_name(fed_slot(procedure).type))
}

foreign_signature :: proc(procedure: ^Procedure) -> string {
	parameters: [dynamic]string
	for argument in foreign_arguments(procedure.input.type, "") {
		append(&parameters, strings.concatenate({c_type_name(argument.type), " *" if argument.type.kind == .Table else ""}))
	}
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
	fmt.sbprintf(&builder, "static inline %s %s(%s *state", return_type, procedure_c_name(procedure), state_type)
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
		if ok && !value.indexes && !overlaps(value.reads, access.writes) do cached[name] = true
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
	on_fail := fmt.aprintf("return slot_%s;", procedure.output.name) if procedure.output != nil else "return;"
	for statement in procedure.parsed.statements {
		assignment := statement.derived.(^ast.Assign_Stmt)
		target := assignment.lhs[0]
		emit_index_checks(program, &scope, out, "\t", {target, assignment.rhs[0]}, "-1", on_fail)
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
	program:      ^Program,
	out:          Output,
	number:       int,
	indent:       string,
	flow_count:   int,
	source_line:  int,
	flow_is_row:  bool, // the line starts with its own table's row
	has_line_end: bool,
	row_table:    ^Type,
	upper_name:   string,
	cached:       ^map[string]bool,
}

// A line over a table is a loop over its rows. A gate skips to the next row.
// (hole intermediate-logging :tags tooling :sev polish) no way to log every named intermediate of a line.
// (hole parallel-lines :tags codegen) lines with disjoint write sets still run one after another.
emit_line :: proc(program: ^Program, out: Output, line: Line, number: int, upper_name: string, cached: ^map[string]bool) {
	parts := line.parts[:]
	emitter := Line_Emitter{program = program, out = out, number = number, source_line = line.location.line, flow_is_row = line.row_table != nil && table_named(program, parts[0].expression) == line.row_table, indent = "\t\t", flow_count = 1, row_table = line.row_table, upper_name = upper_name, cached = cached}

	fmt.sbprintf(out, "\t{{ // %s:%d\n", line.location.path, line.location.line)
	if table := table_flow(program, parts); table != nil {
		emit_parts(&emitter, parts[1:], table, fmt.aprintf("&state->%s", table.name), nil)
		fmt.sbprintf(out, "\t}}\n")
		return
	}
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
	for &part in parts {
		if part_calls_index(program, &part) {
			fmt.sbprintf(out, "%sint codes_before = state->abends.count + state->abends.dropped;\n", emitter.indent)
			break
		}
	}
	scope := Scope{parsed = &parts[0].parsed, row_table = line.row_table, cached = cached}
	flow := default_type(type_of(program, &scope, parts[0].expression))
	emitter.has_line_end ||= emit_index_checks(program, &scope, out, emitter.indent, {parts[0].expression}, emitter_row(&emitter), line_skip(&emitter))
	fmt.sbprintf(out, "%s%s flow_1 = ", emitter.indent, c_type_name(flow))
	emit_expression(program, &scope, out, parts[0].expression, flow)
	fmt.sbprintf(out, ";\n")
	emit_codes_check(&emitter, &parts[0])
	emit_parts(&emitter, parts[1:], flow, "flow_1", nil)

	if line.repeat_count > 0 do fmt.sbprintf(out, "%s}}\n", loop_indent)
	if emitter.has_line_end do fmt.sbprintf(out, "%sline_%d_end:;\n", loop_indent, number)
	if line.row_table != nil do fmt.sbprintf(out, "%s}}\n", outer_indent)
	fmt.sbprintf(out, "\t}}\n")
}

// Mirrors check_parts. Returns the flow variable after the parts.
emit_parts :: proc(emitter: ^Line_Emitter, parts: []Part, flow: ^Type, flow_variable: string, outer: ^Part) -> string {
	program, out, indent := emitter.program, emitter.out, emitter.indent
	flow, flow_variable := flow, flow_variable
	for &part, index in parts {
		scope := Scope{parsed = &part.parsed, flow_type = flow, flow_variable = flow_variable, row_table = emitter.row_table, cached = emitter.cached}
		defer emit_codes_check(emitter, &part)
		if part.kind != .Procedure {
			emitter.has_line_end ||= emit_index_checks(program, &scope, out, indent, {part.expression}, emitter_row(emitter), line_skip(emitter))
		}
		switch part.kind {
		case .Gate:
			fmt.sbprintf(out, "%sif (!(", indent)
			emit_expression(program, &scope, out, part.expression, nil)
			fmt.sbprintf(out, ")) goto line_%d_end;\n", emitter.number)
			emitter.has_line_end = true
		case .Data:
			table := table_named(program, part.expression)
			switch {
			case part.appends:
				next_row := fmt.aprintf("state->%s.count + state->%s.added", table.name, table.name)
				emit_abcont(emitter, fmt.aprintf("%s >= %d", next_row, table.count), "TABLE_FULL", "0")
				emit_row_store(out, indent, table, next_row, flow_variable)
				fmt.sbprintf(out, "%sstate->%s.added += 1;\n", indent, table.name)
			case flow.kind == .Table:
			case table != nil && flow_variable == "flow_1" && emitter.flow_is_row:
				// the row read at the start, unchanged: `shells ?expired? |remove| shells`
				fmt.sbprintf(out, "%s(void)flow_1;\n", indent)
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
				procedure := resolve_procedure(program, found, flow, {line = emitter.source_line})
				call := procedure_call(program, procedure, flow_variable, destination, emitter.row_table, emitter.cached)
				if procedure.output == nil {
					fmt.sbprintf(out, "%s%s;\n", indent, call)
					continue
				}
				flow = procedure.output.type
				flow_variable = next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s = %s;\n", indent, c_type_name(flow), flow_variable, call)
				if procedure.foreign_name != "" && flow.kind == .Enum {
					call := abend_call("abend_step", emitter.upper_name, "ABEND_BAD_CASE", emitter.source_line, emitter_row(emitter), fmt.aprintf("(int)%s", flow_variable))
					fmt.sbprintf(out, "%sif ((uint32_t)%s >= %d) return %s;\n", indent, flow_variable, len(flow.cases), call)
				}
			case ^Match:
				output := check_parts(program, found.arms[0].parts[:], flow, destination, emitter.row_table, nil, found.location)
				result := next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s;\n", indent, c_type_name(output), result)
				subject_scope := Scope{parsed = &found.parsed, row_table = emitter.row_table, cached = emitter.cached}
				emitter.has_line_end ||= emit_index_checks(program, &subject_scope, out, indent, {found.subject}, emitter_row(emitter), line_skip(emitter))
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

// An abcont skips the rest of the line for this row, or stops the step if the host asks.
emit_abcont :: proc(emitter: ^Line_Emitter, condition, abcont, value: string) {
	call := abend_call("record_abend", emitter.upper_name, strings.concatenate({"ABCONT_", abcont}), emitter.source_line, emitter_row(emitter), value)
	fmt.sbprintf(emitter.out, "%sif (%s) {{\n%s\t%s;\n%s\t%s\n%s}}\n", emitter.indent, condition, emitter.indent, call, emitter.indent, line_skip(emitter), emitter.indent)
	emitter.has_line_end = true
}

// A proc or value that indexes records its own abcont; the line then skips the row.
emit_codes_check :: proc(emitter: ^Line_Emitter, part: ^Part) {
	if !part_calls_index(emitter.program, part) do return
	emitter.has_line_end = true
	out, indent := emitter.out, emitter.indent
	fmt.sbprintf(out, "%sif (state->abends.count + state->abends.dropped != codes_before) {{\n", indent)
	if emitter.row_table != nil {
		fmt.sbprintf(out, "%s\tfor (int entry = codes_before; entry < state->abends.count; entry += 1) state->abends.entries[entry].row = row;\n", indent)
	}
	fmt.sbprintf(out, "%s\t%s\n%s}}\n", indent, line_skip(emitter), indent)
}

line_skip :: proc(emitter: ^Line_Emitter) -> string {
	return fmt.aprintf("if (state->abends.stop_on_abcont) return stop_step(state); else goto line_%d_end;", emitter.number)
}

emitter_row :: proc(emitter: ^Line_Emitter) -> string {
	return "row" if emitter.row_table != nil else "-1"
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
	return fmt.aprintf("%s(%s)", procedure_c_name(procedure), strings.to_string(arguments))
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
	fmt.sbprintf(out, "\n%s {{\n", value_signature(match.name, match.type, match.row_table, match.access.indexes, state_type))
	if !match.touches_state do fmt.sbprintf(out, "\t(void)state;\n")
	row, on_fail := table_row(match.row_table), zero_return(match.type)
	subject_scope := Scope{parsed = &match.parsed, row_table = match.row_table}
	emit_index_checks(program, &subject_scope, out, "\t", {match.subject}, row, on_fail)
	emit_switch_open(program, out, match, "\t")
	for &arm, index in match.arms {
		scope := Scope{parsed = &arm.parsed, row_table = match.row_table}
		fmt.sbprintf(out, "\t%s {{\n", case_labels(match, index))
		emit_index_checks(program, &scope, out, "\t\t", {arm.value}, row, on_fail)
		fmt.sbprintf(out, "\t\treturn ")
		emit_expression(program, &scope, out, arm.value, match.type)
		fmt.sbprintf(out, ";\n\t}}\n")
	}
	fmt.sbprintf(out, "\t}}\n}}\n")
}

// A host can write any number into an enum or a table count. Catch it before anything reads it.
emit_state_checks :: proc(out: Output, type: ^Type, path: string, upper_name: string, line: int, row: string, depth: int) {
	indent := strings.repeat("\t", depth)
	if type.kind == .Table {
		call := abend_call("abend_step", upper_name, "ABEND_BAD_COUNT", line, row, fmt.aprintf("%s.count", path))
		fmt.sbprintf(out, "%sif ((unsigned)%s.count > %d) return %s;\n", indent, path, type.count, call)
	}
	if !holds_enum(type) do return
	#partial switch type.kind {
	case .Enum:
		call := abend_call("abend_step", upper_name, "ABEND_BAD_CASE", line, row, fmt.aprintf("(int)%s", path))
		fmt.sbprintf(out, "%sif ((uint32_t)%s >= %d) return %s;\n", indent, path, len(type.cases), call)
	case .Struct:
		for field in type.fields {
			emit_state_checks(out, field.type, fmt.aprintf("%s.%s", path, field.name), upper_name, line, row, depth)
		}
	case .Array, .Table:
		index := fmt.aprintf("index_%d", depth)
		limit := fmt.aprintf("%s.count", path) if type.kind == .Table else fmt.aprintf("%d", type.count)
		fmt.sbprintf(out, "%sfor (int %s = 0; %s < %s; %s += 1) {{\n", indent, index, index, limit, index)
		if type.kind == .Table {
			for column in type.fields {
				emit_state_checks(out, column.type, fmt.aprintf("%s.%s[%s]", path, column.name, index), upper_name, line, index, depth + 1)
			}
		} else {
			emit_state_checks(out, type.element, fmt.aprintf("%s.elements[%s]", path, index), upper_name, line, row, depth + 1)
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
		if indexed, ok := node.expr.derived.(^ast.Index_Expr); ok && is_table_index(program, scope, indexed) {
			fmt.sbprintf(out, "state->%s.%s[%s]", table_named(program, indexed.expr).name, node.field.name, index_text(program, scope, indexed.index))
			emit_element(out, type, element)
			return
		}
		if table := table_named(program, node.expr); table != nil && find_slot(scope.procedure, table.name) == nil {
			fmt.sbprintf(out, "state->%s.%s%s", table.name, node.field.name, "" if is_table_count(node.field.name) else "[row]")
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
	case ^ast.Index_Expr:
		if is_table_index(program, scope, node) {
			fmt.sbprintf(out, "%s", row_literal(table_named(program, node.expr), index_text(program, scope, node.index)))
			return
		}
		emit_expression(program, scope, out, node.expr, nil)
		fmt.sbprintf(out, ".elements[%s]", index_text(program, scope, node.index))
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
		if operand_type.kind == .String {
			emit_string_comparison(program, scope, out, node)
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
	case ^ast.Binary_Expr, ^ast.Unary_Expr, ^ast.Comp_Lit, ^ast.Basic_Lit, ^ast.Call_Expr:
		return true
	case ^ast.Paren_Expr:
		return distributes(node.expr)
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

// Length, then the bytes.
emit_string_comparison :: proc(program: ^Program, scope: ^Scope, out: Output, node: ^ast.Binary_Expr) {
	left_builder, right_builder := strings.builder_make(), strings.builder_make()
	emit_expression(program, scope, &left_builder, node.left, nil)
	emit_expression(program, scope, &right_builder, node.right, nil)
	left, right := strings.to_string(left_builder), strings.to_string(right_builder)
	fmt.sbprintf(out, "%s(%s.len == %s.len && memcmp(%s.data, %s.data, (size_t)%s.len) == 0)", "!" if node.op.text == "!=" else "", left, right, left, right, left)
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
