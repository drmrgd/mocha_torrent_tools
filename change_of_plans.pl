#!/usr/bin/perl
# Script to change the explog.txt file to match a run plan when exporting data to a different server
# for reanalysis.
#
# TODO: Fix the regex renaming sub.  Can't have user input a sub regex; must be a match regex only
#       and then need to parse it out and build the substitution.
#
# 11/6/2013 - D Sims
#####################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long qw(:config bundling auto_abbrev no_ignore_case );
use File::Basename;
use File::Copy;
use Data::Dump;

my $scriptname = basename($0);
my $version = "v1.2.0_112114";
my $description = <<"EOT";
Program to change the explog.txt file of an imported run.  The TS will not assign sample information
defined in a run plan unless it matches the guid and (potentially) the short id of the explog.txt 
file with what's stored in the database.  Therefore, once a run plan has been created in the database,
one will need to update the explog.txt file with this information to match what's in the database.

The direct strings can be passed to the script using the options below.  Optionally, a file containing 
the necessary information can be passed, as long as it's in the following format:

        short_id: 2112R
        guid: 94dc00d9-5974-4b57-ab72-903261a1247a
        expt_name: some_new_experiment_name
EOT

my $usage = <<"EOT";
USAGE: $0 [-s <short_id> -g <guid> | -f <file with ids>] [options] <explog.txt>
    -s, --short-id  The short ID of the run plan (e.g. 2112R)
    -g, --guid      The long guid string of the run plan (e.g. 94dc00d9-5974-4b57-ab72-903261a1247a)
    -n, --name      New experiment name.  By default, the original run name will be used.
    -r, --regex     EXPERIMENTAL: Rename an experiment by inputting a perl regex (e.g. 's/R_\\d+_.*user_(MC3-\\d+).*/\$1_testrun/')
    -f, --file      A file containing the short id and guid of the plan (see above for requisites).
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help = 0;
my $ver_info = 0;
my $short_id;
my $guid;
my $file;
my $expt_name;
my $name_regex;

GetOptions( "help|h"        => \$help,
			"version|v"     => \$ver_info,
			"guid|g=s"      => \$guid,
			"short-id|s=s"  => \$short_id,
			"file|f=s"      => \$file,
            "name|n=s"      => \$expt_name,
            "regex|r=s"     => \$name_regex,
        )
			or print $usage;

sub help {
	printf "%s - %s\n\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub version_info {
	printf "%s - %s\n", $scriptname, $version;
	exit;
}

help if ( $help );
version_info if $ver_info;

# We need either the short_id and the guid or a file with that
if ( ! ( $guid && $short_id ) && ! $file ) {
	print "ERROR: You must provide either a guid and short_id with options or a file with that information.\n\n";
	print $usage;
	exit 1;
}

# Set up the name regex
my $regex = qr/$name_regex/ if $name_regex;

# Make sure enough args passed to script
if ( scalar( @ARGV ) < 1 ) {
	print "ERROR: Missing the explog.txt file!\n\n";
	print "$usage\n";
	exit 1;
}

#########------------------------------ END ARG Parsing ---------------------------------#########
my $explog = shift;

# Create a backup of the current explog.txt file first
copy( $explog, "explog.txt.bak" ) || die "Can't copy the explog.txt file: $!";

# Read in the file
open( my $fh, "<", $explog ) || die "Can't open the explog file: $!";
my @explog_data = <$fh>;
close( $fh );

# Change the explog.txt file with the new data
if ( $file ) {
	from_file( \$file, \@explog_data );
} else {
	open( my $out_fh, ">", "explog.txt" ) || die "Can't open the next explog.txt file for writing: $!";
	
	for my $line ( @explog_data ) {
        $line =~ s/^(Project:\s+).*/$1/ if ( $line =~ /Project/ );
		$line =~ s/^(Planned Run Short ID:).*/$1 $short_id/ if ( $line =~ /Short ID/ );
		$line =~ s/^(Planned Run GUID:).*/$1 $guid/ if ( $line =~ /GUID/ );
        if ( $line =~ /^Experiment Name:/ ) {
            if ( $expt_name ) {
                $line =~ s/^(Experiment Name:).*/$1 $expt_name/;
            }

            elsif ( $regex ) {
                my ($name) = $line =~ /: (.*)$/;
                regex_rename($name);
                #$name =~ $regex;
                #$line =~ s/^(Experiment Name:).*/$1 $name/;
            }
        }
	}

	print $out_fh $_ for @explog_data;
	close( $out_fh );
}

sub regex_rename {
    # Rename an experiment by inputting a regex
    my $orig_name = shift;
    my $new_name;

    print "Regex renaming is not yet implemented!\n";
    exit 1;

    print "=======  DEBUG  =======\n";
    print "\tregex: $regex\n";
    print "\torig:  $orig_name\n";
    print "=======================\n\n";

    #($new_name = $orig_name) =~ $regex;
    #print "new:  $new_name\n";
    $orig_name =~ $regex;
    print "new:  $orig_name\n";

    #return (($new_name) = $orig_name =~ $regex);

    #if ( $orig_name =~ $regex ) {
        #print "it was a success!\n";
    #} else {
        #print "nope!\n";
    #}

}


sub from_file {
	# If a file is provided, do this
	my $plan = shift;
	my $explog_data = shift;

	open( my $plan_fh, "<", $$plan ) || die "Can't open the plan data file: $!";
	chomp( my @plan_data = <$plan_fh> );
	close( $plan_fh );

	# Test that the plan file looks right
	if ( ! grep { /short_id: \w{5}/ || /guid: \w{36}/ } @plan_data ) {
		print "ERROR: The format of the plan file does not look correct.  Check the file's format\n\n";
		print $usage;
		exit 1;
	}

	# Load up a hash of the incoming data
	my %id_data = map { split( /: /, $_ ) } @plan_data;

	open( my $out_fh, ">", "explog.txt" ) || die "Can't create explog.txt to write to: $!";
	
	# Make the changes
	for my $line ( @$explog_data ) {
		$line =~ s/^(Planned Run Short ID.*:).*/$1 $id_data{'short_id'}/ if ( $line =~ /Short ID/ );
		$line =~ s/^(Planned Run GUID:).*/$1 $id_data{'guid'}/ if ( $line =~ /GUID/ );
	}

	print $out_fh $_ for @$explog_data;
	close( $out_fh );
	return;
}
