#!/bin/bash

# Find all Python files in the tests directory
for file in ./tests/*.py; do
    if [ -f "$file" ]; then
        echo "Running tests in $file..."
        python -m pytest "$file" -v
    fi
done
