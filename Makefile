PREFIX ?= /usr/local

annotate: Annotate.swift
	swiftc -O Annotate.swift -o annotate

APP = Annotate.app

.PHONY: install app install-app clean
install: annotate
	mkdir -p $(PREFIX)/bin
	install -m 755 annotate $(PREFIX)/bin/annotate

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
