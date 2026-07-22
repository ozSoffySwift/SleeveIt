#!/bin/sh
# Publishes the bundled catalog seed to the GitHub Pages feed.
#
# The app ships SleeveIt/Catalog/catalog.json as its first-launch seed, and
# fetches https://ozsoffyswift.github.io/SleeveIt/catalog/catalog.json for
# updates. This script keeps the two identical — run it (then commit + push)
# whenever the catalog changes. Forgetting is harmless but inert: clients only
# apply a payload whose version is HIGHER than what they have, so a stale feed
# simply means nobody gets the new games yet.
set -e
cd "$(dirname "$0")/.."
cp SleeveIt/Catalog/catalog.json docs/catalog/catalog.json
echo "Published catalog v$(python3 -c "import json; print(json.load(open('docs/catalog/catalog.json'))['version'])") to docs/catalog/"
echo "Now: git add docs/catalog && git commit && git push"
