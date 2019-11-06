#!/bin/bash

set -o errexit -o pipefail

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile

# Linking to a specific git commit sha to always be sure what version of the files are pulled
URLBASE="https://raw.githubusercontent.com/balena-io-playground/fleetops-supervisor-update/c29ddcc98d975ca0130de03237e03bb67c4f0199"
DOWNLOADS=(xzdec.gz rdiff.xz checksums.txt)
TARGET_VERSION="v6.6.11_logstream"

setup_logfile() {
    local workdir=$1
    LOGFILE="${workdir}/supervisorupdate.$(date +"%Y%m%d_%H%M%S").log"
    touch "$LOGFILE"
    tail -f "$LOGFILE" &
    # this is global
    tail_pid=$!
    # redirect all logs to the logfile
    exec 1>> "$LOGFILE" 2>&1
}

stop_upervisor() {
    systemctl stop resin-supervisor || true
    docker rm -f resin_supervisor || true
    systemctl stop update-resin-supervisor.timer || true
}

retry_download() {
    local url=$1
    local curl_retval
    echo "Downloading: ${url}"
    # Song and dance for curl's strange behaviour with 416 response
    curl -C- --fail -O "$url" || curl_retval=$?
    # This return code 22 is a 416 response, that is not a fail, but success
    if [ -n "$curl_retval" ] && [ "$curl_retval" -eq 22 ]; then
        echo "Aready downloaded"
    else
        while [ -n "$curl_retval" ] && [ "$curl_retval" -ne 22 ]; do
            sleep 5;
            echo "Retrying download";
            curl -C- --fail -O "$url" || curl_retval=$?
        done
    fi
}

update_supervisor() {
    echo "Updating the supervisor"
    sed -e "s|SUPERVISOR_TAG=.*|SUPERVISOR_TAG=${TARGET_VERSION}|" /etc/resin-supervisor/supervisor.conf > /tmp/update-supervisor.conf
    sed -i -e "s|SUPERVISOR_TAG=.*|SUPERVISOR_TAG=${TARGET_VERSION}|" /etc/resin-supervisor/supervisor.conf
    # Needed for OS versions that normally have supervisor v4.x
    docker tag "resin/armv7hf-supervisor:${TARGET_VERSION}" resin/armv7hf-supervisor:latest
    systemctl start resin-supervisor
    update_supervisor_in_api
    systemctl restart update-resin-supervisor.timer
}

update_supervisor_in_api() {
    CONFIGJSON=/mnt/boot/config.json
    TAG=${TARGET_VERSION}
    APIKEY="$(jq -r '.apiKey // .deviceApiKey' "${CONFIGJSON}")"
    DEVICEID="$(jq -r '.deviceId' "${CONFIGJSON}")"
    API_ENDPOINT="$(jq -r '.apiEndpoint' "${CONFIGJSON}")"
    SLUG="$(jq -r '.deviceType' "${CONFIGJSON}")"
    while ! SUPERVISOR_ID=$(curl -s "${API_ENDPOINT}/v3/supervisor_release?\$select=id,image_name&\$filter=((device_type%20eq%20'$SLUG')%20and%20(supervisor_version%20eq%20'$TAG'))&apikey=${APIKEY}" | jq -e -r '.d[0].id'); do
        echo "Retrying..."
        sleep 5
    done
    echo "Extracted supervisor ID: $SUPERVISOR_ID; setting in the API"
    while ! curl -s "${API_ENDPOINT}/v2/device($DEVICEID)?apikey=$APIKEY" -X PATCH -H 'Content-Type: application/json;charset=UTF-8' --data-binary "{\"supervisor_release\": \"$SUPERVISOR_ID\"}" ; do
        echo "Retrying..."
        sleep 5
    done
}

finish_up() {
    local failure=$1
    local exit_code=0
    if [ -n "${failure}" ]; then
        echo "Fail: ${failure}"
        exit_code=1
    fi
    sleep 2
    kill $tail_pid || true
    exit ${exit_code}
}

main() {
    workdir="/mnt/data/ops"
    mkdir -p "${workdir}" && cd "${workdir}"

    # also sets tail_pid
    setup_logfile "${workdir}"

    # load supervisor version: SUPERVISOR_TAG, SUPERVISOR_IMAGE variables
    # shellcheck disable=SC1091
    source /etc/resin-supervisor/supervisor.conf
    if [ "${SUPERVISOR_TAG}" = "${TARGET_VERSION}" ]; then
        echo "Already updated to ${TARGET_VERSION}, nothing to do."
        finish_up
    fi
    delta_name="${SUPERVISOR_TAG}-${TARGET_VERSION}.delta"
    delta_url="${URLBASE}/deltas/${delta_name}.xz"
    echo "Delta URL: ${delta_url}"

    # shellcheck disable=SC1083
    if [ "$(curl -s --head -w %{http_code} "${delta_url}" -o /dev/null)" = "200" ]; then
        echo "Delta found!"
        DOWNLOADS+=("deltas/${delta_name}.xz")
    else
        finish_up "Delta NOT found, bailing!"
    fi

    for item in "${DOWNLOADS[@]}" ; do
        retry_download "${URLBASE}/${item}"
    done

    # Prepare executables
    gunzip -f xzdec.gz && chmod +x xzdec
    ./xzdec rdiff.xz > rdiff && chmod +x rdiff

    # Extract delta
    ./xzdec "${delta_name}.xz" > "${delta_name}"

    current_supervisor="${SUPERVISOR_IMAGE}:${SUPERVISOR_TAG}"
    output_file="${SUPERVISOR_TAG}"

    echo "Docker save of original supervisor started"
    docker save "${current_supervisor}" > "${output_file}" || finish_up "Docker save error"

    # Work in a subdirectory
    rm -rf workdir || true
    mkdir workdir
    cd workdir
    tar -xf "../${output_file}"
    # shellcheck disable=SC2038
    calculated_sha=$(find . -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}'|xargs cat | sha256sum | awk '{ print $1}')
    shipped_sha=$(grep "${SUPERVISOR_TAG}$" ../checksums.txt | awk '{ print $1}')
    if [ "$shipped_sha" != "$calculated_sha" ]; then
        finish_up "Integrity check failure. Expected ${shipped_sha} : got ${calculated_sha}"
    else
        echo "Integrity check okay"
    fi
    # Create delta base
    # shellcheck disable=SC2038
    find . -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}' | xargs cat > delta-base

    ../rdiff patch delta-base "../${delta_name}" "../${TARGET_VERSION}.tar"

    stop_upervisor

    echo "Docker load"
    docker load -i "../${TARGET_VERSION}.tar" || finish_up "Docker load error"

    update_supervisor

    echo "Cleaning up"
    rm -rf /mnt/data/ops/workdir || true
    find /mnt/data/ops -type f ! -name "*.log" -exec rm -rf {} \;

    echo "Finished"

    finish_up
}

(
  # Check if already running and bail if yes
  flock -n 99 || (echo "Already running script..."; exit 1)
  main
) 99>/tmp/updater.lock
# Proper exit, required due to the locking subshell
exit $?
