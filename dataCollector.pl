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
# TODO: 
#     - Tests:
#         1. OCP Run
#         2. MPACT Run
#         3. Pass email / fail email
#         4. Check email lists.
#         5. Redesign the template?
#
# 4/12/13 - D Sims
#
############################################################################################################
use warnings;
use strict;
use version;
use autodie;

use File::Copy;
use File::Basename;
use IO::Tee;
use POSIX qw(strftime);
use Text::Wrap;
use Term::ANSIColor;
use Cwd;
use Cwd qw(abs_path);
use Digest::MD5;
use File::Path qw(remove_tree);
use Getopt::Long qw(:config bundling auto_abbrev no_ignore_case);
use Data::Dump;

use constant DEBUG_OUTPUT => 1;
#use constant LOG_OUT      => "$ENV{'HOME'}/datacollector_dev.log";
use constant LOG_OUT       => "/results/sandbox/dc-test/datacollector_dev.log";
#use constant LOG_OUT      => "/var/log/mocha/archive.log";

print colored( "\n******************************************************\n*******  DEVELOPMENT VERSION OF DATACOLLECTOR  *******\n******************************************************\n\n", "bold yellow on_black");

my $scriptname = basename($0);
my $version = "v3.4.0_042115";
my $description = <<"EOT";
Program to grab data from an Ion Torrent Run and either archive it, or create a directory that can be imported 
to another analysis computer for processing.  

For data import / export, program will grab raw data (starting from 1.wells file) from completed Ion Torrent 
NGS run, including all of the other raw data files required to reanalyze from basecalling through final 
variant calling. The default location for the data is /results/xfer.

For archiving, a hardcoded list of files including the system log files (CSA archive) and the BAM files for 
all of the barcoded samples, and the 'collectedVariants' directory will be added to a tar.gz archive. Note 
that all data is required to be present for the script to run as these data components are required for a 
full analysis and no archive would be complete without all of that data.  This data should also suffice for 
downstream reanalysis starting from either basecalling or alignment if need be as it contains a superset of 
the data collected in the export option as well.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] [-a | -e] <results dir>
    -a, --archive    Create tarball archive of the run data
    -e, --extract    Extract the data for re-analysis on another computer.
    -c, --case       Case number to use for new directory generation
    -O, --OCP        Run is from OCP; Variant calling data on IR / MATCHbox, don't include in archive.
    -o, --output     Custom output file name.  (DEFAULT: 'run_name.mmddyyy')
    -d, --dir        Custom output / destination  directory (DEFAULT: /results/xfer/ for extract and /media/Aperio for archive)
    -r, --randd      Server is R&D server; do not email notify group and be more flexible with missing data.
    -q, --quiet      Run quietly without sending messages to STDOUT
    -v, --version    Version Information
    -h, --help       Display the help information
EOT

my $ver_info;
my $help;
my $archive;
my $extract;
my $output;
my $quiet;
my $outdir = '';
my $case_num = '';
my $r_and_d;
my $ocp_run;

GetOptions( "help|h"      => \$help,
            "version|v"   => \$ver_info,
            "quiet|q"     => \$quiet,
            "extract|e"   => \$extract,
            "archive|a"   => \$archive,
            "output|o"    => \$output,
            "dir|d=s"     => \$outdir,
            "case|c=s"    => \$case_num,
            "randd|r"     => \$r_and_d,
            "OCP|O"       => \$ocp_run,
        ) or do { print "\n$usage\n"; exit 1; };

sub help {
	printf "%s - %s\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub print_version {
    # Have to change sub name due to 'version' package import for checking below
    printf "%s - %s\n", $scriptname, $version;
    exit;
}

help if $help;
print_version if $ver_info;

my $username = $ENV{'USER'};

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

# Get the absolute path of the target dir so that we can find it later.
#my $outdir_path = File::Spec->rel2abs($outdir) if $outdir;
my $outdir_path = abs_path($outdir) if $outdir;

# Create logfile for archive process
my $logfile = LOG_OUT;
open( my $log_fh, ">>", $logfile ) || die "Can't open the logfile '$logfile' for writing\n";

# Direct script messages to either a logfile or both STDOUT and a logfile
my $msg;
if ( $quiet ) {
	print "Running script in quiet mode. Check the log in " . LOG_OUT ." for details\n";
	$msg = $log_fh;
} else {
    $msg = IO::Tee->new( \*STDOUT, $log_fh );
}

