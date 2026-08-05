#!/bin/sh
MYSQL_UNIX_PORT="${MYSQL_UNIX_PORT:-/var/lib/mysql/mysql.sock}" bash /automation/original-initialize-database.sh
