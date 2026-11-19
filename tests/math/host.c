#include <assert.h>
#include <math.h>
#include "program.h"

int main(void) {
	Math_Use state;
	math_use_init(&state);
	assert(math_use(&state) == MATH_USE_OK);
	assert(state.speed == 5.0f);                        // built-in math.eloq
	assert(state.unit.x == 0.6f && state.unit.y == 0.8f);
	assert(state.angle == atan2f(4, 3));                // C math in a body
	assert(state.rounded.x == 1 && state.rounded.y == 3 && state.rounded.z == 0);   // per element
	assert(state.circle == 6.28318530717958647692f);
	return 0;
}
