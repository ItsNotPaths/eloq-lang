#include <assert.h>
#include "program.h"

Fuel_State read_gauge(int gauge) { return gauge; }

int main(void) {
	Abend_Pending state;
	abend_pending_init(&state);
	state.shells.count = 2;
	state.shells.lifetime[1] = 5;
	state.gauge = 9;
	assert(abend_pending(&state) == 2);
	// codes in the order they happen
	assert(state.abends.entries[0].code == ABEND_PENDING_ABCONT_TABLE_FULL);
	Abend_Pending_Abend_Entry abend = state.abends.entries[1];
	assert(abend.code == ABEND_PENDING_ABEND_BAD_CASE && abend.line == 25 && abend.row == -1 && abend.value == 9);
	assert(state.shells.count == 2 && state.shells.removed[0] == 0);   // pending removes and adds are dropped
	assert(state.sparks.count == 0);

	state.gauge = FUEL_STATE_EMPTY;
	assert(abend_pending(&state) == 1);
	assert(state.shells.count == 1 && state.shells.lifetime[0] == 5.0f);

	// the host can make an abcont stop the step like an abend
	state.abends.stop_on_abcont = true;
	state.shells.lifetime[0] = 0;
	state.sparks.count = 0;
	state.gauge = FUEL_STATE_FULL;
	assert(abend_pending(&state) == 1 && state.abends.entries[0].code == ABEND_PENDING_ABCONT_TABLE_FULL);
	assert(state.shells.count == 1 && state.sparks.count == 0);   // pending removes and adds are dropped
	assert(state.fuel_state == FUEL_STATE_EMPTY);                  // the later line never ran
	assert(state.abends.stop_on_abcont);                           // not reset by the step
	return 0;
}
