RELEASE_DIR = dist/app

all:
	mkdir -p $(RELEASE_DIR)
	cabal configure
	cabal build
	coffee -c -o static coffeescripts/*.coffee
	cp dist/build/eventsource-broker/eventsource-broker $(RELEASE_DIR)/eventsource-broker
	mkdir -p $(RELEASE_DIR)/config
	cp -r static $(RELEASE_DIR)
	cd dist &&  tar -czf eventsource-broker.tar.gz app/	
