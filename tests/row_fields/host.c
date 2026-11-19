#include <assert.h>
#include "program.h"

int main(void) {
	Row_Fields state;
	row_fields_init(&state);
	state.crates.count = 3;
	for (int row = 0; row < 3; row += 1) state.crates.weight[row] = (float)(row + 1);
	assert(row_fields(&state) == 0);
	// a field the line writes is read fresh on every row, not copied before the loop
	assert(state.crates.seen[0] == 2.0f && state.crates.seen[1] == 6.0f && state.crates.seen[2] == 12.0f);
	return 0;
}
