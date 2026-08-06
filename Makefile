APP_NAME   := Trailmix
EXECUTABLE := trailmix
BUNDLE_ID  := us.stephenturner.trailmix
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
#
# Signed without --deep. It is deprecated for signing, and there is nothing
# nested here to reach anyway: the bundle holds one Mach-O, an .icns, and two
# plists.
SIGN_ID ?= Trailmix

# SHA-1 of the signing certificate, which is what a requirement's `H"..."`
# literal holds. Lowercased to match how codesign prints it back.
#
# CERT_COUNT exists because rotating this certificate means holding two of them
# for as long as it takes to delete the old one, and `awk ... exit` below would
# pick one arbitrarily while codesign separately refused with "ambiguous
# (matches too many identities)". The `app` target checks it and says which
# identities collided, rather than leaving that to be worked out from codesign.
CERT_MATCHES := $(shell security find-identity -p codesigning 2>/dev/null \
	| grep -cF '"$(SIGN_ID)"')
CERT_SHA := $(shell security find-identity -p codesigning 2>/dev/null \
	| awk '/"$(SIGN_ID)"/ {print tolower($$2); exit}')

# The designated requirement, written by hand rather than left to codesign.
#
# TCC copies an app's designated requirement into its permission row and
# re-evaluates the running process against that stored copy forever after.
# Left alone, codesign generates `identifier "..." and certificate leaf =
# H"<this cert>"`, which pins the grant to one certificate, so changing
# certificates strands every existing user: the requirement can no longer be
# satisfied by any build, kTCCServiceScreenCapture is not allowed to prompt, and
# tccd just returns denied. That is the failure already lived through once here,
# on the `Trailmix Dev` rename, and it is what a future move to a paid Developer
# ID certificate would inflict on everyone who installed a self-signed build.
#
# So the requirement names all three certificates this app could ever be signed
# with, up front: this one, any Apple-issued Developer ID Application
# certificate, or the Mac App Store leaf Apple re-signs a submission with. A
# grant issued against a build signed this way survives both switches, because
# the requirement was stored before either certificate existed.
#
# The third clause is what a homebrew-first plan would otherwise miss. A Mac App
# Store build is not signed with Developer ID: Apple strips the submission
# signature and re-signs with its own leaf (OID ...6.1.9). Same bundle
# identifier, so it lands on the same TCC row, so without this clause anyone who
# installed via brew and later moved to the App Store build would hit exactly
# the failure above.
#
# Strictly wider than the default, and the widening is the point. What it costs:
# another developer holding a Developer ID certificate who signed an app with
# this exact bundle identifier would inherit the grants. Once there is a real
# team, `and certificate leaf[subject.OU] = "<TEAMID>"` closes that.
#
# This cannot be applied retroactively. A TCC row keeps whatever requirement it
# was created with. See STATUS.md for the one-time reset that rewrites a row
# already issued against the old, certificate-pinned form.
DESIGNATED_REQ = designated => identifier "$(BUNDLE_ID)" and \
	(certificate leaf = H"$(CERT_SHA)" or \
	 (anchor apple generic and \
	  certificate 1[field.1.2.840.113635.100.6.2.6] and \
	  certificate leaf[field.1.2.840.113635.100.6.1.13]) or \
	 (anchor apple generic and \
	  certificate leaf[field.1.2.840.113635.100.6.1.9]))

# The hardened runtime, on every build including ad-hoc ones.
#
# Notarization requires it, so a build that only turns it on at release time
# finds out whether it broke the app on the day there is finally a certificate
# to notarize with. It is free to enable now and it is the half of notarization
# that can actually break something: the runtime enforces library validation and
# revokes a handful of capabilities unless a matching entitlement is present.
#
# The one exception this app needs is the microphone, in App/Trailmix.entitlements.
# Screen recording is TCC-only and needs nothing here.
#
# --timestamp is deliberately absent. Notarization needs a secure timestamp, but
# it means a round trip to Apple's timestamp server on every local `make app`,
# which fails offline. Add it to the notarizing path when there is one.
ENTITLEMENTS := App/Trailmix.entitlements
SIGN_OPTS    := --options runtime --entitlements $(ENTITLEMENTS)

