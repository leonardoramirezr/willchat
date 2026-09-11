APP_NAME := WillChat
BUILD_DIR := build

build:
	bash build.sh

install: build
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(BUILD_DIR)/$(APP_NAME).app" /Applications/

.PHONY: build install