# Format the logfile output
$Text::Wrap::columns = 123;
my $space = ' ' x ( length( timestamp('timestamp') ) + 3 );
my $warn =  colored("WARN:", 'bold yellow on_black');
my $info =  colored("INFO:", 'bold green on_black');
my $err =   colored("ERROR:", 'bold red on_black');

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
    version.txt
    sampleKey.txt
};

my @archivelist = qw{ 
	ion_params_00.json
    basecaller_results/datasets_basecaller.json
    basecaller_results/datasets_pipeline.json
    sysinfo.txt
};

# Find out what TS version running in order to customize some downstream functions
open( my $ver_fh, "<", "$resultsDir/version.txt" ) || die "ERROR: can not open the version.txt file for reading: $!";
(my $ts_version) = map { /Torrent_Suite=(.*)/ } <$ver_fh>;
close $ver_fh;

# Looks like location of Bead_density files has moved in 4.2.1.
my $old_version = version->parse('4.2.1');
my $curr_version = version->parse($ts_version);

if ($ts_version >= $old_version ) { 
    print "TSv4.2+ detected.  Making file and path adjustments...\n";
    print "\tModifying path for Bead_density_data...\n";
    map { (/Bead/) ? ($_ = basename($_)) : $_ } @exportFileList;
    print "\tRemoving request for explog_final.txt from list...\n";
    my ($index) = grep { $exportFileList[$_] eq 'explog_final.txt' } 0..$#exportFileList;
    splice( @exportFileList, $index, 1);
} else {
    print "An older version ($ts_version) was detected.  Using old paths\n";
}

# Generate a sampleKey.txt file for the package
print "Generating a sampleKey.txt file for the export package...\n";
eval { system( "cd $resultsDir && sampleKeyGen -o sampleKey.txt" ) };
if ($@) {
    print "$err SampleKeyGen Script encountered errors: $@\n";
    exit 1;
}

# Setup custom and default output names
my ( $run_name ) = $resultsDir =~ /([MP]C[C123]-\d+.*_\d+)\/?$/;;
$output = "$run_name." . timestamp('date') if ( ! defined $output );

if ($extract) {
    data_extract();
    exit;
}
elsif ($archive) {
    data_archive();
    exit;
} else {
	print "ERROR: You must choose archive (-a) or extract (-e) options when running this script\n\n";
	print "$usage\n";
	exit 1;
}

sub data_extract {
    # Run the export subroutine for pushing data to a different server
    my $destination_dir = create_dest( $outdir_path, '/results/xfer/' );

    print "Creating a copy of data in '$destination_dir from '$resultsDir' for export...\n";
    system( "mkdir -p $destination_dir/$output/sigproc_results/" );
    my $sigproc_out = "$destination_dir/$output/sigproc_results/";

    # Add 'analysis_return_code' file to be compatible with TSv3.4+
    if ( ! -e "$resultsDir/sigproc_results/analysis_return_code.txt" ) {
        print "No analysis_return_code.txt file found.  Creating one to be compatible with TSv3.4+\n";
        my $arc_file = "$sigproc_out/analysis_return_code.txt";
        open( my $arc_fh, ">", $arc_file ) 
            || die "Can't created an analysis_return_code.txt file in '$sigproc_out': $!";
        print $arc_fh "0";
        close $arc_fh;
    } else {
        print "Found analysis_return_code.txt file. Adding to the export filelist\n";
        push( @exportFileList, "sigproc_results/analysis_return_code.txt" );
    }

    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "Contents of 'exportFileList':\n";
        print "\t$_\n" for @exportFileList;
        print "======================================\n\n";
    }

    # Copy run data for re-analysis
    for ( @exportFileList ) {
        if ( ! /^sigproc/ && ! /^Bead/ ) {
            copy_data( "$resultsDir/$_", "$destination_dir/$output" );
        } else {
            copy_data( "$resultsDir/$_", "$sigproc_out" );
        }
    }

    # Create tarball of results to make net transfer easier.
    chdir( $destination_dir );
    print "Creating a tarball of $output for export...\n";

    #if ( system( "tar -cf - $output | pigz -9 -p 8 > '${output}.tar.gz'" ) != 0 ) {
    if ( system( "tar cfz ${output}.tar.gz $output" ) != 0 ) {
        print "$err Tarball creation of '$output' failed.\n";
        printf "child died with signal %d, %s coredump\n", 
            ($? & 127), ($? & 128) ? 'with' : 'without';
        exit $?;
    } else {
        print "Removing tmp data '$output'...\n";
        remove_tree( $output );
    }

    print "Finished copying data package for export.  Data ready in '$destination_dir'\n";
}

