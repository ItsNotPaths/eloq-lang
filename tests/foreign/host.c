#include <assert.h>
#include <math.h>
#include "program.h"

static int last_sound;
void play_sound(int sound) { last_sound = sound; }

static int gauge_reading = FUEL_STATE_LOW;
Fuel_State read_gauge(int gauge) { return gauge_reading + gauge - 1; }

int main(void) {
	Foreign_Calls state;
	foreign_calls_init(&state);
	assert(foreign_calls(&state) == 0);
	assert(state.side == 4.0f);
	assert(state.angle == atan2f(1, 0));   // struct fields become arguments in order
	assert(last_sound == 3);
	assert(state.played == 3);             // void gives back its input
	assert(state.fuel_state == FUEL_STATE_LOW);

	gauge_reading = 9;
	assert(foreign_calls(&state) == 1 && state.abends.entries[0].code == FOREIGN_CALLS_ABEND_BAD_CASE);   // a bad enum from C
	return 0;
}
