PREFIX ?= /usr/local
APP     = Annotate.app

.PHONY: install app install-app clean

annotate: Annotate.swift
	swiftc -O $< -o $@

install: annotate
	install -d $(PREFIX)/bin
	install -m 755 annotate $(PREFIX)/bin/

app: annotate Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/
	cp annotate $(APP)/Contents/MacOS/
	codesign --force -s - $(APP)

install-app: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

clean:
	rm -f annotate
	rm -rf $(APP)
