#!/usr/bin/perl
# Use a SampleKey file to rename samples by replacing the "IonXpress_xxx" string with the sample name
# from the sampleKey.txt file.
# 4/2014 - D Sims
#####################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long qw(:config bundling auto_abbrev no_ignore_case);
use File::Basename;
use File::Copy;
use Data::Dump;

my $scriptname = basename($0);
my $version = "3.0.0_092617";
my $description = <<"EOT";
Using a sampleKey.txt file, rename files by associating them with the samples indicated in the sampleKey 
file.  
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] <sampleKey.txt> <files_to_rename> 
    -k, --keep      Keep the barcode string and just add the sample ID to the name.
    -s, --string    Add an additional string to the sample name, right after the replaced barcode string
    -n, --no-act    Perform a dry run of the rename process.
    -t, --tagseq    Using new IonCodeTaq barcodes instead of IonXpress barcodes.
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $noact;
my $string;
my $keep;
my $tagseq;

GetOptions( "string|s=s"    => \$string,
            "tagseq|t"      => \$tagseq,
            "keep|k"        => \$keep,
            "no-act|n"      => \$noact, 
            "version|v"     => \$ver_info,
            "help|h"        => \$help,
    )
        or die $usage;

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
    print "ERROR: No files loaded!\n"; 
    print "$usage\n";
    exit 1;
}
#########------------------------------ END ARG Parsing ---------------------------------#########
my $samplekey = shift;
my @input_files = @ARGV;

open( my $sk_fh, "<", $samplekey ); 
my %sample_hash = map{ split } <$sk_fh>;
die "ERROR: No barcodes found in sampleKey.txt file!\n" unless grep {$_ =~ /(IonXpress|IonCodeTag)/} keys %sample_hash;
close $sk_fh;

if (grep {/IonCode/} keys %sample_hash and ! $tagseq) {
    print("ERROR: It looks like you have a sampleKey file with IonCodeTag barcodes, but have not selected the '-t' option.\n");
    exit 1;
}

for my $file ( @input_files ) {
    my ($barcode,$rest);
    ($tagseq) 
        ? (($barcode,$rest) = $file =~ /(IonCodeTag_\d{4})(.*)/) 
        : (($barcode,$rest) = $file =~ /(IonXpress_\d{3})(.*)/);

    unless ( exists $sample_hash{$barcode}) {
        print "File '$file' does not have a sample associated with barcode '$barcode' in the sampleKey.txt file. ";
        print "Skipping...\n";
        next;
    } 
    my $new_name = $sample_hash{$barcode};
    $new_name .= "_${string}"  if $string; # Adding custom string
    $new_name .= "_${barcode}" if $keep;   # Keeping orig barcode string in.
    $new_name .= $rest;
    ( $noact ) ? (print "$file renamed as $new_name\n") : (move( $file, $new_name) );
}
