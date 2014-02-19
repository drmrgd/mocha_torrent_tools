#!/usr/bin/perl
# Script to pull out column information from a VCF file.  Can also grab variant information
# based on a position lookup using the '-p' option.  
#
# Need to make sure to install the latest version of VCF Tools to avoid generic Perl error 
# message in output.  Can build from source, or I built a .deb file to installed it on 
# Debian systems.
#
# HISTORY:
#   2/21/2013  (v1.0.0)  - Original Script (v1.0.0)
#   10/22/2013 (v2.0.0)  - Updated to add CLI options along with a position lookup (v2.0.0)
#   10/30/2013 (v2.3.0)  - Fixed formatting issue to dynamically change with actual printed variants 
#                          instead of with all variants possible.  
#                          Added batch processing with lookup file.
#                          Added the ability to also look up positions based on shortened strings 
#                          (fuzzy lookups).
#   12/17/2013 (v3.0.0)  - Modified to work with TSv4.0 VCF files.
#   12/18/2013 (v3.0.1)  - Bug fix in format function
#   01/06/2014 (v3.0.2)  - Use FDP for total coverage rather than use sum of FAO and FRO.  Works
#                          better with multiple genotype alleles.
#   02/18/2014 (v3.1.0)  - Fixed bug when multiple alleles are listed in the VCF file at the same 
#                          position, only 1 of the entries was returned.  Now both should be returned
#   02/19/2014 (v3.2.0)  - Added back the algorithm for running TVCv3.2 VCF files.  Will be removed
#                          later when TVCv4.0 fully implemented.
#
# TODO:
#   - Fix fuzzy lookup algorithm:
#       - Doesn't quite work the way you would expect with limiting positions
#
# D Sims 2/21/2013
#################################################################################################

use warnings;
use strict;
use Getopt::Long;
use List::Util qw{ sum min max };
use Data::Dumper;
use Data::Dump;

( my $scriptname = $0 ) =~ s/^(.*\/)+//;
my $version = "v3.2.1";
my $description = <<"EOT";
Program to extract fields from an Ion Torrent VCF file generated by TVCv4.0.  By default the program 
will extract the following fields:

     CHROM:POS REF ALT Filter Filter_Reason VAF RefCov AltCov

This can only be modified currently by the hardcoded variable '\$vcfFormat'.

This version of the program also supports extracting only variants that match a position query
based on using the following string: chr#:position. Multiple positions can be searched by listed 
each separated by a space and wrapping the whole query in quotes:

        vcfExtractor -p "chr17:29553485 chr17:29652976" <vcf_file>

For batch processing, a lookup file with the positions (one on each line in the same format as
above) can be passed with the '-f' option to the script:

        vcfExtractor -f lookup_file <vcf_file>
EOT

my $usage = <<"EOT";
USAGE: $0 [options] <input_vcf_file>
    -o, --output    Send output to custom file.  Default is STDOUT.
    -p, --pos       Position to extract from the VCF file.  Default is to print the whole file.
    -l, --lookup    Read a list of variants from a file to query the VCF. 
    -f, --fuzzy     Used with '-p'. Less precise (fuzzy) position match, using 1 for trim last digit 
                    from the position query, 2 for trim last two digits the the position query, 
                    and so on.  Can not go higher than 3!
    -r, --ref       Output reference calls.  Ref calls filtered out by default
    -t, --tvc32     Run the script using the TVCv3.2 VCF files.  Will be deprecated once TVCv4.0 fully
                    implemented
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $outfile;
my @positions = ();
my $lookup;
my $fuzzy;
my $no_reference = 1;
my $tvc32;

GetOptions( "output=s"    => \$outfile,
            "pos=s"       => \@positions,
            "tvc32"       => \$tvc32,
            "lookup=s"    => \$lookup,
            "fuzzyr=i"    => \$fuzzy,
            "ref=i"       => \$no_reference,
            "version"     => \$ver_info,
            "help"        => \$help )
        or do { print "\n$usage\n"; exit 1; };

sub help {
	printf "%s - %s\n\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub version {
	printf "%s - %s\n", $scriptname, $version;
	exit;
}

help if ( $help );
version if $ver_info;

# Double check that fuzzy option is combined intelligently with a position lookup.
if ( $fuzzy && $fuzzy > 3 ) {
    print "ERROR: Can not trim more than 3 digits from the query string.\n\n";
    print "$usage\n";
    exit 1;
}

