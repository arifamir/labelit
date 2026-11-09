APP := build/Release/LabelIt.app

.PHONY: test app run preview project clean llama install release linux-image linux-test linux-shell linux-cli

project:          ## Regenerate the Xcode project from project.yml
	xcodegen generate

llama:            ## Build llama.cpp (static, Metal) into Vendor/ — once, a few minutes
	scripts/build-llama.sh

test: llama       ## Run the tests (the model test runs when EmbeddingGemma 2 is on this Mac)
	swift test

app: llama project ## Build build/Release/LabelIt.app
	xcodebuild -project LabelIt.xcodeproj -scheme LabelIt -configuration Release \
		-derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR=$(CURDIR)/build/Release build | xcbeautify 2>/dev/null || \
	xcodebuild -project LabelIt.xcodeproj -scheme LabelIt -configuration Release \
		-derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR=$(CURDIR)/build/Release build -quiet

install: app      ## Copy to /Applications (needed for Launch at Login)
	rm -rf /Applications/LabelIt.app && cp -R $(APP) /Applications/

release:          ## Package dist/LabelIt.zip (+ .sha256) for a GitHub release; DEVELOPER_ID/NOTARY_PROFILE to sign
	scripts/release.sh

run: app          ## Build and open the app
	open $(APP)

DIR ?= ~/Downloads
LIMIT ?= 30
preview:          ## Dry run: what would LabelIt name the phone files in DIR? Renames nothing.
	swift run -c release labelit-cli preview $(DIR) $(LIMIT)

# Linux, in Docker. The build lives in a Docker volume (fast); llama.cpp for Linux in Vendor/linux.
# EmbeddingGemma 2 is shared read-only from this Mac when it's here (LabelIt's download or DigUp's).
LINUX_IMAGE := labelit-linux
MODELS_DIR ?= $(shell for d in "$(HOME)/Library/Application Support/LabelIt/Models" "$(HOME)/Library/Application Support/DigUp/Models"; do ls "$$d"/*.gguf > /dev/null 2>&1 && { echo "$$d"; break; }; done)
LINUX_RUN = docker run --rm -t -v "$(CURDIR)":/src -v labelit-linux-build:/build \
	$(if $(MODELS_DIR),-v "$(MODELS_DIR)":/root/.local/share/LabelIt/Models:ro) $(LINUX_IMAGE)

linux-image:      ## Build the Linux Docker image (Swift, libheif, Tesseract)
	docker build -q -t $(LINUX_IMAGE) scripts/linux > /dev/null

linux-test: linux-image ## Build and test on Linux, in Docker
	$(LINUX_RUN) bash -c 'scripts/build-llama.sh && swift test --scratch-path /build'

linux-cli: linux-image  ## Run the CLI on Linux: make linux-cli ARGS="status"
	$(LINUX_RUN) bash -c 'scripts/build-llama.sh && swift run --scratch-path /build -c release labelit-cli $(ARGS)'

linux-shell: linux-image ## A shell in the Linux build environment
	docker run --rm -it -v "$(CURDIR)":/src -v labelit-linux-build:/build $(LINUX_IMAGE) bash

clean:
	rm -rf build .build LabelIt.xcodeproj
