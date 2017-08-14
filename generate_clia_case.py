#!/usr/bin/python
# Auto generate an entry in the clia_case_list.csv file in order to make adding the batchwise MSNs a little easier.
import sys
import os
import re
import subprocess
import shutil
import argparse

from pprint import pprint as pp

version = '2.0.0_081417'

def get_opts():
    parser = argparse.ArgumentParser(
        formatter_class = lambda prog: argparse.HelpFormatter(prog, max_help_position=100, width=200),
        description='''
        Program to generate a new entry in the CLIA case list register for a study. This will register the 
        run name, the sample list, and create a new case number that can be used for the archive process.
        ''')
    parser.add_argument('rundir', metavar='<run_directory>', 
        help='Directory name for the sequencing run we are going to archive')
    parser.add_argument('caselist', metavar='<caselist.csv>',
        help='CLIA caselist CSV to which we want to add the new entry')
    parser.add_argument('-p', '--pedmatch', action='store_true',
        help='Run is from Pediatric MATCH study and MSNs do not follow normal convention.')
    parser.add_argument('-v', '--version', action='version', version = '%(prog)s - ' + version)
    args = parser.parse_args()
    return args

def gen_casenum(caselist):
    with open(caselist) as fh:
        last_entry = fh.readlines()[-1]
        project,number = last_entry.split(',')[0].split('-')
        next_num = "{0:05d}".format(int(number) + 1)
        next_case = project +'-'+ str(next_num)
        return next_case

def get_msn_list(rundir,pedmatch):
    params_file = rundir + '/ion_params_00.json'
    p = subprocess.Popen(
        ['sampleKeyGen.pl', '-p', '-r', '-f', params_file], 
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    result,error = p.communicate()
    msn_list = dict([x.split('\t') for x in result.split('\n') if x]) 

    # If we're running ped match, we don't get the MSN string. This is pretty bad, but nothing we can do
    # Just going to have to assume that [0-9]{5}-[DR]NA is going to always be a ped match sample.
    uniq_msn_set = ()
    if pedmatch:
        sys.stderr.write('INFO: This is a pediatric MATCH run.\n')
        msn_regex = re.compile('^10[0-9]{3}-[DR]NA')
        msns = [v for v in msn_list.values() if re.search(msn_regex,v)]
    else:
        #uniq_msn_set = set(v[:-4] for v in msn_list.values() if v.startswith('MSN'))
        msns = [v for v in msn_list.values() if v.startswith('MSN')]

    uniq_msn_set = set(x[:-4] for x in msns)
    return [x for x in uniq_msn_set]

def gen_case_list_string(run_name,msns,new_casenum,caselist):
    msn_list = ','.join(msns)
    new_entry=','.join([new_casenum,msn_list,run_name])
    print "Adding new entry to case list file:\n{}".format(new_entry)
    with open(caselist,'a') as fh:
        fh.write(','.join([new_casenum,msn_list,run_name]))
        fh.write('\n')

def get_runname(rundir):
    try:
        run_name = re.search('^Auto_user_(.*?\w{3})_\d+_\d+\/?$',os.path.basename(rundir.rstrip('/'))).group(1)
    except AttributeError:
        sys.stdout.write("WARN: atypical run name '%s'.  Using full dirname as run name.\n" % rundir)
        run_name = rundir
    return run_name

if __name__ == '__main__':
    opts = get_opts()

    # Make a backup of the current CLIA caselist file before we proceed just in case bad things happen while we're 
    # editing it.
    (path,cfile_name) = os.path.split(opts.caselist)
    bak_file = '.' + cfile_name + '.bak'
    shutil.copy2(opts.caselist,os.path.join(path, bak_file))

    run_name = get_runname(opts.rundir)
    msn_list = get_msn_list(opts.rundir,opts.pedmatch)
    if len(msn_list) < 1:
        sys.stderr.write('ERROR: No valid MSNs found in run plan! Can not continue.\n')
        sys.exit(1)

    next_casenum = gen_casenum(opts.caselist)

    gen_case_list_string(run_name,msn_list,next_casenum,opts.caselist)
