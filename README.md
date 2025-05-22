# disk-scope

# Overview
disk-scope is a disk analysis tool written in perl, the language of the Gods. The code should be
written in such a fashion to pay homage to the genius of the Larry Wall. It will be written using
sqlite as the persistent data store, and Mojolicious as the GUI front-end.

# Tool Modes

## analyze
Invoked as

% disk-scope analyze --db disk-scope.db --path <path> --min-size 100MB

This will create a new record in the 'run' table with the fields:

* id
* start_date
* end_date
* user
* path
* min-size

It will then scan the specified path and store any files whose size is at least the size specified in
--min-size. It should store meta information about the file: path, size, owner, last modified date


## list
Invoked as

% disk-scope list --db disk-scope.db

This will read the 'run' table in the specified database, and list all runs for which data has been
stored.


## report

% disk-scope report --db disk-scope-db --id <id> --age 1w --age 2w --age 1m --age 6m [--user <user>] --min-size 100MB

Will print out a report of files that exceed the specified minimum size. The data will be printed
in buckets for the specified ages. Optionally, if a user is specified, then only print files that belong
to the specified user.


## web

% disk-report web --db disk-scope.db

Will launch a webserver that provides an interface to the database. The server should have a modern look
and use charts where appropriate to analyze the data as intuitively as possible.

% disk-scope report --db disk-scope.d