# Marketing version lives in App/Info.plist. The build number is the commit
# count: numeric and monotonic, which is what CFBundleVersion is specified to
# be, unlike a short SHA.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

# Marketing version, read back out of the plist so the zip and the bundle can't
# disagree about which release this is.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Info.plist)
ZIP     := $(DIST)/$(APP_NAME)-$(VERSION).zip

.PHONY: all app build icon install uninstall run doctor test release clean

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
	@if [ "$(CERT_MATCHES)" -gt 1 ]; then \
		echo ""; \
		echo "error: $(CERT_MATCHES) code-signing identities match \"$(SIGN_ID)\":"; \
		security find-identity -p codesigning | grep -F '"$(SIGN_ID)"'; \
		echo "       codesign matches SIGN_ID as a substring and refuses when"; \
		echo "       more than one hits. Delete all but the current certificate"; \
		echo "       in Keychain Access (key included), then rebuild."; \
		exit 1; \
	fi
	@if [ -n "$(CERT_SHA)" ]; then \
		echo "signing with \"$(SIGN_ID)\" ($(CERT_SHA))"; \
		codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTS) \
			-r='$(DESIGNATED_REQ)' $(APP); \
	else \
		echo "warning: no \"$(SIGN_ID)\" identity in the keychain, signing ad-hoc."; \
		echo "         permissions will be re-prompted after every rebuild, and"; \
		echo "         \`make release\` will refuse to package the result."; \
		echo "         see the SIGN_ID comment in the Makefile to fix that."; \
		codesign --force --sign - $(SIGN_OPTS) $(APP); \
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

# A zip to attach to a GitHub release, plus the checksum a Homebrew cask needs.
#
# ditto rather than `zip -r`: a .app is a directory whose signature covers its
# layout, and zip mangles symlinks and extended attributes in ways that produce
# a bundle macOS refuses to launch as damaged. --keepParent puts Trailmix.app at
# the top of the archive instead of scattering Contents/ across the download.
#
# The ad-hoc check is the point of having a separate target. `make app` falls
# back to ad-hoc with a warning, which is the right call for a local build and
# the wrong one for anything handed to another person: ad-hoc keys TCC to the
# binary's hash, so every release would re-prompt for permissions, and the
# Screen Recording prompt is the one that cannot be re-issued.
release: app
	@if codesign -dv $(APP) 2>&1 | grep -q "Signature=adhoc"; then \
		echo ""; \
		echo "error: $(APP) is ad-hoc signed. Refusing to package it."; \
		echo "       every install would re-prompt for permissions, and a"; \
		echo "       later signed release would strand them (see STATUS.md)."; \
		echo "       create the \"$(SIGN_ID)\" identity first."; \
		exit 1; \
	fi
	@rm -f $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(APP) $(ZIP)
	@echo ""
	@echo "$(ZIP)"
	@shasum -a 256 $(ZIP)
	@echo ""
	@echo "Not notarized. Downloaders get a Gatekeeper warning and have to allow"
	@echo "it once under System Settings > Privacy & Security. See STATUS.md."

# Dev helpers. Both run the executable inside the bundle rather than the bare
# one in .build, so the process picks up the bundle's Info.plist and TCC
# identity. The bare binary has no microphone usage string and macOS kills it
# the moment it asks for the mic.
run: app
	$(CONTENTS)/MacOS/$(EXECUTABLE) run $(if $(OUT),--out $(OUT),)

doctor: app
	@$(CONTENTS)/MacOS/$(EXECUTABLE) doctor

# Debug rather than release, and no bundle: the suite is pure Swift with no
# model, no network and no capture behind it, so it runs in milliseconds.
test:
	swift test

clean:
	rm -rf $(DIST)
	swift package clean