if ( $fuzzy && $lookup ) {
    print "WARNING: A fuzzy lookup in batch mode may produce a lot of results! Continue? ";
    chomp( my $response = <STDIN> );
    exit if ( $response =~ /[(n|no)]/i );
    print "\n";
}
elsif ( $fuzzy && ! @positions ) {
    print "ERROR: must include position information with the '-f' option\n\n";
    print "$usage\n";
    exit 1;
}

# Make sure enough args passed to script
if ( scalar( @ARGV ) < 1 ) {
    print "ERROR: No VCF file passed to script!\n\n";
    print "$usage\n";
    exit 1;
}

# Run parse the lookup file and add variants to the filter if processing batch-wise
batch_lookup(\$lookup, \@positions) if $lookup;

# If a using lookup positions, double check the format is correct
my @coords= map {split} @positions;
if ( @coords ) {
    ( /\Achr\d+:\d+$/ ) ? next 
        :  do { print "Please use the following format for query strings 'chr#:position'\n"; exit 1; } for @coords;
}

# Write output to either indicated file or STDOUT
my $out_fh;
if ( $outfile ) {
	open( $out_fh, ">", $outfile ) || die "Can't open the output file '$outfile' for writing: $!";
} else {
	$out_fh = \*STDOUT;
}

#########------------------------------ END ARG Parsing ---------------------------------#########

my $inputVCF = shift;

# Check VCF file to make sure it's valid
open( my $vcf_fh, "<", $inputVCF );
my $head = <$vcf_fh>;
if ( $head !~ /VCFv4/ ) {
    print "ERROR: '$inputVCF' does not appear to be a valid VCF file or does not have a header.\n\n";
    print "$usage\n";
    exit 1;
}
close( $vcf_fh );

# Allow for running v3.2 VCF files.  Will be removed later.
if ($tvc32) {
    my %vcf32_data = test_32( \$inputVCF );
    dd \%vcf32_data;
    exit;
}

# Get the data from VCF Tools
my $vcfFormat = "'%CHROM:%POS\t%REF\t%ALT\t%FILTER\t%INFO/FR\t[%GTR\t%GT\t%FDP\t%FRO\t%FAO]\n'";
my @extracted_data = qx/ vcf-query $inputVCF -f $vcfFormat /;

#dd @extracted_data;
#exit;

my %vcf_data = parse_data( \@extracted_data );

# Filter and format extracted data or just format and print it out.
(@positions) ? filter_data(\%vcf_data, \@coords) : format_output( \%vcf_data );

sub test_32 {
    # sub routine to process v3.2 VCF files.  Will go away eventually.
    my $vcf = shift;
    my %parsed_data;

    #my $format = "'%CHROM:%POS\t%REF\t%ALT\t%INFO/Bayesian_Score\t[%GT\t%DP\t%AD]\n'";
    my $format = "'%CHROM:%POS\t%REF\t%ALT\t%INFO/Bayesian_Score\t[%AD]\n'";
    
    my @data = qx/ vcf-query $$vcf -f $format /;

    for ( @data ) {
        my ( $pos, $ref, $alt, $filter, $cov ) = split;
        my ( $rcov, $acov ) = split( /,/, $cov );
        my $varid = join( ":", $pos, $ref, $alt );

        my $tot_coverage = $rcov + $acov;
        my $vaf = vaf_calc( \$filter, \$tot_coverage, \$rcov, \$acov ); 

        push( @{$parsed_data{$varid}}, $pos, $ref, $alt, $filter, $vaf, $tot_coverage, $rcov, $acov );
    }

    return %parsed_data;
}


