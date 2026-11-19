#include <assert.h>
#include "program.h"

int main(void) {
	Values state;
	values_init(&state);
	assert(values(&state) == 0);
	assert(state.height == 0.0f);
	assert(state.marker == 0);         // velocity not doubled yet
	assert(state.velocity == 16.0f);
	assert(state.counter == 1);        // on-demand value sees the line above
	assert(state.weight == 19.6f);
	assert(state.below_cap == 3);      // repeat stops when its gate fails
	assert(state.capped == 4);         // and at its bound
	assert(state.report_one == 8.0f);  // a proc reads a value
	assert(state.report_two == 16.0f); // a value read after a write in the same line
	return 0;
}
