# Azure Function Repo
A repo designed to show how to setup and use Azure Cloud Functions for HTTP requests.
## How to use
- Look in HelloWorld for a simple example with comments
- Look in HelloWorld/README.md for a breif explaination of what functions.json does


## Important information
- Make sure local.settings.json is in your .gitignore. This contains sensitive information


## Quick Start
1. install azure cli
```
brew install azure-cli
```
2. Login to azure:
```
az login
```
& follow the prompts in the browser.
3. Install Functions Core tools:
```
brew tap azure/functions
brew install azure-functions-core-tools@4
```
4. Test the function with:
func start --port 7072 --verbose
