package WebApp;

use strict;
use warnings;
use DBI;
use JSON;
use Data::Dumper;
use Time::localtime;
use Time::Local qw(timelocal);
use POSIX qw(strftime);
use Mojolicious::Lite;

# Routes for the web interface
get '/' => sub {
    my $c = shift;
    $c->render(template => 'index', format => 'html');
};

# Diagnostics route
get '/diagnostics' => sub {
    my $c = shift;
    return $c->render(template => 'diagnostics');
};

# API route to get all runs
get '/api/runs' => sub {
    my $c = shift;
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
        $count_sth->finish();
    }
    $sth->finish();
    
    $dbh->disconnect();
    
    $c->render(json => \@runs);
};

# API route to get details for a specific run
get '/api/runs/:id' => sub {
    my $c = shift;
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
get '/api/runs/:id/visualization/:type' => sub {
    my $c = shift;
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
        
        $data = {
            categories => \@categories,
            counts => \@counts,
            sizes => \@sizes,
            formatted_sizes => [map { format_size($_) } @sizes],
        };
        $sth->finish();
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
        
        $data = {
            owners => \@owners,
            counts => \@counts,
            sizes => \@sizes,
            formatted_sizes => [map { format_size($_) } @sizes],
        };
        $sth->finish();
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

# Helper function to parse date string to timestamp
sub str2time {
    my ($datetime) = @_;
    
    if ($datetime =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
        my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
        return timelocal($sec, $min, $hour, $day, $month - 1, $year - 1900);
    }
    
    return 0;
}

# Helper function to format file sizes
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

# Create index.html.ep template file if it doesn't exist
my $template_file = app->home->rel_file('templates/index.html.ep');
unless (-f $template_file) {
    open my $fh, '>', $template_file or die "Could not open $template_file: $!";
    print $fh <<'EOT';
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>disk-scope - Disk Analysis Tool</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0-alpha1/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body {
            padding-top: 20px;
            padding-bottom: 40px;
            background-color: #f8f9fa;
        }
        .navbar-brand {
            font-weight: bold;
        }
        .card {
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .card-header {
            font-weight: bold;
            background-color: #f1f8ff;
        }
        .table th {
            position: sticky;
            top: 0;
            background-color: #f8f9fa;
        }
        .chart-container {
            position: relative;
            height: 300px;
            margin-bottom: 20px;
        }
        .run-item {
            cursor: pointer;
            transition: background-color 0.2s;
        }
        .run-item:hover {
            background-color: #f1f8ff;
        }
        .run-item.active {
            background-color: #e2f0ff;
            border-left: 4px solid #0d6efd;
        }
        .file-table {
            max-height: 400px;
            overflow-y: auto;
        }
        #loader {
            display: flex;
            justify-content: center;
            align-items: center;
            height: 200px;
        }
        .spinner-border {
            width: 3rem;
            height: 3rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <nav class="navbar navbar-expand-lg navbar-light bg-light mb-4">
            <div class="container-fluid">
                <a class="navbar-brand" href="#">disk-scope</a>
                <span class="navbar-text">
                    A Perl Disk Analysis Tool
                </span>
            </div>
        </nav>

        <div class="row">
            <!-- Runs List -->
            <div class="col-md-4">
                <div class="card">
                    <div class="card-header">Analysis Runs</div>
                    <div class="card-body p-0">
                        <div id="loader">
                            <div class="spinner-border text-primary" role="status">
                                <span class="visually-hidden">Loading...</span>
                            </div>
                        </div>
                        <ul id="runs-list" class="list-group list-group-flush">
                            <!-- Runs will be loaded here -->
                        </ul>
                    </div>
                </div>
            </div>

            <!-- Run Details -->
            <div class="col-md-8">
                <div id="run-details" style="display: none;">
                    <div class="card">
                        <div class="card-header">Run Details</div>
                        <div class="card-body">
                            <h5 id="run-path" class="card-title"></h5>
                            <div class="row">
                                <div class="col-md-6">
                                    <p><strong>Run ID:</strong> <span id="run-id"></span></p>
                                    <p><strong>User:</strong> <span id="run-user"></span></p>
                                </div>
                                <div class="col-md-6">
                                    <p><strong>Start Date:</strong> <span id="run-start-date"></span></p>
                                    <p><strong>End Date:</strong> <span id="run-end-date"></span></p>
                                </div>
                            </div>
                            <div class="row">
                                <div class="col-md-6">
                                    <p><strong>Total Files:</strong> <span id="total-files"></span></p>
                                </div>
                                <div class="col-md-6">
                                    <p><strong>Total Size:</strong> <span id="total-size"></span></p>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="row">
                        <div class="col-md-6">
                            <div class="card">
                                <div class="card-header">Size Distribution</div>
                                <div class="card-body">
                                    <div class="chart-container">
                                        <canvas id="size-chart"></canvas>
                                    </div>
                                </div>
                            </div>
                        </div>
                        <div class="col-md-6">
                            <div class="card">
                                <div class="card-header">Owner Distribution</div>
                                <div class="card-body">
                                    <div class="chart-container">
                                        <canvas id="owner-chart"></canvas>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="card">
                        <div class="card-header">Largest Files</div>
                        <div class="card-body">
                            <div class="file-table">
                                <table class="table table-striped">
                                    <thead>
                                        <tr>
                                            <th>Path</th>
                                            <th>Size</th>
                                            <th>Owner</th>
                                            <th>Modified</th>
                                        </tr>
                                    </thead>
                                    <tbody id="files-table-body">
                                        <!-- Files will be loaded here -->
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
                
                <div id="welcome-message" class="card">
                    <div class="card-body text-center">
                        <h3>Welcome to disk-scope</h3>
                        <p class="lead">Select an analysis run from the list to view its details.</p>
                        <p>Use the command-line tool to perform new analyses:</p>
                        <pre class="bg-light p-3 text-start">disk-scope analyze --db disk-scope.db --path /your/path --min-size 100MB</pre>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Fetch runs on page load
        document.addEventListener('DOMContentLoaded', function() {
            fetchRuns();
        });

        // Function to fetch runs from API
        function fetchRuns() {
            fetch('/api/runs')
                .then(response => response.json())
                .then(runs => {
                    displayRuns(runs);
                })
                .catch(error => {
                    console.error('Error fetching runs:', error);
                    document.getElementById('loader').innerHTML = 
                        '<div class="alert alert-danger">Error loading runs. Please check your database connection.</div>';
                });
        }

        // Function to display runs in the list
        function displayRuns(runs) {
            const runsList = document.getElementById('runs-list');
            document.getElementById('loader').style.display = 'none';
            
            if (runs.length === 0) {
                runsList.innerHTML = '<li class="list-group-item">No analysis runs found. Use the command-line tool to create one.</li>';
                return;
            }
            
            runsList.innerHTML = '';
            runs.forEach(run => {
                const li = document.createElement('li');
                li.className = 'list-group-item run-item';
                li.setAttribute('data-run-id', run.id);
                li.innerHTML = `
                    <div class="d-flex justify-content-between align-items-center">
                        <div>
                            <strong>Run #${run.id}</strong><br>
                            <small>${run.path}</small>
                        </div>
                        <div class="text-end">
                            <span class="badge bg-primary">${run.file_count} files</span><br>
                            <small>${run.formatted_size}</small>
                        </div>
                    </div>
                `;
                li.addEventListener('click', function() {
                    document.querySelectorAll('.run-item').forEach(item => {
                        item.classList.remove('active');
                    });
                    this.classList.add('active');
                    fetchRunDetails(run.id);
                });
                runsList.appendChild(li);
            });
        }

        // Function to fetch run details
        function fetchRunDetails(runId) {
            document.getElementById('welcome-message').style.display = 'none';
            document.getElementById('run-details').style.display = 'none';
            
            fetch(`/api/runs/${runId}`)
                .then(response => response.json())
                .then(data => {
                    displayRunDetails(data.run, data.stats);
                    fetchVisualizations(runId);
                })
                .catch(error => {
                    console.error('Error fetching run details:', error);
                });
        }

        // Function to display run details
        function displayRunDetails(run, stats) {
            document.getElementById('run-path').textContent = run.path;
            document.getElementById('run-id').textContent = run.id;
            document.getElementById('run-user').textContent = run.user;
            document.getElementById('run-start-date').textContent = run.start_date;
            document.getElementById('run-end-date').textContent = run.end_date || 'N/A';
            document.getElementById('total-files').textContent = stats.total_files.toLocaleString();
            document.getElementById('total-size').textContent = stats.formatted_total_size;
            
            // Display top files
            const filesTableBody = document.getElementById('files-table-body');
            filesTableBody.innerHTML = '';
            
            stats.top_files.forEach(file => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${file.path}</td>
                    <td>${file.formatted_size}</td>
                    <td>${file.owner}</td>
                    <td>${file.modified}</td>
                `;
                filesTableBody.appendChild(tr);
            });
            
            document.getElementById('run-details').style.display = 'block';
        }

        // Function to fetch and display visualizations
        function fetchVisualizations(runId) {
            // Fetch size distribution data
            fetch(`/api/runs/${runId}/visualization/size_distribution`)
                .then(response => response.json())
                .then(data => {
                    createSizeChart(data);
                })
                .catch(error => {
                    console.error('Error fetching size distribution:', error);
                });
            
            // Fetch owner distribution data
            fetch(`/api/runs/${runId}/visualization/owner_distribution`)
                .then(response => response.json())
                .then(data => {
                    createOwnerChart(data);
                })
                .catch(error => {
                    console.error('Error fetching owner distribution:', error);
                });
        }

        // Function to create size distribution chart
        function createSizeChart(data) {
            const ctx = document.getElementById('size-chart').getContext('2d');
            
            // Destroy existing chart if it exists
            if (window.sizeChart instanceof Chart) {
                window.sizeChart.destroy();
            }
            
            window.sizeChart = new Chart(ctx, {
                type: 'bar',
                data: {
                    labels: data.categories,
                    datasets: [
                        {
                            label: 'File Count',
                            data: data.counts,
                            backgroundColor: 'rgba(54, 162, 235, 0.5)',
                            borderColor: 'rgba(54, 162, 235, 1)',
                            borderWidth: 1,
                            yAxisID: 'y',
                        },
                        {
                            label: 'Total Size',
                            data: data.sizes,
                            backgroundColor: 'rgba(255, 99, 132, 0.5)',
                            borderColor: 'rgba(255, 99, 132, 1)',
                            borderWidth: 1,
                            yAxisID: 'y1',
                            type: 'line',
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        y: {
                            type: 'linear',
                            display: true,
                            position: 'left',
                            title: {
                                display: true,
                                text: 'File Count'
                            }
                        },
                        y1: {
                            type: 'linear',
                            display: true,
                            position: 'right',
                            title: {
                                display: true,
                                text: 'Total Size (bytes)'
                            },
                            grid: {
                                drawOnChartArea: false
                            }
                        }
                    },
                    plugins: {
                        tooltip: {
                            callbacks: {
                                label: function(context) {
                                    const label = context.dataset.label || '';
                                    const value = context.raw;
                                    if (context.datasetIndex === 0) {
                                        return label + ': ' + value.toLocaleString() + ' files';
                                    } else {
                                        const index = context.dataIndex;
                                        return label + ': ' + data.formatted_sizes[index];
                                    }
                                }
                            }
                        }
                    }
                }
            });
        }

        // Function to create owner distribution chart
        function createOwnerChart(data) {
            const ctx = document.getElementById('owner-chart').getContext('2d');
            
            // Destroy existing chart if it exists
            if (window.ownerChart instanceof Chart) {
                window.ownerChart.destroy();
            }
            
            window.ownerChart = new Chart(ctx, {
                type: 'pie',
                data: {
                    labels: data.owners,
                    datasets: [
                        {
                            data: data.sizes,
                            backgroundColor: [
                                'rgba(255, 99, 132, 0.7)',
                                'rgba(54, 162, 235, 0.7)',
                                'rgba(255, 206, 86, 0.7)',
                                'rgba(75, 192, 192, 0.7)',
                                'rgba(153, 102, 255, 0.7)',
                                'rgba(255, 159, 64, 0.7)',
                                'rgba(199, 199, 199, 0.7)',
                                'rgba(83, 102, 255, 0.7)',
                                'rgba(40, 159, 64, 0.7)',
                                'rgba(210, 199, 199, 0.7)'
                            ],
                            borderColor: [
                                'rgba(255, 99, 132, 1)',
                                'rgba(54, 162, 235, 1)',
                                'rgba(255, 206, 86, 1)',
                                'rgba(75, 192, 192, 1)',
                                'rgba(153, 102, 255, 1)',
                                'rgba(255, 159, 64, 1)',
                                'rgba(199, 199, 199, 1)',
                                'rgba(83, 102, 255, 1)',
                                'rgba(40, 159, 64, 1)',
                                'rgba(210, 199, 199, 1)'
                            ],
                            borderWidth: 1
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        tooltip: {
                            callbacks: {
                                label: function(context) {
                                    const label = context.label || '';
                                    const index = context.dataIndex;
                                    const count = data.counts[index];
                                    const formattedSize = data.formatted_sizes[index];
                                    return label + ': ' + formattedSize + ' (' + count + ' files)';
                                }
                            }
                        },
                        legend: {
                            position: 'right'
                        }
                    }
                }
            });
        }
    </script>
</body>
</html>
EOT
    close $fh;
}

1; 