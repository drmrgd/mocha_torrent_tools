#!/usr/bin/python
# Auto generate an entry in the clia_case_list.csv file in order to make adding the batchwise MSNs a little easier.
import sys
import os
import re
import subprocess
import shutil

version = '1.1.0_060917'

def usage():
    sys.stdout.write('USAGE: {} <run_directory> <clia_case_list.csv>\n'.format(os.path.basename(__file__)))

def gen_casenum(caselist):
    with open(caselist) as fh:
        last_entry = fh.readlines()[-1]
        data = last_entry.split(',')
        (project,number) = data[0].split('-')
        next_num = "{0:05d}".format(int(number) + 1)
        next_case = project +'-'+ str(next_num)
        return next_case

def get_msn_list(rundir):
    params_file = rundir + '/ion_params_00.json'
    p = subprocess.Popen(
        ['sampleKeyGen.pl', '-p', '-r', '-f', params_file], 
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    result,error = p.communicate()
    msn_list = dict([x.split('\t') for x in result.split('\n') if x]) 
    uniq_msn_set = set(v[:-4] for v in msn_list.values() if v.startswith('MSN'))
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
    if (sys.argv[1] == '-h'):
        usage()
        sys.exit()
    elif len(sys.argv) < 3:
        sys.stderr.write('ERROR: not enough args passed to script!\n')
        usage()
        sys.exit(1)

    rundir,caselist = sys.argv[1:]

    # Make a backup of the current CLIA caselist file before we proceed just in case bad things happen while we're 
    # editing it.
    (path,cfile_name) = os.path.split(caselist)
    bak_file = '.' + cfile_name + '.bak'
    shutil.copy2(caselist,os.path.join(path, bak_file))
    run_name = get_runname(rundir)
    msn_list = get_msn_list(rundir)
    next_casenum = gen_casenum(caselist)
    gen_case_list_string(run_name,msn_list,next_casenum,caselist)
