#include <assert.h>
#include "program.h"

int main(void) {
	Indexes state;
	indexes_init(&state);
	state.enemies.count = 2;
	state.enemies.position[1] = (Vector){{1, 2, 3}};
	state.enemies.health[0] = 10;
	state.enemies.health[1] = 20;
	int targets[3] = {1, 5, 0};
	float damages[3] = {1, 2, 4};
	state.missiles.count = 3;
	for (int row = 0; row < 3; row += 1) {
		state.missiles.target[row] = targets[row];
		state.missiles.damage[row] = damages[row];
	}
	state.target = 1;
	state.slot = 2;

	assert(indexes(&state) == 1);
	Indexes_Abend_Entry entry = state.abends.entries[0];
	assert(entry.code == INDEXES_ABCONT_BAD_INDEX && entry.value == 5 && entry.line == 22 && entry.row == 1);
	assert(state.aim.y == 2.0f);                                            // read by index in a line
	assert(state.enemies.health[0] == 6.0f && state.enemies.health[1] == 19.0f);   // the bad row is skipped
	assert(state.first_health == 6.0f);   // a write by index makes values that read the column stale
	assert(state.picked == 3.0f);         // a fixed array by index

	state.target = 7;
	state.slot = 3;
	state.aim = (Vector){{0, 0, 0}};
	assert(indexes(&state) == 3);
	// in the order they happen; the step finishes
	assert(state.abends.entries[0].value == 7 && state.abends.entries[0].line == 30);
	assert(state.abends.entries[1].value == 5);
	assert(state.abends.entries[2].value == 3 && state.abends.entries[2].line == 33);
	assert(state.aim.y == 0.0f && state.enemies.health[0] == 2.0f && state.picked == 3.0f);
	return 0;
}
