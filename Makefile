.PHONY: all build run release run-release clean

all: build

build:
	swift build

run:
	swift run

release:
	swift build -c release

run-release:
	swift run -c release

clean:
	rm -rf .build