sub data_archive {
    # Run full archive on data.

    chdir( $resultsDir ) || die "Can not access the results directory selected: $resultsDir. $!";
    my $archive_name = "$output.tar.gz";
    print $msg timestamp('timestamp') . " $username has started archive on '$output'.\n";
    print $msg timestamp('timestamp') . " $info Running in R&D mode.\n" if $r_and_d;
    
    # Get listing of plugin results to compare; have to deal with random numbered dirs now
    opendir( my $plugin_dir, "plugin_out" ); 
    my @plugin_results = sort( grep { !/^[.]+$/ } readdir( $plugin_dir) );

    my @wanted_plugins = qw( variantCaller_out 
                             varCollector_out 
                             AmpliconCoverageAnalysis_out 
                             CoverageAnalysis_out
                           );

    for my $plugin_data (@plugin_results) {
        push( @archivelist, "plugin_out/$plugin_data" ) if grep { $plugin_data =~ /$_/ } @wanted_plugins;
    }
    push( @archivelist, $_ ) for @exportFileList;

    # Check to be sure that all of the results logs are there or exit so we don't miss anything
    if ( ! grep { /variantCaller_out/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            print $msg timestamp('timestamp') . " $warn No TVC results directory.  Skipping...\n";
        } else {
            print $msg timestamp('timestamp') . " $err TVC results directory is missing. Did you run TVC?\n";
            halt(\$resultsDir, 1);
        }
    }
    if ( ! grep { /varCollector/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            print $msg timestamp('timestamp') . " $warn No varCollector plugin data. Skipping...\n";
        } else {
            print $msg timestamp('timestamp') . " $err No varCollector plugin data. Was varCollector run?\n";
            halt(\$resultsDir, 1);
        }
    }
    if ( ! grep { /AmpliconCoverageAnalysis_out/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            print $msg timestamp('timestamp') . " $warn No AmpliconCoverageAnalysisData. Skipping...\n"; 
        } 
    }
    if ( ! grep { /CoverageAnalysis_out/ } @archivelist ) {
        if ( $ocp_run ) {
            print $msg timestamp('timestamp') . " $err CoverageAnalysis data is missing.\n"; 
            halt(\$resultsDir, 1);
        } else {
            print $msg timestamp('timestamp') . " $warn No CoverageAnalysis. Skipping...\n"; 
        }
    }
    print $msg timestamp('timestamp') . " All data located.  Proceeding with archive creation\n"; 

    # Collect BAM files for the archive
    my $bamzip = get_bams();
    push(@archivelist, $bamzip);

    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        dd \@archivelist;
        print "======================================\n\n";
    }

    # Run the archive subs
    my ($status, $md5sum, $archive_dir) = archive_data( \@archivelist, $archive_name );
    #if ( archive_data( \@archivelist, $archive_name ) == 1 ) {
    if ( $status == 1 ) {
        print $msg timestamp('timestamp') . " Archival of experiment '$output' completed successfully\n\n";
        print "Experiment archive completed successfully\n" if $quiet;
        #send_mail( "success", \$resultsDir, \$case_num );
        # XXX
        # ADD: output path, md5sum
        send_mail( "success", \$resultsDir, \$case_num, \$archive_dir, \$md5sum );
    } else {
        print $msg timestamp('timestamp') . " $err Archive creation failed for '$output'.  Check the logfiles for details\n\n";
        #print "$err Archive creation failed for '$output'. Check /var/log/mocha/archive.log for details\n\n" if $quiet == 1;
        print "$err Archive creation failed for '$output'. Check " . LOG_OUT . " for details\n\n" if $quiet;
        halt(\$resultsDir);
    }
}

