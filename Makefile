# make run      build, sign, and (re)start Spool
# make install  copy Spool to /Applications and start it from there
# make test     run the unit tests
# make clean    remove build output

APP := build/Spool.app

.PHONY: build run install test clean

build:
	scripts/bundle.sh

run: build
	-pkill -TERM -f "Spool.app/Contents/MacOS/Spool"
	@sleep 1
	open $(APP)

install: build
	-pkill -TERM -f "Spool.app/Contents/MacOS/Spool"
	@sleep 1
	rm -rf /Applications/Spool.app
	cp -R $(APP) /Applications/Spool.app
	open /Applications/Spool.app
	@echo "Installed. For the command line tool: ln -s /Applications/Spool.app/Contents/MacOS/spoolctl /usr/local/bin/spoolctl"

test:
	swift test

clean:
	rm -rf .build build
