#include <assert.h>
#include "program.h"

int main(void) {
	Coercion state;
	coercion_init(&state);
	assert(coercion(&state) == 0);
	assert(state.scaled == 6.0f);    // int into a float slot
	assert(state.halved == 1);       // float into an int field, narrowed by C
	assert(state.precise == 9.0);    // int * 1.5 is float, as in C
	return 0;
}
