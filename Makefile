SHELL := /bin/bash
SWIFT_ENV := source "$${SWIFTLY_HOME_DIR:-$$HOME/.local/share/swiftly}/env.sh"

.PHONY: test build clean deploy-atvloadly status-atvloadly

test:
	@$(SWIFT_ENV) && cd Packages/MediaCoreKit && swift test --parallel

build:
	@$(SWIFT_ENV) && cd Packages/MediaCoreKit && swift build

clean:
	@$(SWIFT_ENV) && cd Packages/MediaCoreKit && swift package clean

deploy-atvloadly:
	@cd Scripts/deploy && docker compose -f docker-compose.atvloadly.yml up -d

status-atvloadly:
	@cd Scripts/deploy && docker compose -f docker-compose.atvloadly.yml ps
