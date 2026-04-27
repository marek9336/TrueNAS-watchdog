# TrueNAS Watchdog

Bash watchdog pro TrueNAS SCALE aplikace. Kontroluje, zda vybrané aplikace běží,
umí je zkusit znovu spustit, volitelně kontroluje HTTP healthchecky, reportuje
dostupné aktualizace aplikací/TrueNAS bez instalace, umí explicitně aktualizovat
jen aplikace a posílá Telegram upozornění při problému.

## Bezpečnost

Soubor `truenas-watchdog.conf` obsahuje soukromé Telegram tokeny a lokální
nastavení, proto není verzovaný. V repozitáři je pouze anonymní
`truenas-watchdog.conf.template`.

Ignorované jsou také složky `logs/` a `backup/`.

## Instalace

Na TrueNAS umísti soubory např. do:

```bash
/mnt/POOLNAME/Scripts
```

Vytvoř lokální konfiguraci z template:

```bash
cp /mnt/POOLNAME/Scripts/truenas-watchdog.conf.template /mnt/POOLNAME/Scripts/truenas-watchdog.conf
```

Pak uprav `truenas-watchdog.conf`:

```bash
TELEGRAM_BOT_TOKEN="<telegram_bot_token>"
TELEGRAM_CHAT_ID="<telegram_chat_id>"
APPS=("immich" "joplin" "linkwarden")
```

Volitelně doplň HTTP healthchecky:

```bash
HTTP_HEALTHCHECKS=(
  "immich|http://127.0.0.1:30041|200"
)
```

## Ruční spuštění

Kontrola aplikací:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh check
```

Kontrola dostupných aktualizací aplikací a TrueNASu bez instalace:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh update
```

Kontrola zdraví TrueNASu:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh truenas-health
```

Skutečný update aplikací je oddělený a spouští se jen explicitně:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh app-update
```

Režim `app-update` aktualizuje pouze aplikace z `APPS`. TrueNAS samotný nikdy
neaktualizuje; režim `update` na něj jen pošle upozornění, pokud najde novou
verzi.

## Cron v TrueNAS

V TrueNAS UI otevři `System Settings` -> `Advanced` -> `Cron Jobs` a přidej
příkladové úlohy.

Kontrola aplikací každých 5 minut:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh check >/dev/null 2>&1
```

Kontrola aktualizací např. jednou denně:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh update >/dev/null 2>&1
```

Kontrola zdraví TrueNASu např. jednou za hodinu:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh truenas-health >/dev/null 2>&1
```

Pro debug můžeš výstup dočasně přesměrovat do samostatného logu:

```bash
/usr/bin/bash /mnt/POOLNAME/Scripts/truenas-app-watchdog.sh check >> /mnt/POOLNAME/Scripts/logs/truenas-watchdog-cron.log 2>&1
```

## Poznámky

`START_WAIT` je maximální doba čekání na náběh aplikace. Skript během čekání
polluje stav podle `POLL_INTERVAL` a pokračuje hned, jakmile aplikace přejde do
stavu `RUNNING`.

`UPDATE_SETTLE_WAIT` je krátká pauza po vyžádání aktualizace aplikace. Teprve
potom skript čeká na update job a kontroluje, zda aplikace znovu běží. Pokud po
update nenaběhne do `START_WAIT`, skript vyžádá ruční start a pokračuje na další
aplikaci.
