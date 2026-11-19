package eloqc

import "core:odin/ast"
import "core:strconv"
import "core:strings"

Type_Kind :: enum {
	Integer,
	Float,
	Boolean,
	Struct,
	Enum,
	Array,
	Table, // fields are the columns, count the capacity
}

Type :: struct {
	name:            string,
	kind:            Type_Kind,
	untyped:         bool, // a literal that takes the type of what it meets
	builtin:         bool,
	location:        Location,
	fields:          [dynamic]^Field, // Struct
	cases:           [dynamic]string, // Enum
	element:         ^Type, // Array
	count:           int, // Array
	alias:           ^ast.Expr, // named Array, until resolved
	alias_parsed:    Parsed,
	row:             ^Type, // Table: one row as a struct
	capacity_name:   string, // Table: a named constant, until resolved
	appends:         bool, // Table: some line adds rows
	removes:         bool, // Table: some line removes rows
}

Field :: struct {
	name:            string,
	location:        Location,
	type:            ^Type,
	type_expression: ^ast.Expr,
	initial:         ^ast.Expr,
	parsed:          Parsed,
}

// What a proc, value or line touches. Table columns are "table.column".
Access :: struct {
	reads:       map[string]bool,
	writes:      map[string]bool,
	value_reads: map[string]bool, // on-demand values and value matches, by name
}

Check_Status :: enum {
	Unchecked,
	Checking,
	Checked,
}

// `name :: expression`: a constant, or an on-demand value when it reads state.
Definition :: struct {
	name:       string,
	expression: ^ast.Expr,
	parsed:     Parsed,
	type:       ^Type,
	constant:   bool,
	row_table:  ^Type, // set when it reads columns: one value per row
	access:     Access,
	status:     Check_Status,
}

Slot :: struct {
	name:    string,
	type:    ^Type,
	read:    bool,
	written: bool,
}

Procedure :: struct {
	name:   string,
	parsed: Parsed,
	foreign_name: string, // a C function: never sees the state
	foreign_types: [2]^ast.Expr, // input, output (nil when void)
	slots:  [dynamic]Slot,
	input:  ^Slot, // the read-only slot
	output: ^Slot, // the written slot
	access: Access,
}

// `name :: ?subject?` with one arm per case. Value arms make an on-demand value,
// pipe arms make a proc.
Match :: struct {
	name:          string,
	location:      Location,
	subject:       ^ast.Expr,
	parsed:        Parsed,
	arms:          [dynamic]Arm,
	has_pipes:     bool,
	subject_type:  ^Type,
	type:          ^Type, // value matches
	touches_state: bool,
	row_table:     ^Type,
	access:        Access,
	status:        Check_Status,
}

Arm :: struct {
	label:    string, // a case, or "else"
	location: Location,
	value:    ^ast.Expr,
	parsed:   Parsed,
	parts:    [dynamic]Part,
}

Name :: union {
	^Type,
	^Field,
	^Definition,
	^Procedure,
	^Match,
}

Program :: struct {
	state_name:     string,
	state_location: Location,
	names:          map[string]Name,
	types:          [dynamic]^Type, // declared by the program, in order
	fields:         [dynamic]^Field, // the state
	definitions:    [dynamic]^Definition,
	procedures:     [dynamic]^Procedure,
	matches:        [dynamic]^Match,
	lines:          [dynamic]Line,
}

untyped_integer := &Type{name = "untyped integer", kind = .Integer, untyped = true}
untyped_float := &Type{name = "untyped float", kind = .Float, untyped = true}

builtin_types: map[string]^Type

builtin_type :: proc(name: string) -> ^Type {
	return builtin_types[name]
}

// (hole opaque-strings :tags types) no built-in string {data, len}, no char type, no == on arrays.
BUILTIN_TYPES :: [?]struct {
	name: string,
	kind: Type_Kind,
} {
	{"float", .Float},
	{"double", .Float},
	{"bool", .Boolean},
	{"int", .Integer},
	{"unsigned", .Integer},
	{"char", .Integer},
	{"size_t", .Integer},
	{"int8_t", .Integer},
	{"int16_t", .Integer},
	{"int32_t", .Integer},
	{"int64_t", .Integer},
	{"uint8_t", .Integer},
	{"uint16_t", .Integer},
	{"uint32_t", .Integer},
	{"uint64_t", .Integer},
}

