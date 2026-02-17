APP_NAME     := NeverDrop
VERSION      := $(shell grep 'MARKETING_VERSION' project.yml | head -1 | tr -d ' "' | cut -d: -f2)
BUILD_DIR    := build
ARCHIVE_PATH := $(BUILD_DIR)/$(APP_NAME).xcarchive
APP_PATH     := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH     := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGING  := $(BUILD_DIR)/dmg

.PHONY: all generate build dmg clean

all: dmg

# --- Generate Xcode project from project.yml ---
generate:
	xcodegen generate

# --- Build Release archive (unsigned, local use) ---
build: generate
	xcodebuild archive \
		-project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_ALLOWED=YES
	cp -R $(ARCHIVE_PATH)/Products/Applications/$(APP_NAME).app $(APP_PATH)

# --- Package .app into a DMG ---
dmg: build
	rm -rf $(DMG_STAGING) $(DMG_PATH)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_PATH) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_STAGING) \
		-ov -format UDZO \
		$(DMG_PATH)
	rm -rf $(DMG_STAGING)
	@echo "✅ DMG ready: $(DMG_PATH)"

# --- Remove all build artifacts ---
clean:
	rm -rf $(BUILD_DIR)
