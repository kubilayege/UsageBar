.PHONY: build run app install preview test prices dmg clean
SPARKLE_FRAMEWORK_DIR = .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64

build:
	swift build

run: build
	.build/debug/UsageBar

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install

preview: build
	.build/debug/UsageBar --render-preview build/preview-popover.png --render-dashboard build/preview-dashboard.png

test: build
	swiftc Sources/UsageBar/Support/SelectionFilter.swift Tests/ProviderSelectionRegression.swift -o .build/provider-selection-regression
	.build/provider-selection-regression
	swiftc -D REGRESSION_TESTS -parse-as-library $$(rg --files Sources -g '*.swift') $$(rg --files Tests -g '*.swift' -g '!ProviderSelectionRegression.swift') -F $(SPARKLE_FRAMEWORK_DIR) -framework Sparkle -Xlinker -rpath -Xlinker "$(CURDIR)/$(SPARKLE_FRAMEWORK_DIR)" -lsqlite3 -o .build/behavior-regression
	.build/behavior-regression

dmg: app
	scripts/build-dmg.sh

prices:
	python3 scripts/update-prices.py

clean:
	rm -rf .build build
