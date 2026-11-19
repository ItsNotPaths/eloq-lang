#include <assert.h>
#include <string.h>
#include "program.h"

int count_letters(String text) { return text.len; }

int main(void) {
	Strings state;
	strings_init(&state);
	state.name = (String){"cannon", 6};
	state.expected = (String){"cannon ball", 6};   // the host owns the text; length is what counts
	memcpy(state.tag.elements, "shell", 5);
	memcpy(state.other_tag.elements, "shell", 5);
	assert(strings(&state) == 0);
	assert(state.same_name && state.same_tag);
	assert(state.letters == 6);

	state.expected = (String){"canyon", 6};
	state.other_tag.elements[0] = 'S';
	assert(strings(&state) == 0);
	assert(!state.same_name && !state.same_tag);

	state.expected = (String){"cannon", 5};
	assert(strings(&state) == 0 && !state.same_name);
	return 0;
}
