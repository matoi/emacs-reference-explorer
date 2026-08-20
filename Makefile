EMACS ?= emacs
LISP_FILES := $(wildcard *.el)
CHECK_LISP_FILES := $(filter-out reference-explorer-ui-migemo.el,$(LISP_FILES))
TEST_FILES := $(wildcard test/*-test.el)

.PHONY: test check

test:
	$(EMACS) --batch -Q -L . -L test \
	  $(foreach file,$(TEST_FILES),-l $(file)) \
	  -f ert-run-tests-batch-and-exit

check:
	$(EMACS) --batch -Q -L . $(foreach file,$(CHECK_LISP_FILES),-l $(file))
