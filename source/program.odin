package eloqc

import "core:odin/ast"
import "core:strings"

Type_Kind :: enum {
	Integer,
	Float,
	Boolean,
	Struct,
	Enum,
	Array,
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
}

Field :: struct {
	name:            string,
	location:        Location,
	type:            ^Type,
	type_expression: ^ast.Expr,
	initial:         ^ast.Expr,
	parsed:          Parsed,
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
	slots:  [dynamic]Slot,
	input:  ^Slot, // the read-only slot
	output: ^Slot, // the written slot
	touches_state: bool,
}

Name :: union {
	^Type,
	^Field,
	^Definition,
	^Procedure,
}

Program :: struct {
	state_name:     string,
	state_location: Location,
	names:          map[string]Name,
	types:          [dynamic]^Type, // declared by the program, in order
	fields:         [dynamic]^Field, // the state
	definitions:    [dynamic]^Definition,
	procedures:     [dynamic]^Procedure,
	lines:          [dynamic]Line,
}

untyped_integer := &Type{name = "untyped integer", kind = .Integer, untyped = true}
untyped_float := &Type{name = "untyped float", kind = .Float, untyped = true}

builtin_types: map[string]^Type

builtin_type :: proc(name: string) -> ^Type {
	return builtin_types[name]
}

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
		type := new_clone(Type{name = name, kind = .Struct, location = location})
		for entry in body_entries(item) {
			field_name, _, type_text := strings.partition(entry.text, ":")
			type_expression, parsed := parse_expression(strings.trim_space(type_text), entry)
			append(&type.fields, new_clone(Field{name = strings.trim_space(field_name), location = entry, type_expression = type_expression, parsed = parsed}))
		}
		add_type(program, type)
	case rest == "enum":
		type := new_clone(Type{name = name, kind = .Enum, location = location})
		for entry in body_entries(item) do append(&type.cases, entry.text)
		add_type(program, type)
	case strings.has_prefix(rest, "table"), strings.has_prefix(rest, "foreign"), strings.has_prefix(rest, "?"), strings.has_prefix(rest, GATE_OPENER):
		fail(location, "%s: not built yet", rest)
	case:
		add_declaration(program, item.header.text, location)
	}
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
