#!/bin/bash
set -e

LAYER_DIR="python"
ZIP_FILE="layer.zip"

rm -rf $LAYER_DIR $ZIP_FILE
mkdir -p $LAYER_DIR
pip install --target=$LAYER_DIR google-api-python-client google-auth aggregate-prefixes
zip -r $ZIP_FILE $LAYER_DIR
rm -rf $LAYER_DIR

echo "Lambda Layer packaged into $ZIP_FILE"