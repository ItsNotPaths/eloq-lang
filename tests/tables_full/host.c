#include <assert.h>
#include "program.h"

int main(void) {
	Forge state;
	forge_init(&state);
	assert(forge(&state) == FORGE_ABEND_TABLE_FULL);
	return 0;
}
