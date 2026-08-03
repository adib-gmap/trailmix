APP_NAME   := Trailmix
EXECUTABLE := trailmix
BUNDLE_ID  := io.github.stephenturner.trailmix
CONFIG     := release

BUILD_DIR := .build/$(CONFIG)
DIST      := dist
APP       := $(DIST)/$(APP_NAME).app
CONTENTS  := $(APP)/Contents
ICONSET   := $(DIST)/AppIcon.iconset
ICNS      := $(DIST)/AppIcon.icns

# Where `make install` puts the app.
#
# ~/Applications, not /Applications, because /Applications is root:admin and
# only writable by admin accounts. ~/Applications works for every account, is
# indexed by Spotlight and Launchpad exactly the same way, and SMAppService is
# happy to register a login item from there. Admins who want it system-wide:
#
#     make install INSTALL_DIR=/Applications
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

# Code-signing identity.
#
# TCC keys the Screen Recording and Microphone grants to the signing
# certificate, so signing with a stable identity means those grants survive a
# rebuild. Without one we fall back to ad-hoc ("-"), where TCC keys on the
# binary's hash instead and every single rebuild re-prompts for permissions.
#
# Create the certificate once: Keychain Access > Certificate Assistant >
# Create a Certificate; name it "Trailmix", Identity Type "Self Signed Root",
# Certificate Type "Code Signing".
#
# Both the check below and codesign match SIGN_ID as a substring of the
# certificate's name, so keep exactly one "Trailmix" identity in the keychain.
# A second one still passes the grep but makes codesign bail out with
# "ambiguous (matches too many identities)".
#
# The check below deliberately omits `security find-identity -v`. A self-signed
# root is untrusted (CSSMERR_TP_NOT_TRUSTED) unless someone marks it trusted in
# Keychain Access, and -v means "valid identities only", so -v reports zero and
# the build silently falls back to ad-hoc. codesign signs with an untrusted
# identity happily; trust only matters to whoever verifies the result, which for
# a locally built app is nobody.
SIGN_ID ?= Trailmix

# Marketing version lives in App/Info.plist. The build number is the commit
# count: numeric and monotonic, which is what CFBundleVersion is specified to
# be, unlike a short SHA.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

.PHONY: all app build icon install uninstall run doctor clean

all: app

build:
	swift build -c $(CONFIG)

icon: $(ICNS)

$(ICNS): Scripts/make-icon.swift
	@mkdir -p $(DIST)
	swift Scripts/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@rm -rf $(ICONSET)

app: build $(ICNS)
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD_DIR)/$(EXECUTABLE) $(CONTENTS)/MacOS/$(EXECUTABLE)
	cp $(ICNS) $(CONTENTS)/Resources/AppIcon.icns
	cp App/Info.plist $(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@if security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGN_ID)"; then \
		echo "signing with \"$(SIGN_ID)\""; \
		codesign --force --deep --sign "$(SIGN_ID)" $(APP); \
	else \
		echo "warning: no \"$(SIGN_ID)\" identity in the keychain — signing ad-hoc."; \
		echo "         permissions will be re-prompted after every rebuild."; \
		echo "         see the SIGN_ID comment in the Makefile to fix that."; \
		codesign --force --deep --sign - $(APP); \
	fi
	@echo "built $(APP)"

# Replace the installed copy. Anything already running is quit first; copying
# over a live bundle leaves a half-updated app.
install: app
	@pkill -x $(EXECUTABLE) 2>/dev/null || true
	@mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED)
	@cp -R $(APP) $(INSTALLED) || { \
		echo ""; \
		echo "error: can't write to $(INSTALL_DIR)."; \
		echo "       /Applications needs an admin account; ~/Applications does not."; \
		echo "       try: make install INSTALL_DIR=\$$HOME/Applications"; \
		exit 1; \
	}
	@echo "installed $(INSTALLED)"
	@echo "launch it: open $(INSTALLED)"

uninstall:
	@pkill -x $(EXECUTABLE) 2>/dev/null || true
	rm -rf $(INSTALLED)
	@echo "removed $(INSTALLED)"

# Dev helpers. Both run the executable inside the bundle rather than the bare
# one in .build, so the process picks up the bundle's Info.plist and TCC
# identity — the bare binary has no microphone usage string and macOS kills it
# the moment it asks for the mic.
run: app
	$(CONTENTS)/MacOS/$(EXECUTABLE) run $(if $(OUT),--out $(OUT),)

doctor: app
	@$(CONTENTS)/MacOS/$(EXECUTABLE) doctor

clean:
	rm -rf $(DIST)
	swift package clean
