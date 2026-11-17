# YT Zero til LG webOS

En lille webOS-app, der åbner din YT Zero-instans i fuld skærm med sit eget
ikon. Adressen sættes, når du bygger appen (se "Byg appen" nedenfor). Login sker med YT Zeros indbyggede TV-pairing:
TV'et viser en QR-kode, du godkender på telefonen, og TV'et er så logget ind
i 30 dage. Passkey-login i Authentik behøver derfor ikke virke på TV'et.

Sådan hænger det sammen:

1. Appen (`app/index.html`) tjekker, at serveren svarer. Derefter åbner den
   `<din instans>/tv-login.html`. Svarer serveren ikke, viser
   den en fejlside og prøver igen automatisk.
2. Login-siden (`/tv-login.html`) følger med YT Zero-imaget fra `ui/public`.
   - Er TV'et allerede logget ind, sender den straks videre til forsiden.
   - Ellers henter den en kode fra `/api/auth/device/code` og viser kode og
     QR-kode.
   - Scan QR-koden, log ind på telefonen og godkend "LG TV" på `/tv/pair`.
   - Siden spørger `/api/auth/device/token` med `set_cookie: true`, og serveren
     sætter selv sessionen som den sædvanlige `HttpOnly`-cookie
     `ytzero_session`. Derefter åbner YT Zero som normalt.
3. Efter login åbner TV'et `/tv.html` (`ui/public/tv.html`): en enkel side, der
   kun kan bruges til at se videoer. Den viser Main-feedet som et grid med
   thumbnail, kanalnavn og titel. OK starter videoen i fuld skærm, Højre spoler
   30 s frem og Venstre 15 s tilbage, OK eller et klik i midten sætter pause, og
   Back går tilbage til Main. Afspilningen fortsætter, hvor man slap, og
   fremskridt gemmes.
   Øverst står "Fortsæt med at se". Hold OK nede på en video for at få en
   menu med "Markér som set" og "Afvis". Op fra øverste række går til
   "Opdater" i øverste højre hjørne. Talknapperne virker stadig som genveje
   (1 afviser, 2 markerer som set, 3 opdaterer), men vises ikke. Farveknapperne
   bruges ikke, fordi LG-TV'et selv fanger dem (billed- og
   energiindstillinger).
4. Back på forsiden lukker appen.

Indhold:

- `app/` er selve webOS-appen. Instansens adresse står i `INSTANCE_URL`
  i `index.html`.
- `server/tv-login.src.html` er kilden til login-siden. `build.sh` indlejrer
  QR-biblioteket (qrcode-generator, MIT) og skriver resultatet til
  `ui/public/tv-login.html`, som committes.
- `instance.env.example` viser de to indstillinger. Din egen `instance.env`
  committes ikke.
- `dist/<app-id>_1.0.0_all.ipk` er den færdige pakke.
- `build.sh` bygger både login-siden og IPK-pakken igen.

## 1. Tjek at serveren leverer login-siden

Login-siden følger med imaget, så der skal ikke mountes noget. Kommandoen skal
skrive `1`:

```bash
curl -s https://ytzero.example.com/tv-login.html | grep -c "Log ind på YT Zero"
```

## 2. Byg appen

Kopiér `instance.env.example` til `instance.env`, sæt `YTZERO_URL` til din
instans' adresse og eventuelt `YTZERO_APP_ID`, og byg:

```bash
./build.sh
```

`app/` indeholder kun pladsholdere; adresse og id sættes ind i den kopi, der
pakkes. Uden `YTZERO_URL` stopper buildet.

## 3. Installér appen på TV'et

1. Opret en gratis konto på https://webostv.developer.lge.com.
2. Installér appen **Developer Mode** fra LG Content Store på TV'et og log ind.
   Slå *Dev Mode Status* og *Key Server* til, og genstart TV'et.
3. Notér IP-adressen og passphrasen, som Developer Mode-appen viser.
4. Tilføj TV'et på Mac'en. Kommandoen spørger interaktivt efter IP-adresse
   (port 9922, bruger `prisoner`):

   ```bash
   ./tools/node_modules/.bin/ares-setup-device --add lgtv
   ```

5. Hent nøglen fra TV'et. Her skal passphrasen fra trin 3 tastes ind:

   ```bash
   ./tools/node_modules/.bin/ares-novacom --device lgtv --getkey
   ```

6. Installér og start appen:

   ```bash
   ./tools/node_modules/.bin/ares-install --device lgtv dist/app.ytzero.webos_1.0.0_all.ipk
   ```

   ```bash
   ./tools/node_modules/.bin/ares-launch --device lgtv app.ytzero.webos
   ```

Developer Mode-sessionen udløber efter 50 timer. Forlæng den med *Extend*
i Developer Mode-appen, ellers forsvinder appen fra TV'et.

## Godt at vide

- **Udløbet login:** TV-sessionen udløber efter 30 dage. Udløber den, mens appen
  er åben, sender YT Zero dig til Authentik. Luk appen og åbn den igen, så får du
  en ny QR-kode.
- **Fjern adgang:** TV'et fremgår som en almindelig session i YT Zero. Log ud
  inde fra YT Zero på TV'et for at fjerne adgangen.
- **Cookien:** Login-siden sætter session-cookien fra JavaScript, så den er ikke
  `HttpOnly`, som YT Zeros egen login-cookie er. Det gælder kun på TV'et.

## Byg igen efter ændringer

```bash
./build.sh
```
