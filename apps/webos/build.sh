#!/bin/sh
# Bygger server/tv-login.html (med QR-biblioteket indlejret) og webOS-pakken i dist/.
set -e
cd "$(dirname "$0")"

[ -d tools/node_modules/@webos-tools/cli ] && [ -d tools/node_modules/qrcode-generator ] ||
  npm install --silent --no-fund --no-audit --prefix ./tools @webos-tools/cli qrcode-generator

node -e '
const fs = require("fs");
const lib = fs.readFileSync("tools/node_modules/qrcode-generator/dist/qrcode.js", "utf8");
const src = fs.readFileSync("server/tv-login.src.html", "utf8");
fs.writeFileSync("server/tv-login.html", src.replace("/*QRCODE_LIB*/", () => lib));
'
echo "Bygget server/tv-login.html"

mkdir -p dist
./tools/node_modules/.bin/ares-package app -o dist
