package eloqc

import "core:strings"

Format_Kind :: enum {
	Plain, // pipe lines, values, structs: gates in the header only
	Match, // arms can hold gates
	Body, // a proc body: Odin, left as written
	Inline_C, // left as written below its first indentation
}

// `--format`: one tab per body line, and one gate opener, whichever of `?` and `¿` the
// file uses more, or `¿` with `--upside-down`.
format_file :: proc(path: string, upside_down: bool) {
	lines := file_lines(path)
	kinds := format_kinds(lines[:])
	opener := GATE_OPENER if upside_down || more_upside_down(lines[:], kinds[:]) else "?"
	texts: [dynamic]string
	for index := 0; index < len(lines); {
		if kinds[index] == .Inline_C && is_body_line(lines[index].text) {
			end := index
			for end < len(lines) && kinds[end] == .Inline_C && (is_body_line(lines[end].text) || strings.trim_space(lines[end].text) == "") do end += 1
			prefix := common_indentation(lines[index:end])
			for line in lines[index:end] do append(&texts, strings.concatenate({"\t", line.text[min(len(prefix), len(line.text)):]}) if strings.trim_space(line.text) != "" else "")
			index = end
			continue
		}
		text := lines[index].text
		if is_body_line(text) do text = strings.concatenate({"\t", strings.trim_left_space(text)})
		if kinds[index] == .Match || (kinds[index] == .Plain && !is_body_line(text)) {
			text = set_openers(text, opener)
		}
		append(&texts, text)
		index += 1
	}
	write_file(path, strings.join(texts[:], "\n"))
}

is_body_line :: proc(text: string) -> bool {
	return len(text) > 0 && (text[0] == ' ' || text[0] == '\t') && strings.trim_space(text) != ""
}

// What each line belongs to, by the header of its item.
format_kinds :: proc(lines: []Source_Line) -> [dynamic]Format_Kind {
	kinds: [dynamic]Format_Kind
	kind := Format_Kind.Plain
	for line in lines {
		text := strings.trim_space(strip_comment(line.text))
		if text != "" && !is_body_line(line.text) {
			_, separator, rest := strings.partition(text, "::")
			rest = strings.trim_space(rest)
			switch {
			case separator == "":
				kind = .Plain
			case strings.has_prefix(rest, "?"), strings.has_prefix(rest, GATE_OPENER):
				kind = .Match
			case strings.has_prefix(rest, "foreign ") && !strings.contains(rest, "\""):
				kind = .Inline_C
			case rest == "":
				kind = .Body
			case:
				kind = .Plain
			}
		}
		append(&kinds, kind)
	}
	return kinds
}

more_upside_down :: proc(lines: []Source_Line, kinds: []Format_Kind) -> bool {
	plain, upside_down := 0, 0
	for line, index in lines {
		if kinds[index] == .Body || kinds[index] == .Inline_C do continue
		for opener in gate_openers(line.text) {
			if opener == "?" do plain += 1
			else do upside_down += 1
		}
	}
	return upside_down > plain
}

// The opener of each gate, in order. A gate closes on the next `?`.
gate_openers :: proc(text: string) -> [dynamic]string {
	openers: [dynamic]string
	open := false
	for character in strip_comment(text) {
		switch {
		case character == '¿':
			append(&openers, GATE_OPENER)
			open = true
		case character == '?' && open:
			open = false
		case character == '?':
			append(&openers, "?")
			open = true
		}
	}
	return openers
}

set_openers :: proc(text: string, opener: string) -> string {
	code := strip_comment(text)
	builder := strings.builder_make()
	open := false
	for character in code {
		switch {
		case (character == '¿' || character == '?') && !open:
			strings.write_string(&builder, opener)
			open = true
		case character == '?' && open:
			strings.write_rune(&builder, character)
			open = false
		case:
			strings.write_rune(&builder, character)
		}
	}
	strings.write_string(&builder, text[len(code):])
	return strings.to_string(builder)
}

common_indentation :: proc(lines: []Source_Line) -> string {
	prefix: string
	found := false
	for line in lines {
		if strings.trim_space(line.text) == "" do continue
		indentation := line.text[:len(line.text) - len(strings.trim_left_space(line.text))]
		if !found {
			prefix, found = indentation, true
			continue
		}
		length := 0
		for length < len(prefix) && length < len(indentation) && prefix[length] == indentation[length] do length += 1
		prefix = prefix[:length]
	}
	return prefix
}
