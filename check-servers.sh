#!/bin/sh -e
# Healthcheck: every enabled listener must answer /adv. Uses busybox wget
# (GNU wget would only add packages, and their CVEs, to the image).

if [ "$ENABLE_IPv4" = "1" ]; then
    wget -q -T 2 -O /dev/null http://127.0.0.1:8080/adv
fi

if [ "$ENABLE_IPv6" = "1" ]; then
    wget -q -T 2 -O /dev/null "http://[::1]:8080/adv"
fi
