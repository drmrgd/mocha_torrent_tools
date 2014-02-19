#!/usr/bin/perl
# Program to read in csv files derived from GeneMed output from the same sample analyzed by two different 
# pipelines (in this case TVC3.2 and TVC4.0), and generate some comparison data.  For now it's in the 
# form of a table of variant IDs that can be passed into R to draw a VennDiagram.  I've also bootstrapped
# R in this script to draw the Venn diagram directly to save effort.  Will report all variants (nonsynonymous) 
# and aMOIs.
#
# 12/13/2013 - Added aMOI only Venn Table generation
# 2/11/2014  - Generalized the Venn function so that we can arbitrarily run up to 4 comparisons at a time
#              without having to hard code the R call.  This will allow a single 'draw_venn' function to
#              handle all Venn diagrams instead of having to code multiple functions to handle all cases
#
# 2/18/2014 -  v2.1.0: Fixed bug in incorrectly passing elements to R.  Array counts going in instead of 
#              list of variants, making the Venn Diagrams incorrect.
#
# 2/19/2014 - v2.2.0:  Fixed the start with CSV option.  I added the command line option, but never actually
#                      coded a way to use it in the script!  Now should be able to start with a CSV file
#                      instead of an XLS file.
#
# TODO:
#     - Make the 'version' information more flexible for differnt binning of samples.  Maybe a CLI option?
#
# D Sims - 12/4/2013
#############################################################################################################
use strict;
use warnings;
use feature qw{ state };
use Getopt::Long;
use Cwd;
use Data::Dump;
use File::Basename;

( my $scriptname = $0 ) =~ s/^(.*\/)+//;
my $version = "v2.2.0";
my $description = <<"EOT";
Read in up to four XLS files generated from GeneMed or CSV files generated from those reports, and create
a venn diagram that compares the up to three samples.  This program was written with the Ion Torrent MPACT assay
in mind and uses the following nomeclature to correctly identify the file:

    <genemed_id>_<sample_name>_<run_num>_GM_<version>.xls

This was also originally written to compare TVC versions, and the version number of the software will be required 
to use as a category for the Venn diagrams genreated.  The version string should be written as "3.2", "4.0", etc.
Files with different names may not work as well as they may not associate the data correctly. 

To run this program, several perl modules and the xls2tab program must be installed.  This program will not
work under a Windows envrionment.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] <gm_report_1, 2, 3, etc>
    -c, --csv           Start with CSV file instead of XLS file. Be sure to use the same naming scheme as listed above
    -o, --output        Prefix to use for the output data.  Helpful in the case of CEPH analysis (for example).
    -v, --version       Version information
    -h, --help          Print this help information
EOT

my $help;
my $ver_info;
my $starting_input;
my $out_prefix;

