#!/usr/bin/perl
# Tool to either create a data package that can be imported onto another Torrent Server with the '-e' 
# option in order to run a full analysis on that machine or create an archive with the '-a' option that
# will be sent to long term storage for archival purpose.
#
# The archive sub of the script will package the requested data from the arrays below after producing a 
# md5sum hash for each.  After the tarball is created, the archive is extracted in the /tmp directory and
# the md5 hash values are compared to verify the tarball is correct.  If so, a md5 hash is calculated for 
# the tarball itself and the tarball is copied to the permanent archive location.  Finally the md5 hash of
# the copied archive is compared to the original to make sure it did not get corrupted during the transfer
# and if successful the local copy is deleted.
#
# 4/12/13 - D Sims
#
############################################################################################################

use warnings;
use strict;
use File::Copy;
use File::Basename;
use IO::Tee;
use POSIX qw{ strftime };
use Text::Wrap;
use Cwd;
use Digest::MD5;
use File::Path qw{ remove_tree };
use Getopt::Long;
use Data::Dump;

my $debug = 0;

my $scriptname = basename($0);
my $version = "v1.9.060214";
my $description = <<"EOT";
Program to grab data from an Ion Torrent Run and either archive it, or create a directory that can be imported 
to another analysis computer for processing.  

For data import / export, program will grab raw data (starting from 1.wells file) from completed Ion Torrent NGS run,
including all of the other raw data files required to reanalyze from basecalling through final variant calling. The
default location for the data is /results/xfer.

For archiving, a hardcoded list of files including the system log files (CSA archive) and the BAM files for all 
of the barcoded samples, and the 'collectedVariants' directory will be added to a tar.gz archive. Note that all
data is required to be present for the script to run as these data components are required for a full analysis
and no archive would be complete without all of that data.  This data should also suffice for downstream reanalysis 
starting from either basecalling or alignment if need be as it contains a superset of the data collected in the 
export option as well.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] [-a | -e] <results dir>
    -a, --archive    Create tarball archive of the run data
    -e, --extract    Extract the data for re-analysis on another computer.
    -o, --output     Custom output file name.  (DEFAULT: 'run_name.mmddyyy')
    -d, --dir        Custom output / destination  directory (DEFAULT: /results/xfer/)
    -q, --quiet      Run quietly without sending messages to STDOUT
    -v, --version    Version Information
    -h, --help       Display the help information
EOT

my $verInfo = 0;
my $help = 0;
my $archive;
my $extract;
my $output;
my $quiet = 0;
my $outdir='';
my $case_num;

GetOptions( "help"      => \$help,
            "version"   => \$verInfo,
            "quiet"     => \$quiet,
            "extract"   => \$extract,
            "archive"   => \$archive,
            "output"    => \$output,
            "dir"       => \$outdir,
            "case"      => \$case_num,
        ) or do { print "\n$usage\n"; exit 1; };

sub help {
	printf "%s - %s\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub version_info {
	printf "%s - %s\n", $scriptname, $version;
	exit;
}

help if $help;
version_info if $verInfo;

my $username = $ENV{'USER'};

if ( ! defined $archive && ! defined $extract ) {
	print "ERROR: You must choose archive (-a) or extract (-e) options when running this script\n\n";
	print "$usage\n";
	exit 1;
}

# Make sure that there is an appropriate Results Dir sent to script
my $resultsDir = shift @ARGV;
if ( ! defined $resultsDir ) {
	print "No results directory was entered.  Please select the results directory to process.\n\n";
	print "$usage\n";
	exit 1;
} elsif ( ! -d $resultsDir ) {
	print "The results directory '$resultsDir' can not be found.\n";
	exit 1;
}

# Find out what TS version running in order to customize some downstream functions
open( my $explog_fh, "<", "$resultsDir/explog.txt" ) || die "Can't open the explog.txt file for reading: $!";
(my $ts_version) = map { /PGM SW Release:\s+(\d\.\d\.\d)$/ } <$explog_fh>;

# Setup custom and default output names
my ( $run_name ) = $resultsDir =~ /Auto_user_((?:[PM]CC|MC[12])-\d+.*_\d+)\/?$/;
$output = "$run_name." . timestamp('date') if ( ! defined $output );

my $destination_dir;
( $outdir ) ? ($destination_dir = $outdir) : ($destination_dir = '/results/xfer');

