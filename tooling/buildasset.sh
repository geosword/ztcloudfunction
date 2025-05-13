#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status


# --- Configuration ---
# Name of the directory in the current path containing your Python function code.
# This script assumes host.json, requirements.txt, main.py, function.json
# are all directly inside this directory.
FUNCTION_CODE_DIR=$AZCF_NAME

# Name for the output zip file
OUTPUT_ZIP_FILE="${FUNCTION_CODE_DIR}_package.zip" # e.g., "ztfunction_package.zip"
# --- End Configuration ---

# --- Repository Root Check ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "Error: Not in a git repository. This script must be run from a git repository."
  exit 1
fi

# Compare the git repository root with the current working directory
if [ "$(pwd)" != "$REPO_ROOT" ]; then
  echo "Error: This script must be run from the repository root."
  echo "Current directory: $(pwd)"
  echo "Repository root:   $REPO_ROOT"
  echo "Please change to the repository root directory and try again."
  exit 1
fi

# --- Sanity Checks ---
if [ ! -d "$FUNCTION_CODE_DIR" ]; then
  echo "Error: Source directory './$FUNCTION_CODE_DIR' not found."
  echo "Please navigate to the parent directory of '$FUNCTION_CODE_DIR' or update the FUNCTION_CODE_DIR variable in this script."
  exit 1
fi
if [ ! -f "host.json" ]; then
  echo "Error: './host.json' not found. This file is needed for the zip root."
  exit 1
fi
if [ ! -f "requirements.txt" ]; then
  echo "Error: './requirements.txt' not found. This file is needed for the zip root."
  exit 1
fi
# Basic check for core function files (optional, add more if needed)
if [ ! -f "$FUNCTION_CODE_DIR/function.json" ]; then
  echo "Warning: './$FUNCTION_CODE_DIR/function.json' not found. This is usually required for each function."
fi
if [ ! -f "$FUNCTION_CODE_DIR/*.py" ]; then
  echo "Warning: './$FUNCTION_CODE_DIR/main.py' not found. This is often the default Python entry point."
fi

echo "--- Preparing to create zip package ---"
echo "Output Zip File:          ./$OUTPUT_ZIP_FILE"
echo "Source Code Directory:    ./$FUNCTION_CODE_DIR"
echo "Expected zip structure:"
echo "  host.json"
echo "  requirements.txt"
echo "  $FUNCTION_CODE_DIR/"
echo "    main.py"
echo "    function.json"
echo "    (and other files from ./$FUNCTION_CODE_DIR/)"
echo "---------------------------------------"

# Remove old zip file if it exists to prevent appending to an old structure
rm -f "$OUTPUT_ZIP_FILE"
echo "Removed old '$OUTPUT_ZIP_FILE' if it existed."

# 1. Add host.json and requirements.txt to the ROOT of the zip
#    The -j option "junks" (discards) the path, so "./$FUNCTION_CODE_DIR/host.json"
#    becomes "host.json" in the zip.
echo "Adding 'host.json' from './$FUNCTION_CODE_DIR/host.json' to zip root..."
zip -q -j "$OUTPUT_ZIP_FILE" "host.json"

echo "Adding 'requirements.txt' from 'requirements.txt' to zip root..."
zip -q -j -u "$OUTPUT_ZIP_FILE" "requirements.txt" # -u updates if exists, or adds

# 2. Create a temporary staging directory for the function-specific files
#    This helps ensure we only include what's needed and get the paths right in the zip.
TEMP_STAGE_PARENT_DIR="_temp_zip_build_stage"
TEMP_STAGE_SUBDIR="$TEMP_STAGE_PARENT_DIR/$FUNCTION_CODE_DIR" # e.g., _temp_zip_build_stage/ztfunction

echo "Creating temporary staging area: '$TEMP_STAGE_SUBDIR'"
rm -rf "$TEMP_STAGE_PARENT_DIR" # Clean up from any previous run
mkdir -p "$TEMP_STAGE_SUBDIR"

# Copy files from the original function code directory to the staged subdirectory,
# excluding files already handled or not needed.
echo "Copying function-specific files (excluding host.json, requirements.txt, etc.) to staging area..."
rsync -a \
  --exclude 'host.json' \
  --exclude 'requirements.txt' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  --exclude 'local.settings.json' \
  --exclude 'venv/' \
  --exclude '.venv/' \
  --exclude '.git/' \
  --exclude '.gitattributes' \
  --exclude '.gitignore' \
  --exclude '.vscode/' \
  "$FUNCTION_CODE_DIR/" "$TEMP_STAGE_SUBDIR/"
  # The trailing slash on "$FUNCTION_CODE_DIR/" is important for rsync:
  # it copies the *contents* of FUNCTION_CODE_DIR into TEMP_STAGE_SUBDIR.

# 3. Add the staged function-specific directory to the zip
#    We cd into the parent of the staged subdirectory ($TEMP_STAGE_PARENT_DIR)
#    and then add the $FUNCTION_CODE_DIR directory from there.
#    This ensures that inside the zip, the files appear under $FUNCTION_CODE_DIR/.
if [ -n "$(ls -A $TEMP_STAGE_SUBDIR)" ]; then # Check if the staging subdirectory is not empty
  echo "Adding staged '$FUNCTION_CODE_DIR/' directory and its contents to the zip..."
  (cd "$TEMP_STAGE_PARENT_DIR" && zip -q -r -u "../$OUTPUT_ZIP_FILE" "$FUNCTION_CODE_DIR" -x "*.DS_Store")
  # Example: (cd _temp_zip_build_stage && zip -q -r -u ../ztfunction_package.zip ztfunction)
else
  echo "Warning: Staging directory '$TEMP_STAGE_SUBDIR' was empty. No function-specific files added under '$FUNCTION_CODE_DIR/' in the zip."
fi

# Clean up the temporary staging directory
echo "Cleaning up temporary staging area..."
rm -rf "$TEMP_STAGE_PARENT_DIR"

echo "--- Zip package '$OUTPUT_ZIP_FILE' created successfully! ---"
echo "Contents of the zip file:"
unzip -l "$OUTPUT_ZIP_FILE"
echo "---------------------------------------------------------"
echo "You can now run ./tooling/deploy.sh to deploy './$OUTPUT_ZIP_FILE' to Azure Functions."
