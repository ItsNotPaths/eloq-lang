package eloqc

import "core:fmt"
import "core:odin/ast"
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
	fmt.sbprintf(out, "typedef enum {{ %s_OK, %s_ABEND_BAD_CASE }} %s;\n\n", upper_name, upper_name, abend_type)
	fmt.sbprintf(out, "void %s_init(%s *state);\n", program.state_name, state_type)
	fmt.sbprintf(out, "%s %s(%s *state);\n\n#endif\n", abend_type, program.state_name, state_type)

	source_builder := strings.builder_make()
	out = &source_builder
	fmt.sbprintf(out, "#include \"%s.h\"\n\n", header_name)
	values := on_demand_values(program)
	value_matches: [dynamic]^Match
	for match in program.matches {
		if !match.has_pipes do append(&value_matches, match)
	}
	for definition in values do fmt.sbprintf(out, "%s;\n", value_signature(definition.name, definition.type, state_type))
	for match in value_matches do fmt.sbprintf(out, "%s;\n", value_signature(match.name, match.type, state_type))
	for procedure in program.procedures do fmt.sbprintf(out, "%s;\n", procedure_signature(procedure, state_type))
	for definition in values {
		scope := Scope{parsed = &definition.parsed}
		fmt.sbprintf(out, "\n%s {{\n\treturn ", value_signature(definition.name, definition.type, state_type))
		emit_expression(program, &scope, out, definition.expression, definition.type)
		fmt.sbprintf(out, ";\n}}\n")
	}
	for match in value_matches do emit_value_match(program, out, match, state_type)
	for procedure in program.procedures do emit_procedure(program, out, procedure, state_type)

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
		emit_case_checks(out, field.type, fmt.aprintf("state->%s", field.name), fmt.aprintf("%s_ABEND_BAD_CASE", upper_name), 1)
	}
	for line, index in program.lines do emit_line(program, out, line, index + 1)
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
	}
}

