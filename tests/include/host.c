#include <assert.h>
#include "program.h"

int main(void) {
	Included state;
	included_init(&state);
	assert(included(&state) == 0);
	assert(state.value == 6.0f);
	return 0;
}
