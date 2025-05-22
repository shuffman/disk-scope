#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use DBI;
use File::Find;
use File::Basename;
use Time::localtime;
use Time::Local qw(timelocal timegm);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/lib";
use Mojolicious::Lite;
use File::Spec;
use File::stat;
use Data::Dumper;
use Term::ANSIColor;

my $command = shift @ARGV || 'help';
my %opts;

if ($command eq 'analyze') {
    GetOptions(
        \%opts,
        'db=s',
        'path=s',
        'min-size=s',
    );
    analyze(%opts);
} elsif ($command eq 'list') {
    GetOptions(
        \%opts,
        'db=s',
    );
    list_runs(%opts);
} elsif ($command eq 'report') {
    GetOptions(
        \%opts,
        'db=s',
        'id=i',
        'age=s@',
        'user=s',
        'min-size=s',
    );
    report(%opts);
} elsif ($command eq 'web') {
    GetOptions(
        \%opts,
        'db=s',
    );
    web(%opts);
} else {
    show_help();
}

sub analyze {
    my (%opts) = @_;
    
    # Validate required options
    die "Missing required option: --db\n" unless $opts{'db'};
    die "Missing required option: --path\n" unless $opts{'path'};
    die "Missing required option: --min-size\n" unless $opts{'min-size'};
    
    my $db_path = $opts{'db'};
    my $scan_path = $opts{'path'};
    my $min_size_str = $opts{'min-size'};
    
    # Convert min-size to bytes
    my $min_size = parse_size($min_size_str);
    
    # Initialize database
    my $dbh = init_db($db_path);
    
    # Create a new run record
    my $username = getlogin() || getpwuid($<) || "Unknown";
    
    # Format current time
    my $start_date = format_datetime(time());
    
    $dbh->do("INSERT INTO run (start_date, user, path, min_size) VALUES (?, ?, ?, ?)",
             undef, $start_date, $username, $scan_path, $min_size_str);
    
    my $run_id = $dbh->last_insert_id("", "", "run", "");
    print "Starting analysis with run ID: $run_id\n";
    
    # Scan the directory
    my $file_count = 0;
    
    find({
        wanted => sub {
            return if -d $_;
            my $file_path = $File::Find::name;
            my $stat = stat($file_path);
            
            if ($stat && $stat->size >= $min_size) {
                my $owner = getpwuid($stat->uid) || $stat->uid;
                
                # Format modified time
                my $modified = format_datetime($stat->mtime);
                
                $dbh->do("INSERT INTO file (run_id, path, size, owner, modified) VALUES (?, ?, ?, ?, ?)",
                         undef, $run_id, $file_path, $stat->size, $owner, $modified);
                $file_count++;
                
                if ($file_count % 100 == 0) {
                    print "Processed $file_count files...\n";
                }
            }
        },
        no_chdir => 1,
    }, $scan_path);
    
    # Update run record with end date
    my $end_date = format_datetime(time());
    
    $dbh->do("UPDATE run SET end_date = ? WHERE id = ?", undef, $end_date, $run_id);
    
    print "Analysis complete. Found $file_count files >= $min_size_str\n";
    $dbh->disconnect();
}

sub list_runs {
    my (%opts) = @_;
    
    # Validate required options
    die "Missing required option: --db\n" unless $opts{'db'};
    
    my $db_path = $opts{'db'};
    my $dbh = init_db($db_path);
    
    my $sth = $dbh->prepare("SELECT id, start_date, end_date, user, path, min_size FROM run ORDER BY id");
    $sth->execute();
    
    print "\n";
    printf("%-5s %-20s %-20s %-15s %-30s %-10s\n", 
           "ID", "Start Date", "End Date", "User", "Path", "Min Size");
    print "-" x 100 . "\n";
    
    while (my $row = $sth->fetchrow_hashref) {
        printf("%-5s %-20s %-20s %-15s %-30s %-10s\n", 
               $row->{id},
               $row->{start_date} || 'N/A',
               $row->{end_date} || 'N/A',
               $row->{user} || 'N/A',
               $row->{path} || 'N/A',
               $row->{min_size} || 'N/A');
    }
    
    $dbh->disconnect();
}

