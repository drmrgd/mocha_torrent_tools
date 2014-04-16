MoCha TS Admin and Data Analysis Tools
==

This is a repository of my tools used for Torrent Server administration and data migration / analysis
work.

List of Programs
--

The current programs that are in this repository with a brief description.  See the individual program's
help text for more details.

- <b>batch_loader.pl</b>: From a SQL Run Plan dump file, batch run change of plans on experiments to be
batched. <i>Still working on this.  Want to add ability to actually launch the analysis too</i>

- <b>batch_planner.pl</b>: Create a CSV file to upload into the Torrent Browser run planner in order to 
batch process several samples.  Currently only have 32 barcodes set up, and this will not add in the 
rest of the information required to run (e.g. plan template, plugins, reference, etc.).  Can easily
copy and paste this into a fully formatted template that's been downloaded from the TS.  Run before 
batch_loader.pl.

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

- <b>mocha_mirror.pl</b>: Script to mirror processed Ion Torrent report data to an external harddrive.  The 
program will store as many runs as can fit on the drive by assessing the du of the drive and pushing the 
newest runs onto the stack.  This will, of course, remove older runs that won't fit.

- <b>vcfExtractor.pl</b>: A program to extract data from VCF files generated from the TS v4.0.  Can either
extract the whole dataset or a specific variant by position, and print out a simplified variant call
listing.
