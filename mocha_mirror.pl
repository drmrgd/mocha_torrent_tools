#!/usr/bin/perl
# This script will automatically back up the data in /results/analysis/output/Home to the external storage drive 
# connected to the Torrent Server.  This script is intended to be called from cron for nightly rolling backups.
#
# 12/2/2013 v1.1.0 - updated script.  Instead of using [PM]CC-\d+ numbers for runs to backup, use the report number.
#                    This will allow for non-conventional naming, like in the case of reanalysis data.
#
# 10/24/2013 - D Sims
##################################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long;
use File::Find;
use File::Path;
use File::Basename;
use Data::Dump;
use Log::Log4perl qw{ get_logger };

my $scriptname = basename($0);
my $version = "v1.3.0_041515";
my $description = <<"EOT";
Script to mirror report data to an external hard drive mounted at /media/MoCha_backup.  This script will determine
the data size of the external hard drive, and if needed rotate out the oldest run (note: not determined by last
modified time, but rather by oldest run) to make room for the new data.  Then rsync over a list of runs that will
fit on the drive.
EOT

my $usage = <<"EOT";
USAGE: $0 [options] 
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;

GetOptions( "version"     => \$ver_info,
            "help"        => \$help )
        or print $usage;

sub help {
	printf "%s - %s\n\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub version {
	printf "%s - %s\n", $scriptname, $version;
	exit;
}

help if $help;
version if $ver_info;

# Set up logger
my $logger_conf = q(
    log4perl.logger                                               = DEBUG, Logfile
    log4perl.appender.Logfile                                     = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename                            = /var/log/mocha/mirror.log 
    log4perl.appender.Logfile.mode                                = append
    log4perl.appender.Logfile.layout                              = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.message_chomp_before_newlist = 0
    log4perl.appender.Logfile.layout.ConversionPattern            = %d [ %p ]: %m%n
    log4perl.logger.main = DEBUG
    );

Log::Log4perl->init(\$logger_conf);
my $logger = get_logger();
$logger->info( "Starting data mirror to external hard drive..." );

#########------------------------------ END ARG Parsing ---------------------------------#########
my $results_path = "/results/analysis/output/Home";
my $db_backup_path = '/results/dbase_backup/';
my $backup_path = "/media/MoCha_backup";

# Make sure the external hard drive is mounted before starting.
$logger->info("Checking to be sure that the backup drive is mounted...");
check_mount(\$backup_path);

# Check to see that we have space to add new data
$logger->info("Checking MoCha_backup disc size to make sure there's room for more data...");
my $data_size = check_size();

# Set total allowed size to ~3.3 TB to allow for overhead space
while ( $data_size > 3300000 ) {
    $logger->info("Backup drive too full.  Clearing space for new runs");

    rotate_data( \$backup_path );
    $data_size = check_size();
} 

$logger->info("Looks like there is sufficient space for more data");

# Create list of files to rsync over and run backup
my ( $files_for_backup ) = get_runlist( \$backup_path, \$results_path );

for my $run ( @$files_for_backup ) {
    $logger->info("Backing up $run...");
    eval { qx( rsync -avz --exclude=core.alignStats* $results_path/$run $backup_path/ ) };
    ( $@ ) ? $logger->error( "$@" ) : $logger->info( "$run was successfully backed up" );
}

# Make backup of the dbase_backup directory so that we can import runs to a new server if need be
$logger->info("Syncing backup of database backup directory...");
eval { qx(rsycn -avz $db_backup_path $backup_path) };
($@) ? $logger->error("$@") : $logger->info( "Database backup direcotory was successfully synced to backup directory" );

$logger->info( "Data backup to external hard drive is complete\n\n" );

sub check_size {
    use Filesys::Df; # Perl filesys utility; size is different than native df, but can adjust

    my $size = int((df( "/media/MoCha_backup" )->{used})/1024); 
    $logger->info( "The data size of MoCha_backup is: $size." );

    return $size;
}

sub check_mount {
    my $drive = shift;

    open( my $fh, "<", "/proc/mounts" ) or $logger->logdie("Can't open '/proc/mount' for reading: $!");
    ( grep { /$$drive/ } <$fh> ) ? $logger->info( "The backup drive is mounted and accessible." ) 
        : $logger->logdie( "The backup drive is not mounted.  Exiting." );
    close( $fh );
}

sub rotate_data {
    # Use server generated report number (last number in string) to sort runs, and rotate off the oldest to
    # make room for new data
    my $path = shift;

    opendir( my $backup, $$path ) || $logger->logdie( "Can't read the MoCha backup drive: $!");
    my @sorted_expts = sort_data( [grep { ! /^(:?[.]+) | lost/x } readdir($backup)] ); 
    my $expt_to_remove = shift @sorted_expts;

    $logger->info("Removing '$$path/$expt_to_remove' to make space for new data");
    rmtree( "$$path/$expt_to_remove" );
}

sub get_runlist {
    my $bak_path = shift;
    my $data_path = shift;

    my ( @backup_list, @final_run_list );

    # Get list of files on MoCha_backup drive.
    opendir( my $mirrordir, $$bak_path ) || $logger->logdie("Can't read the MoCha_backup directory: $!");
    my @mirrorfiles = sort_data( [grep { ! /^(:?[.]+) | lost/x } readdir( $mirrordir )] );
    my ($last_run) = $mirrorfiles[-1] =~ /_(\d+)$/;

    # Get list of files in /results 
    opendir( my $datadir, $$data_path ) || $logger->logdie("Can't read the /results directory: $!");
    my @data = grep { ! /^[.]+/ } readdir( $datadir );
    my @run_ids = map { /_(\d+)$/ } sort_data( \@data );
    
    for my $run ( @run_ids ) {
        if ( grep { /_$run$/ } @mirrorfiles ) {
            push( @backup_list, $run );
        } 
        
        # Add newer runs to the list
        if ( $run gt $last_run ) {
            push( @backup_list, $run );
        }
    }

    # Generate final list of runs to backup 
    for my $elem (@backup_list) {
        push( @final_run_list, grep { /_$elem$/ } @data );
    }
    return( \@final_run_list );
}

sub sort_data {
    # Sort the experiment data by the report id string
    my $data = shift;
    my @sorted_data = 
        map { $_ ->[0] } 
        sort { $a->[1] <=> $b->[1] }
        map { /_(\d+)$/; [$_, $1] } @$data;

    return @sorted_data;
}
