PREFIX ?= /usr/local
APP     = Annotate.app
COLOUR ?= 0066FF

.PHONY: install app icon test colour colour-reset clean

annotate: Annotate.swift
	swiftc -O $< -o $@

app: annotate Info.plist Resources/Annotate.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	cp annotate $(APP)/Contents/MacOS/
	mkdir -p $(APP)/Contents/Resources
	cp Resources/Annotate.icns $(APP)/Contents/Resources/
	codesign --force -s - $(APP)

Resources/Annotate.icns: Tools/GenerateIcon.swift
	swift $< Resources

icon:
	swift Tools/GenerateIcon.swift Resources

test:
	bash Tests/run.sh

# CLI on the PATH for scripts, app bundle for Spotlight
install: app
	install -d $(PREFIX)/bin
	install -m 755 annotate $(PREFIX)/bin/
	install -d $(PREFIX)/share/annotate
	install -m 644 Resources/Annotate.icns $(PREFIX)/share/annotate/
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
