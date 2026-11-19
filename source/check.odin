package eloqc

import "core:fmt"
import "core:odin/ast"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

// What names mean while reading one expression.
Scope :: struct {
	parsed:        ^Parsed,
	procedure:     ^Procedure,
	flow_type:     ^Type,
	flow_variable: string,
	touches_state: bool,
	row_table:     ^Type, // the table whose current row columns read from
	row_open:      bool, // the first column read picks row_table (on-demand values)
	access:        ^Access, // where reads go, when someone wants them
	cached:        ^map[string]bool, // values read from a step local, not recomputed
}

note_read :: proc(scope: ^Scope, name: string) {
	if scope.access != nil do scope.access.reads[name] = true
}

note_value_read :: proc(scope: ^Scope, name: string, value: Access) {
	if scope.access == nil do return
	scope.access.value_reads[name] = true
	for read in value.reads do scope.access.reads[read] = true
}

merge_access :: proc(into: ^Access, from: Access) {
	if into == nil do return
	for name in from.reads do into.reads[name] = true
	for name in from.writes do into.writes[name] = true
	for name in from.value_reads do into.value_reads[name] = true
}

column_name :: proc(table: ^Type, column: string) -> string {
	return strings.concatenate({table.name, ".", column})
}

// The state name a data part writes: a field, or "table.column".
target_name :: proc(program: ^Program, expression: ^ast.Expr) -> string {
	if selector, ok := expression.derived.(^ast.Selector_Expr); ok {
		if table := table_named(program, selector.expr); table != nil do return column_name(table, selector.field.name)
		return target_name(program, selector.expr)
	}
	return root_name(expression).name
}

// A column or a per-row value needs a row of its table.
use_row :: proc(scope: ^Scope, table: ^Type, location: Location) {
	switch {
	case scope.row_table == table:
	case scope.row_table == nil && scope.row_open:
		scope.row_table = table
	case:
		fail(location, "%s is per row, use it in a line over %s", table.name, table.name)
	}
}

table_named :: proc(program: ^Program, expression: ^ast.Expr) -> ^Type {
	if expression == nil do return nil
	name, is_name := expression.derived.(^ast.Ident)
	if !is_name do return nil
	field, is_field := program.names[name.name].(^Field)
	return field.type if is_field && field.type.kind == .Table else nil
}

node_location :: proc(scope: ^Scope, node: ^ast.Node) -> Location {
	return {scope.parsed.location.path, scope.parsed.location.line + node.pos.line - WRAPPER_LINES - 1}
}

check_program :: proc(program: ^Program) {
	for type in program.types do complete_type(program, type)
	for field in program.fields do check_field(program, field)
	for definition in program.definitions do check_definition(program, definition)
	for procedure in program.procedures do check_procedure(program, procedure)
	for match in program.matches do check_match(program, match)
	for &line in program.lines do check_line(program, &line)
}

complete_type :: proc(program: ^Program, type: ^Type) {
	if type.alias != nil {
		scope := Scope{parsed = &type.alias_parsed}
		array, ok := type.alias.derived.(^ast.Array_Type)
		if !ok do fail(type.location, "%s: expected an array type", type.name)
		type.alias = nil
		type.element, type.count = array_shape(program, &scope, array)
	}
	for field in type.fields {
		if field.type == nil {
			scope := Scope{parsed = &field.parsed}
			field.type = resolve_type(program, &scope, field.type_expression)
		}
	}
}

resolve_type :: proc(program: ^Program, scope: ^Scope, expression: ^ast.Expr) -> ^Type {
	location := node_location(scope, expression)
	#partial switch node in expression.derived {
	case ^ast.Ident:
		type, ok := program.names[node.name].(^Type)
		if !ok do fail(location, "%s is not a type", node.name)
		complete_type(program, type)
		return type
	case ^ast.Array_Type:
		element, count := array_shape(program, scope, node)
		name := fmt.aprintf("[%d]%s", count, element.name)
		if existing, found := program.names[name].(^Type); found do return existing
		type := new_clone(Type{name = name, kind = .Array, element = element, count = count})
		program.names[name] = type
		append(&program.types, type)
		return type
	}
	fail(location, "not a type")
}