sub get_bams {
    # Generate a zipfile of BAMs generated for each samle for the archive
    my $zipfile = basename($resultsDir) . "_library_bams.zip";

    open( my $sample_key, "<", "sampleKey.txt" );
    my %samples = map{ chomp; split(/\t/) } <$sample_key>;
    close $sample_key;

    my $cwd = abs_path();
    opendir( my $dir, $cwd);
    my @bam_files = grep { /IonXpress.*\.bam(?:\.bai)?$/ } readdir($dir);

    my @wanted_bams;
    for my $bam (@bam_files) {
        my ($barcode) = $bam =~ /(IonXpress_\d+)/;
        push( @wanted_bams, $bam ) if exists $samples{$barcode};
    }

    # Generate a zip archive of the desired BAM files.
    system('zip -q', $zipfile, @wanted_bams );

    return $zipfile;
}

sub create_dest {
    # Create a place to put the data.
    my $outdir = shift;
    my $default = shift;

    my $destination_dir;
    ( $outdir ) ? ($destination_dir = $outdir) : ($destination_dir = $default);

    if ( ! -e $destination_dir ) {
        print "$warn The destination directory '$destination_dir' does not exist.\n";
        while (1) {
            print "(c)reate, (n)ew directory, (q)uit: ";
            chomp( my $resp = <STDIN> );
            if ( $resp !~  /[cnq]/ ) {
                print "$err Not a valid response.\n";
            }
            elsif ( $resp eq 'c' ) {
                print "Creating the directory '$destination_dir'...\n";
                mkdir $destination_dir;
                last;
            }
            elsif( $resp eq 'n' ) {
                print "New target dir: ";
                chomp( $destination_dir = <STDIN>);
                print "New location selected: $destination_dir. Creating the new directory\n";
                mkdir $destination_dir;
                last;
            } else {
                print "Exiting.\n";
                exit 1;
            }
        }
    }
    return $destination_dir;
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
    my $destination_dir = create_dest( $outdir_path, '/media/Aperio/' ); 

    return (1, '93038889640fd9259da155b7de0755a1', 'some/directory/');

    # Check the fileshare before we start
    mount_check(\$destination_dir);

    # Create a archive subdirectory to put all data in.
    my $archive_dir;
    if ( $case_num ) {
        $archive_dir = create_archive_dir( \$case_num, \$destination_dir);
    } else {
        $archive_dir = $destination_dir;
    }
    
	# Create a checksum file for all of the files in the archive and add it to the tarball 
	print $msg timestamp('timestamp') . " Creating an md5sum list for all archive files.\n";
	if ( -e 'md5sum.txt' ) {
		print $msg timestamp('timestamp') . " $info md5sum.txt file already exists in this directory.  Deleting and creating fresh list.\n";
		unlink( 'md5sum.txt' );
	}
	process_md5_files( $filelist );
	push( @$filelist, 'md5sum.txt' );

	print $msg timestamp('timestamp') . " Creating a tarball archive of $archivename.\n";

	# Use two step tar process with 'pigz' multicore gzip utility to speed things up a bit. 
	#if ( system( "tar -cf - @$filelist | pigz -9 -p 8 > $archivename" ) != 0 ) {
     if ( system( "tar cfz $archivename @$filelist" ) != 0 ) {
		print $msg timestamp('timestamp') . " $err Tarball creation failed: $?.\n"; 
        halt( \$resultsDir );
	} else {
		print $msg timestamp('timestamp') . " $info Tarball creation was successful.\n";
	}

	# Uncompress archive in /tmp dir and check to see that md5sum matches.
	my $tmpdir = "/tmp/mocha_archive";
	if ( -d $tmpdir ) {
		print $msg timestamp('timestamp') . " $warn found mocha_tmp directory already.  Cleaning up to make way for new one\n";
		remove_tree( $tmpdir );
	} 
	
	mkdir( $tmpdir );
	
	print $msg timestamp('timestamp') . " Uncompressing tarball in '$tmpdir' for integrity check.\n";
	if ( system( "tar xfz $archivename -C $tmpdir" ) != 0 ) {
		print $msg timestamp('timestamp') . " $warn Can not copy tarball to '/tmp'. $?\n";
		return 0;
	}
	
	# Check md5sum of archive against generated md5sum.txt file
	chdir( $tmpdir );
    print $msg timestamp('timestamp') . " Confirming MD5sum of tarball.\n";
	my $md5check = system( "md5sum -c 'md5sum.txt' >/dev/null" );

	if ( $? == 0 ) {
		print $msg timestamp('timestamp') . " The archive is intact and not corrupt\n";
		chdir( $cwd ) || die "Can't change directory to '$cwd': $!";
        print $msg timestamp('timestamp') . " Removing the tmp data\n";
		remove_tree( $tmpdir );
	} 
	elsif ( $? == 1 ) {
		print $msg timestamp('timestamp') . " $err There was a problem with the archive integrity.  Archive creation halted.\n";
		chdir( $cwd ) || die "Can't change dir back to '$cwd': $!";
		remove_tree( $tmpdir );
		return 0;
	} else {
		print $msg timestamp('timestamp') . " $err An error with the md5sum check was encountered: $?\n";
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
    if (DEBUG_OUTPUT) {
        print "\n==============  DEBUG  ===============\n";
        print "\tMD5 Hash = " . $init_tarball_md5 . "\n"; 
        print "======================================\n\n";
    }
	print $msg timestamp('timestamp') . " Copying archive tarball to '$archive_dir'.\n"; 
	
    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "\tpwd: $cwd\n";
        print "\tpath: $archive_dir\n";
        print "======================================\n\n";
    }

	if ( copy( $archivename, $archive_dir ) == 0 ) {
		print $msg timestamp('timestamp') . " Copying archive to storage device: $!.\n"; 
		return 0;
	} else {
		print $msg timestamp('timestamp') . " $info Archive successfully copied to archive storage device.\n";
	}

	# check integrity of the tarball
	print $msg timestamp('timestamp') . " Calculating MD5 hash for copied archive.\n";
    my $moved_archive = "$archive_dir/$archivename";

	open( my $post_fh, "<", $moved_archive ) || die "Can't open the archive tarball for reading: $!";
	binmode( $post_fh );
	my $post_tarball_md5 = Digest::MD5->new->addfile($post_fh)->hexdigest;
	close( $post_fh );
	
    if (DEBUG_OUTPUT) {
        print "\n==============  DEBUG  ===============\n";
        print "\tMD5 Hash = " . $post_tarball_md5 . "\n"; 
        print "======================================\n\n";
    }

	print $msg timestamp('timestamp') . " Comparing the MD5 hash value for local and fileshare copies of archive.\n";
	if ( $init_tarball_md5 ne $post_tarball_md5 ) {
		print $msg timestamp('timestamp') . " $err The md5sum for the archive does not agree after moving to the storage location. Retry the transfer manually\n";
		return 0;
	} else {
		print $msg timestamp('timestamp') . " $info The md5sum for the archive is in agreement. The local copy will now be deleted.\n";
		unlink( $archivename );
	}
    # XXX
    #
    # Return MD5sum and outdir?
    return (1, $post_tarball_md5, $archive_dir);
	#return 1;
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
    my $expt_name = shift;
    my $code = shift;

    my %fail_codes = (
        1  => "missing files",
        2  => "failed checksum",
        3  => "tarball creation failure",
        4  => "unspecified error",
    );
    my $error = " The archive script failed due to '" . colored($fail_codes{$code}, "bold cyan on_black") . "' and is unable to continue.\n\n"; 
	print $msg timestamp('timestamp'), $error; 
    send_mail( "failure", $expt_name );
	exit 1;
}

