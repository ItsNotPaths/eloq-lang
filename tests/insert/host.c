#include <assert.h>
#include "program.h"

int main(void) {
	Inserted state;
	inserted_init(&state);
	assert(inserted(&state) == 0);
	assert(state.value == 6.0f);
	return 0;
}