build_program :: proc(items: []Item) -> Program {
	program: Program
	for builtin in BUILTIN_TYPES {
		type := new_clone(Type{name = builtin.name, kind = builtin.kind, builtin = true})
		builtin_types[builtin.name] = type
		program.names[builtin.name] = type
	}
	for item in items {
		text := item.header.text
		switch {
		case strings.has_prefix(text, "state "):
			if program.state_name != "" do fail(item.header, "a program has one state, already have %s", program.state_name)
			program.state_name = strings.trim_space(text[len("state "):])
			program.state_location = item.header
			for entry in body_entries(item) {
				add_declaration(&program, entry.text, entry)
			}
		case strings.contains(text, "::"):
			add_definition(&program, item)
		case strings.contains(text, ":"):
			add_declaration(&program, text, item.header)
		case:
			append(&program.lines, parse_line(item.header))
		}
	}
	if program.state_name == "" do fail({items[0].header.path, 1}, "no state declared")
	return program
}

add_name :: proc(program: ^Program, name: string, value: Name, location: Location) {
	if name == "remove" || name == "abends" do fail(location, "%s is built in", name)
	// (hole proc-overloading :tags types) one proc per name; procs should share a name when input slot types differ.
	if name in program.names do fail(location, "%s is already defined", name)
	program.names[name] = value
}

add_definition :: proc(program: ^Program, item: Item) {
	location := item.header.location
	before, _, after := strings.partition(item.header.text, "::")
	name := strings.trim_space(before)
	rest := strings.trim_space(after)
	switch {
	case rest == "":
		text, body_location := body_text(item)
		procedure := new_clone(Procedure{name = name, parsed = parse_odin(text, body_location)})
		add_name(program, name, procedure, location)
		append(&program.procedures, procedure)
	case rest == "struct":
		add_type(program, new_clone(Type{name = name, kind = .Struct, location = location, fields = parse_fields(item)}))
	case rest == "enum":
		type := new_clone(Type{name = name, kind = .Enum, location = location})
		for entry in body_entries(item) do append(&type.cases, entry.text)
		add_type(program, type)
	case strings.has_prefix(rest, "?"), strings.has_prefix(rest, GATE_OPENER):
		add_match(program, name, rest, item)
	case strings.has_prefix(rest, "table "):
		add_table(program, name, rest, item)
	case strings.has_prefix(rest, "foreign "):
		add_foreign(program, name, rest, location)
	case:
		add_declaration(program, item.header.text, location)
	}
}

parse_fields :: proc(item: Item) -> [dynamic]^Field {
	fields: [dynamic]^Field
	for entry in body_entries(item) {
		field_name, _, type_text := strings.partition(entry.text, ":")
		type_expression, parsed := parse_expression(strings.trim_space(type_text), entry)
		append(&fields, new_clone(Field{name = strings.trim_space(field_name), location = entry, type_expression = type_expression, parsed = parsed}))
	}
	return fields
}

// A table is stored data. Its type is not a name; its row type is.
add_table :: proc(program: ^Program, name: string, header: string, item: Item) {
	location := item.header.location
	capacity_text := strings.trim_space(header[len("table "):])
	capacity, is_number := strconv.parse_int(capacity_text, 10)
	if is_number && capacity < 1 do fail(location, "a table needs a positive capacity: %s :: table 512", name)
	columns := parse_fields(item)
	for column in columns {
		if is_table_count(column.name) || column.name == "removed" do fail(column.location, "%s is kept for the table itself", column.name)
	}
	row := new_clone(Type{name = strings.concatenate({strings.to_ada_case(name), "_Row"}), kind = .Struct, location = location, fields = columns})
	add_type(program, row)
	table := new_clone(Type{name = name, kind = .Table, location = location, fields = columns, count = capacity, row = row})
	if !is_number do table.capacity_name = capacity_text
	append(&program.types, table)
	field := new_clone(Field{name = name, location = location, type = table})
	add_name(program, name, field, location)
	append(&program.fields, field)
}

