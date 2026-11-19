# ¿eloq?

[eloq.paths.place](https://eloq.paths.place).

A small, bad idea for data logic, written as pipes. It compiles to C11 that a
C host embeds. 

1) fill a state struct
2) call a step function
3) read the struct

```
fuel     ?> 0? |burn_fuel| fuel
velocity |move| position ?grounded? |snap_to_floor| position
```

A line starts with the value going in and ends with the name the result is written to.
`|move|` runs a proc, and `?grounded?` stops the line unless `grounded` is true.

Examples, the generated C and a walkthrough are on the site.

## Build

```
git clone https://github.com/ItsNotPaths/eloq-lang
cd eloq-lang
./download-deps.sh
./build.sh
tests/run.sh
```

`build.sh` leaves `eloqc` in the repo folder.

## Use

```
eloqc launch_site.eloq -out:launch_site
cc -std=c11 -O2 host.c launch_site.c -lm -o cannon
```

`eloqc` writes `launch_site.c` and `launch_site.h`, plus `eloq.h`, which every program's header
includes. Your `host.c` includes the header, calls `launch_site_init(&state)`, then
`launch_site(&state)` each step. With `ELOQ_STDIO` defined,
`eloq_print_abends(&state.abends, stderr)` prints the step's codes.

`eloqc --format file.eloq` tidies a file in place. `eloqc --report` prints every report
on stdout: coercions, what each line reads and writes, and index writes whose result
depends on row order. It also turns on `--log-intermediates`, which makes the compiled step
print each named value as it runs.
