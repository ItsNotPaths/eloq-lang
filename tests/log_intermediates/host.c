#include <assert.h>
#include "program.h"

int main(void) {
	Logged state;
	logged_init(&state);
	state.crates.count = 2;
	state.crates.weight[0] = 1;
	state.crates.weight[1] = 3;
	assert(logged(&state) == 0);
	return 0;
}
