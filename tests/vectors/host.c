#include <assert.h>
#include "program.h"

int main(void) {
	Vectors state;
	vectors_init(&state);
	assert(vectors(&state) == 0);
	assert(state.velocity.x == 1.0f && state.velocity.y == -5.0f);
	assert(state.position.x == 0.5f && state.position.y == 7.5f);
	assert(state.scaled.x == 0.5f && state.scaled.z == 1.5f);
	return 0;
}
