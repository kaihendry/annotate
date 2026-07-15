PREFIX ?= /usr/local
APP     = Annotate.app
COLOUR ?= 0066FF

.PHONY: install app colour colour-reset clean

annotate: Annotate.swift
	swiftc -O $< -o $@

app: annotate Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	cp annotate $(APP)/Contents/MacOS/
	codesign --force -s - $(APP)

# CLI on the PATH for scripts, app bundle for Spotlight
install: app
	install -d $(PREFIX)/bin
	install -m 755 annotate $(PREFIX)/bin/
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

# make colour COLOUR=00AA00 — set the annotation colour (RRGGBB)
colour:
	defaults write com.hendry.annotate colour $(COLOUR)

colour-reset:
	-defaults delete com.hendry.annotate colour

clean:
	rm -f annotate
	rm -rf $(APP)