sub mount_check {
	# Double check that the destination filesystem is mounted before we begin. 
	my $mount_point = shift;
    $$mount_point =~ s/\/$//; # Get rid of terminal forward slash to match mount info

    open ( my $mount_fh, "<", '/proc/mounts' ) || die "Can't open '/proc/mounts' for reading: $!";
    if ( grep { /$$mount_point/ } <$mount_fh> ) {
        print $msg timestamp('timestamp') . " The remote fileshare is mounted and accessible.\n";
    } 
    elsif ( -e $$mount_point && dirname($$mount_point) ne '/media' ) {
        print $msg timestamp('timestamp') . " The remote fileshare is mounted and accessible.\n";
    } else {
        print $msg timestamp('timestamp') . " $err The remove fileshare is not mounted! You must mount this share before proceeding.\n";
    }
}

sub process_md5_files {
	# Pass files into the md5sum function.  As md5sums can only be calc on files, will recursively process
	# all files within a list.
	my $filelist = shift;
	
	foreach my $file ( @$filelist ) {
        # Skip symlinked files
		if ( -l $file ) {
			next;
		}
		if ( -d $file ) {
			opendir( my $dir_handle, $file ) || die "Can't open the dir '$file': $!";
			my @dirlist = sort( grep { !/^\.|\.\.}$/ } readdir( $dir_handle) );
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

    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "\tProcessing file: $file\n";
        print "\tret code: $@\n";
        print "======================================\n\n";
    }

	if ( $@ ) {
		print $msg timestamp('timestamp') . " $@\n";
        halt(\$resultsDir);
	}
}

