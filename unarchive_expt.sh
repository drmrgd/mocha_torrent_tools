#!/bin/bash
# From experiment archive (i.e. dataCollector output), unarchive a dataset so that we can analyze it
VERSION="0.0.1_062215"

expt_files=("$@")
if (( ${#expt_files[@]} < 1 )); then
    echo "ERROR: you must enter at least one tarball to process!"
    exit 1
fi

for expt in ${expt_files[@]}; do
    new_dir=${expt/\.tar\.gz/_foreign}
    if [[ ! -d $new_dir ]]; then
        echo -n "Creating a directory for results... "
        mkdir $new_dir
        echo "Done!"
    else
        echo "Expt directory already exists. Adding to current directory"
    fi
    echo -n "Unarchving tarball '$expt'... "
    tar -xvzf $expt -C $new_dir 2>&1
    echo "Done"
done