if ( ! -e $destination_dir ) {
    print "ERROR: The destination directory '$destination_dir' does exist.  Check the path.\n";
    exit 1;
}

# Create logfile for archive process
my $logfile = "/var/log/mocha/archive.log";
# XXX
#my $logfile = "/home/ionadmin/testing.log";
open( my $log_fh, ">>", $logfile ) || die "Can't open the logfile '$logfile' for writing\n";

# Direct script messages to either a logfile or both STDOUT and a logfile
my $msg;
$msg = IO::Tee->new( \*STDOUT, $log_fh ) if $quiet == 0;

if ( $quiet == 1 ) {
	print "Running script in quiet mode. Check the log in /var/log/mocha/archive_log.txt for details\n";
	$msg = $log_fh;
}

# Format the logfile output
$Text::Wrap::columns = 123;
my $space = ' ' x ( length( timestamp('timestamp') ) + 3 );

##----------------------------------------- End Command Arg Parsing ------------------------------------##

# Files sufficient for a new export and reanalysis
my @exportFileList = qw{
	sigproc_results/1.wells
	sigproc_results/analysis.bfmask.bin
	sigproc_results/bfmask.bin
	sigproc_results/analysis.bfmask.stats
	sigproc_results/bfmask.stats
	sigproc_results/Bead_density_raw.png
	sigproc_results/Bead_density_200.png
	sigproc_results/Bead_density_70.png
	sigproc_results/Bead_density_20.png
	sigproc_results/Bead_density_1000.png
	sigproc_results/Bead_density_contour.png
	sigproc_results/avgNukeTrace_ATCG.txt
	sigproc_results/avgNukeTrace_TCAG.txt
	explog.txt
	explog_final.txt
};

my @archivelist = qw{ 
	ion_params_00.json
	collectedVariants
    basecaller_results/datasets_basecaller.json
    basecaller_results/datasets_pipeline.json
};

# Just run the export subroutine for pushing data to a different server
if ( $extract ) {
	print "Creating a copy of data in '$destination_dir from '$resultsDir' for export...\n";
	system( "mkdir -p $destination_dir/$output/sigproc_results/" );
	my $sigproc_out = "$destination_dir/$output/sigproc_results/";
	
    if ( -f "$resultsDir/plugin_out/varCollector_out/sampleKey.txt" ) {
        print "Sample key file located in varCollector plugin data. Adding to export data package.\n";
        push( @exportFileList, "plugin_out/varCollector_out/sampleKey.txt" );
    }
    elsif ( -f "$resultsDir/collectedVariants/sampleKey.txt" ) {
		print "SampleKey file located in 'collectedVariants/'.  Adding to export data package.\n";
		push( @exportFileList, "collectedVariants/sampleKey.txt" );		
	} else {
		print "No sampleKey file located.  Creating a new one to include in export package.\n";
        (my $major_version = $ts_version) =~ /(\d)\..*/;

        if ( $major_version == 3 ) {
            eval {
                print "Using TSv3.2.1 sampleKeyGen scripts.\n";
                system( "sampleKeyGen32 -o $resultsDir/sampleKey.txt /opt/mocha-tools/varCollector/resources/bcIndex.txt ${resultsDir}ion_params_00.json" );
            };
        } else {
            print "Using TSv4.0.2 sampleKeyGen scripts.\n";
            eval { system( "sampleKeyGen -o $resultsDir/sampleKey.txt" );
            };
        }
		print "ERROR: SampleKeyGen Script encountered errors: $@" if $@;
		push( @exportFileList, "$resultsDir/sampleKey.txt" );
		
	}
		if ($debug == 1) {
			print "DEBUG: contents of 'exportFileList':\n";
			print "\t$_\n" for @exportFileList;
		}

	# Add 'analysis_return_code' file to be compatible with TSv3.4+
	if ( ! -e "sigproc_results/analysis_return_code.txt" ) {
		print "No analysis_return_code.txt file found.  Creating one to be compatible with TSv3.4+\n";
		my $arc_file = "$sigproc_out/analysis_return_code.txt";
		open( OUT, ">", $arc_file ) || die "Can't created an analysis_return_code.txt file in '$sigproc_out: $!";
		print OUT "0";
		close( OUT );
	} else {
		print "Found analysis_return_code.txt file and adding to the export filelist\n";
		push( @exportFileList, "$sigproc_out/analysis_return_code.txt" );
	}

	# Copy run data for re-analysis
	for ( @exportFileList ) {
		if ( /explog.*\.txt/ or /sampleKey\.txt/ ) {
			copy_data( "$resultsDir/$_", "$destination_dir/$output" );
		} else {
			copy_data( "$resultsDir/$_", "$sigproc_out" );
		}
	}

    # Create tarball of results to make net transfer easier.
    chdir( $destination_dir );
    print "Creating a tarball of $output for export...\n";

    if ( system( "tar -cf - $output | pigz -9 -p 8 > '${output}.tar.gz'" ) != 0 ) {
        print "ERROR: Tarball creation of '$output' failed.\n";
        printf "chile died with signal %d, %s coredump\n", 
            ($? & 127), ($? & 128) ? 'with' : 'without';
        exit $?;
    } else {
        print "Removing tmp data '$output'...\n";
        remove_tree( $output );
    }

	print "Finished copying data package for export.  Data ready in '$destination_dir'\n";
}