sub report {
    my (%opts) = @_;
    
    # Validate required options
    die "Missing required option: --db\n" unless $opts{'db'};
    die "Missing required option: --id\n" unless $opts{'id'};
    die "Missing required option: --min-size\n" unless $opts{'min-size'};
    die "Missing required option: --age (at least one age bucket)\n" unless $opts{'age'} && @{$opts{'age'}};
    
    my $db_path = $opts{'db'};
    my $run_id = $opts{'id'};
    my $min_size_str = $opts{'min-size'};
    my $min_size = parse_size($min_size_str);
    my $user_filter = $opts{'user'};
    my @age_buckets = @{$opts{'age'}};
    
    # Initialize database
    my $dbh = init_db($db_path);
    
    # Verify run exists
    my $run = $dbh->selectrow_hashref("SELECT * FROM run WHERE id = ?", undef, $run_id);
    die "Run ID $run_id not found in database\n" unless $run;
    
    # Prepare file query
    my $sql = "SELECT path, size, owner, modified FROM file WHERE run_id = ? AND size >= ?";
    my @params = ($run_id, $min_size);
    
    if ($user_filter) {
        $sql .= " AND owner = ?";
        push @params, $user_filter;
    }
    
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    
    # Process files and organize by age buckets
    my %age_data;
    for my $bucket (@age_buckets) {
        $age_data{$bucket} = {
            files => [],
            total_size => 0,
            count => 0,
        };
    }
    
    my $now = time();
    
    while (my $file = $sth->fetchrow_hashref) {
        my $mod_time = str2time($file->{modified});
        my $age_seconds = $now - $mod_time;
        
        for my $bucket (@age_buckets) {
            my $bucket_seconds = parse_time_period($bucket);
            if ($age_seconds >= $bucket_seconds) {
                push @{$age_data{$bucket}{files}}, $file;
                $age_data{$bucket}{total_size} += $file->{size};
                $age_data{$bucket}{count}++;
            }
        }
    }
    
    # Print report
    print "\nDisk Usage Report for Run ID: $run_id\n";
    print "Path: $run->{path}\n";
    if ($user_filter) {
        print "Filtered by user: $user_filter\n";
    }
    print "Minimum file size: $min_size_str\n\n";
    
    for my $bucket (sort { parse_time_period($a) <=> parse_time_period($b) } @age_buckets) {
        my $data = $age_data{$bucket};
        print colored(['bold'], "Files older than $bucket: $data->{count} files, " . 
                     format_size($data->{total_size}) . " total\n");
        
        if ($data->{count} > 0) {
            print "-" x 100 . "\n";
            printf("%-60s %-15s %-15s %-20s\n", "Path", "Size", "Owner", "Modified");
            print "-" x 100 . "\n";
            
            for my $file (sort { $b->{size} <=> $a->{size} } @{$data->{files}}) {
                printf("%-60s %-15s %-15s %-20s\n",
                      truncate_path($file->{path}, 60),
                      format_size($file->{size}),
                      $file->{owner},
                      $file->{modified});
            }
            print "\n";
        }
    }
    
    $dbh->disconnect();
}

sub web {
    my (%opts) = @_;
    
    # Validate required options
    die "Missing required option: --db\n" unless $opts{'db'};
    
    my $db_path = $opts{'db'};
    
    # Make the database path absolute if it's not already
    $db_path = File::Spec->rel2abs($db_path) unless File::Spec->file_name_is_absolute($db_path);
    
    # Set the database path as an app variable
    app->config(db_path => $db_path);
    
    # Include the web application routes and templates
    do "$Bin/lib/WebApp.pm" or die "Failed to load WebApp.pm: $@";
    
    # Start the Mojolicious web server
    app->start('daemon', '-l', 'http://*:3000');
}

sub show_help {
    print <<EOF;
Usage: disk-scope COMMAND [OPTIONS]

Commands:
  analyze   Analyze disk usage and store results in a database
  list      List all analysis runs in the database
  report    Generate a report from a previous analysis run
  web       Start a web interface to view and analyze data

Options for 'analyze':
  --db FILE         Path to the SQLite database file
  --path DIR        Directory to analyze
  --min-size SIZE   Minimum file size to include (e.g., 100MB)

Options for 'list':
  --db FILE         Path to the SQLite database file

Options for 'report':
  --db FILE         Path to the SQLite database file
  --id NUM          ID of the analysis run to report on
  --age PERIOD      Age bucket for files (can be specified multiple times)
                    Format: Nw (weeks), Nm (months), Ny (years)
  --user USER       Optional: filter files by owner
  --min-size SIZE   Minimum file size to include in report

Options for 'web':
  --db FILE         Path to the SQLite database file

Examples:
  disk-scope analyze --db disk-scope.db --path /home/user --min-size 100MB
  disk-scope list --db disk-scope.db
  disk-scope report --db disk-scope.db --id 1 --age 1w --age 1m --age 6m --min-size 100MB
  disk-scope web --db disk-scope.db
EOF
    exit;
}

