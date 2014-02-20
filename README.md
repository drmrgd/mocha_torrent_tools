MoCha TS Admin and Data Analysis Tools
==

This is a repository of my tools used for Torrent Server administration and data migration / analysis
work.

List of Programs
--

The current programs that are in this repository with a brief description.  See the individual program's
help text for more details.

- <b>change_of_plans.pl</b>: Simple program to create a new explog.txt file from the original (making
a backup copy of the original first) that can be used to when reanalyzing an Ion Torrent Run.  This 
will allow the run plan in the DB to associate with the data in order to link plugins, sample names,
etc.

- <b>dataCollector.pl</b>:  A program to extract Ion Torrent Runs for importation to another TS, or to
archive for permanent storage on a secure server for historic purposes.

- <b>from_archive_analyze.pl</b>: A program to extract the data exported from dataCollector and launch
a reanalysis of the experiment using the current software version.

- <b>genemed_compare.pl</b>: Starting with either the XLS or a CSV derived from the XLS report, compare GeneMed
output from different versions of the Torrent Variant Caller.

- <b>vcfExtractor.pl</b>: A program to extract data from VCF files generated from the TS v4.0.  Can either
extract the whole dataset or a specific variant by position, and print out a simplified variant call
listing.