# XXX
# Run full archive on data.
if ( $archive ) {

	chdir( $resultsDir ) || die "Can not access the results directory selected: $resultsDir. $!";
	my $archive_name = "$output.tar.gz";
	print $msg timestamp('timestamp') . " $username has started archive on '$output'.\n";
	
	# Add in extra BAM files and such
	my @data = grep { -f } glob( '*.barcode.bam.zip *.support.zip' );
	my @plugins = grep { -d } glob( 'plugin_out/AmpliconCoveragePlots* plugin_out/variantCaller* plugin_out/varCollector* plugin_out/AmpliconCoverageAnalysis*' );

	push( @archivelist, $_ ) for @data;
	push( @archivelist, $_ ) for @exportFileList;
	push( @archivelist, $_ ) for @plugins;

	# Add check to be sure that all of the results dirs and logs are there. Exit otherwise so we don't miss anything
	if ( ! -e "collectedVariants" ) {
		print $msg timestamp('timestamp') . " INFO: collectedVariants directory is not present. Skipping.\n";
        remove_file( "collectedVariants", \@archivelist );
	} 
	elsif ( ! -e "plugin_out/variantCaller_out" ) {
		print $msg timestamp('timestamp') . " ERROR: TVC results directory is missing.  Did you run TVC?\n";
		halt();
	}
	elsif ( ! -e "plugin_out/AmpliconCoveragePlots_out" ) {
		print $msg timestamp('timestamp') . " INFO: AmpliconCoveragePlots directory is not present. Skipping.\n";
        remove_file( "plugin_out/AmpliconCoveragePlots", \@archivelist );
    }
	elsif ( ! -e "plugin_out/varCollector_out" ) {
		print $msg timestamp('timestamp') . " ERROR: No varCollector plugin data.  Did you run varCollector?\n";
        halt();
    }
	elsif ( ! -e "plugin_out/AmpliconCoverageAnalysis" ) {
		print $msg timestamp('timestamp') . " WARN: AmpliconCoverageAnalysis is missing. Data may be prior to implementation.\n";
        remove_file( "plugin_out/AmpliconCoverageAnalysis_out", \@archivelist );
    }
    elsif ( ! -e glob("basecaller_results/datasets*") ) {
        print $msg timestamp('timestamp') . "INFO: No 'datasets_basecaller.json' or 'datasets_pipeline.json' files found.  Data may be prior to TSv4.0 implementation.\n";
        remove_file( "basecaller_results/datasets_basecaller.json", \@archivelist );
        remove_file( "basecaller_results/datasets_pipeline.json", \@archivelist );
	} 
    else {
		print $msg timestamp('timestamp') . " All data located.  Proceeding with archive creation\n"; 
	}

    #dd \@archivelist;
    #exit;

	# Run the archive subs
	if ( archive_data( \@archivelist, $archive_name ) == 1 ) {
		print $msg timestamp('timestamp') . " Archival of experiment '$output' completed successfully\n\n";
		print "Experiment archive completed successfully\n" if $quiet == 1;
	} else {
		print $msg timestamp('timestamp') . " Archive creation failed for '$output'.  Check the logfiles for details\n\n";
		print "Archive creation failed for '$output'. Check /var/log/mocha/archive.log for details\n\n" if $quiet == 1;
		halt();
	}
}