sub init_db {
    my ($db_path) = @_;
    
    my $db_exists = -f $db_path;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
        RaiseError => 1,
        AutoCommit => 1,
    }) or die "Cannot connect to database: $DBI::errstr";
    
    # Create tables if they don't exist
    unless ($db_exists) {
        $dbh->do(q{
            CREATE TABLE run (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_date TEXT,
                end_date TEXT,
                user TEXT,
                path TEXT,
                min_size TEXT
            )
        });
        
        $dbh->do(q{
            CREATE TABLE file (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER,
                path TEXT,
                size INTEGER,
                owner TEXT,
                modified TEXT,
                FOREIGN KEY (run_id) REFERENCES run(id)
            )
        });
        
        # Create indexes for better performance
        $dbh->do("CREATE INDEX idx_file_run_id ON file (run_id)");
        $dbh->do("CREATE INDEX idx_file_owner ON file (owner)");
        $dbh->do("CREATE INDEX idx_file_size ON file (size)");
        $dbh->do("CREATE INDEX idx_file_modified ON file (modified)");
    }
    
    return $dbh;
}

sub parse_size {
    my ($size_str) = @_;
    
    if ($size_str =~ /^(\d+(?:\.\d+)?)([KMGT]B?)$/i) {
        my ($num, $unit) = ($1, uc($2));
        my %multiplier = (
            'K'  => 1024,
            'KB' => 1024,
            'M'  => 1024 * 1024,
            'MB' => 1024 * 1024,
            'G'  => 1024 * 1024 * 1024,
            'GB' => 1024 * 1024 * 1024,
            'T'  => 1024 * 1024 * 1024 * 1024,
            'TB' => 1024 * 1024 * 1024 * 1024,
        );
        
        return $num * $multiplier{$unit};
    } else {
        # If no unit is specified, assume bytes
        return $size_str;
    }
}

sub format_size {
    my ($size) = @_;
    
    my @units = qw(B KB MB GB TB);
    my $i = 0;
    
    while ($size >= 1024 && $i < $#units) {
        $size /= 1024;
        $i++;
    }
    
    return sprintf("%.2f %s", $size, $units[$i]);
}

sub parse_time_period {
    my ($period) = @_;
    
    if ($period =~ /^(\d+)([wmy])$/i) {
        my ($num, $unit) = ($1, lc($2));
        my %multiplier = (
            'w' => 7 * 24 * 60 * 60,        # weeks in seconds
            'm' => 30 * 24 * 60 * 60,       # months (approx) in seconds
            'y' => 365 * 24 * 60 * 60,      # years (approx) in seconds
        );
        
        return $num * $multiplier{$unit};
    } else {
        die "Invalid time period format: $period. Use Nw (weeks), Nm (months), or Ny (years)\n";
    }
}

sub str2time {
    my ($datetime) = @_;
    
    if ($datetime =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
        my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
        return timelocal($sec, $min, $hour, $day, $month - 1, $year - 1900);
    }
    
    return 0;
}

sub truncate_path {
    my ($path, $max_length) = @_;
    
    if (length($path) <= $max_length) {
        return $path;
    }
    
    my $filename = basename($path);
    my $dir = dirname($path);
    
    # Ensure filename is shown completely if possible
    my $filename_length = length($filename);
    my $available_space = $max_length - $filename_length - 4; # 4 for ".../"
    
    if ($available_space <= 0) {
        # Filename too long, truncate it
        return "..." . substr($filename, -($max_length - 3));
    }
    
    return substr($dir, 0, $available_space) . ".../" . $filename;
}

# Format date and time in YYYY-MM-DD HH:MM:SS format
sub format_datetime {
    my ($time) = @_;
    
    my $tm = localtime($time);
    my $year = 1900 + $tm->year;
    my $month = sprintf("%02d", $tm->mon + 1);
    my $day = sprintf("%02d", $tm->mday);
    my $hour = sprintf("%02d", $tm->hour);
    my $minute = sprintf("%02d", $tm->min);
    my $second = sprintf("%02d", $tm->sec);
    
    return "$year-$month-$day $hour:$minute:$second";
} 