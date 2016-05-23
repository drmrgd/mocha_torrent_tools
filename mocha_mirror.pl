#!/usr/bin/perl
# This script will automatically back up the data in /results/analysis/output/Home to the external storage drive 
# connected to the Torrent Server.  This script is intended to be called from cron for nightly rolling backups.
#
# 12/2/2013 v1.1.0 - updated script.  Instead of using [PM]CC-\d+ numbers for runs to backup, use the report 
#                    number. This will allow for non-conventional naming, like in the case of reanalysis data.
#
# 10/24/2013 - D Sims
#################################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long;
use File::Find;
use File::Path;
use File::Basename;
use Data::Dump;
use Log::Log4perl qw{ get_logger };

use constant DEBUG => 1;

my $scriptname = basename($0);
my $version = "v2.4.0_052316";
my $description = <<"EOT";
Script to mirror report data to an external hard drive mounted at /media/MoCha_backup.  This script will 
determine the data size of the external hard drive, and if needed rotate out the oldest run (note: not 
determined by last modified time, but rather by oldest run) to make room for the new data.  Then rsync over 
a list of runs that will fit on the drive.
EOT

my $usage = <<"EOT";
USAGE: $0 [options] 
    -t, --target    Target backup drive (DEFAULT: '/media/mocha_clia_nas')
    -s, --server    Server name.
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $target = '/media/mocha_clia_nas';
my $server;

GetOptions( "target|t=s"  => \$target,
            "server|s=s"  => \$server,
            "version"     => \$ver_info,
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

die "ERROR: You must input the server name to run this!\n" unless $server;
$server = lc($server);

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
my $results_path   = '/results/analysis/output/Home';
my $db_backup_path = '/results/dbase_backup';
#my $backup_path = "/media/MoCha_backup";
#my $backup_root = "/media/mocha_clia_nas";
# TODO: Shift this in
#my $server = 'mcc-clia';

$target =~ s/\/$//; #dump terminal slash if it's there for the regexp later.
my $backup_path = "$target/$server";

if (DEBUG) {
    print '='x50 . ' DEBUG ' . '='x50 . "\n";
    print "\ttarget path: $target\n";
    print "\tserver name: $server\n";
    print "\tbackup path: $backup_path\n";
    print '='x107 . "\n";
}

# Make sure the external hard drive is mounted before starting.
$logger->info("Checking to be sure that the backup drive is mounted...");
#check_mount(\$backup_path);
#check_mount(\$backup_root);
check_mount(\$target);

# Check to see that we have space to add new data
$logger->info("Checking MoCha_backup disc size to make sure there's room for more data...");
my $data_size = check_size($backup_path);

# Set total allowed size to ~3.3 TB to allow for overhead space
#while ( $data_size > 3300000 ) {
# Now total size <= 10,000 GB
while ( $data_size > 10000) {
    $logger->info("Backup drive too full.  Clearing space for new runs");

    rotate_data( \$backup_path );
    $data_size = check_size();
} 
$logger->info("Looks like there is sufficient space for more data");
exit;

# Create list of files to rsync over and run backup
my ( $files_for_backup ) = get_runlist( \$backup_path, \$results_path );

for my $run ( @$files_for_backup ) {
    $logger->info("Backing up $run...");
    #eval { qx( rsync -avz --exclude=core.alignStats* $results_path/$run $backup_path/ ) };
    eval { qx( rsync -av --exclude=core.alignStats* $results_path/$run $backup_path/ ) };
    ( $@ ) ? $logger->error( "$@" ) : $logger->info( "$run was successfully backed up" );
}

# Make backup of the dbase_backup directory so that we can import runs to a new server if need be
$logger->info("Syncing backup of database backup directory...");
#eval { qx(rsync -avz $db_backup_path $backup_path) };
eval { qx(rsync -av $db_backup_path $backup_path) };
($@) ? $logger->error("$@") : $logger->info( "Database backup directory was successfully synced to backup directory" );

$logger->info( "Data backup to external hard drive is complete\n\n" );

sub check_size {
    use Filesys::Df; # Perl filesys utility; size is different than native df, but can adjust
    my $dir = shift;

    #my $size = int((df( "/media/MoCha_backup" )->{used})/1024); 
    my $size = qx(du -s --block-size=1G --exclude='lost+found' $dir);
    my @elems = split(/\s+/,$size);
    $logger->info( "The data size of MoCha_backup is: $elems[0]GB." );
    print( "The data size of MoCha_backup is: $elems[0]GB.\n" ) if DEBUG;
    return $elems[0];
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
    my @sorted_expts = sort_data( [grep { ! /^\.+ | lost/x } readdir($backup)] ); 
    
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
    my @mirrorfiles = sort_data( [grep { ! /^\.+ | lost | dbase/x } readdir( $mirrordir )] );
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

    # Need to remove 'dbase_backup' from the sort routine so we don't have issues. Always want this anyway.
    my ($index) = grep { $$data[$_] eq 'dbase_backup' } 0..$#{$data};
    splice( @$data, $index, 1 ) if $index;

    my @sorted_data = 
        map { $_ ->[0] } 
        sort { $a->[1] <=> $b->[1] }
        map { /_(\d+)$/; [$_, $1] } @$data;

    return @sorted_data;
}