sub remove_file {
    # remove file from extract or archive list; called too many times to not have subroutine!
    my $file = shift;
    my $filelist = shift;

    print $msg timestamp('timestamp') . " Removing file '$file' from archive list\n";

    my $index = grep { $archivelist[$_] =~ /$file/ } 0..$#archivelist;
    splice( @archivelist, $index, 1 );

    return;
}

sub copy_data {
	my ( $file, $location ) = @_;
	print "Copying file '$file' to '$location'...\n";
	system( "cp $file $location" );
}

sub archive_data {
	my $filelist = shift;
	my $archivename = shift;
	my $cwd = getcwd;
	my $path;
    ($outdir) ? ($path = $destination_dir) : ($path = '/media/Aperio/');

    # Check the fileshare before we start
    mount_check(\$path);

    print "exiting before we make the new sub dir; line: 338\n";
    exit;

    # TODO:
    # Create a archive subdirectory to put all data in.
    #if ( create_archive_dir( \$case_num, \$destination_dir ) != 0 ) {
        #print $mgs timestamp('timestamp') . "ERROR: Unable to create an archive subdirectory in '$destination_dir'!\n";
        #halt();
    #}

    
	# Create a checksum file for all of the files in the archive and add it to the tarball 
	print $msg timestamp('timestamp') . " Creating an md5sum list for all archive files.\n";
	if ( -e 'md5sum.txt' ) {
		print $msg timestamp('timestamp') . " md5sum.txt file already exists in this directory.  Deleting and creating fresh list.\n";
		unlink( 'md5sum.txt' );
	}
	process_md5_files( $filelist );
	push( @$filelist, 'md5sum.txt' );
	
	print $msg timestamp('timestamp') . " Creating a tarball archive of $archivename.\n";

	# Use two step tar process with 'pigz' multicore gzip utility to speed things up a bit. 
	if ( system( "tar -cf - @$filelist | pigz -9 -p 8 > $archivename" ) != 0 ) {
		print $msg timestamp('timestamp') . " Tarball creation failed: $?.\n"; 
		return 0;	
	} else {
		print $msg timestamp('timestamp') . " Tarball creation was successful.\n";
	}

	# Uncompress archive in /tmp dir and check to see that md5sum matches.
	my $tmpdir = "/tmp/mocha_archive";
	if ( -d $tmpdir ) {
		print $msg timestamp('timestamp') . " WARNING: found mocha_tmp directory already.  Cleaning up to make way for new one\n";
		remove_tree( $tmpdir );
	} 
	
	mkdir( $tmpdir );
	
	print $msg timestamp('timestamp') . " Uncompressing tarball in '$tmpdir' for integrity check.\n";
	if ( system( "tar xfz $archivename -C $tmpdir" ) != 0 ) {
		print $msg timestamp('timestamp') . " Can not copy tarball to '/tmp'. $?\n";
		return 0;
	}
	
	# Check md5sum of archive against generated md5sum.txt file
	chdir( $tmpdir );
    print $msg timestamp('timestamp') . " Confirming MD5sum of tarball.\n";
	my $md5check = system( "md5sum -c 'md5sum.txt' >/dev/null" );

	if ( $? == 0 ) {
		print $msg timestamp('timestamp') . " The archive is intact and not corrupt\n";
		chdir( $cwd ) || die "Can't change directory to '$cwd': $!";
		remove_tree( $tmpdir );
	} 
	elsif ( $? == 1 ) {
		print $msg timestamp('timestamp') . " There was a problem with the archive integrity.  Archive creation halted.\n";
		chdir( $cwd ) || die "Can't change dir back to '$cwd': $!";
		remove_tree( $tmpdir );
		return 0;
	} else {
		print $msg timestamp('timestamp') . " An error with the md5sum check was encountered: $?\n";
		chdir( $cwd ) || die "Can't change dir back to '$cwd': $!";
		remove_tree( $tmpdir );
		return 0;
	}
	
	# Get md5sum for tarball prior to moving.
	print $msg timestamp('timestamp') . " Getting MD5 hash for tarball prior to copying.\n";
	open( my $pre_fh, "<", $archivename ) || die "Can't open the archive tarball for reading: $!";
	binmode( $pre_fh );
	my $init_tarball_md5 = Digest::MD5->new->addfile($pre_fh)->hexdigest;
	close( $pre_fh );
	print "DEBUG: MD5 Hash = " . $init_tarball_md5 . "\n" if $debug == 1;

	print $msg timestamp('timestamp') . " Copying archive tarball to '$path'.\n"; 
	
	print "DEBUG: pwd => $cwd\n" if $debug == 1;
	print "DEBUG: path => $path\n" if $debug == 1;
	
	if ( copy( $archivename, $path ) == 0 ) {
		print $msg timestamp('timestamp') . " Copying archive to storage device: $!.\n"; 
		return 0;
	} else {
		print $msg timestamp('timestamp') . " Archive successfully copied to archive storage device.\n";
	}

	# check integrity of the tarball
	print $msg timestamp('timestamp') . " Calculating MD5 hash for copied archive.\n";
    my $moved_archive = "$path/$archivename";

	open( my $post_fh, "<", $moved_archive ) || die "Can't open the archive tarball for reading: $!";
	binmode( $post_fh );
	my $post_tarball_md5 = Digest::MD5->new->addfile($post_fh)->hexdigest;
	close( $post_fh );
	
	print "DEBUG: MD5 Hash = " . $post_tarball_md5 . "\n" if $debug == 1;

	print $msg timestamp('timestamp') . " Comparing the MD5 hash value for local and fileshare copies of archive.\n";
	if ( $init_tarball_md5 ne $post_tarball_md5 ) {
		print $msg timestamp('timestamp') . " The md5sum for the archive does not agree after moving to the storage location. Retry the transfer manually\n";
		return 0;
	} else {
		print $msg timestamp('timestamp') . " The md5sum for the archive is in agreement. The local copy will now be deleted.\n";
		unlink( $archivename );
	}

	return 1;
}

