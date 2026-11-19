#include <assert.h>
#include "program.h"

int main(void) {
	Inline_C state;
	inline_c_init(&state);
	state.crates.count = 2;
	state.crates.weight[0] = 1;
	state.crates.weight[1] = 5;
	assert(inline_c(&state) == 0);
	assert(state.flat_unit.x == 0.6f && state.flat_unit.y == 0.8f);   // the flow picks the C
	assert(state.deep_unit.z == 1.0f);
	assert(state.crates.weight[0] == 2.0f && state.crates.weight[1] == 10.0f);   // the whole table, once
	return 0;
}
