#!/bin/bash
set -u

CONFIG="/mnt/Apps/Scripts/truenas-watchdog.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Chyba: chybí config $CONFIG"
  exit 1
fi

# shellcheck disable=SC1090
source <(tr -d '\r' < "$CONFIG")

MIDCLT="/usr/bin/midclt"
JQ="/usr/bin/jq"
CURL="/usr/bin/curl"
DATE="/bin/date"
SLEEP="/bin/sleep"
BASENAME="/usr/bin/basename"

MODE="${1:-check}"   # check | update

log() {
  local msg="[$($DATE '+%F %T')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

tg_send() {
  local text="$1"
  $CURL -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1
}

get_app_json() {
  local app="$1"
  $MIDCLT call app.query "[[\"id\",\"=\",\"${app}\"]]" "{\"get\": true}" 2>/dev/null
}

get_app_state() {
  local app="$1"
  get_app_json "$app" | $JQ -r '.state // "UNKNOWN"' 2>/dev/null
}

get_upgrade_available() {
  local app="$1"
  get_app_json "$app" | $JQ -r '.upgrade_available // false' 2>/dev/null
}

wait_for_job() {
  local job_id="$1"
  # čekání na dokončení jobu
  $MIDCLT call core.job_wait "$job_id" >/dev/null 2>&1
  return $?
}

start_app() {
  local app="$1"
  log "Pokouším se nastartovat app: $app"
  local job_id
  job_id=$($MIDCLT call app.start "$app" 2>/dev/null | tr -d '\n')

  if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    log "Nepodařilo se získat job ID pro start app $app"
    tg_send "⚠️ TrueNAS watchdog: nepodařilo se spustit app '$app' (neplatné job ID)."
    return 1
  fi

  wait_for_job "$job_id"
  log "Start job dokončen pro $app, čekám ${START_WAIT}s na náběh"
  $SLEEP "$START_WAIT"

  local state
  state=$(get_app_state "$app")
  if [ "$state" = "RUNNING" ]; then
    log "App $app úspěšně běží"
    tg_send "✅ TrueNAS watchdog: app '$app' byla automaticky spuštěna."
    return 0
  else
    log "App $app po startu stále neběží. Stav: $state"
    tg_send "❌ TrueNAS watchdog: app '$app' se nepodařilo nahodit. Stav po pokusu: $state"
    return 1
  fi
}

upgrade_app() {
  local app="$1"
  log "Provádím update app: $app"

  local job_id
  job_id=$($MIDCLT call app.upgrade "$app" '{"app_version":"latest","snapshot_hostpaths":false}' 2>/dev/null | tr -d '\n')

  if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    log "Nepodařilo se získat job ID pro update app $app"
    tg_send "⚠️ TrueNAS watchdog: update app '$app' se nespustil (neplatné job ID)."
    return 1
  fi

  wait_for_job "$job_id"
  log "Update job dokončen pro $app, čekám ${START_WAIT}s na náběh"
  $SLEEP "$START_WAIT"

  local state
  state=$(get_app_state "$app")

  if [ "$state" = "RUNNING" ]; then
    log "App $app po update běží"
    tg_send "⬆️ TrueNAS watchdog: app '$app' byla aktualizována a běží."
    return 0
  else
    log "App $app po update neběží. Stav: $state. Zkouším ruční start."
    tg_send "⚠️ TrueNAS watchdog: app '$app' po update nenaběhla (stav: $state). Zkouším ruční spuštění."
    start_app "$app"
    return $?
  fi
}

check_apps() {
  for app in "${APPS[@]}"; do
    local state
    state=$(get_app_state "$app")

    if [ -z "$state" ] || [ "$state" = "null" ] || [ "$state" = "UNKNOWN" ]; then
      log "App $app nebyla nalezena nebo nešla načíst"
      tg_send "⚠️ TrueNAS watchdog: app '$app' nebyla nalezena nebo nešla načíst."
      continue
    fi

    if [ "$state" != "RUNNING" ]; then
      log "App $app neběží. Aktuální stav: $state"
      start_app "$app"
    else
      log "App $app je v pořádku (RUNNING)"
    fi
  done
}

update_apps() {
  for app in "${APPS[@]}"; do
    local upgrade
    local state

    state=$(get_app_state "$app")
    if [ "$state" != "RUNNING" ]; then
      log "App $app před update neběží (stav: $state), nejdřív ji zkusím spustit"
      start_app "$app"
    fi

    upgrade=$(get_upgrade_available "$app")
    if [ "$upgrade" = "true" ]; then
      upgrade_app "$app"
    else
      log "App $app nemá dostupný update"
    fi
  done
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  case "$MODE" in
    check)
      log "=== Spouštím kontrolu aplikací ==="
      check_apps
      ;;
    update)
      log "=== Spouštím týdenní update aplikací ==="
      update_apps
      ;;
    *)
      echo "Použití: $0 [check|update]"
      exit 1
      ;;
  esac
}

main