sub timestamp {
	my $type = shift;
	
	if ( $type eq 'date' ) {
		my $datestring = strftime( "%m%d%Y", localtime() );
		return $datestring;
	}
	elsif ( $type eq 'timestamp' ) {
		my $timestamp = "[" . strftime( "%a %b %d, %Y %H:%M:%S", localtime() ) . "]";
		my $logstring = wrap( '', $space, $timestamp );
		return $logstring;
	}
}

sub halt {
	print $msg timestamp('timestamp') . " The archive script encountered errors and was unable to complete successfully\n\n";
	exit 1;
}

sub mount_check {
	# Double check that the destination filesystem is mounted before we begin. 

	my $mount_point = shift;
    $$mount_point =~ s/\/$//; # Get rid of terminal forward slash to match mount info

    open ( my $mount_fh, "<", '/proc/mounts' ) || die "Can't open '/proc/mounts' for reading: $!";
    if ( ! grep { $_ =~ /$$mount_point/ } <$mount_fh> ) {
		print $msg timestamp('timestamp') . " ERROR: The remote fileshare is not mounted!\n";
        halt();
	} else {
		print $msg timestamp('timestamp') . " The remote fileshare is mounted and accessible.\n";
	}
}

sub process_md5_files {
	# Pass files into the md5sum function.  As md5sums can only be calc on files, will recursively process
	# all files within a list.
	my $filelist = shift;
	
	# Since symlinks can cause downstrem problems is the dir structure changes, skip adding these to the md5sum check
	foreach my $file ( @$filelist ) {
		if ( -l $file ) {
			next;
		}
		if ( -d $file ) {
			opendir( DIR, $file ) || die "Can't open the dir '$file': $!";
			my @dirlist = sort( grep { !/^\.|\.\.}$/ } readdir( DIR ) );
			my @recurs_files = map { $file ."/". $_ } @dirlist;
			process_md5_files( \@recurs_files );
		} else {
			md5sum( $file );
		}
	}
}

sub md5sum {
	# Generate an md5sum for a file and write to a textfile
	my $file = shift;
	my $md5_list = "md5sum.txt";
	open( my $md5_fh, ">>", $md5_list ) || die "Can't open the md5sum.txt file for writing: $!";

	eval {
		open( my $input_fh, "<", $file ) || die "Can't open the input file '$file': $!";
		binmode( $input_fh );
		my $ctx = Digest::MD5->new;
		$ctx->addfile( *$input_fh );
		my $digest = $ctx->hexdigest;
		print $md5_fh "$digest  $file\n";
		close( $input_fh );
	};

	if ( $@ ) {
		print $msg timestamp('timestamp') . " $@\n";
		return 0;
	}
}

#sub create_archive_dir {
    # Create an archive directory with a case name for pooling all clinical data together

    #my $archive_name = shift;
    #my $path = shift;

    #if ( ! -e $path
    
#}