GetOptions( "csv"         => \$starting_input,
            "output=s"    => \$out_prefix,
            "version"     => \$ver_info,
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
if ( @ARGV < 2 ) {
    print "ERROR: only ". scalar(@ARGV) . "files passed to script.  Need at least two to compare!\n\n";
    print "$usage\n";
    exit 1;
}

#########------------------------------ END ARG Parsing ---------------------------------#########
my %results;
my $cwd = getcwd;
my @datasets = @ARGV;
my ($csv_file, $analysis_version, $sample, $gm_id, $run_num);

# Read in GM reports and generate a csv file to be used with rest of analysis.
if ( $starting_input ) {
    foreach $csv_file ( @datasets ) {
        ($gm_id, $sample, $run_num, undef, $analysis_version) = split( /_/, basename( $csv_file ) );
        ($analysis_version) =~ s/\.csv//;
        import_csv( \$csv_file, \$analysis_version );
    }
} else {
    foreach ( @datasets) {
        ( $csv_file, $analysis_version, $sample ) = generate_csv( \$_ );
        import_csv( \$csv_file, \$analysis_version );
    }
}

$sample .= "_$out_prefix" if ( $out_prefix );
#print "new sample name: $sample\n";
#exit;

# Generate a output table that can be fed into R for drawing a Venn Diagram
my ($all_vars, $amois) = venn_table( \%results, \$sample );

# Draw all variants Venn Diagram
draw_venn( $all_vars, "$sample All Variants Comparison" );

# Draw aMOI Venns
draw_venn( $amois, "$sample aMOI Variants Comparison" );

sub generate_csv {
    # Use xls2csv to generate CSV file from GeneMed report
    use IPC::Cmd qw{ can_run run };

    my $input_file = shift;
    my ($gm_id, $sample_name, $run_num, $foo, $analysis_string) = split( /_/, basename( $$input_file ) );
    my ($version) = $analysis_string =~ /(.*?)\.xls/;
    my $new_name = join( "_", $sample_name, $run_num, $version ) . ".csv";

    my $prog_path = can_run( 'xls2csv' ) or 
        do { 
            print "ERROR: xls2csv is not installed. Install this program or manually create a CSV file and rerun with the '-c' option.\n";
            exit 1;
        };

    my $cmd = "$prog_path -x $$input_file -w 'Sequence Profiling Report' -c $new_name";
    my $buffer;
    if ( scalar run( command  => $cmd,
                     verbose  => 0,
                     buffer   => \$buffer,
                     timeout  => 20 )
    ) {
        print "Successfully created the CSV file: $new_name\n";
    } else {
        print "$buffer\n";
        exit 1;
    }
    return ($new_name, $version, $sample_name);
}

sub import_csv {
    # After using xls2csv, process resulting file into hash; will handle intial GM report 
    # as well as review report now.
    use Text::CSV;
    my $infile = shift;
    my $version = shift;

    my $csv = Text::CSV->new( { binary => 1 } );
    open( my $fh, "<", $$infile ) || die "Can't open the CSV file '$$infile' for reading: $!";
    while ( my $row = $csv->getline( $fh ) ) {
        next if ( grep { /Gene/ } @$row );
        my @data= @$row;
        map { s/\r\n//g } @data;
        if ( $data[0] =~ /not reviewed yet/ ) {
            next if ( $data[21] == 0 );
            $results{$$version}->{join( ":", @data[6,17,18,19,20] )} = [@data[5,6,17,18,19,20,21,22,]];
        } else {
            next if ( $data[16] == 0 );
            $results{$$version}->{join( ":", @data[1,12,13,14,15] )} = [@data[0,1,12,13,14,15,16,17,]];
        }
    }
    $csv->eof or $csv->error_diag();
    close $fh;
}

sub venn_table {
    # Make a table of variant call data useful for generating a Venn diagram.  Also pull out aMOIs
    # and store in a new hash to use for aMOI only Venn.
    
    my $data = shift;
    my $samp = shift;
    my (%all_vars, %amois);

    # Make some output file handles
    my $outfile = "$${samp}_venn_data.txt";
    open( my $allvars_out, ">", $outfile ) || die "Can't create the file '$outfile' for writing: $!";
    
    # All Variants Table
    for my $analysis_ver ( keys %$data ) {
        my $varcount = scalar( keys $$data{$analysis_ver} );
        print $allvars_out "TVCv$analysis_ver Variants ($varcount):\n";
        print $allvars_out "\t$_\n" for keys $$data{$analysis_ver};

        push( @{$all_vars{$analysis_ver}}, keys $$data{$analysis_ver} );

        # Get the aMOI subset variant calls into a new hash.
        push( @{$amois{$analysis_ver}}, grep { $$data{$analysis_ver}->{$_}[0] =~ /Yes/ } keys $$data{$analysis_ver} );
    }
    close $allvars_out;

    my $amoi_outfile = "$${samp}_aMOI_venn_data.txt";
    open( my $amoi_out, ">", $amoi_outfile ) || die "Can't create the file '$amoi_outfile' for writing: $!";

    for my $ver ( keys %amois ) {
        print $amoi_out "TVCv$ver aMOIs (" . scalar( @{$amois{$ver}} ) . "):\n";
        print $amoi_out "\t$_\n" for @{$amois{$ver}};
    }
    close $amoi_outfile;

    return (\%all_vars, \%amois );
}

sub draw_venn {
    # Bootstrap R and draw Venn Diagram directly from this script.  Can create up to 4 diagrams
    # with this function

    use Statistics::R;
    my $data = shift;
    my $title = shift;

    # Prepare data to pass to R
    my @categories = keys %$data;

    if ( @categories > 4 ) {
        print "ERROR: more than 4 datasets detected.  We can not use this to draw more than a 4-way Venn Diagram\n";
        exit 1;
    }
    elsif ( @categories < 1 ) {
        print "No data to be plotted.  Check the <sample>_venn_data.txt file to find out why.\n";
        exit;
    }

    (my $venn_outfile = $title) =~ s/\s/_/g;

    my @rbins = map { "TVC" . $_ } keys %$data;

    my @color_pallet = qw{ "red" "dodgerblue" "forestgreen" "yellow" };

    my $R = Statistics::R->new();
    $R->run( q/library("VennDiagram")/ );
    $R->run( qq/outfile <- "$venn_outfile.tiff"/ );

    # Load up the data into bins to create a list in R below
    my ( @elements, @colors );

    # TODO: What if no aMOIs in any run?  Write something to bail out in that case
    for my $i ( 0..$#categories ) {
        if ( @{$$data{$categories[$i]}} ) {
            my $label = sprintf( "cat%s_data", $i+1 );
            $R->set( "$label", [@{$$data{$categories[$i]}}] );
            push( @elements, "$rbins[$i] = $label" );
            push( @colors, $color_pallet[$i] ); # Use array to get the necessary number of colors
        }
    }

    # Create fill string
    my $fill = "c( " . join( ", ", @colors ) . " )";

    # Create R list elements string
    my $relems = "elements <- list( " . join( ", ", @elements ) . " )";
    $R->run( "$relems" );

    my $venn_plot = <<EOF;
    venn.diagram( elements,
                  filename = outfile,
                  euler.d = TRUE,
                  main = "$title",
                  main.fontface = "bold",
                  main.fontfamily = "sans",
                  main.cex = 1.2,
                  main.pos = c(0.5, 0.95),
                  scaled = TRUE,
                  fill = $fill,
                  lwd = 2,
                  alpha = 0.5,
                  cex = 1.0,
                  fontfamily = "sans",
                  cat.fontface = "bold",
                  cat.fontfamily = "sans",
                  #cat.dist = 0.1,
                  margin = 0.3 )
EOF
    $R->run( qq/$venn_plot/ );
    $R->stop();
}
