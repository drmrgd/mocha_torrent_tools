#!/usr/bin/perl
# use 'change_of_plans.pl' with a run plan dump from the SQL DB to batch associate runs that need
# to be reanalyzed. Need 'plans.txt' from SQL dump, which can be obtained by running: 
#     psql iondb ion
#     \copy rundb_plannedexperiment to 'plans.txt' csv
# 
# after creating batch run plans.  Run names will come from directories resulting from tarballs generated
#
# 4/16/2014 - D Sims
########################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long;
use Data::Dump;
use Cwd;
use Cwd 'abs_path';
use Text::CSV;
use Term::ANSIColor;
use File::Basename;

my $scriptname = basename($0);
my $version = "v1.1.060415";
my $description = <<"EOT";
After pulling out a planned experiments dump of the SQL database, batch run change of plans on a 
list of experiments input into the program in preparation for reanalysis.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] <sql_runplan_dump_file> <experiment_dir(s)>
    -p, --prefix    Custom prefix to use for run name.  This must match what's been entered in the run plan. (DEFAULT: Reanalysis).
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;
my $prefix = "Reanalysis";

GetOptions( "version"     => \$ver_info,
            "prefix=s"    => \$prefix,
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
if ( scalar( @ARGV ) < 2 ) {
    print "ERROR: Not enough arguments passed to script!\n\n";
    print "$usage\n";
    exit 1;
}

#########------------------------------ END ARG Parsing ---------------------------------#########
my $sql_dump = shift;
my %plan_data;

my $sql_csv = Text::CSV->new({ sep_char => ',', eol => '\n' });

open( my $sql_fh, "<", $sql_dump ) || die "Can't open the SQL CSV file for processing: $!";
while (<$sql_fh>) {
    if ( $sql_csv->parse($_) ) {
        my @fields = $sql_csv->fields();
        if ( $fields[5] eq 'planned' && $fields[1] =~ /Reanalysis.*/ ) {
            $plan_data{$fields[1]} = { 
                short_id   => $fields[3], 
                guid       => $fields[2],
                state      => $fields[5] 
            };
        }
    }
}
close $sql_fh;

#dd %plan_data;
#exit;

# Get list of runs to process, and add the full path
my @runs_list = map{ abs_path($_) } @ARGV;

#dd \@runs_list;
#exit;

print "prefix: $prefix\n";

for my $run ( @runs_list ) {
    chdir($run) or die "ERROR: Can't stat '$run': $!";
    (my $new_name = basename($run)) =~ s/(.*?)(?:\.\d{8})?/${prefix}_$1/;

    my $new_sid = $plan_data{$new_name}->{short_id};
    my $new_guid = $plan_data{$new_name}->{guid};

    print "Updating the explog file for '$run'...\n";
    if ( system( "change_of_plans -s $new_sid -g $new_guid 'explog.txt'" ) != 0 ) {
        print colored("Issue encountered with '$run'; Skipping and moving on...", 'bold yellow on_black'), "\n\n";
    }
    print "\n";
}
