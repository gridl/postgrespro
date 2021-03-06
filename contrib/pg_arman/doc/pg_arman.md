# pg_arman(1) 

## NAME 

pg_arman - Backup and recovery manager for PostgreSQL

## SYNOPSIS 
```
pg_arman [ OPTIONS ]
    { init |
      backup |
      restore |
      show [ DATE | timeline ] |
      validate [ DATE ] |
      delete DATE }
```

DATE is the start time of the target backup in ISO-format:
(YYYY-MM-DD HH:MI:SS). Prefix match is used to compare DATE and backup
files.

## DESCRIPTION 

pg_arman is a utility program to backup and restore PostgreSQL database.

It proposes the following features:

- Backup while database runs including tablespaces with just one
  command
- Recovery from backup with just one command, with customized targets
  to facilitate the use of PITR.
- Support for full and differential backup + ptrack differential backup
- Management of backups with integrated catalog

## COMMANDS 

pg_arman supports the following commands. See also **OPTIONS** for more
details.

* **init**:  
	Initialize a backup catalog.

* **backup**:  
	Take an online backup.

* **restore**:  
	Perform restore.

* **show**:  
	Show backup history. The timeline option shows timeline of the backup and the parent's timeline for each backup.

* **validate**:  
    Validate backup files.

* **delete**:  
	Delete backup files.

### INITIALIZATION 

First, you need to create "a backup catalog" to store backup files and
their metadata. It is recommended to setup archive_mode and archive_command
in postgresql.conf before initializing the backup catalog. If the variables
are initialized, pg_arman can adjust the config file to the setting. In this
case, you have to specify the database cluster path for PostgreSQL. Please
specify it in PGDATA environmental variable or -D/--pgdata option.

```
$ pg_arman init -B /path/to/backup/
```

### BACKUP 

Backup target can be one of the following types:

- Full backup, backup a whole database cluster.
- Differential backup, backup only files or pages modified after the last
verified backup. A scan of the WAL records since the last backup up to the
LSN position of pg_start_backup is done and all the blocks touched are
recorded and tracked as part of the backup. As the WAL segments scanned
need to be located in the WAL archive, the last segment after pg_start_backup
has been run needs to be forcibly switched.
- ptrack differential backup, use bitmap ptrack file for detect changed pages.
For use it you need set ptrack_enable option to "on".

It is recommended to verify backup files as soon as possible after backup.
Unverified backup cannot be used in restore and in differential backups.

### RESTORE 

PostgreSQL server should be stopped before performing a restore. If database
cluster still exists, restore command will save unarchived transaction log
and delete all database files. You can retry recovery until a new backup is
taken. After restoring files, pg_arman creates recovery.conf in $PGDATA. The
conf file contains parameters for recovery. It is as well possible to modify
the file manually.

It is recommended to take a full backup as soon as possible after recovery
has succeeded.

If "--recovery-target-timeline" is not specifed, the last checkpoint's
TimeLineID in control file ($PGDATA/global/pg_control) will be the restore
target. If pg_control is not present, TimeLineID in the full backup used by
the restore will be a restore target.


### EXAMPLES 

To reduce the number of command line arguments, you can set BACKUP_PATH,
an environment variable, to the absolute path of the backup catalog and
write default configuration into ${BACKUP_PATH}/pg_arman.ini.

```
$ cat $BACKUP_PATH/pg_arman.ini
ARCLOG_PATH = /home/postgres/arclog
BACKUP_MODE = FULL
KEEP_DATA_GENERATIONS = 3
KEEP_DATA_DAYS = 120
```

### TAKE A BACKUP 

This example takes a full backup of the whole database. Then, it validates
all unvalidated backups.
```
$ pg_arman backup --backup-mode=full
$ pg_arman validate
```

### RESTORE FROM A BACKUP 

Here are some commands to restore from a backup:

```
$ pg_ctl stop -m immediate
$ pg_arman restore
$ pg_ctl start
```

### SHOW A BACKUP 
```
$ pg_arman show
===================================================================================
Start                Mode  Current TLI  Parent TLI  Time    Data   Backup   Status 
===================================================================================
2013-12-25 03:02:31  PAGE            1           0    0m   203kB     67MB   DONE
2013-12-25 03:02:31  PAGE            1           0    0m      0B       0B   ERROR
2013-12-25 03:02:25  FULL            1           0    0m    33MB    364MB   OK
```
The fields are:

* Start: start time of backup
* Mode: Mode of backup: FULL (full) or PAGE (page differential) or PTRACK (differential by ptrack)
* Current TLI: current timeline of backup
* Parent TLI: parent timeline of backup
* Time: total time necessary to take this backup
* Data: size of data files
* Log: size of read server log files
* Backup: size of backup (= written size)
* Status: status of backup. Possible values are:
	* OK : backup is done and validated.
	* DONE : backup is done, but not validated yet.
	* RUNNING : backup is running
	* DELETING : backup is being deleted.
	* DELETED : backup has been deleted.
	* ERROR : backup is unavailable because some errors occur during backup.
	* CORRUPT : backup is unavailable because it is broken.

When a date is specified, more details about a backup is retrieved:

```
$ pg_arman show '2011-11-27 19:15:45'
# configuration
BACKUP_MODE=FULL
# result
TIMELINEID=1
START_LSN=0/08000020
STOP_LSN=0/080000a0
START_TIME='2011-11-27 19:15:45'
END_TIME='2011-11-27 19:19:02'
RECOVERY_XID=1759
RECOVERY_TIME='2011-11-27 19:15:53'
DATA_BYTES=25420184
BLOCK_SIZE=8192
XLOG_BLOCK_SIZE=8192
STATUS=OK
```

You can check the "RECOVERY_XID" and "RECOVERY_TIME" which are used for
restore option "--recovery-target-xid", "--recovery-target-time".

The delete command deletes backup files not required by recovery after
the specified date. This command also cleans up in the WAL archive the
WAL segments that are no longer needed to restore from the remaining
backups.

### OPTIONS 

pg_arman accepts the following command line parameters. Some of them can
be also specified as environment variables. See also *PARAMETERS* for the
details.

### COMMON OPTIONS 
As a general rule, paths for data location need to be specified as
absolute paths; relative paths are not allowed.

**-D** PATH / **--pgdata**=PATH:  
    The absolute path of database cluster. Required on backup and
    restore.

**-A** PATH / **--arclog-path**=PATH:  
    The absolute path of archive WAL directory. Required for restore
    and show command.

**-B** PATH / **--backup-path**=PATH:  
    The absolute path of backup catalog. This option is mandatory.

**-c** / **--check**:  
    If specifed, pg_arman doesn't perform actual jobs but only checks
    parameters and required resources. The option is typically used with
    --verbose option to verify the operation.

### BACKUP OPTIONS

**-b** BACKUPMODE / **--backup-mode**=BACKUPMODE:  
    Specify backup target files. Available options are: "full",
    "page", "ptrack".

**-C** / **--smooth-checkpoint**:  
    Checkpoint is performed on every backups. If the option is specified,
    do smooth checkpoint then. See also the second argument for
    pg_start_backup().

**--validate**:  
    Validate a backup just after taking it. Other backups taken
    previously are ignored.

**--keep-data-generations**=NUMBER / **--keep-data-days**=DAYS:  
    Specify how long backuped data files will be kept.
    --keep-data-generations means number of backup generations.
    --keep-data-days means days to be kept.
    Only files exceeded one of those settings are deleted.

**-j**=NUMBER / **--threads**=NUMBER:
    Number of threads for backup. 

**--stream**:
	Enable stream replication for save WAL during backup process.

**--disable-ptrack-clear**:
	Disable clear ptrack files for postgres without ptrack patch.

### RESTORE OPTIONS 

The parameters whose name start are started with --recovery refer to
the same parameters as the ones in recovery.confin recovery.conf.

**--recovery-target-timeline**=_TIMELINE_:  
    Specifies recovering into a particular timeline. If not specified,
    the current timeline is used.

**--recovery-target-time**=TIMESTAMP:  
    This parameter specifies the timestamp up to which recovery will
    proceed.

**--recovery-target-xid**=XID:  
    This parameter specifies the transaction ID up to which recovery
    will proceed.

**--recovery-target-inclusive**:  
    Specifies whether server pauses when recovery target is reached.

**-j**=NUMBER / **--threads**=NUMBER:
    Number of threads for restore. 

**--stream**:
    Restore without recovery.conf and use pg_xlog WALs. Before you need 
    backup with **--stream** option. This option will disable all **--recovery-**
	options.

### CATALOG OPTIONS

**-a** / **--show-all**:  
    Show all existing backups, including the deleted ones.

### CONNECTION OPTIONS 
Parameters to connect PostgreSQL server.

**-d** DBNAME / **--dbname**=DBNAME:  
    The database name to execute pg_start_backup() and pg_stop_backup().

**-h** HOSTNAME / **--host**=HOSTNAME:  
    Specifies the host name of the machine on which the server is running.
    If the value begins with a slash, it is used as the directory for the
    Unix domain socket.

