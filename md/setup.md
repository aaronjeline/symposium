# Installation and setup

## Development setup

* Checkout the project
* Run `cargo setup --dev` which will
    * install the Symposium MCP server in `~/.cargo/bin`
    * configure recognized CLI agents to use the MCP server globally
    * install the Symposium VSCode extension
* Build the macOS application: `cd application/osx && ./build-app.sh`
* To run the symposium app:
    * `open "application/osx/.build/arm64-apple-macosx/release/Symposium.app"`
* **Note**: After installing the VSCode extension, restart VSCode to activate it
