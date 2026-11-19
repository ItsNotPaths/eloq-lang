#include <assert.h>
#include "program.h"

int main(void) {
	Value_Pipes state;
	value_pipes_init(&state);
	state.enemies.count = 1;
	state.enemies.position[0] = (Vector3){{3, 4, 0}};
	assert(value_pipes(&state) == 0);
	assert(state.distance == 5.0f);
	assert(state.later == 4.0f);   // a write to what its procs read makes the value stale

	state.target = 9;
	state.distance = 0;
	assert(value_pipes(&state) == 2);
	assert(state.abends.entries[0].code == VALUE_PIPES_ABCONT_BAD_INDEX && state.abends.entries[0].value == 9);
	assert(state.distance == 0.0f);   // the line skips
	return 0;
}
