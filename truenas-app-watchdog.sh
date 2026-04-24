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

MODE="${1:-check}"   # check | update | app-update | truenas-health
POLL_INTERVAL="${POLL_INTERVAL:-5}"
if ! declare -p HTTP_HEALTHCHECKS >/dev/null 2>&1; then
  HTTP_HEALTHCHECKS=()
fi

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

get_app_upgrade_info() {
  local app="$1"
  get_app_json "$app" | $JQ -r '
    if (.upgrade_available // false) == true then
      [
        .id,
        (.version // "unknown"),
        (.latest_version // .latest_app_version // .upgrade_version // "unknown")
      ] | @tsv
    else
      empty
    end
  ' 2>/dev/null
}

wait_for_job() {
  local job_id="$1"
  # čekání na dokončení jobu
  $MIDCLT call core.job_wait "$job_id" >/dev/null 2>&1
  return $?
}

wait_for_app_running() {
  local app="$1"
  local waited=0
  local state

  while [ "$waited" -lt "$START_WAIT" ]; do
    state=$(get_app_state "$app")
    if [ "$state" = "RUNNING" ]; then
      log "App $app naběhla po ${waited}s"
      return 0
    fi

    log "App $app zatím neběží (stav: $state), další kontrola za ${POLL_INTERVAL}s"
    $SLEEP "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done

  state=$(get_app_state "$app")
  log "App $app nenaběhla do ${START_WAIT}s. Stav: $state"
  return 1
}

check_http_health() {
  local app="$1"
  local url="$2"
  local expected="${3:-200}"
  local code

  code=$($CURL -k -L -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 "$url" 2>/dev/null || true)

  if [ "$code" = "$expected" ]; then
    log "HTTP healthcheck $app OK ($url -> $code)"
    return 0
  fi

  log "HTTP healthcheck $app selhal ($url -> ${code:-NO_RESPONSE}, očekáváno $expected)"
  tg_send "⚠️ TrueNAS watchdog: HTTP healthcheck app '$app' selhal. URL: $url, odpověď: ${code:-NO_RESPONSE}, očekáváno: $expected."
  return 1
}

check_http_healthchecks() {
  local item
  local app
  local url
  local expected

  for item in "${HTTP_HEALTHCHECKS[@]}"; do
    IFS='|' read -r app url expected <<< "$item"
    if [ -z "${app:-}" ] || [ -z "${url:-}" ]; then
      log "Přeskakuji neplatný HTTP healthcheck: $item"
      continue
    fi

    if [ "$(get_app_state "$app")" = "RUNNING" ]; then
      check_http_health "$app" "$url" "${expected:-200}"
    else
      log "HTTP healthcheck $app přeskočen, aplikace neběží"
    fi
  done
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

  if ! wait_for_job "$job_id"; then
    log "Start job pro $app skončil chybou"
    tg_send "❌ TrueNAS watchdog: start job app '$app' skončil chybou."
    return 1
  fi

  log "Start job dokončen pro $app, čekám na náběh max ${START_WAIT}s"

  if wait_for_app_running "$app"; then
    log "App $app úspěšně běží"
    tg_send "✅ TrueNAS watchdog: app '$app' byla automaticky spuštěna."
    return 0
  else
    local state
    state=$(get_app_state "$app")
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

  if ! wait_for_job "$job_id"; then
    log "Update job pro $app skončil chybou"
    tg_send "❌ TrueNAS watchdog: update app '$app' skončil chybou."
    return 1
  fi

  log "Update job dokončen pro $app, čekám na náběh max ${START_WAIT}s"

  if wait_for_app_running "$app"; then
    log "App $app po update běží"
    tg_send "⬆️ TrueNAS watchdog: app '$app' byla aktualizována a běží."
    return 0
  else
    local state
    state=$(get_app_state "$app")
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

  check_http_healthchecks
}

check_app_updates() {
  local app
  local found=0
  local info
  local message="Dostupné aktualizace aplikací:"

  for app in "${APPS[@]}"; do
    info=$(get_app_upgrade_info "$app")
    if [ -n "$info" ]; then
      found=1
      local app_id current latest
      IFS=$'\t' read -r app_id current latest <<< "$info"
      log "App $app_id má dostupný update (${current} -> ${latest})"
      message="${message}
- ${app_id}: ${current} -> ${latest}"
    else
      log "App $app nemá dostupný update"
    fi
  done

  if [ "$found" -eq 1 ]; then
    tg_send "⬆️ TrueNAS watchdog: ${message}"
  fi
}

check_truenas_updates() {
  local raw
  local summary

  raw=$($MIDCLT call update.available_versions 2>/dev/null || true)
  if [ -z "$raw" ]; then
    raw=$($MIDCLT call update.check_available 2>/dev/null || true)
  fi

  if [ -z "$raw" ]; then
    log "TrueNAS update check se nepodařilo načíst"
    tg_send "⚠️ TrueNAS watchdog: nepodařilo se zkontrolovat aktualizace TrueNAS."
    return 1
  fi

  if echo "$raw" | $JQ -e '(type == "array" and length > 0) or .status == "AVAILABLE" or .available == true or .update_available == true' >/dev/null 2>&1; then
    summary=$(echo "$raw" | $JQ -r '
      if type == "array" then
        [ .[] | "\(.train): \(.version.version // .version // "unknown")" ] | join(", ")
      else
        [
          (.version // .new_version // .train // empty),
          (.changelog // .release_notes_url // empty)
        ] | map(select(. != "")) | join(" | ")
      end
    ' 2>/dev/null)
    log "TrueNAS má dostupnou aktualizaci${summary:+: $summary}"
    tg_send "⬆️ TrueNAS watchdog: je dostupná aktualizace TrueNAS${summary:+: $summary}."
  else
    log "TrueNAS nemá dostupnou aktualizaci"
  fi
}

check_truenas_health() {
  local issues=()
  local alerts
  local pools
  local unhealthy_pools

  alerts=$($MIDCLT call alert.list 2>/dev/null || true)
  if [ -n "$alerts" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && issues+=("Alert: $line")
    done < <(echo "$alerts" | $JQ -r '.[]? | select((.dismissed // false) == false) | "\(.klass // .key // "unknown"): \(.formatted // .text // .message // "bez detailu")"' 2>/dev/null)
  else
    issues+=("Nepodařilo se načíst TrueNAS alerty")
  fi

  pools=$($MIDCLT call pool.query 2>/dev/null || true)
  unhealthy_pools=$(echo "$pools" | $JQ -r '.[]? | select((.healthy // true) != true or (.status // "ONLINE") != "ONLINE") | "\(.name): status=\(.status // "unknown"), healthy=\(.healthy // "unknown")"' 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] && issues+=("Pool: $line")
  done <<< "$unhealthy_pools"

  if [ "${#issues[@]}" -eq 0 ]; then
    log "TrueNAS health OK"
    return 0
  fi

  local message="TrueNAS health problém:"
  local issue
  for issue in "${issues[@]}"; do
    log "$issue"
    message="${message}
- $issue"
  done

  tg_send "⚠️ TrueNAS watchdog: ${message}"
  return 1
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
      log "=== Kontroluji dostupné aktualizace aplikací a TrueNAS ==="
      check_app_updates
      check_truenas_updates
      ;;
    app-update)
      log "=== Spouštím update aplikací ==="
      update_apps
      ;;
    truenas-health)
      log "=== Kontroluji zdraví TrueNAS ==="
      check_truenas_health
      ;;
    *)
      echo "Použití: $0 [check|update|app-update|truenas-health]"
      exit 1
      ;;
  esac
}

main
