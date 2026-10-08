#!/bin/sh
# tests/mock.sh start|stop WORKDIR   run tests/mock_api.py in the background (pid in WORKDIR/mock.pid)
cd "$(dirname "$0")/.."
W=${2:-work}
mkdir -p "$W/serve"
ln -sfn "$(pwd)" "$W/serve/dev"
case "$1" in
	start)
		[ -f "$W/mock.pid" ] && kill "$(cat "$W/mock.pid")" 2>/dev/null
		python3 tests/mock_api.py --port 8443 --log "$W/mock.jsonl" --certdir "$W" --files "$W/serve" > "$W/mock.out" 2>&1 &
		echo $! > "$W/mock.pid"
		sleep 2
		cat "$W/mock.out" ;;
	stop)
		[ -f "$W/mock.pid" ] && kill "$(cat "$W/mock.pid")" 2>/dev/null
		rm -f "$W/mock.pid" ;;
esac
