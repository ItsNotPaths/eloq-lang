package eloqc

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strconv"
import "core:strings"

// Eloq bodies and expressions are Odin, parsed inside this wrapper.
WRAPPER :: "package eloq\nbody :: proc() {\n"
WRAPPER_LINES :: 2

// Stands for the flowing value in a gate that starts with an operator.
FLOW_NAME :: "_flow"

Parsed :: struct {
	statements:   []^ast.Stmt,
	location:     Location, // where the text starts
	slot_offsets: map[int]bool, // offsets of identifiers marked with `$`
}

parse_location: Location

parse_odin :: proc(text: string, location: Location) -> Parsed {
	parsed := Parsed{location = location}
	source := transmute([]u8)strings.concatenate({WRAPPER, text, "\n}\n"})
	// Same-length rewrites, so offsets and columns hold.
	for index in 0 ..< len(source) {
		switch {
		case source[index] == '$':
			source[index] = ' '
			parsed.slot_offsets[index + 1] = true
		case is_word_at(source, index, "not"):
			copy(source[index:], "!  ")
		}
	}

	parse_location = location
	file := ast.File{src = string(source), fullpath = location.path}
	odin_parser := parser.default_parser()
	odin_parser.err = parse_error
	if !parser.parse_file(&odin_parser, &file) || file.syntax_error_count > 0 {
		os.exit(1)
	}
	procedure := file.decls[0].derived.(^ast.Value_Decl).values[0].derived.(^ast.Proc_Lit)
	parsed.statements = procedure.body.derived.(^ast.Block_Stmt).stmts
	return parsed
}

parse_error :: proc(position: tokenizer.Pos, message: string, args: ..any) {
	fmt.eprintf("%s:%d: ", parse_location.path, parse_location.line + position.line - WRAPPER_LINES - 1)
	fmt.eprintfln(message, ..args)
}

parse_expression :: proc(text: string, location: Location) -> (^ast.Expr, Parsed) {
	parsed := parse_odin(text, location)
	if len(parsed.statements) == 1 {
		if statement, ok := parsed.statements[0].derived.(^ast.Expr_Stmt); ok {
			return statement.expr, parsed
		}
	}
	fail(location, "expected an expression: %s", text)
}

is_word_at :: proc(source: []u8, index: int, word: string) -> bool {
	end := index + len(word)
	if end > len(source) || string(source[index:end]) != word do return false
	before_ok := index == 0 || !is_name_character(source[index - 1])
	after_ok := end == len(source) || !is_name_character(source[end])
	return before_ok && after_ok
}

is_name_character :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

Part_Kind :: enum {
	Data,
	Procedure,
	Gate,
}

Part :: struct {
	kind:       Part_Kind,
	name:       string, // Procedure
	expression: ^ast.Expr, // Data, Gate
	parsed:     Parsed,
	appends:    bool, // Data: a table that gets a new row
}

Line :: struct {
	location:     Location,
	repeat_count: int, // 0 runs once
	row_table:    ^Type, // runs once per row of this table
	parts:        [dynamic]Part,
}

GATE_OPENER :: "¿"

parse_line :: proc(source: Source_Line) -> Line {
	line := Line{location = source.location}
	text := source.text
	if strings.has_prefix(text, "repeat ") {
		count_text, _, rest := strings.partition(strings.trim_space(text[len("repeat "):]), " ")
		count, ok := strconv.parse_int(count_text, 10)
		if !ok || count < 1 do fail(source, "repeat needs a positive count, got %s", count_text)
		line.repeat_count = count
		text = rest
	}

	position := 0
	for position < len(text) {
		rest := text[position:]
		switch {
		case rest[0] == ' ' || rest[0] == '\t':
			position += 1
		case rest[0] == '|':
			end := strings.index_byte(rest[1:], '|')
			if end < 0 do fail(source, "proc name missing its closing |")
			append(&line.parts, Part{kind = .Procedure, name = strings.trim_space(rest[1:][:end])})
			position += end + 2
		case rest[0] == '?' || strings.has_prefix(rest, GATE_OPENER):
			opener := rest[0] == '?' ? 1 : len(GATE_OPENER)
			end := strings.index_byte(rest[opener:], '?')
			if end < 0 do fail(source, "gate missing its closing ?")
			gate_text := strings.trim_space(rest[opener:][:end])
			if starts_with_comparison(gate_text) {
				gate_text = strings.concatenate({FLOW_NAME, " ", gate_text})
			}
			expression, parsed := parse_expression(gate_text, source)
			append(&line.parts, Part{kind = .Gate, expression = expression, parsed = parsed})
			position += opener + end + 1
		case:
			end := len(rest)
			for stop in ([]string{" ", "\t", "|", "?", GATE_OPENER}) {
				if found := strings.index(rest, stop); found >= 0 do end = min(end, found)
			}
			expression, parsed := parse_expression(rest[:end], source)
			append(&line.parts, Part{kind = .Data, expression = expression, parsed = parsed})
			position += end
		}
	}
	return line
}

starts_with_comparison :: proc(text: string) -> bool {
	for operator in ([]string{"==", "!=", "<", ">"}) {
		if strings.has_prefix(text, operator) do return true
	}
	return false
}
