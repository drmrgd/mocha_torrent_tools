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
############################################################################################################
use warnings;
use strict;
use version;
use autodie;

use File::Basename;
use IO::Tee;
use POSIX qw(strftime);
use Text::Wrap;
use Term::ANSIColor;
use Cwd qw(abs_path getcwd);
use Digest::MD5;
use File::Copy;
use File::Path qw(remove_tree);
use Getopt::Long qw(:config bundling auto_abbrev no_ignore_case);
use Data::Dump;
use File::Slurp;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);

use constant DEBUG_OUTPUT => 1;
use constant LOG_OUT      => "$ENV{'HOME'}/datacollector_dev.log";
#use constant LOG_OUT      => "/var/log/mocha/archive.log";

my $string = ' 'x19 . "DEVELOPMENT VERSION OF DATACOLLECTOR" . ' 'x19;
print colored( '*'x75, 'bold yellow on_black');
print colored("\n$string\n", 'bold yellow on_black');
print colored('*'x75, 'bold yellow on_black');
print "\n\n";

my $scriptname = basename($0);
my $version = "v4.5.2_053116-dev";
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
USAGE: $scriptname [options] [-t] <'clinical', 'general'> [-a | -e] <results dir>
    -t, --type       Type of experiment data to be archived ('clinical', 'general').
    -a, --archive    Create tarball archive of the run data
    -e, --extract    Extract the data for re-analysis on another computer.
    -c, --case       Case number to use for new directory generation
    -O, --OCP        Run is from OCP; Variant calling data on IR / MATCHbox, don't include in archive.
    -o, --output     Custom output file name.  (DEFAULT: 'run_name.mmddyyy')
    -d, --dir        Custom output / destination  directory (DEFAULT: /results/xfer/ for extract and /media/Aperio for archive)
    -r, --randd      Server is R&D server; do not email notify group and be more flexible with missing data.
    -s, --server     Server type.  Can be PGM or S5 (DEFAULT: PGM).
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
my $outdir;
my $case_num;
my $r_and_d;
my $ocp_run;
my $expt_type;
my $server_type = 'PGM';

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
            "type|t=s"    => \$expt_type,
            "server|s=s"  => \$server_type,
        ) or die "\n$usage\n";

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

# Format the logfile output
$Text::Wrap::columns = 123;
my $space = ' ' x ( length( timestamp('timestamp') ) + 3 );
my $warn =  colored("WARN:", 'bold yellow on_black');
my $info =  colored("INFO:", 'bold green on_black');
my $err =   colored("ERROR:", 'bold red on_black');

# Make sure that there is an appropriate Results Dir sent to script
my $resultsDir = shift @ARGV;
if ( ! defined $resultsDir ) {
	print "$err No results directory was entered.  Please select the results directory to process.\n\n";
    die "$usage\n";
} 
elsif ( ! -d $resultsDir ) {
	die "$err The results directory '$resultsDir' can not be found.\n\n";
}
elsif ( $resultsDir =~ /.*_tn_\d+\/?$/ ) {
    die "$err An S5 thumbnail directory is only a partial dataset that can not be backed up. Use a full report directory instead!\n";
}

# Check for experiment type to know how to deal with this later.  May combine / supercede $r_and_d.
if ( ! defined $expt_type || $expt_type ne 'general' && $expt_type ne 'clinical' ) {
    print "$err No experiment type defined.  Please choose 'clinical' or 'general'\n\n";
    die $usage;
}

# Get the absolute path of the target and starting dirs to make it easier.
my $outdir_path = abs_path($outdir) if $outdir;
my $expt_dir = abs_path($resultsDir);

# Create logfile for archive process
my $logfile = LOG_OUT;
open( my $log_fh, ">>", $logfile ) || die "Can't open the logfile '$logfile' for writing\n";

# Direct script messages to either a logfile or both STDOUT and a logfile
my $msg;
if ( $quiet ) {
	print "$info Running script in quiet mode. Check the log in " . LOG_OUT ." for details\n";
	$msg = $log_fh;
} else {
    $msg = IO::Tee->new( \*STDOUT, $log_fh );
}

sub log_msg {
    # Set up logger print statements to make typing easier later!
    my $text = shift;
    print $msg timestamp('timestamp') . $text;
    return;
}

# Verify that the server type is valid.
my @valid_servers = qw( PGM S5 S5-XL S5XL );
$server_type = uc($server_type);
unless ( grep{$_ eq $server_type} @valid_servers ) {
    print "$err '$server_type' is not a valid server type. Valid servers are:\n";
    print "\t\"$_\"\n" for @valid_servers;
    exit 1;
}