array_shape :: proc(program: ^Program, scope: ^Scope, array: ^ast.Array_Type) -> (element: ^Type, count: int) {
	location := node_location(scope, array)
	if array.len == nil do fail(location, "an array needs a fixed length")
	literal, ok := array.len.derived.(^ast.Basic_Lit)
	if !ok || literal.tok.kind != .Integer do fail(location, "an array needs a fixed integer length")
	count, _ = strconv.parse_int(literal.tok.text)
	return resolve_type(program, scope, array.elem), count
}

check_field :: proc(program: ^Program, field: ^Field) {
	scope := Scope{parsed = &field.parsed}
	if field.type_expression != nil {
		field.type = resolve_type(program, &scope, field.type_expression)
	}
	if field.initial == nil {
		if field.type == nil do fail(field.location, "%s needs a type or a value", field.name)
		return
	}
	initial_type := type_of(program, &scope, field.initial)
	if scope.touches_state do fail(field.location, "the starting value of %s must be constant", field.name)
	if field.type == nil {
		field.type = default_type(initial_type)
	} else if !accepts(field.type, initial_type) {
		fail(field.location, "%s is %s, its starting value is %s", field.name, field.type.name, initial_type.name)
	}
}

check_definition :: proc(program: ^Program, definition: ^Definition) {
	switch definition.status {
	case .Checked:
		return
	case .Checking:
		fail(definition.parsed.location, "%s is defined in terms of itself", definition.name)
	case .Unchecked:
	}
	definition.status = .Checking
	scope := Scope{parsed = &definition.parsed, row_open = true, access = &definition.access}
	type := type_of(program, &scope, definition.expression)
	definition.row_table = scope.row_table
	definition.constant = !scope.touches_state
	definition.type = definition.constant ? type : default_type(type)
	definition.status = .Checked
}

check_procedure :: proc(program: ^Program, procedure: ^Procedure) {
	location := procedure.parsed.location
	scope := Scope{parsed = &procedure.parsed, procedure = procedure, access = &procedure.access}
	if procedure.foreign_name != "" {
		check_foreign(program, procedure)
		return
	}

	for statement in procedure.parsed.statements {
		assignment, ok := statement.derived.(^ast.Assign_Stmt)
		if !ok do fail(node_location(&scope, statement), "a proc body holds assignments only")
		if len(assignment.lhs) != 1 || len(assignment.rhs) != 1 {
			fail(node_location(&scope, statement), "assign one value at a time")
		}
		for name in gather_names(assignment.lhs[0]) do mark_slot(procedure, &scope, name, false)
		for name in gather_names(assignment.rhs[0]) do mark_slot(procedure, &scope, name, true)
		target := root_name(assignment.lhs[0])
		mark_slot(procedure, &scope, target, assignment.op.text != "=", true)
	}

	for &slot in procedure.slots {
		switch found in program.names[slot.name] {
		case ^Type:
			complete_type(program, found)
			slot.type = found
		case ^Field:
			// (hole whole-array-procs :tags tables) a slot on a table is one row; a foreign proc on a table should get Table * once.
			slot.type = found.type.row if found.type.kind == .Table else found.type
		case nil:
			slot.type = column_type(program, slot.name, location)
		case ^Definition, ^Procedure, ^Match:
			fail(location, "slot %s must be labeled with a type, a state name or a column", slot.name)
		}
		switch {
		case slot.written:
			if procedure.output != nil do fail(location, "%s writes two slots: %s and %s", procedure.name, procedure.output.name, slot.name)
			procedure.output = &slot
		case slot.read:
			if procedure.input != nil do fail(location, "%s reads two slots: %s and %s", procedure.name, procedure.input.name, slot.name)
			procedure.input = &slot
		}
	}
	if len(procedure.slots) == 0 do fail(location, "%s has no slot, mark one with $", procedure.name)

	for statement in procedure.parsed.statements {
		check_assignment(program, &scope, statement.derived.(^ast.Assign_Stmt))
	}
}

check_foreign :: proc(program: ^Program, procedure: ^Procedure) {
	scope := Scope{parsed = &procedure.parsed}
	for expression, index in procedure.foreign_types {
		if expression == nil do continue
		append(&procedure.slots, Slot{name = index == 0 ? "input" : "output", type = resolve_type(program, &scope, expression), read = index == 0, written = index == 1})
	}
	procedure.input = &procedure.slots[0]
	if len(procedure.slots) == 2 do procedure.output = &procedure.slots[1]
}