**-p** PORT / **--port**=PORT:  
    Specifies the TCP port or local Unix domain socket file extension on
    which the server is listening for connections.

**-U** USERNAME / **--username**=USERNAME:  
    User name to connect as.

**-w** / **--no-password**:  
    Never issue a password prompt. If the server requires password
    authentication and a password is not available by other means such as
    a .pgpass file, the connection attempt will fail. This option can be
    useful in batch jobs and scripts where no user is present to enter a
    password.

**-W** / **--password**:  
    Force pg_arman to prompt for a password before connecting to a database.
    This option is never essential, since pg_arman will automatically
    prompt for a password if the server demands password authentication.
    However, pg_arman will waste a connection attempt in order to find out
    if the server wants a password. In some cases it is worth typing -W
    to avoid the extra connection attempt.

### GLOBAL OPTIONS 

**--help**:  
    Print help, then exit.

**-V** / **--version**:  
    Print version information, then exit.

**-v** / **--verbose**:  
    If specified, pg_arman works in verbose mode.

## PARAMETERS 

Some of parameters can be specified as command line arguments, environment
variables or in configuration file as follows:
```
Short   Long                    Env                     File
-h      --host                  PGHOST                  No
-p      --port                  PGPORT                  No
-d      --dbname                PGDATABASE              No
-U      --username              PGUSER                  No
                                PGPASSWORD              No
-w      --password                                      No
-W      --no-password                                   No
-D      --pgdata                PGDATA                  Yes
-B      --backup-path           BACKUP_PATH             Yes
-A      --arclog-path           ARCLOG_PATH             Yes
-b      --backup-mode           BACKUP_MODE             Yes
-C      --smooth-checkpoint     SMOOTH_CHECKPOINT       Yes
        --validate              VALIDATE                Yes
        --keep-data-generations KEEP_DATA_GENERATIONS   Yes
        --keep-data-days        KEEP_DATA_DAYS          Yes
        --recovery-target-timeline RECOVERY_TARGET_TIMELINE Yes
        --recovery-target-xid   RECOVERY_TARGET_XID     Yes
        --recovery-target-time  RECOVERY_TARGET_TIME    Yes
        --recovery-target-inclusive RECOVERY_TARGET_INCLUSIVE Yes
```

Variable names in configuration file are the same as long names or names
of environment variables. The password can not be specified in command
line and configuration file for security reason.

This utility, like most other PostgreSQL utilities, also uses the
environment variables supported by libpq (see Environment Variables).

## RESTRICTIONS

pg_arman has the following restrictions.

- Requires to read database cluster directory and write backup catalog
  directory. It is usually necessary to mount the disk where backup
  catalog is placed with NFS or related from database server.
- Major versions of pg_arman and server should match.
- Block sizes of pg_arman and server should match.
- If there are some unreadable files/directories in data folder of server
  WAL directory or archived WAL directory, the backup or restore will fail
  depending on the backup mode selected.

## DETAILS

### RECOVERY TO POINT-IN-TIME 
pg_arman can recover to point-in-time if timeline, transaction ID, or
timestamp is specified in recovery.conf. xlogdump is a contrib module of
PostgreSQL core that allows checking in the content of WAL files and
determine when to recover. This might help.

### CONFIGURATION FILE 
Setting parameters in configuration file is done as "name=value". Quotes
are required if the value contains whitespaces. Comments should start with
"#" and are automatically ignored. Whitespaces and tabs are ignored
excluding values.

### RESTRICTIONS
* In order to work, the PostgreSQL instance on which backups are taken need
to have data checksums enabled or to enable wal_log_hints.
* pg_arman is aimed at working with PostgreSQL 9.5 and newer versions.
* For ptrack feature you need special version of Postgres and set wal_level to
archive or hot_standby and ptrack_enable.
* For stream feature you need configure streaming replication in your postgres. 

### EXIT CODE 
pg_arman returns exit codes for each error status.

```
Code    Name                    Description
0       SUCCESS                 Operation succeeded.
1       ERROR                   Generic error
2       FATAL                   Exit because of repeated errors
3       PANIC                   Unknown critical condition
```

## AUTHOR ##
pg_arman is a fork of pg_arman that was originally written by NTT, now
developed and maintained by Michael Paquier.
Threads, WAL diff, ptrack diff, stream WAL and some other features developed by
Yury Zhuravlev aka stalkerg from PostgresPro. 

Please report bug reports at <https://github.com/postgrespro/pg_arman/issues>.
