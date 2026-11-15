# YT Zero til LG webOS

En lille webOS-app, der åbner YT Zero-instansen `https://ytzero.example.com/`
i fuld skærm med sit eget ikon. Login sker med YT Zeros indbyggede TV-pairing:
TV'et viser en QR-kode, du godkender på telefonen, og TV'et er så logget ind
i 30 dage. Passkey-login i Authentik behøver derfor ikke virke på TV'et.

Sådan hænger det sammen:

1. Appen (`app/index.html`) tjekker, at serveren svarer. Derefter åbner den
   `https://ytzero.example.com/tv-login.html`. Svarer serveren ikke, viser
   den en fejlside og prøver igen automatisk.
2. Login-siden (`server/tv-login.html`) ligger på din YT Zero-server.
   - Er TV'et allerede logget ind, sender den straks videre til forsiden.
   - Ellers henter den en kode fra `/api/auth/device/code` og viser kode og
     QR-kode.
   - Scan QR-koden, log ind på telefonen og godkend "LG TV" på `/tv/pair`.
   - Siden spørger `/api/auth/device/token` og gemmer den udstedte session i
     cookien `ytzero_session`. Derefter åbner YT Zero som normalt.
3. Tilbage-knappen på fjernbetjeningen går tilbage i YT Zero. Fra forsiden
   lukker den appen.

Indhold:

- `app/` er selve webOS-appen. Instansens adresse står i `INSTANCE_URL`
  i `index.html`.
- `server/tv-login.src.html` er kilden til login-siden.
- `server/tv-login.html` er den færdige login-side med QR-biblioteket
  (qrcode-generator, MIT) indbygget. Det er den fil, der skal på serveren.
- `dist/app.ytzero.webos_1.0.0_all.ipk` er den færdige pakke.
- `build.sh` bygger både login-siden og IPK-pakken igen.

## 1. Læg login-siden på serveren

YT Zero serverer selv statiske filer fra `/app/public` i containeren. Mount
`tv-login.html` ind der i `docker-compose.yml`:

```yaml
services:
  ytzero:
    volumes:
      - ./tv-login.html:/app/public/tv-login.html:ro
```

Kopiér `server/tv-login.html` til mappen ved siden af `docker-compose.yml`, og
genstart derefter containeren:

```bash
docker compose up -d
```

Tjek at siden bliver serveret. Kommandoen skal skrive `1`:

```bash
curl -s https://ytzero.example.com/tv-login.html | grep -c "Log ind på YT Zero"
```

Skriver den `0`, får du YT Zeros forside i stedet, og så er mounten ikke slået
igennem.

## 2. Installér appen på TV'et

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