// A column name as a slot label, when every table agrees on its type.
column_type :: proc(program: ^Program, name: string, location: Location) -> ^Type {
	type: ^Type
	for field in program.fields {
		if field.type.kind != .Table do continue
		for column in field.type.fields {
			if column.name != name do continue
			if type != nil && type != column.type do fail(location, "slot %s: columns named %s differ in type, label it with a type", name, name)
			type = column.type
		}
	}
	if type == nil do fail(location, "slot %s must be labeled with a type, a state name or a column", name)
	return type
}

// Adds a slot for a `$` name, and records how slot names are used.
mark_slot :: proc(procedure: ^Procedure, scope: ^Scope, name: ^ast.Ident, read: bool, written := false) {
	if name == nil do return
	slot := find_slot(procedure, name.name)
	if slot == nil {
		if !scope.parsed.slot_offsets[name.pos.offset] do return
		append(&procedure.slots, Slot{name = name.name})
		slot = &procedure.slots[len(procedure.slots) - 1]
	}
	slot.read ||= read
	slot.written ||= written
}

find_slot :: proc(procedure: ^Procedure, name: string) -> ^Slot {
	if procedure == nil do return nil
	for &slot in procedure.slots {
		if slot.name == name do return &slot
	}
	return nil
}

// Every name read by an expression, not counting field names after a dot.
gather_names :: proc(expression: ^ast.Expr) -> [dynamic]^ast.Ident {
	names: [dynamic]^ast.Ident
	gather :: proc(expression: ^ast.Expr, names: ^[dynamic]^ast.Ident) {
		if expression == nil do return
		#partial switch node in expression.derived {
		case ^ast.Ident:
			append(names, node)
		case ^ast.Selector_Expr:
			gather(node.expr, names)
		case ^ast.Paren_Expr:
			gather(node.expr, names)
		case ^ast.Unary_Expr:
			gather(node.expr, names)
		case ^ast.Binary_Expr:
			gather(node.left, names)
			gather(node.right, names)
		case ^ast.Comp_Lit:
			for element in node.elems do gather(element, names)
		case ^ast.Field_Value:
			gather(node.value, names)
		case ^ast.Call_Expr:
			if !is_table_call(node) {
				for argument in node.args do gather(argument, names)
			}
		}
	}
	gather(expression, &names)
	return names
}

// C math, by its double name. A float argument calls the `f` version.
math_arity :: proc(name: string) -> int {
	switch name {
	case "sqrt", "cbrt", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
	     "exp", "exp2", "log", "log2", "log10", "floor", "ceil", "round", "trunc", "fabs":
		return 1
	case "atan2", "pow", "fmod", "fmin", "fmax", "hypot", "copysign":
		return 2
	}
	return 0
}

is_table_call :: proc(call: ^ast.Call_Expr) -> bool {
	name, is_name := call.expr.derived.(^ast.Ident)
	return is_name && (name.name == "count" || name.name == "capacity")
}

// The name an assignment target hangs off: `a` in `a.b.c`.
root_name :: proc(expression: ^ast.Expr) -> ^ast.Ident {
	#partial switch node in expression.derived {
	case ^ast.Ident:
		return node
	case ^ast.Selector_Expr:
		return root_name(node.expr)
	}
	return nil
}

check_assignment :: proc(program: ^Program, scope: ^Scope, assignment: ^ast.Assign_Stmt) {
	target := assignment.lhs[0]
	location := node_location(scope, target)
	root := root_name(target)
	if root == nil do fail(location, "can only assign to a slot or state")
	_, is_field := program.names[root.name].(^Field)
	if find_slot(scope.procedure, root.name) == nil && !is_field {
		fail(location, "can only assign to a slot or state, %s is neither", root.name)
	}

	if is_field && find_slot(scope.procedure, root.name) == nil do scope.access.writes[root.name] = true
	target_type := type_of(program, scope, target)
	value_type := type_of(program, scope, assignment.rhs[0])
	if assignment.op.text != "=" {
		value_type = arithmetic_type(target_type, value_type, location)
	}
	if !accepts(target_type, value_type) {
		fail(location, "cannot assign %s to %s", value_type.name, target_type.name)
	}
}

