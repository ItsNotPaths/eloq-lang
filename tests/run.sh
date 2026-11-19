#!/usr/bin/env bash
# Each tests/<case>/ holds program.eloq and one of: host.c, which runs the step and
# asserts on the state; expect-error, text that eloqc's error must contain; or
# expect-output, lines that stdout must hold: the run's with host.c, else eloqc's.
# An optional flags file holds extra eloqc arguments.
set -uo pipefail
cd "$(dirname "$0")/.."
./build.sh || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
for case in tests/*/; do
	case=${case%/}
	name=$(basename "$case")
	mkdir -p "$work/$name"
	if [[ -f $case/expect-error ]]; then
		if ./eloqc "$case/program.eloq" -out:"$work/$name/program" 2>"$work/$name/error"; then
			echo "FAIL $name: compiled, expected an error"; failed=1
		elif ! grep -qF -- "$(cat "$case/expect-error")" "$work/$name/error"; then
			echo "FAIL $name: wrong error: $(cat "$work/$name/error")"; failed=1
		else
			echo "ok   $name"
		fi
		continue
	fi
	flags=$(cat "$case/flags" 2>/dev/null)
	if [[ -f $case/expect-output && ! -f $case/host.c ]]; then
		./eloqc $flags "$case/program.eloq" -out:"$work/$name/program" >"$work/$name/output" || { echo "FAIL $name"; failed=1; continue; }
		missing=$(grep -vxF -f "$work/$name/output" "$case/expect-output")
		if [[ -n $missing ]]; then
			echo "FAIL $name: missing: $missing"; failed=1
		else
			echo "ok   $name"
		fi
		continue
	fi
	if ./eloqc $flags "$case/program.eloq" -out:"$work/$name/program" \
		&& ${CC:-cc} -std=c11 -pedantic -Wall -Wextra -Werror -I"$work/$name" "$case/host.c" "$work/$name/program.c" -lm -o "$work/$name/run" \
		&& "$work/$name/run" >"$work/$name/output"; then
		if [[ -f $case/expect-output ]] && missing=$(grep -vxF -f "$work/$name/output" "$case/expect-output"); then
			echo "FAIL $name: missing: $missing"; failed=1
		else
			echo "ok   $name"
		fi
	else
		echo "FAIL $name"; failed=1
	fi
done
exit $failed