sub create_archive_dir {
    #Create an archive directory with a case name for pooling all clinical data together
    my $case = shift;
    my $path = shift;

    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "\tCase No: $$case\n";
        print "\tPath: $$path\n";
        print "======================================\n\n";
    }

    print $msg timestamp('timestamp') . " $info No case number assigned for this archive.\n" unless $$case; 
    print $msg timestamp('timestamp') . " $err The path '$$path' does not exist.  Can not continue!\n" unless ( -e $$path );

    my $archive_dir = "$$path/$$case";

    if ( -e $archive_dir ) {
        print $msg timestamp('timestamp') . " $warn Directory '$archive_dir' already exists. Adding data to '$archive_dir'.\n";
    } else {
        print $msg timestamp('timestamp') . " Creating subdirectory '$archive_dir' to put archive into...\n";
        mkdir( "$archive_dir" ) || die "$err Can not create an archive directory in '$$path'";
    }
    return $archive_dir;
}

# XXX
sub send_mail {
    # Send out a system email upon error or completion of archive
    use File::Slurp;
    use Email::MIME;
    use Email::Sender::Simple qw( sendmail );

    my $status = shift;
    my $expt_name = shift;
    my $case = shift;
    my $outdir = shift;
    my $md5sum = shift;
    my @additional_recipients;

    $$case //= "---"; 
    $$expt_name =~ s/\/$//;
    my ($pgm_name) = $$expt_name =~ /([PM]C[123C]-\d+)/;
    $pgm_name //= 'Unknown';
    (my $time = timestamp('timestamp')) =~ s/[\[\]]//g;

    my $template_path = dirname(abs_path($0)) . "/templates/";
    my $target = 'simsdj@mail.nih.gov';
    
    if ( $r_and_d || DEBUG_OUTPUT ) {
        @additional_recipients = '';
    } else {
        @additional_recipients = qw( 
        harringtonrd@mail.nih.gov
        vivekananda.datta@nih.gov
        patricia.runge@nih.gov
        );
    }

    if ( DEBUG_OUTPUT ) {
        print "============  DEBUG  ============\n";
        print "\ttime:   $time\n";
        print "\tstatus: $status\n";
        print "\tname:   $$expt_name\n";
        print "\tcase:   $$case\n";
        print "\tpath:   $$outdir\n";
        print "\tmd5sum: $$md5sum\n";
        print "\tpgm:    $pgm_name\n";
        print "=================================\n";
    }

    # Choose template and recipient.
    my ($msg, $cc_list);
    if ( $status eq 'success' ) {
        $msg = "$template_path/clinical_archive_success.html";
        $cc_list = join( ";", @additional_recipients );
    }
    elsif ( $status eq 'failure' ) {
        $msg = "$template_path/archive_failure.html";
        $cc_list = '';
    }
    elsif ( $status eq 'test' ) {
        $msg = "$template_path/test_email.html";
        $cc_list = '';
    }

    my $content = read_file($msg);
    # Replace dummy fields with specific data in the message template.
    $content =~ s/%%CASE_NUM%%/$$case/g;
    $content =~ s/%%EXPT%%/$$expt_name/g;
    $content =~ s/%%PATH%%/$$outdir/g;
    $content =~ s/%%PGM%%/$pgm_name/g;
    $content =~ s/%%MD5%%/$$md5sum/g;
    $content =~ s/%%DATE%%/$time/g;

    my $message = Email::MIME->create(
        header_str => [
            From     => 'ionadmin@mcc-clia.ncifcrf.gov',
            To       => $target,
            Cc       => $cc_list, 
            Subject  => "Archive Summary for $$expt_name",
            ],
            attributes  => {
                encoding      => 'quoted-printable',
                content_type  => 'text/html',
                charset       => 'ISO-8859-1',
            },
            body_str => $content,
        );

        sendmail($message);
}
