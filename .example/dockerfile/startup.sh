#! /bin/bash

set -eu
if [ -n "$DEBUG" ]; then touch .debug; else rm -f .debug; fi
backup
exec busybox crond -f -l 0 -L /dev/stdout
