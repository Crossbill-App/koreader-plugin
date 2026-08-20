# Crossbill KOReader plugin
#
# Device installs read KOREADER_PLUGINS_PATH from .env (see .env.example).
# Lint/format require luacheck and stylua; run `make tools` for install hints.

LUA_SOURCES := crossbill.koplugin patches
COPY_SCRIPT := scripts/copy_to_pocketbook.sh

.DEFAULT_GOAL := help

.PHONY: help install install-test install-all lint format format-check check tools

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

lint: ## Run luacheck over the plugin sources
	@command -v luacheck >/dev/null || { \
		echo "luacheck not found. Install it with: luarocks install luacheck"; exit 1; }
	@luacheck $(LUA_SOURCES)

format: ## Format the plugin sources with stylua
	@command -v stylua >/dev/null || { \
		echo "stylua not found. See https://github.com/JohnnyMorganz/StyLua#installation"; exit 1; }
	@stylua $(LUA_SOURCES)

format-check: ## Check formatting without writing changes
	@command -v stylua >/dev/null || { \
		echo "stylua not found. See https://github.com/JohnnyMorganz/StyLua#installation"; exit 1; }
	@stylua --check $(LUA_SOURCES)

check: lint format-check ## Run lint and the formatting check

tools: ## Print how to install the lint/format tools
	@echo "luacheck: luarocks install luacheck"
	@echo "stylua:   cargo install stylua   (or: npm install -g @johnnymorganz/stylua-bin)"
