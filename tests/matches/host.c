#include <assert.h>
#include "program.h"

int main(void) {
	Matches state;
	matches_init(&state);
	assert(matches(&state) == 0);
	assert(state.thrust_now == 40.0f);   // value match
	assert(state.flag_word == 1);
	assert(state.braked == 0.0f);        // a gate in an arm stops the line
	assert(state.moved == 10.0f);        // an arm's last proc starts from the line's destination

	matches_init(&state);
	state.fuel_state = 7;
	assert(matches(&state) == 1 && state.abends.entries[0].code == MATCHES_ABEND_BAD_CASE);
	assert(state.thrust_now == 0.0f);    // nothing ran
	return 0;
}
