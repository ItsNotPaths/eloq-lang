#include <assert.h>
#include "program.h"

int main(void) {
	Pipes state;
	pipes_init(&state);
	assert(pipes(&state) == PIPES_OK);
	assert(state.fuel == 7.0f);
	assert(state.empty_tank == 0.0f);                    // a false gate stops the line
	assert(state.doubled == 8.0f);                       // names mid-chain are written
	assert(state.quadrupled == 16.0f);
	assert(state.position == 5.0f);                      // output starts as its destination
	assert(state.moved_twice == 8.0f);                   // an unnamed destination starts at zero
	assert(state.copy == 4.0f && state.total == 4.0f);   // no written slot passes the input on
	return 0;
}
