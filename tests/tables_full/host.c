#include <assert.h>
#include "program.h"

int main(void) {
	Forge state;
	forge_init(&state);
	state.embers.count = 20;
	assert(forge(&state) == 19);
	assert(state.sparks.count == 1);   // adds past capacity are dropped
	assert(state.bellows == 1.0f);     // and the step finishes
	Forge_Abend_Entry first = state.abends.entries[0];
	assert(first.code == FORGE_ABCONT_TABLE_FULL && first.line == 17 && first.row == 1);
	assert(state.abends.entries[15].row == 16);
	assert(state.abends.count == 16 && state.abends.dropped == 3);

	state.embers.count = 0;
	assert(forge(&state) == 0 && state.abends.count == 0);   // reset each step
	return 0;
}
