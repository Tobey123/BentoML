.DEFAULT_GOAL := help

GIT_ROOT ?= $(shell git rev-parse --show-toplevel)

CHECKER_IMG ?= bentoml/checker:1.0
BASE_ARGS := -i --rm -u $(shell id -u):$(shell id -g) -v $(GIT_ROOT):/bentoml
GPU_ARGS := --device /dev/nvidia0 --device /dev/nvidiactl --device /dev/nvidia-modeset --device /dev/nvidia-uvm --device /dev/nvidia-uvm-tools
GPU ?=false
USE_POETRY ?=false

ifeq ($(GPU),true)
CNTR_ARGS := $(BASE_ARGS) $(GPU_ARGS) $(CHECKER_IMG)
else
CNTR_ARGS := $(BASE_ARGS) $(CHECKER_IMG)
endif

CMD := docker run $(CNTR_ARGS)
TTY := docker run -t $(CNTR_ARGS)

check_defined = \
    $(strip $(foreach 1,$1, \
        $(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
    $(if $(value $1),, \
        $(error Undefined $1$(if $2, ($2))$(if $(value @), \
                required by target `$@`)))

__style_src := $(wildcard $(GIT_ROOT)/scripts/ci/style/*.sh)
__style_name := ${__style_src:_check.sh=}
tools := $(foreach t, $(__style_name), ci-$(shell basename $(t)))

check-defined-% : __check_defined_FORCE
	$(eval $@_target := $(subst check-defined-, ,$@))
	@:$(call check_defined, $*, $@_target)

.PHONY : __check_defined_FORCE
__check_defined_FORCE:

help: ## Show all Makefile targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[33m%-30s\033[0m %s\n", $$1, $$2}'

build-checker-img: check-defined-GIT_ROOT check-defined-CHECKER_IMG ## Build checker images
	@if [[ `git diff $(GIT_ROOT)/scripts/Dockerfile-checker` != "" ]]; then \
		docker build -f ./scripts/Dockerfile-checker -t $(CHECKER_IMG) . ;\
		docker push $(CHECKER_IMG); \
	fi

pull-checker-img: ## Pull checker images
	@if [[ `docker images --filter=reference='bentoml/checker' -q` == "" ]]; then \
		echo "Pulling bentoml/checker:1.0..."; \
	    docker pull bentoml/checker:1.0; \
	fi \

chore: build-checker-img pull-checker-img ## Chore work

format: pull-checker-img ## Running code formatter: black and isort
	$(CMD) ./scripts/tools/formatter.sh
lint: pull-checker-img ## Running lint checker: flake8 and pylint
	$(CMD) ./scripts/tools/linter.sh
type: pull-checker-img ## Running type checker: mypy and pyright
	$(CMD) ./scripts/tools/type_checker.sh

ci-all: $(tools) ## Running codestyle in CI: black, isort, flake8, pylint, mypy, pyright

ci-%: chore
	$(eval style := $(subst ci-, ,$@))
	$(eval SHELL :=/bin/bash)
	$(CMD) ./scripts/ci/style/$(style)_check.sh

.PHONY: ci-format
ci-format: ci-black ci-isort ## Running format check in CI: black, isort

.PHONY: ci-lint
ci-lint: ci-flake8 ci-pylint ## Running lint check in CI: flake8, pylint

.PHONY: ci-type
ci-type: ci-mypy ci-pyright ## Running type check in CI: mypy, pyright

tests-%:
	$(eval type :=$(subst tests-, , $@))
	$(eval RUN_ARGS:=$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS)))
	$(eval __positional:=$(foreach t, $(RUN_ARGS), --$(t)))
	$(eval SHELL :=/bin/bash)
	./scripts/ci/run_tests.sh -v $(type) $(__positional)


ifeq ($(USE_POETRY),true)
install-local: ## Install BentoML with poetry
	@./scripts/init.sh
install-dev-deps: ## Install BentoML with tests dependencies via poetry
	poetry install -vv -E "model-server types docs"
install-docs-deps: install-dev-deps ## Install BentoML with docs dependencies via poetry
else
install-local: ## Install BentoML in editable mode
	@pip install --editable .
install-dev-deps: ## Install all dev and tests dependencies
	@echo Ensuring dev dependencies...
	@pip install -e ".[dev]"
install-docs-deps: ## Install documentation dependencies
	@echo Installing docs dependencies...
	@pip install -e ".[doc_builder]"
endif

# Docs
watch-docs: install-docs-deps ## Build and watch documentation
	@./scripts/watch_docs.sh || (echo "Error building... You may need to run 'make install-watch-deps'"; exit 1)
spellcheck-docs: ## Spell check documentation
	@if [[ `command -v poetry >/dev/null 2>&1` ]]; then \
		poetry run sphinx-build -b spelling ./docs/source ./docs/build || (echo "Error running spellchecker.. You may need to run 'make install-spellchecker-deps'"; exit 1); \
	else \
		sphinx-build -b spelling ./docs/source ./docs/build || (echo "Error running spellchecker.. You may need to run 'make install-spellchecker-deps'"; exit 1); \
	fi

OS := $(shell uname)
ifeq ($(OS),Darwin)
install-watch-deps: ## Install MacOS dependencies for watching docs
	brew install fswatch
install-spellchecker-deps: ## Install MacOS dependencies for spellchecker
	brew install enchant
	pip install sphinxcontrib-spelling
else ifneq ("$(wildcard $(/etc/debian_version))","")
install-watch-deps: ## Install Debian-based OS dependencies for watching docs
	sudo apt install inotify-tools
install-spellchecker-deps: ## Install Debian-based dependencies for spellchecker
	sudo apt install libenchant-dev
else
install-watch-deps: ## Inform users to install inotify-tools depending on their distros
	@echo Make sure to install inotify-tools from your distros package manager
	@exit 1
install-spellchecker-deps: ## Inform users to install enchant depending on their distros
	@echo Make sure to install enchant from your distros package manager
	@exit 1
endif

hooks: ## Install pre-defined hooks
	@./scripts/install_hooks.sh
