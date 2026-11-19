package eloqc

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Source_Line :: struct {
	using location: Location,
	text:           string,
}

// A top-level line and the indented lines under it.
Item :: struct {
	header: Source_Line, // comment and outer whitespace removed
	body:   [dynamic]Source_Line,
}

read_source :: proc(path: string) -> [dynamic]Source_Line {
	lines: [dynamic]Source_Line
	inserted: map[string]bool
	directory := path[:strings.last_index_byte(path, '/') + 1]
	for line in file_lines(path) {
		target, is_insert := insert_target(line.text)
		if !is_insert {
			append(&lines, line)
			continue
		}
		for inserted_path in insert_paths(strings.concatenate({directory, target}), target, line) {
			if inserted[inserted_path] do continue
			inserted[inserted_path] = true
			for inserted_line in file_lines(inserted_path) {
				if _, nested := insert_target(inserted_line.text); !nested {
					append(&lines, inserted_line)
				}
			}
		}
	}
	return lines
}

file_lines :: proc(path: string) -> [dynamic]Source_Line {
	source: string
	if strings.has_prefix(path, BAKED_DIRECTORY) {
		source, _ = baked_text(path[len(BAKED_DIRECTORY):])
	} else {
		data, error := os.read_entire_file(path, context.allocator)
		if error != nil {
			fmt.eprintfln("cannot read %s: %v", path, error)
			os.exit(1)
		}
		source = string(data)
	}
	lines: [dynamic]Source_Line
	for text, index in strings.split(source, "\n") {
		append(&lines, Source_Line{{path, index + 1}, strings.trim_right(text, "\r")})
	}
	return lines
}

insert_target :: proc(text: string) -> (target: string, is_insert: bool) {
	if !strings.has_prefix(text, "insert ") do return
	return strings.trim_space(strip_comment(text[len("insert "):])), true
}

// Files built into the compiler, inserted when no local file has the name.
BAKED_FILES := [?]struct {
	name: string,
	text: string,
} {
	{"math.eloq", #load("../library/math.eloq", string)},
}
BAKED_DIRECTORY :: "eloqc/"

baked_text :: proc(name: string) -> (text: string, found: bool) {
	for file in BAKED_FILES {
		if file.name == name || file.name == strings.concatenate({name, ".eloq"}) do return file.text, true
	}
	return "", false
}

// A folder inserts every eloq file in it.
insert_paths :: proc(path: string, target: string, line: Source_Line) -> []string {
	if !os.is_directory(path) {
		if os.exists(path) do return slice.clone([]string{path})
		if _, found := baked_text(target); found do return slice.clone([]string{strings.concatenate({BAKED_DIRECTORY, target})})
		fail(line, "insert: %s not found", path)
	}
	entries, error := os.read_directory_by_path(path, -1, context.allocator)
	if error != nil do fail(line, "insert: cannot read %s", path)
	paths: [dynamic]string
	for entry in entries {
		if strings.has_suffix(entry.name, ".eloq") || strings.has_suffix(entry.name, ".¿") {
			append(&paths, entry.fullpath)
		}
	}
	slice.sort(paths[:])
	return paths[:]
}

strip_comment :: proc(text: string) -> string {
	if comment := strings.index(text, "//"); comment >= 0 {
		return text[:comment]
	}
	return text
}

group_items :: proc(lines: []Source_Line) -> [dynamic]Item {
	items: [dynamic]Item
	for line in lines {
		text := strings.trim_space(strip_comment(line.text))
		indented := len(line.text) > 0 && (line.text[0] == ' ' || line.text[0] == '\t')
		switch {
		case text == "":
			if len(items) > 0 do append(&items[len(items) - 1].body, line)
		case indented:
			if len(items) == 0 do fail(line, "indented line with nothing above it")
			append(&items[len(items) - 1].body, line)
		case:
			append(&items, Item{header = {line.location, text}})
		}
	}
	return items
}

// Body lines that hold something, comments and whitespace removed.
body_entries :: proc(item: Item) -> [dynamic]Source_Line {
	entries: [dynamic]Source_Line
	for line in item.body {
		text := strings.trim_space(strip_comment(line.text))
		if text != "" do append(&entries, Source_Line{line.location, text})
	}
	return entries
}

body_text :: proc(item: Item) -> (text: string, location: Location) {
	if len(item.body) == 0 do fail(item.header, "%s has an empty body", item.header.text)
	texts: [dynamic]string
	for line in item.body do append(&texts, line.text)
	return strings.join(texts[:], "\n"), item.body[0].location
}
