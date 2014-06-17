#!/usr/bin/perl
# Use a SampleKey file to rename samples by replacing the "IonXpress_xxx" string with the sample name
# from the sampleKey.txt file.

use warnings;
use strict;
use Getopt::Long;
use File::Basename;
use File::Copy;
use Data::Dump;

my $scriptname = basename($0);
my $version = "v0.2.1_042114";
my $description = <<"EOT";
Using a sampleKey.txt file, rename files by associating them with the samples indicated in the sampleKey 
file.  
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] -s <sampleKey.txt> <files_to_rename> 
    -n, --no-act    Perform a dry run of the rename process.
    -s, --sk        Sample key file to use
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $sk_file;
my $noact;

GetOptions( "sk=s"          => \$sk_file,
            "version"     => \$ver_info,
            "help"        => \$help,
            "no-act"      => \$noact, 
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

if ( ! $sk_file ) {
    print "ERROR: You must load a samplekey file!\n\n";
    print $usage;
    exit 1;
}

# Make sure enough args passed to script
if ( scalar( @ARGV ) < 1 ) {
    print "ERROR: No files loaded!\n"; 
    print "$usage\n";
    exit 1;
}
#########------------------------------ END ARG Parsing ---------------------------------#########

#my $samplekey = shift;
my $samplekey = $sk_file;
my @input_files = @ARGV;

open( my $sk_fh, "<", $samplekey ) || die "Can't open the sampleKey.txt file for reading: $!";

# Crude check to be sure we have a valid sampleKey file; probably not the best way, but good enough
if ( ! grep { /IonXpress_\d+\s+\w+$/ } <$sk_fh> ) {
    print "ERROR: File '$samplekey' does not appear to be a sampleKey.txt file. Check the file and try again.\n\n";
    print $usage;
    exit 1;
}
seek $sk_fh, 0, 0;
my %sample_hash = map{ split } <$sk_fh>;
close $sk_fh;

#dd \%sample_hash;
#exit;

for my $file ( @input_files ) {
    (my $barcode = $file ) =~ s/.*?(IonXpress_\d+).*/$1/;
    if ( exists $sample_hash{$barcode} ) {
        (my $new_name = $file) =~ s/IonXpress_\d+/$sample_hash{$barcode}/;
        ( $noact ) ? (print "$file renamed as $new_name\n") : (move( $file, $new_name) );
    } else {
        warn "File '$file' does not have a sample associated with barcode '$barcode' in the sampleKey.txt file.  Skipping...\n";
    }
}
