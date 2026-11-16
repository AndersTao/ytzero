#!/bin/sh
# Bygger login-siden (med QR-biblioteket indlejret) til ui/public/tv-login.html,
# så YT Zero-imaget leverer den, og webOS-pakken i dist/ til din egen instans.
#
# Instansens adresse og app-id kommer fra miljøet eller fra instance.env ved
# siden af dette script (den fil committes ikke):
#   YTZERO_URL=https://ytzero.example.com/   (påkrævet)
#   YTZERO_APP_ID=com.example.ytzero         (valgfri, standard app.ytzero.webos)
set -e
cd "$(dirname "$0")"

[ -f instance.env ] && . ./instance.env
if [ -z "${YTZERO_URL:-}" ]; then
  echo "Mangler YTZERO_URL: adressen på din YT Zero-instans." >&2
  echo "Kopiér instance.env.example til instance.env og udfyld den." >&2
  exit 1
fi
YTZERO_APP_ID="${YTZERO_APP_ID:-app.ytzero.webos}"

[ -d tools/node_modules/@webos-tools/cli ] && [ -d tools/node_modules/qrcode-generator ] ||
  npm install --silent --no-fund --no-audit --prefix ./tools @webos-tools/cli qrcode-generator

node -e '
const fs = require("fs");
const lib = fs.readFileSync("tools/node_modules/qrcode-generator/dist/qrcode.js", "utf8");
const src = fs.readFileSync("server/tv-login.src.html", "utf8");
fs.writeFileSync("../../ui/public/tv-login.html", src.replace("/*QRCODE_LIB*/", () => lib));
'
echo "Bygget ui/public/tv-login.html"

# Pak en kopi af app/ med adresse og id indsat; app/ selv forbliver generisk.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R app/. "$stage/"
YTZERO_URL="$YTZERO_URL" YTZERO_APP_ID="$YTZERO_APP_ID" node -e '
const fs = require("fs");
const dir = process.argv[1];
let url = process.env.YTZERO_URL.trim();
if (!/^https?:\/\/[^/]+/.test(url)) { console.error("YTZERO_URL skal starte med http:// eller https://"); process.exit(1); }
if (!url.endsWith("/")) url += "/";
const id = process.env.YTZERO_APP_ID.trim();
if (!/^[a-z0-9]+(\.[a-z0-9-]+)+$/.test(id)) { console.error("YTZERO_APP_ID skal ligne com.example.ytzero"); process.exit(1); }
for (const [file, token, value] of [["index.html", "__YTZERO_URL__", url], ["appinfo.json", "__YTZERO_APP_ID__", id]]) {
  const path = dir + "/" + file;
  const text = fs.readFileSync(path, "utf8");
  if (!text.includes(token)) { console.error(file + " mangler " + token); process.exit(1); }
  fs.writeFileSync(path, text.split(token).join(value));
}
console.log("Pakker " + id + " til " + url);
' "$stage"

mkdir -p dist
./tools/node_modules/.bin/ares-package "$stage" -o dist
