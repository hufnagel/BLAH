#!/bin/bash
#
# File:     lsf_submit.sh
# Author:   David Rebatto (david.rebatto@mi.infn.it)
#
# Revision history:
#     8-Apr-2004: Original release
#    28-Apr-2004: Patched to handle arguments with spaces within (F. Prelz)
#                 -d debug option added (print the wrapper to stderr without submitting)
#    10-May-2004: Patched to handle environment with spaces, commas and equals
#    13-May-2004: Added cleanup of temporary file when successfully submitted
#    18-May-2004: Search job by name in log file (instead of searching by jobid)
#     8-Jul-2004: Try a chmod u+x on the file shipped as executable
#                 -w option added (cd into submission directory)
#    21-Sep-2004: -q option added (queue selection)
#    29-Sep-2004: -g option added (gianduiotto selection) and job_ID=job_ID_log
# 
#
# Description:
#   Submission script for LSF, to be invoked by blahpd server.
#   Usage:
#     lsf_submit.sh -c <command> [-i <stdin>] [-o <stdout>] [-e <stderr>] [-w working dir] [-- command's arguments]
#
#
#  Copyright (c) 2004 Istituto Nazionale di Fisica Nucleare (INFN).
#  All rights reserved.
#  See http://grid.infn.it/grid/license.html for license details.
#

usage_string="Usage: $0 -c <command> [-i <stdin>] [-o <stdout>] [-e <stderr>] [-v <environment>] [-- command_arguments]"

if [ ! -z "$LSF_BIN_PATH" ]; then
    binpath=${LSF_BIN_PATH}/
else
    binpath=/usr/local/lsf/bin/
fi

confpath=${LSF_CONF_PATH:-/etc}
conffile=$confpath/lsf.conf

lsf_base_path=`cat $conffile|grep LSB_SHAREDIR| awk -F"=" '{ print $2 }'`

lsf_clustername=`${binpath}lsid | grep 'My cluster name is'|awk -F" " '{ print $5 }'`
logpath=$lsf_base_path/$lsf_clustername/logdir

logfilename=lsb.events

stgcmd="yes"
workdir="."

stgproxy="yes"

#default is to create file for gianduiotto 
giandu="yes"

###############################################################
# Parse parameters
###############################################################

while getopts "i:o:e:c:s:v:dw:q:g" arg 
do
    case "$arg" in
    i) stdin="$OPTARG" ;;
    o) stdout="$OPTARG" ;;
    e) stderr="$OPTARG" ;;
    v) envir="$OPTARG";;
    c) the_command="$OPTARG" ;;
    s) stgcmd="$OPTARG" ;;
    d) debug="yes" ;;
    w) workdir="$OPTARG";;
    q) queue="$OPTARG";;
    g) giandu="yes" ;;

    -) break ;;
    ?) echo $usage_string
       exit 1 ;;
    esac
done

# Command is mandatory
if [ "x$the_command" == "x" ]
then
    echo $usage_string
    exit 1
fi

shift `expr $OPTIND - 1`
arguments=$*

###############################################################
# Create wrapper script
###############################################################

# Get a suitable name for temp file
if [ "x$debug" != "xyes" ]
then
    tmp_file=`mktemp -q blahjob_XXXXXX`
    if [ $? -ne 0 ]; then
        echo Error
        exit 1
    fi
else
    # Just print to stderr if in debug
    tmp_file="/proc/$$/fd/2"
fi

#search for gianduiotto conf file

if [ "x$giandu" == "xyes" ] ; then
  giandupath=${GLITE_LOCATION:-/opt/glite}
  gianduconf=$giandupath/etc/dgas_gianduia.conf
  if [ -f $gianduconf ] ; then
    giandudir=`cat $gianduconf|grep chocolateBox| awk -F"=" '{ print $2 }'|sed 's/\"//g'`
  fi
fi

# Write wrapper preamble
cat > $tmp_file << end_of_preamble
#!/bin/bash
# LSF job wrapper generated by `basename $0`
# on `/bin/date`
#
# LSF directives:
#BSUB -L /bin/bash
#BSUB -N
#BSUB -u prelz@mi.infn.it
#BSUB -J $tmp_file
end_of_preamble

# Write LSF directives according to command line options

[ -z "$stdin" ]  || arguments="$arguments < $stdin"
[ -z "$stdout" ] || echo "#BSUB -o `basename $stdout`" >> $tmp_file
[ -z "$stderr" ] || echo "#BSUB -e `basename $stderr`" >> $tmp_file
[ -z "$queue" ]  || echo "#BSUB -q $queue" >> $tmp_file

