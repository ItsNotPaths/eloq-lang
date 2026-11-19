#include <assert.h>
#include "program.h"

int main(void) {
	Data_Types state;
	data_types_init(&state);
	assert(state.ticks == 5);
	assert(state.spawn.y == 2.0f && state.spawn.elements[1] == 2.0f);   // both names reach an element
	state.hero.health = 100;
	assert(data_types(&state) == DATA_TYPES_OK);
	assert(state.fuel_state == FUEL_STATE_LOW);
	assert(state.hero.health == 90.0f);
	assert(state.hero.position.y == 1.0f);
	return 0;
}
