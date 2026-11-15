#!/bin/sh
# Bygger login-siden (med QR-biblioteket indlejret) til ui/public/tv-login.html,
# så YT Zero-imaget leverer den, og webOS-pakken i dist/.
set -e
cd "$(dirname "$0")"

[ -d tools/node_modules/@webos-tools/cli ] && [ -d tools/node_modules/qrcode-generator ] ||
  npm install --silent --no-fund --no-audit --prefix ./tools @webos-tools/cli qrcode-generator

node -e '
const fs = require("fs");
const lib = fs.readFileSync("tools/node_modules/qrcode-generator/dist/qrcode.js", "utf8");
const src = fs.readFileSync("server/tv-login.src.html", "utf8");
fs.writeFileSync("../../ui/public/tv-login.html", src.replace("/*QRCODE_LIB*/", () => lib));
'
echo "Bygget ui/public/tv-login.html"

mkdir -p dist
./tools/node_modules/.bin/ares-package app -o dist
