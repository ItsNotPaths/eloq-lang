#include <assert.h>
#include "program.h"

int main(void) {
	Launch_Site state;
	launch_site_init(&state);
	float lifetimes[3] = {1, 5, 2};
	state.shells.count = 3;
	for (int row = 0; row < 3; row += 1) {
		state.shells.lifetime[row] = lifetimes[row];
		state.shells.position[row] = (Vector){{(float)row, 0, 0}};
		state.shells.velocity[row] = (Vector){{0, 0, 1}};
	}
	assert(launch_site(&state) == 0);
	assert(state.shells.count == 3);   // room counts the pending add, so the second fire is gated off
	// row 0 ran out and was swapped for the new shell, which no line saw this step
	assert(state.shells.lifetime[0] == 3.0f);
	assert(state.shells.velocity[0].y == 2.0f && state.shells.position[0].z == 0.0f);
	// columns run once per row
	assert(state.shells.lifetime[1] == 4.0f && state.shells.position[1].z == 1.0f);
	assert(state.shells.lifetime[2] == 1.0f && state.shells.position[2].x == 2.0f);

	state.shells.count = 4;
	for (int row = 0; row < 4; row += 1) state.shells.lifetime[row] = 10;
	assert(launch_site(&state) == 0);
	assert(state.shells.count == 4);   // a gate on room drops the add

	state.shells.count = 9;
	assert(launch_site(&state) == 1 && state.abends.entries[0].code == ELOQ_ABEND_BAD_COUNT);
	return 0;
}
