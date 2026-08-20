# Crossbill KOReader plugin
#
# Device installs read KOREADER_PLUGINS_PATH from .env (see .env.example).
# Lint/format/test require luacheck, stylua and busted; run `make tools` for
# install hints.

LUA_SOURCES := crossbill.koplugin patches spec
COPY_SCRIPT := scripts/copy_to_pocketbook.sh

.DEFAULT_GOAL := help

.PHONY: help install install-test install-all lint format format-check test check tools

help: ## Show this help
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Copy the production plugin to the device
	@$(COPY_SCRIPT) production

install-test: ## Copy the test plugin to the device
	@$(COPY_SCRIPT) test

install-all: ## Copy both the production and test plugins to the device
	@$(COPY_SCRIPT) all

lint: ## Run luacheck over the plugin and spec sources
	@command -v luacheck >/dev/null || { \
		echo "luacheck not found. Install it with: luarocks install luacheck"; exit 1; }
	@luacheck $(LUA_SOURCES)

format: ## Format the plugin and spec sources with stylua
	@command -v stylua >/dev/null || { \
		echo "stylua not found. See https://github.com/JohnnyMorganz/StyLua#installation"; exit 1; }
	@stylua $(LUA_SOURCES)

format-check: ## Check formatting without writing changes
	@command -v stylua >/dev/null || { \
		echo "stylua not found. See https://github.com/JohnnyMorganz/StyLua#installation"; exit 1; }
	@stylua --check $(LUA_SOURCES)

test: ## Run the busted unit tests in spec/
	@command -v busted >/dev/null || { \
		echo "busted not found. Install it with: luarocks --lua-version=5.1 install busted"; exit 1; }
	@busted

check: lint format-check test ## Run lint, the formatting check and the tests

tools: ## Print how to install the lint/format/test tools
	@echo "luacheck: luarocks install luacheck"
	@echo "stylua:   cargo install stylua   (or: npm install -g @johnnymorganz/stylua-bin)"
	@echo "busted:   luarocks --lua-version=5.1 install busted"
