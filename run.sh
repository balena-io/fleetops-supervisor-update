cat batch | stdbuf -oL xargs -I{} -P 15 /bin/sh -c "cat updater.sh | balena ssh {} -s | sed 's/^/{} : /' | tee --append supervisor-update.log"