// `name :: foreign "c_name" Input |proc| Output`, Output left out for void.
add_foreign :: proc(program: ^Program, name: string, header: string, location: Location) {
	rest := strings.trim_space(header[len("foreign "):])
	if !strings.has_prefix(rest, "\"") do fail(location, "foreign needs the C name in quotes")
	end := strings.index_byte(rest[1:], '"')
	if end < 1 do fail(location, "foreign needs the C name in quotes")
	procedure := new_clone(Procedure{name = name, foreign_name = rest[1:][:end]})
	input_text, separator, output_text := strings.partition(rest[end + 2:], "|proc|")
	if separator == "" do fail(location, "foreign is written: foreign \"c_name\" Input |proc| Output")
	procedure.parsed.location = location
	procedure.foreign_types[0], _ = parse_expression(strings.trim_space(input_text), location)
	if output := strings.trim_space(output_text); output != "" {
		procedure.foreign_types[1], _ = parse_expression(output, location)
	}
	add_name(program, name, procedure, location)
	append(&program.procedures, procedure)
}

add_match :: proc(program: ^Program, name: string, header: string, item: Item) {
	location := item.header.location
	opener := header[0] == '?' ? 1 : len(GATE_OPENER)
	if !strings.has_suffix(header, "?") do fail(location, "match subject missing its closing ?")
	match := new_clone(Match{name = name, location = location})
	match.subject, match.parsed = parse_expression(strings.trim_space(header[opener:len(header) - 1]), location)

	for entry in body_entries(item) {
		label, separator, rest := strings.partition(entry.text, ":")
		if separator == "" do fail(entry, "a match arm is `case : value` or `case : |pipe|`")
		arm := Arm{label = strings.trim_space(label), location = entry.location}
		rest = strings.trim_space(rest)
		if strings.has_prefix(rest, "|") || strings.has_prefix(rest, "?") || strings.has_prefix(rest, GATE_OPENER) {
			arm.parts = parse_line({entry.location, rest}).parts
			match.has_pipes = true
		} else {
			arm.value, arm.parsed = parse_expression(rest, entry)
		}
		append(&match.arms, arm)
	}
	if len(match.arms) == 0 do fail(location, "%s has no arms", name)
	for arm in match.arms {
		if (arm.value == nil) == match.has_pipes do continue
		fail(arm.location, "arms of %s must all be values or all be pipes", name)
	}
	add_name(program, name, match, location)
	append(&program.matches, match)
}

add_type :: proc(program: ^Program, type: ^Type) {
	add_name(program, type.name, type, type.location)
	append(&program.types, type)
}

// One Odin declaration: `a := 1`, `a : float = 1`, `a : float`, `a :: 1`, `A :: [3]float`.
add_declaration :: proc(program: ^Program, text: string, location: Location) {
	parsed := parse_odin(text, location)
	declaration, ok := parsed.statements[0].derived.(^ast.Value_Decl)
	if !ok || len(parsed.statements) != 1 || len(declaration.names) != 1 || len(declaration.values) > 1 {
		fail(location, "expected one declaration: %s", text)
	}
	name := declaration.names[0].derived.(^ast.Ident).name
	value := len(declaration.values) == 1 ? declaration.values[0] : nil

	if declaration.is_mutable {
		field := new_clone(Field{name = name, location = location, type_expression = declaration.type, initial = value, parsed = parsed})
		add_name(program, name, field, location)
		append(&program.fields, field)
		return
	}
	if _, is_array := value.derived.(^ast.Array_Type); is_array {
		add_type(program, new_clone(Type{name = name, kind = .Array, location = location, alias = value, alias_parsed = parsed}))
		return
	}
	definition := new_clone(Definition{name = name, expression = value, parsed = parsed})
	add_name(program, name, definition, location)
	append(&program.definitions, definition)
}
