#!/usr/bin/perl
# From a data that has been archived, extract and reanalyze using the 1.wells file.  This script won't
# be able to make changes to the DB.  So, there will be no run plan created and no sample information
# imported.  However, there should be a sample key from the original run that can be used for analysis
# downstream, and all plugins can be launched manually.
#
# 1/13/2014 - D Sims
######################################################################################################

use warnings;
use strict;
use Getopt::Long;
use File::Copy::Recursive qw{ fcopy rcopy dircopy };
use Cwd;
use Data::Dump;

( my $scriptname = $0 ) =~ s/^(.*\/)+//;
my $version = "v1.0.0";
my $description = <<"EOT";
Extract an Ion Torrent experiment archive and re-analyze using the current version of the Torrent Suite.  This
program will extract the tarball to a new directory in /results/uploads, create the necessary 'analysis_return_code.txt'
if it does not already exist, create a copy of the 'sampleKey.txt' file in the target directory, and launch an
analysis of the data.

This script is written for data from v3.2 - v4.0 and may not be compatible with more recent versions of the Torrent
Suite.  Also, there is no way to import the metadata into the DB, and so no run plan will be created and no
plugins will automatically be run.  
EOT

my $usage = <<"EOT";
USAGE: $0 [options] <archive_name>
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

# Make sure enough args passed to script
if ( scalar( @ARGV ) < 1 ) {
    print "ERROR: Not enough arguments passed to script!\n\n";
    print "$usage\n";
    exit 1;
}

#########------------------------------ END ARG Parsing ---------------------------------#########

my $archive = shift;
my $uploads_dir = "/results/uploads";
(my $run_name = $archive) =~ s/(.*?)\.tar\.gz$/Reanlysis_$1/;
my $new_run_dir = "$uploads_dir/$run_name";
my $cwd = getcwd();

print "Creating a new directory to extract the archive into for re-analsyis...\n";
mkdir $new_run_dir if ( ! -d $new_run_dir );

# Extract Tarball
print "Extracting the experiment archive to '$new_run_dir'...\n";
if ( system( "tar xvfz $archive -C $new_run_dir" ) != 0 ) {
    print "ERROR: The tarball could not be extracted\n";
    printf "Child died with signal %d, %s coredump\n", ($? & 127), ($? & 128) ? 'with' : 'without';
    exit $?;
} else {
    print "Tarball '$archive' successfully extracted to '$new_run_dir'\n";
}

# Get the samplekey
chdir( $new_run_dir );
print "Looking for a sampleKey.txt file to use for downstream work...\n";
if ( -d "plugin_out/varCollector_out" ) {
    print "varCollector plugin results found.  Using a sampleKey from that dataset.\n";
    rcopy( "plugin_out/varCollector_out/sampleKey.txt", $new_run_dir );
}
elsif ( -d "collectedVariants" ) {
    print "collectedVariants results found.  Using a sampleKey from that dataset.\n";
    rcopy( "collectedVariants/sampleKey.txt", $new_run_dir );
}
else {
    print "WARNING: No varCollector or collectedVariants dir found.  Can not use old sampleKey for this run\n";
}

# Generate analysis return code for this run
print "Looking to make sure there is a return_analysis_code.txt file to be compatible with TSv4.0...\n";
if ( ! -e "analysis_return_code.txt" ) {
    print "No analysis_return_code.txt file found.  Creating one...\n";
    return_code_gen( \$new_run_dir );
} else {
    print "Found return_analysis_code.txt file for this run.  Everything ready for re-analysis.\n";
}

# Launch analysis
print "Starting analysis on '$run_name'\n";
system( "python /opt/ion/iondb/bin/from_wells_analysis.py $new_run_dir" );

sub return_code_gen {
    # Generate an analysis return code if one does not exist
    my $wd = shift;
    my $arc_file = "$$wd/sigproc_results/analysis_return_code.txt";
    open( my $arc_fh, ">", $arc_file ) || die "Can not create '$arc_file' for writing: $!";
    print $arc_fh "0";
    close( $arc_fh );

    return;
}
