MoCha TS Admin and Data Analysis Tools
==

This is a repository of my tools used for Torrent Server administration and data migration / analysis
work.

List of Programs
--

The current programs are in this repository with a brief description.  See the individual program's
help text for more details

- dataCollector.pl:  A program to extract Ion Torrent Runs for importation to another TS, or to
archive for permanent storage on a secure server for historic purposes

- from_archive_analyze.pl: A program to extract the data exported from dataCollector and launch
a reanalysis of the experiment using the current software version

- vcfExtractor.pl: A program to extract data from VCF files generated from the TS v4.0.  Can either
extract the whole dataset or a specific variant by position, and print out a simplified variant call
listing.