check_line :: proc(program: ^Program, line: ^Line) {
	parts := line.parts[:]
	if len(parts) < 2 || parts[0].kind != .Data || parts[len(parts) - 1].kind != .Data {
		fail(line.location, "a line needs data on both ends")
	}
	line.row_table = line_row_table(program, line)
	last := &parts[len(parts) - 1]
	if table := table_named(program, last.expression); table != nil && table != line.row_table {
		last.appends = true
		table.appends = true
	}
	scope := Scope{parsed = &parts[0].parsed, row_table = line.row_table, access = &line.access}
	flow := default_type(type_of(program, &scope, parts[0].expression))
	check_parts(program, parts[1:], flow, nil, line.row_table, &line.access, line.location)
}

// The table a line runs over, once per row: the one its columns or per-row values
// name. A table at the end of the line is a target, not a reason to loop.
line_row_table :: proc(program: ^Program, line: ^Line) -> ^Type {
	table: ^Type
	last := len(line.parts) - 1
	for &part, index in line.parts {
		if index == last && table_named(program, part.expression) != nil do continue
		note_row_tables(program, &part, &table, line.location)
	}
	return table
}

note_row_tables :: proc(program: ^Program, part: ^Part, table: ^^Type, location: Location) {
	note :: proc(table: ^^Type, found: ^Type, location: Location) {
		if found == nil do return
		if table^ != nil && table^ != found do fail(location, "a line runs over one table, this one names %s and %s", table^.name, found.name)
		table^ = found
	}
	switch part.kind {
	case .Data, .Gate:
		for name in gather_names(part.expression) {
			#partial switch found in program.names[name.name] {
			case ^Field:
				if found.type.kind == .Table do note(table, found.type, location)
			case ^Definition:
				note(table, found.row_table, location)
			case ^Match:
				note(table, found.row_table, location)
			}
		}
	case .Procedure:
		match, is_match := program.names[part.name].(^Match)
		if !is_match do return
		note(table, match.row_table, location)
		for &arm in match.arms {
			for &arm_part in arm.parts do note_row_tables(program, &arm_part, table, location)
		}
	}
}

// Checks parts fed with `flow` and returns what flows out. `outer` is where output
// lands when the parts run out, for match arms.
// `access` collects what the parts touch, nil when nobody asks.
check_parts :: proc(program: ^Program, parts: []Part, flow: ^Type, outer: ^Part, row_table: ^Type, access: ^Access, location: Location) -> ^Type {
	flow := flow
	for &part, index in parts {
		scope := Scope{parsed = &part.parsed, flow_type = flow, row_table = row_table, access = access}
		switch part.kind {
		case .Gate:
			if gate_type := type_of(program, &scope, part.expression); gate_type.kind != .Boolean {
				fail(location, "a gate needs a bool, got %s", gate_type.name)
			}
		case .Data:
			if table := table_named(program, part.expression); table != nil && access != nil {
				for column in table.fields do access.writes[column_name(table, column.name)] = true
				if part.appends do access.writes[column_name(table, "added")] = true
			} else if access != nil {
				access.writes[target_name(program, part.expression)] = true
			}
			if part.appends {
				table := table_named(program, part.expression)
				if flow != table.row do fail(location, "a row of %s is %s, got %s", table.name, table.row.name, flow.name)
				continue
			}
			check_target(program, &scope, part.expression, location)
			if target_type := type_of(program, &scope, part.expression); target_type != flow {
				fail(location, "cannot write %s to %s", flow.name, target_type.name)
			}
		case .Procedure:
			destination := destination_of(parts[index + 1:], outer)
			if part.name == "remove" {
				if row_table == nil || flow != row_table.row do fail(location, "remove takes a row of the table the line runs over")
				row_table.removes = true
				if access != nil do access.writes[column_name(row_table, "removed")] = true
				continue
			}
			switch found in program.names[part.name] {
			case ^Procedure:
				flow = check_call(program, found, flow, destination, row_table, location)
				merge_access(access, found.access)
			case ^Match:
				if !found.has_pipes do fail(location, "%s is a value, not a proc", part.name)
				check_match(program, found)
				merge_access(access, found.access)
				output: ^Type
				for &arm in found.arms {
					arm_output := check_parts(program, arm.parts[:], flow, destination, row_table, access, arm.location)
					if output != nil && arm_output != output {
						fail(arm.location, "arms of %s give %s and %s", part.name, output.name, arm_output.name)
					}
					output = arm_output
				}
				flow = output
			case ^Type, ^Field, ^Definition, nil:
				fail(location, "%s is not a proc", part.name)
			}
		}
	}
	return flow
}