c_type_name :: proc(type: ^Type) -> string {
	type := default_type(type)
	if type.kind == .Array && strings.has_prefix(type.name, "[") {
		return fmt.aprintf("Array_%d_%s", type.count, c_type_name(type.element))
	}
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

value_signature :: proc(name: string, type: ^Type, state_type: string) -> string {
	return fmt.aprintf("static inline %s value_%s(const %s *state)", c_type_name(type), name, state_type)
}

// Parameters: the read-only slot, then the written slot. Returns the written slot.
procedure_signature :: proc(procedure: ^Procedure, state_type: string) -> string {
	builder := strings.builder_make()
	return_type := procedure.output != nil ? c_type_name(procedure.output.type) : "void"
	fmt.sbprintf(&builder, "static inline %s proc_%s(%s *state", return_type, procedure.name, state_type)
	for slot in ([]^Slot{procedure.input, procedure.output}) {
		if slot != nil do fmt.sbprintf(&builder, ", %s slot_%s", c_type_name(slot.type), slot.name)
	}
	fmt.sbprintf(&builder, ")")
	return strings.to_string(builder)
}

emit_procedure :: proc(program: ^Program, out: Output, procedure: ^Procedure, state_type: string) {
	scope := Scope{parsed = &procedure.parsed, procedure = procedure}
	fmt.sbprintf(out, "\n%s {{\n", procedure_signature(procedure, state_type))
	if !procedure.touches_state do fmt.sbprintf(out, "\t(void)state;\n")
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
	fmt.sbprintf(out, "}}\n")
}

Line_Emitter :: struct {
	program:    ^Program,
	out:        Output,
	number:     int,
	indent:     string,
	flow_count: int,
	has_gate:   bool,
}

emit_line :: proc(program: ^Program, out: Output, line: Line, number: int) {
	parts := line.parts[:]
	emitter := Line_Emitter{program = program, out = out, number = number, indent = "\t\t", flow_count = 1}

	fmt.sbprintf(out, "\t{{ // %s:%d\n", line.location.path, line.location.line)
	if line.repeat_count > 0 {
		fmt.sbprintf(out, "\t\tfor (int pass = 0; pass < %d; pass += 1) {{\n", line.repeat_count)
		emitter.indent = "\t\t\t"
	}
	scope := Scope{parsed = &parts[0].parsed}
	flow := default_type(type_of(program, &scope, parts[0].expression))
	fmt.sbprintf(out, "%s%s flow_1 = ", emitter.indent, c_type_name(flow))
	emit_expression(program, &scope, out, parts[0].expression, flow)
	fmt.sbprintf(out, ";\n")
	emit_parts(&emitter, parts[1:], flow, "flow_1", nil)

	if line.repeat_count > 0 do fmt.sbprintf(out, "\t\t}}\n")
	if emitter.has_gate do fmt.sbprintf(out, "\tline_%d_end:;\n", number)
	fmt.sbprintf(out, "\t}}\n")
}

// Mirrors check_parts. Returns the flow variable after the parts.
emit_parts :: proc(emitter: ^Line_Emitter, parts: []Part, flow: ^Type, flow_variable: string, outer: ^Part) -> string {
	program, out, indent := emitter.program, emitter.out, emitter.indent
	flow, flow_variable := flow, flow_variable
	for &part, index in parts {
		scope := Scope{parsed = &part.parsed, flow_type = flow, flow_variable = flow_variable}
		switch part.kind {
		case .Gate:
			fmt.sbprintf(out, "%sif (!(", indent)
			emit_expression(program, &scope, out, part.expression, nil)
			fmt.sbprintf(out, ")) goto line_%d_end;\n", emitter.number)
			emitter.has_gate = true
		case .Data:
			fmt.sbprintf(out, "%s", indent)
			emit_expression(program, &scope, out, part.expression, nil)
			fmt.sbprintf(out, " = %s;\n", flow_variable)
		case .Procedure:
			destination := destination_of(parts[index + 1:], outer)
			#partial switch found in program.names[part.name] {
			case ^Procedure:
				call := procedure_call(program, found, flow_variable, destination)
				if found.output == nil {
					fmt.sbprintf(out, "%s%s;\n", indent, call)
					continue
				}
				flow = found.output.type
				flow_variable = next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s = %s;\n", indent, c_type_name(flow), flow_variable, call)
			case ^Match:
				output := check_parts(program, found.arms[0].parts[:], flow, destination, found.location)
				result := next_flow(emitter)
				fmt.sbprintf(out, "%s%s %s;\n", indent, c_type_name(output), result)
				emit_switch_open(emitter.program, out, found, indent)
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

procedure_call :: proc(program: ^Program, procedure: ^Procedure, flow_variable: string, destination: ^Part) -> string {
	arguments := strings.builder_make()
	fmt.sbprintf(&arguments, "state, %s", flow_variable)
	if procedure.input != nil && procedure.output != nil {
		fmt.sbprintf(&arguments, ", ")
		if destination != nil {
			scope := Scope{parsed = &destination.parsed}
			emit_expression(program, &scope, &arguments, destination.expression, nil)
		} else {
			fmt.sbprintf(&arguments, "(%s){{0}}", c_type_name(procedure.output.type))
		}
	}
	return fmt.aprintf("proc_%s(%s)", procedure.name, strings.to_string(arguments))
}

emit_switch_open :: proc(program: ^Program, out: Output, match: ^Match, indent: string) {
	scope := Scope{parsed = &match.parsed}
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
	fmt.sbprintf(out, "\n%s {{\n", value_signature(match.name, match.type, state_type))
	if !match.touches_state do fmt.sbprintf(out, "\t(void)state;\n")
	emit_switch_open(program, out, match, "\t")
	for &arm, index in match.arms {
		scope := Scope{parsed = &arm.parsed}
		fmt.sbprintf(out, "\t%s return ", case_labels(match, index))
		emit_expression(program, &scope, out, arm.value, match.type)
		fmt.sbprintf(out, ";\n")
	}
	fmt.sbprintf(out, "\t}}\n}}\n")
}

// A host can write any number into an enum field. Catch it before anything reads it.
emit_case_checks :: proc(out: Output, type: ^Type, path: string, abend: string, depth: int) {
	if !holds_enum(type) do return
	indent := strings.repeat("\t", depth)
	#partial switch type.kind {
	case .Enum:
		fmt.sbprintf(out, "%sif ((uint32_t)%s >= %d) return %s;\n", indent, path, len(type.cases), abend)
	case .Struct:
		for field in type.fields {
			emit_case_checks(out, field.type, fmt.aprintf("%s.%s", path, field.name), abend, depth)
		}
	case .Array:
		index := fmt.aprintf("index_%d", depth)
		fmt.sbprintf(out, "%sfor (int %s = 0; %s < %d; %s += 1) {{\n", indent, index, index, type.count, index)
		emit_case_checks(out, type.element, fmt.aprintf("%s.elements[%s]", path, index), abend, depth + 1)
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
	}
}

// Expressions that are built per element, rather than read whole.
distributes :: proc(expression: ^ast.Expr) -> bool {
	#partial switch node in expression.derived {
	case ^ast.Binary_Expr, ^ast.Unary_Expr, ^ast.Comp_Lit, ^ast.Basic_Lit:
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
	#partial switch _ in program.names[name] {
	case ^Definition, ^Match:
		return fmt.aprintf("value_%s(state)", name)
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
