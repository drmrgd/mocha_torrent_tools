#!/usr/bin/perl
# Create batch job from sample Key file.  This is completely reworked from the original and should 
# now be pretty usable.  For now have to cut and paste this into the right format.  Can add the rest
# of the information to be generated later?
#
# Created: 12/19/2013 - D Sims
######################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long;
use File::Basename;
use Term::ANSIColor;
use JSON::XS;
use Data::Dump;

my $scriptname = basename($0);
my $version = "v1.3.1_092415-dev";
my $description = <<"EOT";
Create the template necessary for a batch upload to the Torrent Browser run plan API.  For now the rest
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
if ( scalar( @ARGV ) < 1 ) {
    print "ERROR: Not enough arguments passed to script!\n\n";
    print "$usage\n";
    exit 1;
}

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
=cut
for my $dir ( @expt_dirs ) {
    opendir( my $dir_fh, $dir );
    #print "processing $dir\n";
    if ( ! grep { -f "$dir/sampleKey.txt" } readdir($dir_fh) ) {
        print colored("WARNING: No sample key file found in '$dir'. Skipping...", 'bold yellow on_black'), "\n";
        next;
    }
}

my %data;
for my $expt ( @expt_dirs ) {
    (my $runname = $expt) =~ s/(.*?)\.\d{8}?$/${prefix}_$1/;
    open( my $sk_fh, "<", "$expt/sampleKey.txt" ) || die "Can't open the sampleKey.txt file: $!";
    $data{$runname} = { map{ chomp; split( /\t/, $_) } <$sk_fh> };
}
=cut

# Get sample info
my %data;
for my $expt ( @expt_dirs ) {
    (my $runname = $expt) =~ s/(.*?)\.\d{8}?$/${prefix}_$1/;
    my $params_file = "$expt/ion_params_00.json";
    ( -e $params_file ) ? 
        ($data{$runname} = get_sample_info(\$params_file)) : 
        print colored("WARNING: No ion_params_00.json file found in '$expt'. Skipping...\n", 'bold yellow on_black');
}
#dd %data;
#exit;

my %agg_data;
my @bc_list;
for ( my $num = 1; $num <= 96; $num++ ) {
    my $barcode = "IonXpress_" . pad_numbers(\$num);
    push( @bc_list, $barcode );
    for my $run ( keys %data ) {
        if ( $data{$run}->{$barcode} ) {
            #$agg_data{$run}->{$barcode} = $data{$run}->{$barcode};
            (my $sample = $data{$run}->{$barcode}) =~ s/\s/_/g;
            $agg_data{$run}->{$barcode} = $sample;
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

    print "${prefix}_$run" . $delim;
    for my $barcode ( sort keys %{$agg_data{$run}} ) {
        print $agg_data{$run}->{$barcode} . $delim;
    }
    print "\n";
}

sub pad_numbers {
    my $number = shift;
    return sprintf( "%03d", $$number );
}

# XXX
sub get_sample_info {
    my $json_file = shift;
    my $parsed_json;
    my %sample_data;

    open (my $json_fh, "<", $$json_file);
    # First read in the whole thing...
    my $json_data = JSON::XS->new->decode(<$json_fh>);
    # Then read in the barcode samples sub-JSON element.
    my $sample_json = JSON::XS->new->decode($$json_data{'barcodeSamples'});

    for my $sample ( keys %$sample_json ) {
        #print "$sample  =>  "; 
        my $barcodes = $$sample_json{$sample}->{'barcodes'};
        for my $barcode (@$barcodes) {
            my $type = $$sample_json{$sample}->{'barcodeSampleInfo'}{$barcode}{'nucleotideType'};
            #print "$sample => $type  =>  $barcode\n";
            $sample_data{$barcode} = "$sample;TYPE:$type";
        }
    }

    #dd \%sample_data;
    #exit;
    return \%sample_data;
}