check_call :: proc(program: ^Program, procedure: ^Procedure, flow: ^Type, destination: ^Part, row_table: ^Type, location: Location) -> ^Type {
	fed := procedure.input if procedure.input != nil else procedure.output
	if fed.type != flow do fail(location, "%s takes %s, got %s", procedure.name, fed.type.name, flow.name)
	if procedure.output == nil do return flow
	if destination != nil {
		if destination_type(program, destination, row_table) != procedure.output.type {
			fail(location, "%s gives %s, which does not fit its destination", procedure.name, procedure.output.type.name)
		}
	}
	return procedure.output.type
}

destination_type :: proc(program: ^Program, destination: ^Part, row_table: ^Type) -> ^Type {
	if destination.appends do return table_named(program, destination.expression).row
	scope := Scope{parsed = &destination.parsed, row_table = row_table}
	return type_of(program, &scope, destination.expression)
}

// The data a proc's output lands in: the next data part, past any gates.
destination_of :: proc(rest: []Part, outer: ^Part) -> ^Part {
	for &part in rest {
		switch part.kind {
		case .Gate:
			continue
		case .Data:
			return &part
		case .Procedure:
			return nil
		}
	}
	return outer
}

check_match :: proc(program: ^Program, match: ^Match) {
	switch match.status {
	case .Checked:
		return
	case .Checking:
		fail(match.location, "%s is defined in terms of itself", match.name)
	case .Unchecked:
	}
	match.status = .Checking
	scope := Scope{parsed = &match.parsed, row_open = true, access = &match.access}
	subject := default_type(type_of(program, &scope, match.subject))
	match.subject_type = subject
	cases: []string
	#partial switch subject.kind {
	case .Enum:
		cases = subject.cases[:]
	case .Boolean:
		cases = {"true", "false"}
	case:
		fail(match.location, "a match needs an enum or bool, got %s", subject.name)
	}

	covered: map[string]bool
	for arm, index in match.arms {
		if arm.label == "else" {
			if index != len(match.arms) - 1 do fail(arm.location, "else must be the last arm")
			for name in cases do covered[name] = true
			continue
		}
		if !slice.contains(cases, arm.label) do fail(arm.location, "%s has no case %s", subject.name, arm.label)
		if covered[arm.label] do fail(arm.location, "case %s twice", arm.label)
		covered[arm.label] = true
	}
	for name in cases {
		if !covered[name] do fail(match.location, "%s misses case %s", match.name, name)
	}

	if !match.has_pipes {
		for &arm in match.arms {
			arm_scope := Scope{parsed = &arm.parsed, row_table = scope.row_table, row_open = true, access = &match.access}
			arm_type := type_of(program, &arm_scope, arm.value)
			match.type = arm_type if match.type == nil else unify(match.type, arm_type, arm.location)
			scope.touches_state ||= arm_scope.touches_state
			if arm_scope.row_table != nil do use_row(&scope, arm_scope.row_table, arm.location)
		}
		match.type = default_type(match.type)
	}
	match.touches_state = scope.touches_state
	match.row_table = scope.row_table
	match.status = .Checked
}

check_target :: proc(program: ^Program, scope: ^Scope, expression: ^ast.Expr, location: Location) {
	root := root_name(expression)
	if root == nil do fail(location, "cannot write to this")
	if _, is_field := program.names[root.name].(^Field); !is_field {
		fail(location, "can only write to state, %s is not stored data", root.name)
	}
}

default_type :: proc(type: ^Type) -> ^Type {
	if type == untyped_integer do return builtin_type("int")
	if type == untyped_float do return builtin_type("float")
	return type
}


