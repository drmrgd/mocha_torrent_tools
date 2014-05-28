#!/usr/bin/perl
# use 'change_of_plans.pl' with a run plan dump from the SQL DB to batch associate runs that need
# to be reanalyzed. Need 'plans.txt' from SQL dump (see notes on how to get), after creating batch
# run plans.  Run names will come from directories resulting from tarballs generated
#
# 4/16/2014 - D Sims
########################################################################################################

use warnings;
use strict;

use Data::Dump;
use Getopt::Long;
use Cwd;
use Text::CSV;
use File::Basename;

my $scriptname = basename($0);
my $version = "v0.1.041614";
my $description = <<"EOT";
After pulling out a planned experiments dump of the SQL database, batch run change of plans on a 
list of experiments input into the program in preparation for reanalysis.
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] <sql_runplan_dump_file> <experiment_dir>
    -v, --version   Version information
    -h, --help      Print this help information
EOT

my $help;
my $ver_info;

GetOptions( "version"     => \$ver_info,
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
open( my $sql_fh, "<", $sql_dump ) || die "Can't open the SQL CSV file for processing: $!";
my $sql_csv = Text::CSV->new( {
        sep_char  => ',',
        eol       => '\n',
});

my %plan_data;
while (<$sql_fh>) {
    if ( $sql_csv->parse($_) ) {
        my @fields = $sql_csv->fields();
        #$plan_data{$fields[1]} = { short_id => $fields[3], guid => $fields[2] } if ( $fields[5] eq "planned" && $fields[1] =~ /Reanalysis/ );
        if ( $fields[5] eq 'planned' && $fields[1] =~ /Reanalysis.*/ ) {
            $plan_data{$fields[1]} = { 
                short_id   => $fields[3], 
                guid       => $fields[2],
                state      => $fields[5] 
            };
        }
    }
}


#dd %plan_data;
#exit;

# Get list of runs to process
# TODO: Can I make this better?  Let's just glob dirs for now.
#opendir( my $dir_handle, getcwd() );
#my @runs_list = grep { s/(.*?\.\d+)\.tar\.gz/$1/ } readdir($dir_handle);
my @runs_list = @ARGV;

for my $run ( @runs_list ) {
    (my $rundir = $run) =~ s/Auto_user_(.*?)/$1/;
    chdir "/results/uploads/$rundir" or do {
        print "ERROR: Can't stat '$rundir'; $!\n";
        exit 1;
    };
    #print "pwd: " . getcwd(), "\n";
    #exit;
    #my $explog = "$run/explog.txt";
    (my $new_name = $run) =~ s/(.*?)(:?_\d+)?_\d+\.\d{8}/Reanalysis_$1/;

    #print "run:\t$run\n";
    #print "new name:\t$new_name\n";

    my $new_sid = $plan_data{$new_name}->{short_id};
    my $new_guid = $plan_data{$new_name}->{guid};

    #print "New short id:\t$new_sid\n"; 
    #print "New GUID:\t$new_guid\n";
    #print "\n";
    #next;
    
    print "Updating the explog file for '$run'...\n";
    if ( system( "change_of_plans -s $new_sid -g $new_guid 'explog.txt'" ) != 0 ) {
        warn "Issue encountered with '$run'; Skipping and moving on...\n\n";
    }
}