[ -z "$stgcmd" ] || echo "#BSUB -f \"$the_command > `basename $the_command`\"" >> $tmp_file
[ -z "$stdout" ] || echo "#BSUB -f \"$stdout < `basename $stdout`\"" >> $tmp_file
[ -z "$stderr" ] || echo "#BSUB -f \"$stderr < `basename $stderr`\"" >> $tmp_file

proxy_string=`echo ';'$envir | sed -e 's/.*;[^X]*X509_USER_PROXY[^=]*\= *\([^\; ]*\).*/\1/'`

if [ "x$stgproxy" == "xyes" ] && [ "x$proxy_string" != "x" ] ; then
    if [ "x$workdir" != "x" ] ; then
        proxy_local_file=${workdir}"/"`basename $proxy_string`;
    else
        proxy_local_file=$proxy_string;
    fi
    if [ -r $proxy_local_file ] ; then
        echo "#BSUB -f \"$proxy_local_file > ${tmp_file}.proxy\"" >> $tmp_file
    fi
fi

# Set the required environment variables (escape values with double quotes)
if [ "x$envir" != "x" ]  
then
    echo "" >> $tmp_file
    echo "# Setting the environment:" >> $tmp_file
    echo "export `echo ';'$envir | sed -e 's/;\([^=]*\)=\([^;]*\)/ \1=\"\2\"/g'`" >> $tmp_file
    echo "# Finding a working globus-url-copy on AFS" >> $tmp_file
    echo "source /afs/infn.it/project/datamat/ui/setup_ui.sh" >> $tmp_file
#'#
fi

# Set the path to the user proxy
if [ "x$stgproxy" == "xyes" ]; then 
    echo "export X509_USER_PROXY=\`pwd\`/${tmp_file}.proxy" >> $tmp_file
fi

# Add the command (with full path if not staged)
echo "" >> $tmp_file
echo "# Command to execute:" >> $tmp_file
if [ "x$stgcmd" == "xyes" ] 
then
    the_command="./`basename $the_command`"
    echo "if [ ! -x $the_command ]; then chmod u+x $the_command; fi" >> $tmp_file
# God *really* knows why LSF doesn't like a 'dot' in here
# To be investigated further. prelz@mi.infn.it 20040911
    echo "\`pwd\`/`basename $the_command` $arguments" >> $tmp_file
else
    echo "$the_command $arguments" >> $tmp_file
fi

# Exit if it was just a test
if [ "x$debug" == "xyes" ]
then
    exit 255
fi

# Let the wrap script be at least 1 second older than logfile
# for subsequent "find -newer" command to work
sleep 1


###############################################################
# Submit the script
###############################################################
curdir=`pwd`

cd $workdir
if [ $? -ne 0 ]; then
    echo "Failed to CD to Initial Working Directory." >&2
    echo Error # for the sake of waiting fgets in blahpd
    exit 1
fi

jobID=`${binpath}bsub < $curdir/$tmp_file | awk -F" " '{ print $2 }' | sed "s/>//" |sed "s/<//"` # actual submission
retcode=$?


# find the correct logfile (it must have been modified
# *more* recently than the wrapper script)

logfile=""
log_check_retry_count=0

while [ "x$logfile" == "x" ]; do 

# Sleep for a while to allow job enter the queue
    sleep 2
    logfile=`find $logpath/$logfilename* -type f -newer $curdir/$tmp_file -exec grep -lP "\"JOB_NEW\" \"[0-9\.]+\" [0-9]+ $jobID " {} \;`

    if (( log_check_retry_count++ >= 5 )); then
        ${binpath}bkill $jobID
        echo "Error: job not found in logs" >&2
        echo Error # for the sake of waiting fgets in blahpd
        exit 1
    fi
done

# Don't trust bsub retcode, it could have crashed
# between submission and id output, and we would
# loose track of the job

# Search for the job in the logfile using job name

jobID_log=`grep \"JOB_NEW\" $logfile | awk -F" " '{ print $4" " $42 }' | grep $tmp_file|awk -F" " '{ print $1 }'`
if [ "$jobID_log" != "$jobID" ]; then
    echo "WARNING: JobID in log file is different from the one returned by bsub!" >&2
    echo "($jobID_log != $jobID)" >&2
    echo "I'll be using the one in the log ($jobID_log)..." >&2
    $jobID=$jobID_log
fi

# Compose the blahp jobID (log file + lsf jobid)
echo "lsf/`basename $logfile`/$jobID"

#Create info file for gianduiotto

if [ "x$giandu" == "xyes" ] && [ -f $gianduconf ]; then
  cp $proxy_string ${giandudir}/lsf_${jobID}.proxy
  cat > ${giandudir}/lsf_${jobID} <<end_gianduiotto
EDG_JOB_ID=$EDG_WL_JOBID
HLR_LOCATION=$HLR_LOCATION
end_gianduiotto
fi

# Clean temporary files
cd $curdir
rm $tmp_file

exit $retcode