// Whether a value of type `source` can be stored in `target`.
// (hole coercion :tags types) strict; every coercion should be automatic by C rules, both widening and narrowing.
accepts :: proc(target, source: ^Type) -> bool {
	if target == source do return true
	if !source.untyped do return false
	#partial switch target.kind {
	case .Float:
		return true
	case .Integer:
		return source == untyped_integer
	case .Array:
		return accepts(target.element, source)
	}
	return false
}

unify :: proc(left, right: ^Type, location: Location) -> ^Type {
	switch {
	case left == right:
		return left
	case left.untyped && right.untyped:
		return untyped_float
	case left.untyped && accepts(right, left):
		return right
	case right.untyped && accepts(left, right):
		return left
	}
	fail(location, "type mismatch: %s and %s", left.name, right.name)
}

is_numeric :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Integer, .Float:
		return true
	case .Array:
		return is_numeric(type.element)
	}
	return false
}

// `+ - * /`: element-wise on arrays, and a scalar spreads over an array.
arithmetic_type :: proc(left, right: ^Type, location: Location) -> ^Type {
	result: ^Type
	switch {
	case left.kind == .Array && right.kind != .Array:
		if !accepts(left.element, right) do fail(location, "type mismatch: %s and %s", left.name, right.name)
		result = left
	case right.kind == .Array && left.kind != .Array:
		if !accepts(right.element, left) do fail(location, "type mismatch: %s and %s", left.name, right.name)
		result = right
	case:
		result = unify(left, right, location)
	}
	if !is_numeric(result) do fail(location, "arithmetic needs numbers, got %s", result.name)
	return result
}

ELEMENT_NAMES :: [?]string{"xyzw", "rgba"}

element_index :: proc(type: ^Type, name: string) -> int {
	if len(name) != 1 do return -1
	for names in ELEMENT_NAMES {
		index := strings.index_byte(names, name[0])
		if index >= 0 && index < type.count do return index
	}
	return -1
}

enum_named :: proc(program: ^Program, expression: ^ast.Expr) -> ^Type {
	name, is_name := expression.derived.(^ast.Ident)
	if !is_name do return nil
	type, is_type := program.names[name.name].(^Type)
	return type if is_type && type.kind == .Enum else nil
}

