#!/bin/sh
bash -c 'mysql() { command mysql --socket=/var/lib/mysql/mysql.sock "$@"; }; . /automation/original-initialize-database.sh'