if ( DEBUG_OUTPUT ) {
    no warnings;
    print "\n==============  DEBUG  ===============\n";
    print "Options input into script:\n";
    print "\tExpt Dir     =>  $resultsDir\n";
    print "\tUser         =>  $username\n";
    print "\tMethod       =>"; 
    ($archive) ? print "  archive\n" : print "  extract\n";
    print "\tOutput       =>  $output\n";
    print "\tQuiet        =>  $quiet\n";
    print "\tOutdir:      =>  $outdir\n";
    print "\tcase #:      =>  $case_num\n";
    print "\tR&D Expt:    =>  $r_and_d\n";
    print "\tOCP Run:     =>  $ocp_run\n";
    print "\tExpt Type    =>  $expt_type\n";
    print "\tServer Type  =>  $server_type\n";
    print "======================================\n\n";
}
exit;

##----------------------------------------- End Command Arg Parsing ------------------------------------##

# Files sufficient for a new export and reanalysis
# TODO: maybe need to move this to a subroutine where we cna alter the list based on the server type?
my @exportFileList = qw{
	sigproc_results/1.wells
	sigproc_results/analysis.bfmask.bin
	sigproc_results/bfmask.bin
	sigproc_results/analysis.bfmask.stats
	sigproc_results/bfmask.stats
    sigproc_results/analysis_return_code.txt
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

# Setup custom and default output names
# TODO: going to neeed a new regex here for the S5 server.
my ( $run_name ) = $expt_dir =~ /([MP]C[C123]-\d+.*_\d+)\/?$/;;
$output = "$run_name." . timestamp('date') if ( ! defined $output );

# Stage the intial components of either an extraction or archive.
chdir $expt_dir || die "Can not access the results directory '$expt_dir': $!";
version_check();
sample_key_gen();
generate_return_code(\$expt_dir);

if ($extract) {
    data_extract();
    exit;
}
elsif ($archive) {
    data_archive();
    exit;
} else {
	print "$err You must choose archive (-a) or extract (-e) options when running this script\n\n";
	print "$usage\n";
	exit 1;
}

sub data_extract {
    # TODO: Going to need to totally rework this for an S5 run.  Then again, this may not be possible.  For now, 
    #       just halt on attempts with an S5 run?
    # Run the export subroutine for pushing data to a different server

    # Create a place for our new data.
    my $destination_dir = create_dest( $outdir_path, '/results/xfer/' );
    print "Creating a copy of data in '$destination_dir from '$expt_dir' for export...\n";
    system( "mkdir -p $destination_dir/$output/sigproc_results/" );
    my $sigproc_out = "$destination_dir/$output/sigproc_results/";


    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "Contents of 'exportFileList':\n";
        print "\t$_\n" for @exportFileList;
        print "======================================\n\n";
    }

    # Copy run data for re-analysis
    for ( @exportFileList ) {
        if ( ! /^sigproc/ && ! /^Bead/ ) {
            copy_data( "$expt_dir/$_", "$destination_dir/$output" );
        } else {
            copy_data( "$expt_dir/$_", "$sigproc_out" );
        }
    }

    # Create tarball of results to make net transfer easier.
    chdir( $destination_dir );
    print "Creating a tarball of $output for export...\n";

    if ( system( "tar cfz ${output}.tar.gz $output/" ) != 0 ) {
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

    my $archive_name = "$output.tar.gz";
    log_msg(" $username has started archive on '$output'.\n");
    log_msg(" $info Running in R&D mode.\n") if $r_and_d;

    # Get listing of plugin results to compare; have to deal with random numbered dirs now
    opendir( my $plugin_dir, "plugin_out" ); 
    my @plugin_results = sort( grep { !/^\.+$/ } readdir( $plugin_dir) );

    my @wanted_plugins = qw( variantCaller_out 
                             varCollector_out 
                             AmpliconCoverageAnalysis_out 
                             coverageAnalysis_out
                           );

    for my $plugin_data (@plugin_results) {
        push( @archivelist, "plugin_out/$plugin_data" ) if grep { $plugin_data =~ /$_/ } @wanted_plugins;
    }
    push( @archivelist, $_ ) for @exportFileList;

    # Check to be sure that all of the results logs are there or exit so we don't miss anything
    if ( ! grep { /variantCaller_out/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            log_msg(" $warn No TVC results directory. Skipping...\n");
        } else {
            log_msg(" $err TVC results directory is missing. Did you run TVC?\n");
            halt(\$expt_dir, 1);
        }
    }
    if ( ! grep { /varCollector/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            log_msg(" $warn No varCollector plugin data. Skipping...\n");
        } else {
            log_msg(" $err No varCollector plugin data. Was varCollector run?\n");
            halt(\$expt_dir, 1);
        }
    }
    if ( ! grep { /AmpliconCoverageAnalysis_out/ } @archivelist ) {
        if ( $r_and_d || $ocp_run ) {
            log_msg(" $warn No AmpliconCoverageAnalysisData. Skipping...\n");
        } 
    }
    if ( ! grep { /coverageAnalysis_out/ } @archivelist ) {
        if ( $ocp_run && ! $r_and_d ) {
            log_msg(" $err CoverageAnalysis data is missing.\n");
            halt(\$expt_dir, 1);
        } else {
            log_msg(" $warn No CoverageAnalysis. Skipping...\n");
        }
    }
    log_msg(" All data located.  Proceeding with archive creation\n");

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
    if ( $status == 1 ) {
        log_msg(" Archival of experiment '$output' completed successfully\n\n");
        print "Experiment archive completed successfully\n" if $quiet;
        send_mail( "success", \$case_num, \$archive_dir, \$md5sum, \$expt_type );
    } else {
        log_msg(" $err Archive creation failed for '$output'.  Check " . LOG_OUT . " for details\n\n");
        print "$err Archive creation failed for '$output'. Check " . LOG_OUT . " for details\n\n" if $quiet;
        halt(\$expt_dir, 4);
    }
}

sub version_check {
    # Find out what TS version running in order to customize some downstream functions
    # TODO: Update for TSS v5.0 and for S5 
    log_msg(" $info Checking TSS version for file path info...\n");

    open( my $ver_fh, "<", "version.txt" ) || die "$err can not open the version.txt file for reading: $!";
    (my $ts_version) = map { /Torrent_Suite=(.*)/ } <$ver_fh>;
    close $ver_fh;

    # Looks like location of Bead_density files has moved in 4.2.1.
    my $old_version = version->parse('4.2.1');
    my $curr_version = version->parse($ts_version);

    if ($ts_version >= $old_version ) { 
        log_msg(colored(" TSv4.2+ run detected. Making file and path adjustments...\n", "bold cyan on_black"));
        log_msg( "\tModifying path for Bead_density_data...\n" );
        map { (/Bead/) ? ($_ = basename($_)) : $_ } @exportFileList;
    } else {
        log_msg(" $info An older version ($ts_version) was detected. Using old paths\n");
    }

    # Check to see if there is a 'explog_final.txt' file in cwd or else try to get one from the 
    # pgm_logs.zip
    if ( ! -e "$expt_dir/explog_final.txt" ) {
        log_msg(" $warn No explog_final.txt in $expt_dir. Attempting to get from pgm_logs.zip...\n");
        if ( ! qx( unzip -j pgm_logs.zip explog_final.txt ) ) {
            log_msg(" $err Can not extract explog_final.txt from the pgm_logs. Can not continue!\n");
            halt( \$expt_dir, 1 );
        } else {
            log_msg(" $info Successfully retrieved the explog_final.txt file from the pgm_log.zip file\n");
        }
    } 
    return;
}

sub sample_key_gen {
    # Generate a sampleKey.txt file for the package
    # TODO: Double check that sampleKeyGen works on S5 servers.
    log_msg(" Generating a sampleKey.txt file for the export package...\n" );
    eval { system( "cd $expt_dir && sampleKeyGen -o sampleKey.txt" ) };
    if ($@) {
        log_msg(" $err SampleKeyGen Script encountered errors: $@\n");
        halt( \$expt_dir, 1);
    }
    return;
}

sub get_bams {
    # Generate a zipfile of BAMs generated for each sample for the archive
    # TODO: Double check that this can be done on S5 Server.
    my $zipfile = basename($expt_dir) . "_library_bams.zip";

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
    log_msg(" Generating a ZIP archive of BAM files for the package...\n");
    system('zip', '-q', $zipfile, @wanted_bams );

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
            if ( $resp !~ /[cnq]/ ) {
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

sub generate_return_code {
    # Add 'analysis_return_code' file to be compatible with TSv3.4+
    my $expt_dir = shift;

    if ( ! -e "$$expt_dir/sigproc_results/analysis_return_code.txt" ) {
        log_msg(" No analysis_return_code.txt file found.  Creating one to be compatible with TSv3.4+\n");
        my $arc_file = "$$expt_dir/sigproc_results/analysis_return_code.txt";
        open( my $arc_fh, ">", $arc_file ) || die "Can't created an analysis_return_code.txt file: $!";
        print $arc_fh "0";
        close $arc_fh;
    } else {
        log_msg(" Found analysis_return_code.txt file. Adding to the export file list\n");
    }
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
    # TODO: Fix this!  Aperio no longer exists and is not a good default.
    my $destination_dir = create_dest( $outdir_path, '/media/Aperio/' ); 

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
    # TODO: Can i optimize this at all?  
	log_msg(" Creating an md5sum list for all archive files.\n");

	if ( -e 'md5sum.txt' ) {
		log_msg(" $info md5sum.txt file already exists in this directory. Creating fresh list.\n");
		unlink( 'md5sum.txt' );
	}
	process_md5_files( $filelist );
	push( @$filelist, 'md5sum.txt' );

	log_msg(" Creating a tarball archive of $archivename.\n");
    if ( system( "tar cfz $archivename @$filelist" ) != 0 ) {
		log_msg(" $err Tarball creation failed: $!.\n");
        printf "child died with signal %d, %s coredump\n", 
            ($? & 127), ($? & 128) ? 'with' : 'without';
        halt( \$expt_dir, 3 );
	} else {
		log_msg(" $info Tarball creation was successful.\n");
	}

	# Uncompress archive in /tmp dir and check to see that md5sum matches.
	my $tmpdir = "/tmp/mocha_archive";
	if ( -d $tmpdir ) {
		log_msg(" $warn found mocha_tmp directory already.  Cleaning up to make way for new one\n");
		remove_tree( $tmpdir );
	} 
	
	mkdir( $tmpdir );
	
	log_msg(" Uncompressing tarball in '$tmpdir' for integrity check.\n");
	if ( system( "tar xfz $archivename -C $tmpdir" ) != 0 ) {
		log_msg(" $warn Can not copy tarball to '/tmp'. $?\n");
		return 0;
	}
	
	# Check md5sum of archive against generated md5sum.txt file
	chdir( $tmpdir );
    log_msg(" Confirming MD5sum of tarball.\n");
	my $md5check = system( "md5sum -c 'md5sum.txt' >/dev/null" );

	if ( $? == 0 ) {
		log_msg(" The archive is intact and not corrupt\n");
		chdir( $cwd ) || die "Can't change directory to '$cwd': $!";
        log_msg(" Removing the tmp data\n");
		remove_tree( $tmpdir );
	} 
	elsif ( $? == 1 ) {
		log_msg(" $err There was a problem with the archive integrity.  Archive creation halted.\n");
		chdir( $cwd ) || die "Can't change dir back to '$cwd': $!";
		remove_tree( $tmpdir );
		return 0;
	} else {
		log_msg(" $err An error with the md5sum check was encountered: $?\n");
		chdir( $cwd ) || die "Can't change dir back to '$cwd': $!";
		remove_tree( $tmpdir );
		return 0;
	}
	
	# Get md5sum for tarball prior to moving.
	log_msg(" Getting MD5 hash for tarball prior to copying.\n");
	open( my $pre_fh, "<", $archivename ) || die "Can't open the archive tarball for reading: $!";
	binmode( $pre_fh );
	my $init_tarball_md5 = Digest::MD5->new->addfile($pre_fh)->hexdigest;
	close( $pre_fh );
    if (DEBUG_OUTPUT) {
        print "\n==============  DEBUG  ===============\n";
        print "\tMD5 Hash = " . $init_tarball_md5 . "\n"; 
        print "======================================\n\n";
    }
	log_msg(" Copying archive tarball to '$archive_dir'.\n");
	
    if ( DEBUG_OUTPUT ) {
        print "\n==============  DEBUG  ===============\n";
        print "\tpwd: $cwd\n";
        print "\tpath: $archive_dir\n";
        print "======================================\n\n";
    }

	if ( copy( $archivename, $archive_dir ) == 0 ) {
		log_msg(" Copying archive to storage device: $!.\n");
		return 0;
	} else {
		log_msg(" $info Archive successfully copied to archive storage device.\n");
	}

	# check integrity of the tarball
	log_msg(" Calculating MD5 hash for copied archive.\n");
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

	log_msg(" Comparing the MD5 hash value for local and fileshare copies of archive.\n");
	if ( $init_tarball_md5 ne $post_tarball_md5 ) {
		log_msg(" $err The md5sum for the archive does not agree after moving to the storage location. Retry the transfer manually\n");
		return 0;
	} else {
		log_msg(" $info The md5sum for the archive is in agreement. The local copy will now be deleted.\n");
		unlink( $archivename );
	}
    return (1, $post_tarball_md5, $archive_dir);
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
    $code //= 4; # If nothing, go unspecified.

    my %fail_codes = (
        1  => "missing files",
        2  => "failed checksum",
        3  => "tarball creation failure",
        4  => "unspecified error",
    );
    my $error = colored($fail_codes{$code}, 'bold red on_black');

    log_msg(" The archive script failed due to '$error' and is unable to continue.\n\n");
    send_mail( "failure", \$case_num, \$expt_name, undef, \$expt_type );
	exit 1;
}

sub mount_check {
	# Double check that the destination filesystem is mounted before we begin. 
	my $mount_point = shift;
    $$mount_point =~ s/\/$//; # Get rid of terminal forward slash to match mount info

    open ( my $mount_fh, "<", '/proc/mounts' ) || die "Can't open '/proc/mounts' for reading: $!";
    if ( grep { /$$mount_point/ } <$mount_fh> ) {
        log_msg(" The remote fileshare is mounted and accessible.\n");
    } 
    elsif ( -e $$mount_point && dirname($$mount_point) ne '/media' ) {
        log_msg(" The remote fileshare is mounted and accessible.\n");
    } else {
        log_msg(" $err The remove fileshare is not mounted! You must mount this share before proceeding.\n");
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

	if ( $@ ) {
		log_msg(" $@\n");
        halt(\$expt_dir, 2);
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

    log_msg(" $info No case number assigned for this archive.\n") unless $$case; 
    log_msg(" $err The path '$$path' does not exist.  Can not continue!\n") unless ( -e $$path );

    my $archive_dir = "$$path/$$case";

    if ( -e $archive_dir ) {
        log_msg(" $warn Directory '$archive_dir' already exists. Adding data to '$archive_dir'.\n");
    } else {
        log_msg(" Creating subdirectory '$archive_dir' to put archive into...\n");
        mkdir( "$archive_dir" ) || die "$err Can not create an archive directory in '$$path'";
    }
    return $archive_dir;
}

sub send_mail {
    # Send out a system email upon error or completion of archive
    my $status = shift;
    my $case = shift;
    my $outdir = shift;
    my $md5sum = shift;
    my $type = shift;
    my @additional_recipients;

    $$case //= "---"; 
    # TODO: Need to fix this regex for new S5 servers.
    my ($pgm_name) = $run_name =~ /([PM]C[123C]-\d+)/;
    $pgm_name //= 'Unknown';
    (my $time = timestamp('timestamp')) =~ s/[\[\]]//g;

    my $template_path = dirname(abs_path($0)) . "/templates/";
    my $target = 'simsdj@mail.nih.gov';
    
    if ( $r_and_d || $type eq 'general' || DEBUG_OUTPUT ) {
        @additional_recipients = '';
    } else {
        @additional_recipients = qw( 
        harringtonrd@mail.nih.gov
        vivekananda.datta@nih.gov
        patricia.runge@nih.gov
        );
    }
    $$md5sum //= '---';

    # Get the hostname for the 'from' line in the email header.
    chomp(my $hostname = qx(hostname -s));

    if ( DEBUG_OUTPUT ) {
        no strict; no warnings;
        print "============  DEBUG  ============\n";
        print "\ttime:   $time\n";
        print "\ttype:   $$type\n";
        print "\tstatus: $status\n";
        print "\tname:   $run_name\n";
        print "\tcase:   $$case\n";
        print "\tpath:   $$outdir\n";
        print "\tmd5sum: $$md5sum\n";
        print "\tpgm:    $pgm_name\n";
        print "=================================\n";
    }

    # Choose template and recipient.
    my ($msg, $cc_list);
    if ( $status eq 'success' ) {
        if ($$type eq 'clinical') {
            $msg = "$template_path/clinical_archive_success.html";
            $cc_list = join( ";", @additional_recipients );
        }
        elsif ($$type eq 'general') {
            $msg = "$template_path/general_archive_success.html";
            $cc_list = '';
        }
    }
    elsif ( $status eq 'failure' ) {
        $msg = "$template_path/archive_failure.html";
        $cc_list = '';
    }

    my $content = read_file($msg);
    # Replace dummy fields with specific data in the message template.
    $content =~ s/%%CASE_NUM%%/$$case/g;
    $content =~ s/%%EXPT%%/$run_name/g;
    $content =~ s/%%PATH%%/$$outdir/g;
    $content =~ s/%%PGM%%/$pgm_name/g;
    $content =~ s/%%MD5%%/$$md5sum/g;
    $content =~ s/%%DATE%%/$time/g;

    my $message = Email::MIME->create(
        header_str => [
            From     => 'ionadmin@'.$hostname.'.ncifcrf.gov',
            To       => $target,
            Cc       => $cc_list, 
            Subject  => "Archive Summary for $run_name",
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
