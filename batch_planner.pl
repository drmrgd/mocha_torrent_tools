#!/usr/bin/perl
# Create batch job from sample Key file.  This is completely reworked from the original and should 
# now be pretty usable.  For now have to cut and paste this into the right format.  Can add the rest
# of the information to be generated later?
#
# Created: 12/19/2013 - D Sims
######################################################################################################

use warnings;
use strict;

use Getopt::Long;
use File::Basename;
use Data::Dump;

#( my $scriptname = $0 ) =~ s/^(.*\/)+//;
my $scriptname = basename($0);
my $version = "v0.1.041514";
my $description = <<"EOT";
Create a batch run plan for an Ion Torrent Reanalysis.  This script will just use barcodes 001 - 032 to
create the template necessary for a batch upload to the Torrent Browser run plan API.  For now the rest
of the necessary data (plugins, params, etc) are missing.  But, you can cut and paste this into the CSV
file that is generated from the TB and start from there.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] <input_file>
    -p, --prefix    Prefix to add to the beginning of new renalysis name (DEFAULT: 'Renalysis')
    -t, --tab       Create tab delimited output instead of CSV.
    -o, --output    Send output to custom file.  Default is STDOUT.
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $outfile;
my $prefix = "Reanalysis";
my $tab;

GetOptions( "prefix=s"    => \$prefix, 
            "tab"         => \$tab,
            "output=s"    => \$outfile,
            "version"     => \$ver_info,
            "help"        => \$help )
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
#if ( scalar( @ARGV ) < 1 ) {
	#print "ERROR: Not enough arguments passed to script!\n\n";
	#print "$usage\n";
	#exit 1;
#}

# Write output to either indicated file or STDOUT
my $out_fh;
if ( $outfile ) {
	open( $out_fh, ">", $outfile ) || die "Can't open the output file '$outfile' for writing: $!";
} else {
	$out_fh = \*STDOUT;
}

#########------------------------------ END ARG Parsing ---------------------------------#########

my @expt_dirs= @ARGV;

# Check to be sure we have a sampleKey.txt file for each one or else we can't proceed.
for my $dir ( @expt_dirs ) {
    opendir( my $dir_fh, $dir );
    #print "processing $dir\n";
    if ( ! grep { -f "$dir/sampleKey.txt" } readdir($dir_fh) ) {
        print "ERROR: no sample key file found in '$dir'\n";
        exit 1;
    }
}

my %data;
for my $expt ( @expt_dirs ) {
    # XXX Trim more: take it all the way to the tech initials
    #(my $runname = $expt) =~ s/(.*?)(:?_\d+)?_\d+\.\d{8}\/?$/${prefix}_$1$2/;
    (my $runname = $expt) =~ s/(.*?\d+.\w+).*\d{8}?$/${prefix}_$1/;
    open( my $sk_fh, "<", "$expt/sampleKey.txt" ) || die "Can't open the sampleKey.txt file: $!";
    $data{$runname} = { map{ chomp; split( /\t/, $_) } <$sk_fh> };
}

dd %data;
exit;

my %agg_data;
my @bc_list;
for ( my $num = 1; $num <= 32; $num++ ) {
    my $barcode = "IonXpress_" . pad_numbers(\$num);
    push( @bc_list, $barcode );
    for my $run ( keys %data ) {
        if ( $data{$run}->{$barcode} ) {
            $agg_data{$run}->{$barcode} = $data{$run}->{$barcode};
        } else {
            $agg_data{$run}->{$barcode} = '';
        }
    }
}

#dd %agg_data;
#exit;

# Use custom delimiter.
my $delim;
( $tab ) ? $delim = "\t" : $delim = ",";

select $out_fh;
# Create Barcode list header
print " $delim";
print join( $delim, @bc_list );
print "\n";

# print out the run data
for my $run( sort keys %agg_data ) {
    print $run . $delim;
    for my $barcode ( sort keys %{$agg_data{$run}} ) {
        print $agg_data{$run}->{$barcode} . $delim;
    }
    print "\n";
}

sub pad_numbers {
    my $number = shift;
    return sprintf( "%03d", $$number );
}