type_of :: proc(program: ^Program, scope: ^Scope, expression: ^ast.Expr) -> ^Type {
	location := node_location(scope, expression)
	#partial switch node in expression.derived {
	case ^ast.Basic_Lit:
		#partial switch node.tok.kind {
		case .Integer:
			return untyped_integer
		case .Float:
			return untyped_float
		}
	case ^ast.Ident:
		return type_of_name(program, scope, node.name, location)
	case ^ast.Paren_Expr:
		return type_of(program, scope, node.expr)
	case ^ast.Selector_Expr:
		if enum_type := enum_named(program, node.expr); enum_type != nil {
			for name in enum_type.cases {
				if name == node.field.name do return enum_type
			}
			fail(location, "%s has no case %s", enum_type.name, node.field.name)
		}
		if table := table_named(program, node.expr); table != nil && find_slot(scope.procedure, table.name) == nil {
			use_row(scope, table, location)
			scope.touches_state = true
			note_read(scope, column_name(table, node.field.name))
			return struct_field(table.row, node.field.name, location).type
		}
		base := type_of(program, scope, node.expr)
		#partial switch base.kind {
		case .Struct:
			for field in base.fields {
				if field.name == node.field.name do return field.type
			}
		case .Array:
			if element_index(base, node.field.name) >= 0 do return base.element
		}
		fail(location, "%s has no field %s", base.name, node.field.name)
	case ^ast.Unary_Expr:
		operand := type_of(program, scope, node.expr)
		switch node.op.text {
		case "-", "+":
			if !is_numeric(operand) do fail(location, "%s needs a number", node.op.text)
			return operand
		case "!":
			if operand.kind != .Boolean do fail(location, "not needs a bool")
			return operand
		}
	case ^ast.Binary_Expr:
		left := type_of(program, scope, node.left)
		right := type_of(program, scope, node.right)
		switch node.op.text {
		case "&&", "||":
			if left.kind != .Boolean || right.kind != .Boolean do fail(location, "%s needs bools", node.op.text)
			return left
		case "==", "!=":
			if unify(left, right, location).kind == .Struct do fail(location, "structs cannot be compared")
			return builtin_type("bool")
		case "<", ">", "<=", ">=":
			if unified := unify(left, right, location); unified.kind != .Integer && unified.kind != .Float {
				fail(location, "%s needs numbers", node.op.text)
			}
			return builtin_type("bool")
		case "+", "-", "*", "/":
			return arithmetic_type(left, right, location)
		case "%", "&", "|", "~", "<<", ">>":
			if unified := unify(left, right, location); unified.kind == .Integer do return unified
			fail(location, "%s needs integers", node.op.text)
		}
	case ^ast.Call_Expr:
		name, is_name := node.expr.derived.(^ast.Ident)
		if !is_name do fail(location, "call a function by name")
		if is_table_call(node) {
			table := table_named(program, node.args[0]) if len(node.args) == 1 else nil
			if table == nil do fail(location, "%s takes a table", name.name)
			if name.name == "count" {
				scope.touches_state = true
				note_read(scope, column_name(table, "count"))
			}
			return builtin_type("int")
		}
		arity := math_arity(name.name)
		if arity == 0 do fail(location, "%s is not a function: calls are count, capacity and C math", name.name)
		if len(node.args) != arity do fail(location, "%s takes %d values", name.name, arity)
		result := type_of(program, scope, node.args[0])
		for argument in node.args[1:] do result = arithmetic_type(result, type_of(program, scope, argument), location)
		if result == untyped_integer do result = untyped_float
		scalar := result.element if result.kind == .Array else result
		if scalar.kind != .Float do fail(location, "%s takes float or double, got %s", name.name, result.name)
		return result
	case ^ast.Comp_Lit:
		if node.type == nil do fail(location, "name the type: Vector{1, 2, 3}")
		type := resolve_type(program, scope, node.type)
		#partial switch type.kind {
		case .Array:
			if len(node.elems) != type.count do fail(location, "%s takes %d values", type.name, type.count)
			for element in node.elems {
				if !accepts(type.element, type_of(program, scope, element)) do fail(location, "%s holds %s", type.name, type.element.name)
			}
		case .Struct:
			for element in node.elems {
				field_value, ok := element.derived.(^ast.Field_Value)
				if !ok do fail(location, "name each field: %s{health = 1}", type.name)
				field := struct_field(type, field_value.field.derived.(^ast.Ident).name, location)
				if !accepts(field.type, type_of(program, scope, field_value.value)) do fail(location, "%s.%s is %s", type.name, field.name, field.type.name)
			}
		case:
			fail(location, "%s cannot be built with {}", type.name)
		}
		return type
	}
	// (hole index-syntax :tags types :needs abcont) no enemies[target].position reads or writes; out of range should be an abcont.
	fail(location, "not allowed in eloq: %v", reflect.union_variant_typeid(expression.derived))
}

struct_field :: proc(type: ^Type, name: string, location: Location) -> ^Field {
	for field in type.fields {
		if field.name == name do return field
	}
	fail(location, "%s has no field %s", type.name, name)
}

type_of_name :: proc(program: ^Program, scope: ^Scope, name: string, location: Location) -> ^Type {
	if name == FLOW_NAME && scope.flow_type != nil do return scope.flow_type
	if name == "true" || name == "false" do return builtin_type("bool")
	if slot := find_slot(scope.procedure, name); slot != nil do return slot.type
	switch found in program.names[name] {
	case ^Field:
		scope.touches_state = true
		if found.type.kind != .Table {
			note_read(scope, name)
			return found.type
		}
		use_row(scope, found.type, location)
		for column in found.type.fields do note_read(scope, column_name(found.type, column.name))
		return found.type.row
	case ^Definition:
		check_definition(program, found)
		if !found.constant {
			scope.touches_state = true
			note_value_read(scope, name, found.access)
		}
		if found.row_table != nil do use_row(scope, found.row_table, location)
		return found.type
	case ^Match:
		if found.has_pipes do fail(location, "%s is a proc, not a value", name)
		check_match(program, found)
		scope.touches_state = true
		note_value_read(scope, name, found.access)
		if found.row_table != nil do use_row(scope, found.row_table, location)
		return found.type
	case ^Type, ^Procedure:
		fail(location, "%s is not a value", name)
	case nil:
	}
	fail(location, "unknown name %s", name)
}
