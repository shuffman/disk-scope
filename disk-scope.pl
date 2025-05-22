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
    my $run_sth = $dbh->prepare("SELECT * FROM run WHERE id = ?");
    $run_sth->execute($run_id);
    my $run = $run_sth->fetchrow_hashref;
    
    unless ($run) {
        $run_sth->finish();
        $dbh->disconnect();
        die "Run ID $run_id not found in database\n";
    }
    $run_sth->finish();
    
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
    $sth->finish();
    
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
    
    # Remove any existing Mojolicious instance and start fresh
    no warnings 'once';
    undef $Mojolicious::Lite::APP;
    
    # Initialize a new Mojolicious app
    use Mojolicious::Lite -signatures;
    
    # Set up app configuration
    app->config(db_path => $db_path);
    app->log->level('info');
    
    # Set up static file serving
    app->static->paths->[0] = "$Bin/public";
    
    # Define route for home page
    get '/' => sub ($c) {
        return $c->render(template => 'index');
    };
    
    # Diagnostics route
    get '/diagnostics' => sub ($c) {
        return $c->render(template => 'diagnostics');
    };
    
    # Test run data route
    get '/test_run' => sub ($c) {
        return $c->render(template => 'test_run');
    };
    
    # API route to get all runs
    get '/api/runs' => sub ($c) {
        my $dbh = _get_db_connection($c->app->config('db_path'));
        
        my $sth = $dbh->prepare("SELECT id, start_date, end_date, user, path, min_size FROM run ORDER BY id DESC");
        $sth->execute();
        
        my @runs;
        while (my $row = $sth->fetchrow_hashref) {
            # Add file counts and total size for each run
            my $count_sth = $dbh->prepare("SELECT COUNT(*) as file_count, SUM(size) as total_size FROM file WHERE run_id = ?");
            $count_sth->execute($row->{id});
            my $count_data = $count_sth->fetchrow_hashref;
            
            $row->{file_count} = $count_data->{file_count} || 0;
            $row->{total_size} = $count_data->{total_size} || 0;
            $row->{formatted_size} = format_size($row->{total_size});
            
            push @runs, $row;
        }
        
        $dbh->disconnect();
        
        $c->render(json => \@runs);
    };
    
    # API route to get details for a specific run
    get '/api/runs/:id' => sub ($c) {
        my $run_id = $c->param('id');
        my $dbh = _get_db_connection($c->app->config('db_path'));
        
        my $run_sth = $dbh->prepare("SELECT * FROM run WHERE id = ?");
        $run_sth->execute($run_id);
        my $run = $run_sth->fetchrow_hashref;
        
        unless ($run) {
            $run_sth->finish();
            $dbh->disconnect();
            return $c->render(json => { error => "Run ID $run_id not found" }, status => 404);
        }
        $run_sth->finish();
        
        # Get file statistics
        my $stats = {
            total_files => 0,
            total_size => 0,
            size_distribution => {
                '< 1MB' => { count => 0, size => 0 },
                '1-10MB' => { count => 0, size => 0 },
                '10-100MB' => { count => 0, size => 0 },
                '100MB-1GB' => { count => 0, size => 0 },
                '> 1GB' => { count => 0, size => 0 },
            },
            age_distribution => {
                '< 1 week' => { count => 0, size => 0 },
                '1-4 weeks' => { count => 0, size => 0 },
                '1-3 months' => { count => 0, size => 0 },
                '3-6 months' => { count => 0, size => 0 },
                '> 6 months' => { count => 0, size => 0 },
            },
            owner_distribution => {},
        };
        
        my $files_sth = $dbh->prepare("SELECT * FROM file WHERE run_id = ?");
        $files_sth->execute($run_id);
        
        my $now = time();
        
        while (my $file = $files_sth->fetchrow_hashref) {
            $stats->{total_files}++;
            $stats->{total_size} += $file->{size};
            
            # Size distribution
            my $size_mb = $file->{size} / (1024 * 1024);
            if ($size_mb < 1) {
                $stats->{size_distribution}{'< 1MB'}{count}++;
                $stats->{size_distribution}{'< 1MB'}{size} += $file->{size};
            } elsif ($size_mb < 10) {
                $stats->{size_distribution}{'1-10MB'}{count}++;
                $stats->{size_distribution}{'1-10MB'}{size} += $file->{size};
            } elsif ($size_mb < 100) {
                $stats->{size_distribution}{'10-100MB'}{count}++;
                $stats->{size_distribution}{'10-100MB'}{size} += $file->{size};
            } elsif ($size_mb < 1024) {
                $stats->{size_distribution}{'100MB-1GB'}{count}++;
                $stats->{size_distribution}{'100MB-1GB'}{size} += $file->{size};
            } else {
                $stats->{size_distribution}{'> 1GB'}{count}++;
                $stats->{size_distribution}{'> 1GB'}{size} += $file->{size};
            }
            
            # Age distribution
            my $mod_time = str2time($file->{modified});
            my $age_seconds = $now - $mod_time;
            my $age_days = $age_seconds / (24 * 60 * 60);
            
            if ($age_days < 7) {
                $stats->{age_distribution}{'< 1 week'}{count}++;
                $stats->{age_distribution}{'< 1 week'}{size} += $file->{size};
            } elsif ($age_days < 28) {
                $stats->{age_distribution}{'1-4 weeks'}{count}++;
                $stats->{age_distribution}{'1-4 weeks'}{size} += $file->{size};
            } elsif ($age_days < 90) {
                $stats->{age_distribution}{'1-3 months'}{count}++;
                $stats->{age_distribution}{'1-3 months'}{size} += $file->{size};
            } elsif ($age_days < 180) {
                $stats->{age_distribution}{'3-6 months'}{count}++;
                $stats->{age_distribution}{'3-6 months'}{size} += $file->{size};
            } else {
                $stats->{age_distribution}{'> 6 months'}{count}++;
                $stats->{age_distribution}{'> 6 months'}{size} += $file->{size};
            }
            
            # Owner distribution
            my $owner = $file->{owner} || 'unknown';
            $stats->{owner_distribution}{$owner} ||= { count => 0, size => 0 };
            $stats->{owner_distribution}{$owner}{count}++;
            $stats->{owner_distribution}{$owner}{size} += $file->{size};
        }
        $files_sth->finish();
        
        # Format sizes
        $stats->{formatted_total_size} = format_size($stats->{total_size});
        
        foreach my $category (keys %{$stats->{size_distribution}}) {
            $stats->{size_distribution}{$category}{formatted_size} = 
                format_size($stats->{size_distribution}{$category}{size});
        }
        
        foreach my $category (keys %{$stats->{age_distribution}}) {
            $stats->{age_distribution}{$category}{formatted_size} = 
                format_size($stats->{age_distribution}{$category}{size});
        }
        
        foreach my $owner (keys %{$stats->{owner_distribution}}) {
            $stats->{owner_distribution}{$owner}{formatted_size} = 
                format_size($stats->{owner_distribution}{$owner}{size});
        }
        
        # Get top files by size
        my $top_files_sth = $dbh->prepare("SELECT * FROM file WHERE run_id = ? ORDER BY size DESC LIMIT 100");
        $top_files_sth->execute($run_id);
        
        my @top_files;
        while (my $file = $top_files_sth->fetchrow_hashref) {
            $file->{formatted_size} = format_size($file->{size});
            push @top_files, $file;
        }
        $top_files_sth->finish();
        
        $stats->{top_files} = \@top_files;
        
        $dbh->disconnect();
        
        $c->render(json => {
            run => $run,
            stats => $stats,
        });
    };
    
    # API route to get data for visualizations
    get '/api/runs/:id/visualization/:type' => sub ($c) {
        my $run_id = $c->param('id');
        my $viz_type = $c->param('type');
        my $dbh = _get_db_connection($c->app->config('db_path'));
        
        my $data;
        
        if ($viz_type eq 'size_distribution') {
            my $query = "SELECT 
                CASE 
                    WHEN size < 1048576 THEN '< 1MB'
                    WHEN size < 10485760 THEN '1-10MB'
                    WHEN size < 104857600 THEN '10-100MB'
                    WHEN size < 1073741824 THEN '100MB-1GB'
                    ELSE '> 1GB'
                END as category,
                COUNT(*) as count,
                SUM(size) as total_size
                FROM file 
                WHERE run_id = ?
                GROUP BY category
                ORDER BY 
                CASE category
                    WHEN '< 1MB' THEN 1
                    WHEN '1-10MB' THEN 2
                    WHEN '10-100MB' THEN 3
                    WHEN '100MB-1GB' THEN 4
                    WHEN '> 1GB' THEN 5
                END";
            
            my $sth = $dbh->prepare($query);
            $sth->execute($run_id);
            
            my @categories;
            my @counts;
            my @sizes;
            
            while (my $row = $sth->fetchrow_hashref) {
                push @categories, $row->{category};
                push @counts, $row->{count};
                push @sizes, $row->{total_size};
            }
            $sth->finish();
            
            $data = {
                categories => \@categories,
                counts => \@counts,
                sizes => \@sizes,
                formatted_sizes => [map { format_size($_) } @sizes],
            };
        } elsif ($viz_type eq 'owner_distribution') {
            my $query = "SELECT 
                owner, 
                COUNT(*) as count,
                SUM(size) as total_size
                FROM file 
                WHERE run_id = ?
                GROUP BY owner
                ORDER BY total_size DESC
                LIMIT 10";
            
            my $sth = $dbh->prepare($query);
            $sth->execute($run_id);
            
            my @owners;
            my @counts;
            my @sizes;
            
            while (my $row = $sth->fetchrow_hashref) {
                push @owners, $row->{owner} || 'unknown';
                push @counts, $row->{count};
                push @sizes, $row->{total_size};
            }
            $sth->finish();
            
            $data = {
                owners => \@owners,
                counts => \@counts,
                sizes => \@sizes,
                formatted_sizes => [map { format_size($_) } @sizes],
            };
        } elsif ($viz_type eq 'extension_distribution') {
            # Get total size for percentage calculation
            my $total_sth = $dbh->prepare("SELECT SUM(size) as total_size FROM file WHERE run_id = ?");
            $total_sth->execute($run_id);
            my $total_row = $total_sth->fetchrow_hashref;
            my $total_size = $total_row->{total_size} || 1; # Avoid division by zero
            $total_sth->finish();
            
            # Extract file extensions and group by them
            my $query = "SELECT 
                LOWER(CASE 
                    WHEN path LIKE '%.%' THEN SUBSTR(path, INSTR(path, '.', -1) + 1)
                    ELSE 'no extension'
                END) as extension,
                COUNT(*) as count,
                SUM(size) as total_size
                FROM file 
                WHERE run_id = ?
                GROUP BY extension
                ORDER BY total_size DESC
                LIMIT 10";
            
            my $sth = $dbh->prepare($query);
            $sth->execute($run_id);
            
            my @extensions;
            my @counts;
            my @sizes;
            my @percentages;
            
            while (my $row = $sth->fetchrow_hashref) {
                push @extensions, $row->{extension};
                push @counts, $row->{count};
                push @sizes, $row->{total_size};
                push @percentages, ($row->{total_size} / $total_size) * 100;
            }
            $sth->finish();
            
            $data = {
                extensions => \@extensions,
                counts => \@counts,
                sizes => \@sizes,
                percentages => \@percentages,
                formatted_sizes => [map { format_size($_) } @sizes],
            };
        }
        
        $dbh->disconnect();
        
        $c->render(json => $data);
    };
    
    # Helper function to get database connection
    sub _get_db_connection {
        my ($db_path) = @_;
        
        return DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
            RaiseError => 1,
            AutoCommit => 1,
        }) or die "Cannot connect to database: $DBI::errstr";
    }
    
    # Create templates directory if it doesn't exist
    my $template_dir = "$Bin/templates";
    mkdir $template_dir unless -d $template_dir;
    
    # Create index template if it doesn't exist
    my $index_file = "$template_dir/index.html.ep";
    unless (-f $index_file) {
        open my $fh, '>', $index_file or die "Could not open $index_file: $!";
        print $fh <<'EOT';
<!DOCTYPE html>
<html>
<head>
  <title>Disk Scope</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0-alpha1/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body>
  <div class="container">
    <h1 class="mt-4 mb-4">Disk Scope</h1>
    
    <div class="row">
      <div class="col-md-12">
        <div class="card">
          <div class="card-header">Analysis Runs</div>
          <div class="card-body">
            <div id="loader">Loading runs...</div>
            <div id="runs-list"></div>
          </div>
        </div>
      </div>
    </div>
  </div>
  
  <script>
    document.addEventListener('DOMContentLoaded', function() {
      fetch('/api/runs')
        .then(response => response.json())
        .then(runs => {
          const runsList = document.getElementById('runs-list');
          document.getElementById('loader').style.display = 'none';
          
          if (runs.length === 0) {
            runsList.innerHTML = '<p>No analysis runs found. Use the command-line tool to create one.</p>';
            return;
          }
          
          let html = '<ul class="list-group">';
          runs.forEach(run => {
            html += `
              <li class="list-group-item">
                <div class="d-flex justify-content-between">
                  <div>
                    <strong>Run #${run.id}</strong><br>
                    <small>${run.path}</small>
                  </div>
                  <div class="text-end">
                    <span class="badge bg-primary">${run.file_count} files</span><br>
                    <small>${run.formatted_size}</small>
                  </div>
                </div>
              </li>
            `;
          });
          html += '</ul>';
          
          runsList.innerHTML = html;
        })
        .catch(error => {
          console.error('Error:', error);
          document.getElementById('loader').innerHTML = 
            '<div class="alert alert-danger">Error loading runs</div>';
        });
    });
  </script>
</body>
</html>
EOT
        close $fh;
    }
    
    # Start the web server
    app->start('daemon', '-l', 'http://*:3001');
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