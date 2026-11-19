#include <assert.h>
#include <math.h>
#include "program.h"

static int last_sound;
void play_sound(int sound) { last_sound = sound; }

static int gauge_reading = FUEL_STATE_LOW;
Fuel_State read_gauge(int gauge) { return gauge_reading + gauge - 1; }

void sort_crates(Crates_Table *crates) {
	for (int row = 1; row < crates->count; row += 1) {
		for (int other = row; other > 0 && crates->weight[other - 1] > crates->weight[other]; other -= 1) {
			float weight = crates->weight[other];
			crates->weight[other] = crates->weight[other - 1];
			crates->weight[other - 1] = weight;
		}
	}
}

int main(void) {
	Foreign_Calls state;
	foreign_calls_init(&state);
	state.crates.count = 3;
	state.crates.weight[0] = 3;
	state.crates.weight[1] = 1;
	state.crates.weight[2] = 2;
	assert(foreign_calls(&state) == 0);
	assert(state.side == 4.0f);
	assert(state.angle == atan2f(1, 0));   // struct fields become arguments in order
	assert(last_sound == 3);
	assert(state.played == 3);             // void gives back its input
	assert(state.fuel_state == FUEL_STATE_LOW);
	// the whole table goes to C once; later lines see its new order
	assert(state.crates.weight[0] == 2.0f && state.crates.weight[1] == 4.0f && state.crates.weight[2] == 6.0f);

	gauge_reading = 9;
	assert(foreign_calls(&state) == 1 && state.abends.entries[0].code == ELOQ_ABEND_BAD_CASE);   // a bad enum from C
	return 0;
}