sub parse_data {
    # Extract the VCF information and create a hash of the data.  
    my $data = shift;
    my %parsed_data;

    for ( @$data ) {
        my ( $pos, $ref, $alt, $filter, $reason, $gtr, $gt, $tot_coverage, $ref_cov, $alt_cov ) = split;

        $reason =~ s/^\.,//;

        # If the reference filter is on and the call is reference, move on.
        next if ( $no_reference == 1 && $gtr =~ /0\/0/ );

        # Let's seperate out any multiple allele lines into their own.
        my $var_id;
        my $vaf;

        if ( $alt =~ /,/ ) {
            my @alt_alleles = split( /,/, $alt );
            my @mult_cov = split( /,/, $alt_cov );
            for ( my $i = 0; $i <= $#alt_alleles; $i++ ) {
                $var_id = join( ":", $pos, $ref, $alt_alleles[$i] );

                # Get the VAF for this variant
                my $vaf = vaf_calc( \$filter, \$tot_coverage, \$ref_cov, \$mult_cov[$i] );

                push( @{$parsed_data{$var_id}}, $pos, $ref, $alt_alleles[$i], $filter, $reason, $gt, $vaf, $tot_coverage, $ref_cov, $mult_cov[$i] );
            }
        } else {
            $var_id = join( ":", $pos, $ref, $alt );
            my $vaf = vaf_calc( \$filter, \$tot_coverage, \$ref_cov, \$alt_cov );

            push( @{$parsed_data{$var_id}}, $pos, $ref, $alt, $filter, $reason, $gt, $vaf, $tot_coverage, $ref_cov, $alt_cov );
        }
    }

    return %parsed_data;
}

sub vaf_calc {
    # Determine the VAF
    my $nocall = shift;
    my $tcov = shift;
    my $rcov = shift;
    my $acov = shift;

    my $vaf;

    if ( $$nocall eq "NOCALL" ) {
        $vaf = '.';
    } else {
        $vaf = sprintf( "%.2f", 100*($$acov / $$tcov) );
    }

    return $vaf;
}

sub filter_data {
    # Filtered out extracted dataset.
    my $data = shift;
    my $filter = shift;
    my %filtered_data;
    my @fuzzy_pos;
    my %counter;

    if ( $fuzzy ) {

        my $re = qr/(.*).{$fuzzy}/;
        @fuzzy_pos = map { /$re/ } @$filter;

        for my $query ( @fuzzy_pos ) {
            for ( sort keys %$data ) {
                if ( $$data{$_}[0] =~ /$query(.*)?/ ) {
                    @{$filtered_data{$query}} = @{$$data{$_}};
                    $counter{$query} = 1;
                }
            }
        }
    } else {
        for my $variant ( keys %$data ) {
            if ( my ($query) = grep { ($_) =~ /$$data{$variant}[0]/ } @$filter ) {
                @{$filtered_data{$variant}} = @{$$data{$variant}};
                $counter{$query} = 1;
            }
        }
    }

    format_output( \%filtered_data );

    if ( $fuzzy ) {
        for my $query ( @fuzzy_pos ) {
            my $string = $query . ( '*' x $fuzzy );
            printf $out_fh "\n>>> No variant found at position: %s <<<\n", $string if ( ! exists $counter{$query} );
            }
        } else {
            for my $query ( @$filter ) {
                print $out_fh "\n>>> No variant found at position: $query <<<\n" if ( ! exists $counter{$query} );
            } 
        }
}

sub format_output {
    # Format and print out the results
    my $data = shift;
    my ( $w1, $w2, $w3 ) = field_width( $data );

    my $format = "%-19s %-${w1}s %-${w2}s %-10s %-${w3}s %-10s %-10s %-10s %-10s\n";
    my @header = qw( CHROM:POS REF ALT Filter Filter_Reason VAF TotCov RefCov AltCov );

    printf $out_fh $format, @header;

    for my $variant ( sort keys %$data ) {
        printf $out_fh $format, @{$$data{$variant}}[0,1,2,3,4,6,7,8,9];
    }
}

sub field_width {
    # Get the longest field width for formatting later.
    my $data_ref = shift;
    my $ref_width = 0;
    my $var_width = 0;
    my $filter_width= 0;

    for my $variant ( keys %$data_ref ) {
        my $ref_len = length( $$data_ref{$variant}[1] );
        my $alt_len = length( $$data_ref{$variant}[2] );
        my $filter_len = length( $$data_ref{$variant}[4] );
        $ref_width = $ref_len if ( $ref_len > $ref_width );
        $var_width = $alt_len if ( $alt_len > $var_width );
        $filter_width = $filter_len if ( $filter_len > $filter_width );
    }
    
    ( $filter_width > 13 ) ? ($filter_width += 4) : ($filter_width = 17);

    return ( $ref_width + 4, $var_width + 4, $filter_width);
}

sub batch_lookup {
    # Process a lookup file, and load up @filter
    my $file = shift;
    my $filter = shift;

    open( my $fh, "<", $$file ) or die "Can't open the lookup file: $!";
    chomp( @$filter = <$fh> );
    close($fh);

    return $filter;
}
