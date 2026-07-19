#!/bin/sh
set -eu
backup-images.sh
backup-db.sh
backup-config.sh
